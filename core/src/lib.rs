//! C bridge between RightType's OS-free core and the macOS app.
//!
//! The Swift side owns the OS work (the event tap, typing into the focused
//! app, switching input sources). This side owns every decision, made with
//! the same core calls, in the same order, as the Windows hook (and its
//! OS-free replay, `righttype::sim`): `WordBuffer` for the word in progress,
//! `policy::live_reading` + `render::delta` for showing Thai while a word is
//! still being typed (D-008), the `COMMIT_HORIZON` anchor (D-009),
//! `policy::detect_token` / `revise_converted` at a word boundary, `Recent`
//! for Shift+Backspace across several words, and the seed-phrase guard.
//!
//! Modes, as the app names them: Manual (Shift+Backspace only), Semi-auto
//! (`autofix`: judge a word when it ends) and Auto (`live` as well: fix Thai
//! typed on the English layout while it is typed).

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use righttype::buffer::{Key, WordBuffer};
use righttype::dict::{self, Dictionary};
use righttype::layout::{auto_convert, en_to_th};
use righttype::policy::{self, InputLayout, Reading};
use righttype::recent::Recent;
use righttype::render;
use righttype::secret::SeedTracker;
use zeroize::Zeroize;

/// Layout codes shared with Swift.
pub const RT_LAYOUT_NONE: i32 = -1;
pub const RT_LAYOUT_ENGLISH: i32 = 0;
pub const RT_LAYOUT_THAI: i32 = 1;

/// What an action did, for the little message the app shows.
pub const RT_NOTE_NONE: i32 = 0;
/// Fixed one word (Shift+Backspace or at a boundary).
pub const RT_NOTE_FIXED: i32 = 1;
/// Flipped `words` words back in one press.
pub const RT_NOTE_FIXED_MANY: i32 = 2;
/// Put the words back as they were.
pub const RT_NOTE_REVERTED: i32 = 3;
/// Shift+Backspace found nothing to flip.
pub const RT_NOTE_NOTHING: i32 = 4;

/// An edit for the app to make before the caret.
#[repr(C)]
pub struct RtAction {
    /// Backspaces to send first.
    pub backspaces: u32,
    /// UTF-8 text to type after them, or NULL (owned; release with `rt_action_clear`).
    pub insert: *mut c_char,
    /// A boundary key to send after `insert` (`' '`, `'\r'`, `'\t'`), or 0.
    pub boundary: u32,
    /// Input source to switch to afterwards (`RT_LAYOUT_*`).
    pub layout: i32,
    /// `RT_NOTE_*`.
    pub note: i32,
    /// Words flipped, for `RT_NOTE_FIXED_MANY`.
    pub words: u32,
    /// The key that led to this action never reaches the app (the edit
    /// stands in for it). When false the action is only a layout switch, made
    /// as the key goes through.
    pub swallow: bool,
}

impl RtAction {
    fn empty() -> Self {
        RtAction {
            backspaces: 0,
            insert: ptr::null_mut(),
            boundary: 0,
            layout: RT_LAYOUT_NONE,
            note: RT_NOTE_NONE,
            words: 0,
            swallow: true,
        }
    }
}

/// Who has decided what the word in progress is (`hook::TokenMark`).
#[derive(Clone, Copy, PartialEq, Eq)]
enum Mark {
    Plain,
    /// Anchored mid-word into Thai (D-009): the boundary judges the whole
    /// token again, with `revise_converted`.
    Converted,
    /// The typist flipped it with Shift+Backspace: left alone from here on.
    Decided,
}

/// A run RightType is currently showing as Thai (`hook::OwnedRun`).
struct Owned {
    rendered: String,
    /// Keystrokes the Thai reading has survived.
    stable: usize,
}

impl Drop for Owned {
    fn drop(&mut self) {
        self.rendered.zeroize();
    }
}

pub struct Engine {
    en: &'static Dictionary,
    th: &'static Dictionary,
    buf: WordBuffer,
    recent: Recent,
    mark: Mark,
    owned: Option<Owned>,
    seed: SeedTracker,
    /// Whether a flip-back teaches the dictionaries (off in tests, which share them).
    learns: bool,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine {
    pub fn new() -> Self {
        Engine {
            en: dict::english(),
            th: dict::thai(),
            buf: WordBuffer::new(),
            recent: Recent::new(),
            mark: Mark::Plain,
            owned: None,
            seed: SeedTracker::new(),
            learns: true,
        }
    }

    /// One printable key, named by the character it types on US QWERTY
    /// (upper case and symbols mean Shift is held), typed on `layout`.
    /// `Some` when the key is swallowed and the action typed instead.
    ///
    /// The key is kept as Kedmanee would type it rather than as the app shows
    /// it: macOS's Thai layout differs from Kedmanee on two keys (`` ` `` and
    /// `3`), and the conversion tables are Kedmanee's.
    pub fn key(&mut self, key: char, layout: InputLayout, live: bool) -> Option<RtAction> {
        let produced = match layout {
            InputLayout::UsQwerty => key,
            InputLayout::ThaiKedmanee => en_to_th(&key.to_string()).chars().next().unwrap_or(key),
        };
        self.recent.end_chain();
        self.buf.observe(Key::Char(produced));
        if live && self.mark == Mark::Plain && layout == InputLayout::UsQwerty {
            if let Some(action) = self.reconcile_run() {
                return Some(action);
            }
        }
        if self.buf.is_poisoned() || self.buf.current().is_empty() {
            self.mark = Mark::Plain;
        }
        None
    }

    /// Backspace. `Some` when it is swallowed: the run shown as Thai is
    /// re-rendered for the shorter keys instead.
    pub fn backspace(&mut self, live: bool) -> Option<RtAction> {
        self.buf.observe(Key::Backspace);
        // The text before the caret is no longer what `recent` recorded.
        self.recent.clear();
        if live && self.owned.is_some() && self.mark == Mark::Plain {
            if let Some(action) = self.reconcile_run() {
                return Some(action);
            }
        }
        if self.buf.is_poisoned() || self.buf.current().is_empty() {
            self.mark = Mark::Plain;
        }
        None
    }

    /// The caret may have moved (a click, an arrow, a shortcut, another app).
    /// A run shown as Thai stays on screen as it is.
    pub fn reset(&mut self, also_recent: bool) {
        self.buf.clear();
        self.mark = Mark::Plain;
        self.owned = None;
        if also_recent {
            self.recent.clear();
            self.seed.reset();
        }
    }

    /// The typist switched input source themselves: put the keys back in
    /// place of a run shown as Thai, and start a new word.
    pub fn switch_layout(&mut self) -> Option<RtAction> {
        let action = self.owned.take().map(|owned| {
            let delta = render::delta(&owned.rendered, self.buf.current());
            edit(delta.backspaces, &delta.insert, '\0', RT_LAYOUT_NONE, RT_NOTE_NONE, 0)
        });
        self.buf.clear();
        self.mark = Mark::Plain;
        action
    }

    /// Space, Return or Tab. `Some` when the word is changed (the boundary is
    /// then swallowed and re-sent by the action), or — `swallow` false — when
    /// a Thai run stands and only the layout follows it.
    pub fn boundary(&mut self, boundary: char, layout: InputLayout, autofix: bool) -> Option<RtAction> {
        let Some(mut word) = self.buf.observe(Key::Boundary) else {
            // Nothing (or something too long to judge) before the boundary.
            self.owned = None;
            if boundary != ' ' {
                self.recent.clear();
            }
            return None;
        };
        let mark = std::mem::replace(&mut self.mark, Mark::Plain);

        // What the app shows for this word.
        let mut screen = word.clone();
        if let Some(owned) = self.owned.take() {
            if !policy::run_goes_back(&word, &owned.rendered, self.en, self.th) {
                // The Thai reading stands; the boundary goes through as typed.
                self.remember(&owned.rendered, boundary, true);
                word.zeroize();
                screen.zeroize();
                return Some(RtAction { layout: RT_LAYOUT_THAI, swallow: false, ..RtAction::empty() });
            }
            // The word cannot end as Thai after all: it goes back to the keys
            // and is judged like any other.
            screen.zeroize();
            screen = owned.rendered.clone();
        }

        let converted = mark == Mark::Converted;
        let mut detection = match (autofix, mark) {
            (false, _) | (_, Mark::Decided) => None,
            (true, Mark::Converted) => policy::revise_converted(&word, self.en, self.th),
            (true, Mark::Plain) => policy::detect_token(&word, layout, self.en, self.th),
        };
        let corrected = detection.as_ref().map(|d| d.corrected.as_str());
        if self.seed.observe_candidate(&word, corrected) {
            detection = None;
        }

        let (mut text, kept_converted, to, note) = match detection {
            Some(d) => {
                let to = layout_code(&d.corrected);
                (d.corrected, true, to, RT_NOTE_FIXED)
            }
            // Thai typed in a wrong order (เเ for แ): the word put right.
            None if autofix && mark != Mark::Decided && layout == InputLayout::ThaiKedmanee => {
                match policy::thai_spelling(&word, self.th) {
                    Some(fixed) => (fixed, false, RT_LAYOUT_NONE, RT_NOTE_NONE),
                    None => (word.clone(), converted, RT_LAYOUT_NONE, RT_NOTE_NONE),
                }
            }
            None => (word.clone(), converted, RT_LAYOUT_NONE, RT_NOTE_NONE),
        };

        let action = (text != screen).then(|| {
            let delta = render::delta(&screen, &text);
            edit(delta.backspaces, &delta.insert, boundary, to, note, 1)
        });
        self.remember(&text, boundary, kept_converted);
        text.zeroize();
        word.zeroize();
        screen.zeroize();
        action
    }

    /// Shift+Backspace: put back the keys of a run shown as Thai; or flip the
    /// word in progress; or — right after a boundary — the word before it, then
    /// one more word on each further press.
    pub fn flip(&mut self) -> RtAction {
        if let Some(owned) = self.owned.take() {
            // The typist rejects the reading mid-word: keys back, and the rest
            // of this word is theirs.
            let delta = render::delta(&owned.rendered, self.buf.current());
            self.mark = Mark::Decided;
            return edit(delta.backspaces, &delta.insert, '\0', RT_LAYOUT_ENGLISH, RT_NOTE_REVERTED, 1);
        }

        let word = self.buf.current().to_string();
        if !word.is_empty() {
            let mut converted = auto_convert(&word);
            if converted == word {
                converted.zeroize();
                return note(RT_NOTE_NOTHING);
            }
            let action = edit(word.chars().count(), &converted, '\0', layout_code(&converted), RT_NOTE_FIXED, 1);
            // The word stays open: the typist can carry on, and the boundary
            // will not reinterpret it.
            self.buf.replace(&converted);
            self.mark = Mark::Decided;
            converted.zeroize();
            let mut word = word;
            word.zeroize();
            return action;
        }

        let Some(step) = self.recent.next_step(auto_convert) else {
            return note(RT_NOTE_NOTHING);
        };
        if step.insert.chars().count() + 1 == step.backspaces
            && step.restore.strip_suffix(step.boundary) == Some(step.insert.as_str())
        {
            // Nothing changes on screen (a number, say): move on to the word
            // before it.
            self.recent.commit(auto_convert);
            return self.flip();
        }
        if let Some(learned) = step.learn.as_deref().filter(|_| self.learns) {
            // Flipping back a word RightType converted itself says the
            // original was a real word. Remembered until the app quits.
            if learned.chars().any(|c| c.is_ascii_alphabetic()) {
                self.en.learn(learned);
            } else {
                self.th.learn(learned);
            }
        }
        let n = if step.reverts {
            RT_NOTE_REVERTED
        } else if step.words > 1 {
            RT_NOTE_FIXED_MANY
        } else {
            RT_NOTE_FIXED
        };
        let action = edit(step.backspaces, &step.insert, step.boundary, layout_code(&step.newest), n, step.words);
        self.recent.commit(auto_convert);
        action
    }

    /// `hook::reconcile_run`: show the run's best reading, given what the app
    /// shows for it now. `Some` when the key is swallowed and the action typed
    /// instead.
    fn reconcile_run(&mut self) -> Option<RtAction> {
        let holding = self.owned.is_some();
        if self.buf.is_poisoned() {
            // Too long to follow: what is on screen stays.
            self.owned = None;
            return None;
        }
        let mut run = self.buf.current().to_string();
        if !holding && run.is_empty() {
            return None;
        }
        let mut reading = policy::live_reading(&run, holding, self.en, self.th);
        if matches!(reading, Reading::Thai(_)) && self.seed.guarding() {
            reading = Reading::AsTyped;
        }
        // What the app shows: what we rendered, or — before we own the run —
        // the run minus the key that has not reached it yet.
        let mut assumed = match &self.owned {
            Some(o) => o.rendered.clone(),
            None if matches!(reading, Reading::AsTyped) => {
                run.zeroize();
                return None;
            }
            None => run.chars().take(run.chars().count().saturating_sub(1)).collect(),
        };
        let mut target = match &reading {
            Reading::AsTyped => run.clone(),
            Reading::Thai(thai) => thai.clone(),
        };
        let delta = render::delta(&assumed, &target);
        let mut action = edit(delta.backspaces, &delta.insert, '\0', RT_LAYOUT_NONE, RT_NOTE_NONE, 0);

        match reading {
            Reading::AsTyped => self.owned = None,
            Reading::Thai(mut thai) => {
                let stable = self.owned.as_ref().map_or(0, |o| o.stable) + 1;
                if stable >= policy::COMMIT_HORIZON {
                    // D-009: release the run, keep the token, and let the Thai
                    // layout carry the rest of the word.
                    self.owned = None;
                    self.buf.replace(&target);
                    self.mark = Mark::Converted;
                    action.layout = RT_LAYOUT_THAI;
                } else {
                    self.owned = Some(Owned { rendered: target.clone(), stable });
                }
                thai.zeroize();
            }
        }
        run.zeroize();
        assumed.zeroize();
        target.zeroize();
        Some(action)
    }

    /// Keep a finished word for Shift+Backspace. Not one ended by Tab: Tab
    /// often moves to another field (macOS does not tell the tap), and
    /// flipping would then retype the word there.
    fn remember(&mut self, word: &str, boundary: char, converted: bool) {
        if boundary == '\t' {
            self.recent.clear();
        } else {
            self.recent.push(word, boundary, converted);
        }
    }
}

fn edit(backspaces: usize, insert: &str, boundary: char, layout: i32, note: i32, words: usize) -> RtAction {
    RtAction {
        backspaces: backspaces as u32,
        insert: if insert.is_empty() {
            ptr::null_mut()
        } else {
            CString::new(insert).map_or(ptr::null_mut(), CString::into_raw)
        },
        boundary: boundary as u32,
        layout,
        note,
        words: words as u32,
        swallow: true,
    }
}

fn note(note: i32) -> RtAction {
    RtAction { note, ..RtAction::empty() }
}

/// The layout a piece of text ends in, to switch to after a fix.
fn layout_code(text: &str) -> i32 {
    let thai = text
        .chars()
        .rev()
        .find(|c| !c.is_ascii_punctuation())
        .map_or_else(|| text.chars().any(is_thai), is_thai);
    if thai {
        RT_LAYOUT_THAI
    } else {
        RT_LAYOUT_ENGLISH
    }
}

fn is_thai(c: char) -> bool {
    ('\u{0E00}'..='\u{0E7F}').contains(&c)
}

fn input_layout(code: i32) -> InputLayout {
    if code == RT_LAYOUT_THAI {
        InputLayout::ThaiKedmanee
    } else {
        InputLayout::UsQwerty
    }
}

/// Write `action` to `out`; true when there was one.
unsafe fn give(action: Option<RtAction>, out: *mut RtAction) -> bool {
    match (action, out.as_mut()) {
        (Some(action), Some(out)) => {
            *out = action;
            true
        }
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// C API. Every function takes the engine made by `rt_engine_new`, from one
// thread (the app's main thread). Functions that return bool fill `out` only
// when they return true; release it with `rt_action_clear`.

/// Load the dictionaries (a few hundred ms) and make an engine.
#[no_mangle]
pub extern "C" fn rt_engine_new() -> *mut Engine {
    Box::into_raw(Box::new(Engine::new()))
}

/// # Safety
/// `engine` came from `rt_engine_new` and is not used again.
#[no_mangle]
pub unsafe extern "C" fn rt_engine_free(engine: *mut Engine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}

/// A printable key. True: swallow the key and apply `out` instead.
///
/// # Safety
/// `engine` came from `rt_engine_new`; `out` is writable.
#[no_mangle]
pub unsafe extern "C" fn rt_key(engine: *mut Engine, key: u32, layout: i32, live: bool, out: *mut RtAction) -> bool {
    let (Some(e), Some(c)) = (engine.as_mut(), char::from_u32(key)) else {
        return false;
    };
    give(e.key(c, input_layout(layout), live), out)
}

/// Backspace. True: swallow it and apply `out` instead.
///
/// # Safety
/// `engine` came from `rt_engine_new`; `out` is writable.
#[no_mangle]
pub unsafe extern "C" fn rt_backspace(engine: *mut Engine, live: bool, out: *mut RtAction) -> bool {
    let Some(e) = engine.as_mut() else {
        return false;
    };
    give(e.backspace(live), out)
}

/// # Safety
/// `engine` came from `rt_engine_new`.
#[no_mangle]
pub unsafe extern "C" fn rt_reset(engine: *mut Engine, also_recent: bool) {
    if let Some(e) = engine.as_mut() {
        e.reset(also_recent);
    }
}

/// The user switched input source. True: apply `out` (there is no key to swallow).
///
/// # Safety
/// `engine` came from `rt_engine_new`; `out` is writable.
#[no_mangle]
pub unsafe extern "C" fn rt_layout_changed(engine: *mut Engine, out: *mut RtAction) -> bool {
    let Some(e) = engine.as_mut() else {
        return false;
    };
    give(e.switch_layout(), out)
}

/// Space, Return or Tab. True: apply `out`, and swallow the key if `out.swallow`.
///
/// # Safety
/// `engine` came from `rt_engine_new`; `out` is writable.
#[no_mangle]
pub unsafe extern "C" fn rt_boundary(
    engine: *mut Engine,
    boundary: u32,
    layout: i32,
    autofix: bool,
    out: *mut RtAction,
) -> bool {
    let (Some(e), Some(b)) = (engine.as_mut(), char::from_u32(boundary)) else {
        return false;
    };
    give(e.boundary(b, input_layout(layout), autofix), out)
}

/// Shift+Backspace. Always fills `out` (its `note` says what happened).
///
/// # Safety
/// `engine` came from `rt_engine_new`; `out` is writable.
#[no_mangle]
pub unsafe extern "C" fn rt_flip(engine: *mut Engine, out: *mut RtAction) {
    if let (Some(e), Some(out)) = (engine.as_mut(), out.as_mut()) {
        *out = e.flip();
    }
}

/// Wipe and release the text an action holds.
///
/// # Safety
/// `action` was filled by this library.
#[no_mangle]
pub unsafe extern "C" fn rt_action_clear(action: *mut RtAction) {
    if let Some(a) = action.as_mut() {
        if !a.insert.is_null() {
            let mut bytes = CString::from_raw(a.insert).into_bytes();
            bytes.zeroize();
            a.insert = ptr::null_mut();
        }
    }
}

/// Fix a whole piece of text (a selection): each mistyped word in it put back
/// in the right layout, the rest left as it is. When nothing looks mistyped,
/// the whole text is flipped, as asked.
///
/// # Safety
/// `text` is a NUL-terminated UTF-8 string. Release the result with `rt_string_free`.
#[no_mangle]
pub unsafe extern "C" fn rt_repair(text: *const c_char) -> *mut c_char {
    if text.is_null() {
        return ptr::null_mut();
    }
    let Ok(text) = CStr::from_ptr(text).to_str() else {
        return ptr::null_mut();
    };
    let mut fixed = righttype::repair::repair(text, dict::english(), dict::thai()).text;
    if fixed == text {
        fixed = auto_convert(text);
    }
    CString::new(fixed).map_or(ptr::null_mut(), CString::into_raw)
}

/// The character Kedmanee types on the key named by its US-QWERTY character,
/// or 0. The app uses it to recognise Thai input sources by what they type.
#[no_mangle]
pub extern "C" fn rt_kedmanee(key: u32) -> u32 {
    char::from_u32(key)
        .and_then(|k| en_to_th(&k.to_string()).chars().next())
        .filter(|&c| u32::from(c) != key)
        .map_or(0, u32::from)
}

/// # Safety
/// `s` came from this library.
#[no_mangle]
pub unsafe extern "C" fn rt_string_free(s: *mut c_char) {
    if !s.is_null() {
        let mut bytes = CString::from_raw(s).into_bytes();
        bytes.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use righttype::sim;

    fn insert(a: &RtAction) -> String {
        if a.insert.is_null() {
            return String::new();
        }
        unsafe { CStr::from_ptr(a.insert).to_str().unwrap().to_string() }
    }

    /// The engine driving a text box the way the Swift side does.
    struct Box {
        e: Engine,
        screen: String,
        layout: InputLayout,
        autofix: bool,
        live: bool,
    }

    impl Box {
        fn new(layout: InputLayout, autofix: bool, live: bool) -> Self {
            let mut e = Engine::new();
            e.learns = false;
            Box { e, screen: String::new(), layout, autofix, live }
        }

        fn apply(&mut self, a: RtAction) {
            for _ in 0..a.backspaces {
                self.screen.pop();
            }
            self.screen.push_str(&insert(&a));
            if a.boundary != 0 {
                self.screen.push(char::from_u32(a.boundary).unwrap());
            }
            if a.layout != RT_LAYOUT_NONE {
                self.layout = input_layout(a.layout);
            }
            let mut a = a;
            unsafe { rt_action_clear(&mut a) };
        }

        fn key(&mut self, k: char) {
            let produced = match self.layout {
                InputLayout::UsQwerty => k,
                InputLayout::ThaiKedmanee => en_to_th(&k.to_string()).chars().next().unwrap(),
            };
            match self.e.key(k, self.layout, self.live) {
                Some(a) => self.apply(a),
                None => self.screen.push(produced),
            }
        }

        fn backspace(&mut self) {
            match self.e.backspace(self.live) {
                Some(a) => self.apply(a),
                None => {
                    self.screen.pop();
                }
            }
        }

        fn boundary(&mut self, b: char) {
            match self.e.boundary(b, self.layout, self.autofix) {
                Some(a) => {
                    let swallow = a.swallow;
                    self.apply(a);
                    if !swallow {
                        self.screen.push(b);
                    }
                }
                None => self.screen.push(b),
            }
        }

        fn flip(&mut self) {
            let a = self.e.flip();
            self.apply(a);
        }

        /// Keys by US name: `<` Backspace, `^` Shift+Backspace, space/newline boundaries.
        fn keys(&mut self, seq: &str) -> &str {
            for c in seq.chars() {
                match c {
                    '<' => self.backspace(),
                    '^' => self.flip(),
                    ' ' | '\n' => self.boundary(c),
                    _ => self.key(c),
                }
            }
            &self.screen
        }
    }

    fn manual(layout: InputLayout) -> Box {
        Box::new(layout, false, false)
    }
    fn semi(layout: InputLayout) -> Box {
        Box::new(layout, true, false)
    }
    fn auto(layout: InputLayout) -> Box {
        Box::new(layout, true, true)
    }

    use InputLayout::{ThaiKedmanee as Thai, UsQwerty as Us};

    #[test]
    fn manual_flips_word_in_progress_and_back() {
        let mut b = manual(Us);
        assert_eq!(b.keys("l;ylfu^"), "สวัสดี");
        assert_eq!(b.layout, Thai);
        assert_eq!(b.keys("^"), "l;ylfu");
        assert_eq!(b.layout, Us);
    }

    #[test]
    fn manual_flips_recent_words_one_more_each_press() {
        let mut b = manual(Thai);
        assert_eq!(b.keys("correct word "), "แนพพำแะ ไนพก ");
        let a = b.e.flip();
        assert_eq!(a.note, RT_NOTE_FIXED);
        b.apply(a);
        assert_eq!(b.screen, "แนพพำแะ word ");
        let a = b.e.flip();
        assert_eq!(a.note, RT_NOTE_FIXED_MANY);
        b.apply(a);
        assert_eq!(b.screen, "correct word ");
    }

    #[test]
    fn manual_never_changes_text_on_its_own() {
        assert_eq!(manual(Us).keys("l;ylfu8iy[ "), "l;ylfu8iy[ ");
    }

    #[test]
    fn semi_auto_fixes_at_the_boundary_only() {
        let mut b = semi(Us);
        assert_eq!(b.keys("l;ylfu"), "l;ylfu");
        assert_eq!(b.keys(" "), "สวัสดี ");
        assert_eq!(b.layout, Thai);
        assert_eq!(b.keys("^"), "l;ylfu ");
    }

    #[test]
    fn semi_auto_fixes_english_typed_on_thai() {
        assert_eq!(semi(Thai).keys("hello world "), "hello world ");
    }

    #[test]
    fn auto_fixes_thai_without_a_space() {
        // Thai is written without spaces: the fix cannot wait for one.
        let mut b = auto(Us);
        assert_eq!(b.keys("l;ylfu8iy["), "สวัสดีครับ");
        assert_eq!(b.layout, Thai);
    }

    #[test]
    fn auto_leaves_english_alone_while_typing() {
        let mut b = auto(Us);
        assert_eq!(b.keys("the quick brown fox "), "the quick brown fox ");
        assert_eq!(b.layout, Us);
    }

    #[test]
    fn shift_backspace_takes_a_live_reading_back() {
        let mut b = auto(Us);
        let mut typed = String::new();
        for k in "l;ylfu8iy[".chars() {
            b.key(k);
            typed.push(k);
            if b.e.owned.is_some() {
                break;
            }
        }
        assert!(b.e.owned.is_some(), "a Thai reading is shown before the anchor");
        assert_ne!(b.screen, typed);
        b.flip();
        assert_eq!(b.screen, typed);
        assert_eq!(b.layout, Us);
        // The rest of the word is the typist's: a space leaves it alone.
        b.keys(" ");
        assert_eq!(b.screen, format!("{typed} "));
    }

    #[test]
    fn tab_forgets_recent_words() {
        let mut b = manual(Us);
        b.keys("l;ylfu");
        b.boundary('\t');
        assert_eq!(b.e.flip().note, RT_NOTE_NOTHING);
    }

    #[test]
    fn mac_thai_minus_key_converts_as_kedmanee() {
        // Key `3` types `_` on macOS Thai but `-` on Kedmanee: the buffer keeps
        // Kedmanee's, so flipping gives the key back.
        let mut b = manual(Thai);
        b.keys("a3b");
        let a = b.e.flip();
        assert_eq!(insert(&a), "a3b");
    }

    #[test]
    fn repair_fixes_a_selection() {
        let s = CString::new("l;ylfu hello").unwrap();
        let out = unsafe { rt_repair(s.as_ptr()) };
        let fixed = unsafe { CStr::from_ptr(out).to_str().unwrap().to_string() };
        unsafe { rt_string_free(out) };
        assert_eq!(fixed, "สวัสดี hello");
    }

    // --- Auto must behave exactly as the Windows hook does. `sim::Engine` is
    // the original project's replay of that hook; drive both with the same
    // keystrokes and compare the text and the layout after every key.

    const SENTENCES: &[&str] = &[
        "สวัสดีครับ วันนี้เป็นอย่างไรบ้าง",
        "ขอบคุณมากนะคะ ไว้เจอกันใหม่",
        "พรุ่งนี้ประชุมกี่โมงครับ",
        "ช่วยส่งไฟล์รายงานให้หน่อยได้ไหม",
        "เดี๋ยวโทรกลับนะ ตอนนี้ติดประชุมอยู่",
        "ผมจะไปถึงที่ทำงานประมาณเก้าโมงเช้า",
        "ขอโทษที่ตอบช้านะครับ เพิ่งเห็นข้อความ",
        "เอกสารนี้ต้องส่งภายในวันศุกร์นี้",
        "แม่ทำอาหารอร่อยที่สุดในโลก",
        "ฝนตกหนัก รถติดมากเลยวันนี้",
        "ช่วย review pull request นี้ให้หน่อย",
        "พรุ่งนี้ deploy ขึ้น production ตอนบ่ายสองนะ",
        "meeting ย้ายไปห้อง conference room ชั้นสาม",
        "Can you send me the report by Friday",
        "The middleware handles authentication and logging",
        "I will be there at nine tomorrow morning",
    ];

    fn compare(keys: &[Option<char>], start: InputLayout, label: &str) {
        let mut sim = sim::Engine::new(dict::english(), dict::thai(), start);
        let mut mac = auto(start);
        for (i, k) in keys.iter().enumerate() {
            match k {
                None => {
                    sim.backspace();
                    mac.backspace();
                }
                Some(c @ (' ' | '\n')) => {
                    sim.boundary(*c);
                    mac.boundary(*c);
                }
                Some(c) => {
                    sim.key(*c);
                    mac.key(*c);
                }
            }
            assert_eq!(mac.screen, sim.screen, "{label}: after key {i}");
            assert_eq!(mac.layout, sim.layout(), "{label}: layout after key {i}");
        }
    }

    /// The keys that type `text` without ever switching layout by hand.
    fn blind(text: &str) -> Vec<Option<char>> {
        text.chars()
            .map(|c| Some(if c == ' ' { c } else { sim::key_for(c).map_or(c, |(k, _)| k) }))
            .collect()
    }

    #[test]
    fn auto_matches_the_windows_hook_on_sentences() {
        for s in SENTENCES {
            let mut keys = blind(s);
            keys.push(Some(' '));
            compare(&keys, Us, s);
            compare(&keys, Thai, s);
        }
    }

    #[test]
    fn auto_matches_the_windows_hook_on_random_typing() {
        const ALPHABET: &[u8] = b"l;yfu8i[mjohkdrtgpbnvsaecwq,.'<< ";
        let mut state: u64 = 0x5eed_1234_abcd_ef01;
        let mut next = || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for round in 0..2000 {
            let len = 5 + (next() % 30) as usize;
            let keys: Vec<Option<char>> = (0..len)
                .map(|_| match ALPHABET[(next() % ALPHABET.len() as u64) as usize] {
                    b'<' => None,
                    c => Some(c as char),
                })
                .collect();
            let start = if round % 2 == 0 { Us } else { Thai };
            compare(&keys, start, &format!("round {round}"));
        }
    }
}

