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
//! (judge a word when it ends), Auto (also fix Thai typed on the English
//! layout while it is typed) and Suggest (show the fix; Tab takes it).
//!
//! Beyond the Windows hook's core path this side also owns the typist's
//! snippets (`righttype::snippets`, `righttype::macros`), the learned words
//! kept across launches (`learn`) and the selection transforms the palette
//! offers.

mod learn;

use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::time::{Duration, Instant};

use righttype::buffer::{Key, WordBuffer};
use righttype::dict::{self, Dictionary};
use righttype::layout::{auto_convert, en_to_th};
use righttype::policy::{self, InputLayout, Reading};
use righttype::recent::Recent;
use righttype::render;
use righttype::secret::SeedTracker;
use righttype::snippets::{self, Scope, Snippet};
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
/// A snippet's trigger became its text.
pub const RT_NOTE_SNIPPET: i32 = 5;
/// One of the typist's own misspellings put right.
pub const RT_NOTE_TYPO: i32 = 6;

/// Modes, as the app numbers them.
pub const RT_MODE_OFF: i32 = 0;
pub const RT_MODE_MANUAL: i32 = 1;
pub const RT_MODE_SEMI_AUTO: i32 = 2;
pub const RT_MODE_AUTO: i32 = 3;
pub const RT_MODE_SUGGEST: i32 = 4;

/// Tab takes a Suggest hint only this soon after it appeared (`hook::SUGGEST_TAB_WINDOW`).
const SUGGEST_TAB_WINDOW: Duration = Duration::from_secs(4);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Manual,
    SemiAuto,
    Auto,
    Suggest,
}

impl Mode {
    fn from_code(code: i32) -> Mode {
        match code {
            RT_MODE_SEMI_AUTO => Mode::SemiAuto,
            RT_MODE_AUTO => Mode::Auto,
            RT_MODE_SUGGEST => Mode::Suggest,
            _ => Mode::Manual,
        }
    }

    /// Fixes a word on its own when it ends.
    fn autofix(self) -> bool {
        matches!(self, Mode::SemiAuto | Mode::Auto)
    }

    /// Fixes Thai typed on the English layout while it is typed.
    fn live(self) -> bool {
        self == Mode::Auto
    }
}

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
    /// stands in for it). When false the action is only a layout switch or a
    /// hint, made as the key goes through.
    pub swallow: bool,
    /// Suggest: the word as it would be fixed, to show by the caret (Tab
    /// takes it), or NULL. Owned, like `insert`.
    pub hint: *mut c_char,
    /// A macro snippet's steps, one per line, for the app to run after the
    /// edit, or NULL: `T<text>`, `K<virtual keys, comma-separated>`,
    /// `W<milliseconds>`, `C` (type the clipboard). Owned, like `insert`.
    pub steps: *mut c_char,
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
            hint: ptr::null_mut(),
            steps: ptr::null_mut(),
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

/// A Suggest hint for the word just ended (`hook::SuggestionRecord`).
struct Suggestion {
    /// The word as on screen.
    original: String,
    corrected: String,
    boundary: char,
    at: Instant,
}

impl Drop for Suggestion {
    fn drop(&mut self) {
        self.original.zeroize();
        self.corrected.zeroize();
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
    snippets: Vec<Snippet>,
    /// Suggest: the fix offered for the word just ended.
    suggestion: Option<Suggestion>,
    /// Suggest: when a hint for the word in progress was shown.
    live_hint: Option<Instant>,
    /// Common Thai misspellings put right when a word ends (`righttype::spelling`).
    spelling: bool,
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
            snippets: Vec::new(),
            suggestion: None,
            live_hint: None,
            spelling: false,
        }
    }

    /// One printable key, named by the character it types on US QWERTY
    /// (upper case and symbols mean Shift is held), typed on `layout`.
    /// `Some` when there is something to do: the key is then swallowed and
    /// the action typed instead, unless `swallow` is false (a Suggest hint).
    ///
    /// The key is kept as Kedmanee would type it rather than as the app shows
    /// it: macOS's Thai layout differs from Kedmanee on two keys (`` ` `` and
    /// `3`), and the conversion tables are Kedmanee's.
    pub fn key(&mut self, key: char, layout: InputLayout, mode: Mode) -> Option<RtAction> {
        let produced = match layout {
            InputLayout::UsQwerty => key,
            InputLayout::ThaiKedmanee => en_to_th(&key.to_string()).chars().next().unwrap_or(key),
        };
        self.suggestion = None;
        self.live_hint = None;
        self.recent.end_chain();
        self.buf.observe(Key::Char(produced));
        if mode.live() && self.mark == Mark::Plain && layout == InputLayout::UsQwerty {
            if let Some(action) = self.reconcile_run() {
                return Some(action);
            }
        }
        if self.buf.is_poisoned() || self.buf.current().is_empty() {
            self.mark = Mark::Plain;
        }
        if mode == Mode::Suggest && self.mark == Mark::Plain && layout == InputLayout::UsQwerty {
            return self.live_hint();
        }
        None
    }

    /// Backspace. `Some` when it is swallowed: the run shown as Thai is
    /// re-rendered for the shorter keys instead.
    pub fn backspace(&mut self, mode: Mode) -> Option<RtAction> {
        self.suggestion = None;
        self.live_hint = None;
        self.buf.observe(Key::Backspace);
        // The text before the caret is no longer what `recent` recorded.
        self.recent.clear();
        if mode.live() && self.owned.is_some() && self.mark == Mark::Plain {
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
        self.suggestion = None;
        self.live_hint = None;
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
        self.suggestion = None;
        self.live_hint = None;
        action
    }

    /// Space, Return or Tab. `Some` when the word is changed (the boundary is
    /// then swallowed and re-sent by the action), or — `swallow` false — when
    /// a Thai run stands and only the layout follows it, or Suggest offers a
    /// fix.
    pub fn boundary(&mut self, boundary: char, layout: InputLayout, mode: Mode) -> Option<RtAction> {
        self.suggestion = None;
        self.live_hint = None;
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

        // A snippet's trigger: its text instead, in every mode.
        if let Some(snippet) = snippets::find(&self.snippets, &screen, layout) {
            let action = expand(&screen, boundary, &snippet.text);
            self.recent.clear();
            word.zeroize();
            screen.zeroize();
            return Some(action);
        }

        let converted = mark == Mark::Converted;
        let judge = mode.autofix() || mode == Mode::Suggest;
        let mut detection = match (judge, mark) {
            (false, _) | (_, Mark::Decided) => None,
            (true, Mark::Converted) => policy::revise_converted(&word, self.en, self.th),
            (true, Mark::Plain) => policy::detect_token(&word, layout, self.en, self.th),
        };
        let corrected = detection.as_ref().map(|d| d.corrected.as_str());
        let seed_run = self.seed.observe_candidate(&word, corrected);
        if seed_run {
            detection = None;
        }
        if !seed_run && self.learns && policy::allows_learning(Some(layout), detection.is_some()) {
            learn::observe(&word);
        }

        if mode == Mode::Suggest && mark != Mark::Decided {
            // Nothing changes on screen: the fix is shown, and Tab takes it.
            // Only after a space: Return may have sent the text, Tab moved on.
            let action = match detection {
                Some(d) if boundary == ' ' && screen == word => {
                    let hint = owned_string(&d.corrected);
                    self.suggestion = Some(Suggestion {
                        original: word.clone(),
                        corrected: d.corrected.clone(),
                        boundary,
                        at: Instant::now(),
                    });
                    Some(RtAction { hint, swallow: false, ..RtAction::empty() })
                }
                _ => None,
            };
            self.remember(&screen, boundary, converted);
            word.zeroize();
            screen.zeroize();
            return action;
        }

        let (mut text, kept_converted, to, note) = match detection {
            Some(d) => {
                let to = layout_code(&d.corrected);
                (d.corrected, true, to, RT_NOTE_FIXED)
            }
            None if mode.autofix() && mark != Mark::Decided && !seed_run => {
                if let Some(right) = snippets::find_typo(&self.snippets, &word) {
                    // One of the typist's own misspellings.
                    (right.to_string(), false, RT_LAYOUT_NONE, RT_NOTE_TYPO)
                } else if layout == InputLayout::ThaiKedmanee {
                    // Thai typed in a wrong order (เเ for แ), or misspelt.
                    match policy::thai_spelling(&word, self.th) {
                        Some(fixed) => (fixed, false, RT_LAYOUT_NONE, RT_NOTE_NONE),
                        None => match self.spelling.then(|| righttype::spelling::fix(&word, self.th)).flatten() {
                            Some((fixed, _, _)) => (fixed, false, RT_LAYOUT_NONE, RT_NOTE_TYPO),
                            None => (word.clone(), converted, RT_LAYOUT_NONE, RT_NOTE_NONE),
                        },
                    }
                } else {
                    (word.clone(), converted, RT_LAYOUT_NONE, RT_NOTE_NONE)
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

    /// Tab, before it is taken as a boundary: Suggest's hint, if one is
    /// showing, is taken instead (`hook::accept_suggestion`).
    pub fn tab(&mut self) -> Option<RtAction> {
        if let Some(s) = self.suggestion.take().filter(|s| s.at.elapsed() < SUGGEST_TAB_WINDOW) {
            let action = edit(
                s.original.chars().count() + 1,
                &s.corrected,
                s.boundary,
                layout_code(&s.corrected),
                RT_NOTE_FIXED,
                1,
            );
            // Shift+Backspace now flips the fix back.
            self.recent.clear();
            self.recent.push(&s.corrected, s.boundary, false);
            return Some(action);
        }
        if self.live_hint.take().is_some_and(|at| at.elapsed() < SUGGEST_TAB_WINDOW) && !self.buf.current().is_empty() {
            return Some(self.flip());
        }
        None
    }

    /// Suggest, mid-word: the reading Auto would show, as a hint
    /// (`hook::show_live_hint`).
    fn live_hint(&mut self) -> Option<RtAction> {
        let run = self.buf.current();
        if run.is_empty()
            || self.seed.guarding()
            || snippets::starts_a_trigger(&self.snippets, run, InputLayout::UsQwerty)
        {
            return None;
        }
        match policy::live_reading(run, false, self.en, self.th) {
            Reading::Thai(mut thai) => {
                self.live_hint = Some(Instant::now());
                let hint = owned_string(&thai);
                thai.zeroize();
                Some(RtAction { hint, swallow: false, ..RtAction::empty() })
            }
            Reading::AsTyped => None,
        }
    }

    /// Shift+Backspace: put back the keys of a run shown as Thai; or flip the
    /// word in progress; or — right after a boundary — the word before it, then
    /// one more word on each further press.
    pub fn flip(&mut self) -> RtAction {
        self.suggestion = None;
        self.live_hint = None;
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
            // original was a real word.
            learn::learn_now(learned);
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
        // A snippet's trigger being typed stays as typed, to be found at its
        // boundary (`;today` spells Thai keys).
        if matches!(reading, Reading::Thai(_))
            && !holding
            && snippets::starts_a_trigger(&self.snippets, &run, InputLayout::UsQwerty)
        {
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
        insert: owned_string(insert),
        boundary: boundary as u32,
        layout,
        note,
        words: words as u32,
        ..RtAction::empty()
    }
}

/// `text` for the C side, or NULL when it is empty.
fn owned_string(text: &str) -> *mut c_char {
    if text.is_empty() {
        ptr::null_mut()
    } else {
        CString::new(text).map_or(ptr::null_mut(), CString::into_raw)
    }
}

/// A snippet's trigger `shown` on screen, ended by `boundary`, becomes its
/// `text` (`hook::expand_snippet`). A macro takes the trigger away and leaves
/// its steps for the app to run; the boundary is not typed after it.
fn expand(shown: &str, boundary: char, text: &str) -> RtAction {
    let backspaces = shown.chars().count();
    if let Some(steps) = macro_steps(text) {
        let mut encoded = steps.join("\n");
        let action = RtAction {
            backspaces: backspaces as u32,
            steps: owned_string(&encoded),
            note: RT_NOTE_SNIPPET,
            ..RtAction::empty()
        };
        encoded.zeroize();
        return action;
    }
    let mut filled = snippets::fill(text, &now());
    let action = edit(backspaces, &filled, boundary, RT_LAYOUT_NONE, RT_NOTE_SNIPPET, 1);
    filled.zeroize();
    action
}

/// Key names as a Mac keyboard prints them, as the core's (Windows) names:
/// Command is where Windows has its Windows key, Option its Alt.
fn mac_key_names(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let after = &rest[open..];
        let Some(close) = after.find('}') else {
            break;
        };
        let body = &after[1..close];
        let (name, arg) = body.split_once(' ').unwrap_or((body, ""));
        if ["keys", "key", "press", "กด"].iter().any(|n| n.eq_ignore_ascii_case(name)) {
            let keys: Vec<&str> = arg
                .split('+')
                .map(|k| match k.trim().to_lowercase().as_str() {
                    "cmd" | "command" | "⌘" => "Win",
                    "option" | "opt" | "⌥" => "Alt",
                    "⌃" => "Ctrl",
                    "⇧" => "Shift",
                    "return" | "↩" => "Enter",
                    _ => k.trim(),
                })
                .collect();
            out.push('{');
            out.push_str(name);
            out.push(' ');
            out.push_str(&keys.join("+"));
            out.push('}');
        } else {
            out.push_str(&after[..=close]);
        }
        rest = &after[close + 1..];
    }
    out.push_str(rest);
    out
}

/// The steps of a macro snippet, encoded for the app (see `RtAction::steps`),
/// or `None` for a plain snippet (or one that cannot run on a Mac).
fn macro_steps(text: &str) -> Option<Vec<String>> {
    use righttype::macros::Step;
    let Some(Ok(steps)) = righttype::macros::steps(&mac_key_names(text)) else {
        return None;
    };
    let now = now();
    steps
        .into_iter()
        .map(|step| match step {
            Step::Text(t) => Some(format!("T{}", snippets::fill(&t, &now))),
            Step::Keys(k) => righttype::shortcuts::virtual_keys(&k)
                .map(|vks| format!("K{}", vks.iter().map(u16::to_string).collect::<Vec<_>>().join(","))),
            Step::Wait(ms) => Some(format!("W{ms}")),
            Step::Clipboard => Some("C".to_string()),
            // Windows' own commands and Word styles: nothing to run here.
            Step::Command(_) | Step::Style(_) => None,
        })
        .collect()
}

/// Why a snippet cannot be kept (`RT_SNIP_*`), or 0.
fn snippet_problem(trigger: &str, text: &str, scope: Scope) -> i32 {
    use righttype::snippets::Problem;
    let mac = mac_key_names(text);
    match snippets::check(trigger, &mac, scope) {
        Ok(_) if righttype::macros::steps(&mac).is_some() && macro_steps(text).is_none() => RT_SNIP_MAC_UNSUPPORTED,
        Ok(_) => 0,
        Err(Problem::TriggerLength) => 1,
        Err(Problem::TriggerSpace) => 2,
        Err(Problem::TextEmpty) => 3,
        Err(Problem::TextLong) => 4,
        Err(Problem::MacroStep) => 5,
    }
}

/// A macro step Windows has and a Mac does not (`{คำสั่ง …}`, `{สไตล์ …}`).
pub const RT_SNIP_MAC_UNSUPPORTED: i32 = 6;

/// The local date and time, for a snippet's date and time fields.
fn now() -> snippets::Now {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        let t = libc::time(ptr::null_mut());
        libc::localtime_r(&t, &mut tm);
    }
    snippets::Now {
        year: (tm.tm_year + 1900) as u32,
        month: (tm.tm_mon + 1) as u32,
        day: tm.tm_mday as u32,
        weekday: tm.tm_wday as u32,
        hour: tm.tm_hour as u32,
        minute: tm.tm_min as u32,
    }
}

fn scope(code: i32) -> Scope {
    match code {
        0 => Scope::Thai,
        1 => Scope::English,
        3 => Scope::Typo,
        _ => Scope::Either,
    }
}

/// A C string as `&str`, or `None` for NULL or bad UTF-8.
unsafe fn text<'a>(s: *const c_char) -> Option<&'a str> {
    if s.is_null() {
        None
    } else {
        CStr::from_ptr(s).to_str().ok()
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

/// A printable key. True: apply `out`, and swallow the key if `out.swallow`.
///
/// # Safety
/// `engine` came from `rt_engine_new`; `out` is writable.
#[no_mangle]
pub unsafe extern "C" fn rt_key(engine: *mut Engine, key: u32, layout: i32, mode: i32, out: *mut RtAction) -> bool {
    let (Some(e), Some(c)) = (engine.as_mut(), char::from_u32(key)) else {
        return false;
    };
    give(e.key(c, input_layout(layout), Mode::from_code(mode)), out)
}

/// Backspace. True: swallow it and apply `out` instead.
///
/// # Safety
/// `engine` came from `rt_engine_new`; `out` is writable.
#[no_mangle]
pub unsafe extern "C" fn rt_backspace(engine: *mut Engine, mode: i32, out: *mut RtAction) -> bool {
    let Some(e) = engine.as_mut() else {
        return false;
    };
    give(e.backspace(Mode::from_code(mode)), out)
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
    mode: i32,
    out: *mut RtAction,
) -> bool {
    let (Some(e), Some(b)) = (engine.as_mut(), char::from_u32(boundary)) else {
        return false;
    };
    give(e.boundary(b, input_layout(layout), Mode::from_code(mode)), out)
}

/// Tab, before `rt_boundary`. True: Suggest's hint was taken; swallow the
/// Tab and apply `out`.
///
/// # Safety
/// `engine` came from `rt_engine_new`; `out` is writable.
#[no_mangle]
pub unsafe extern "C" fn rt_tab(engine: *mut Engine, out: *mut RtAction) -> bool {
    let Some(e) = engine.as_mut() else {
        return false;
    };
    give(e.tab(), out)
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
        for s in [&mut a.insert, &mut a.hint, &mut a.steps] {
            rt_string_free(*s);
            *s = ptr::null_mut();
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

/// Forget the snippets, before adding the current list with `rt_snippet_add`.
///
/// # Safety
/// `engine` came from `rt_engine_new`.
#[no_mangle]
pub unsafe extern "C" fn rt_snippets_clear(engine: *mut Engine) {
    if let Some(e) = engine.as_mut() {
        for s in e.snippets.iter_mut() {
            s.text.zeroize();
        }
        e.snippets.clear();
    }
}

/// Add a snippet (`scope`: 0 Thai, 1 English, 2 either, 3 a misspelling of
/// the typist's own). Returns 0, or why it cannot be kept (`rt_snippet_check`).
///
/// # Safety
/// `engine` came from `rt_engine_new`; the strings are NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn rt_snippet_add(engine: *mut Engine, trigger: *const c_char, body: *const c_char, scope_code: i32) -> i32 {
    let (Some(e), Some(trigger), Some(body)) = (engine.as_mut(), text(trigger), text(body)) else {
        return 3;
    };
    let problem = snippet_problem(trigger, body, scope(scope_code));
    if problem == 0 && e.snippets.len() < snippets::MAX_SNIPPETS {
        // Kept with the core's key names (`{กด Cmd+B}` as `{กด Win+B}`).
        if let Ok(s) = snippets::check(trigger, &mac_key_names(body), scope(scope_code)) {
            e.snippets.push(s);
        }
    }
    problem
}

/// Whether a snippet can be kept: 0, or 1 trigger not 2–32 characters,
/// 2 trigger has a space, 3 no text, 4 text too long, 5 a step in braces that
/// cannot run, 6 a step a Mac does not have.
///
/// # Safety
/// The strings are NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn rt_snippet_check(trigger: *const c_char, body: *const c_char, scope_code: i32) -> i32 {
    match (text(trigger), text(body)) {
        (Some(trigger), Some(body)) => snippet_problem(trigger, body, scope(scope_code)),
        _ => 3,
    }
}

/// A snippet's text with its date and time fields filled in for now (the
/// settings page shows it).
///
/// # Safety
/// `body` is NUL-terminated UTF-8. Release the result with `rt_string_free`.
#[no_mangle]
pub unsafe extern "C" fn rt_snippet_preview(body: *const c_char) -> *mut c_char {
    text(body).map_or(ptr::null_mut(), |t| owned_string(&snippets::fill(t, &now())))
}

/// Common Thai misspellings put right when a word ends, and web addresses,
/// email addresses and numbers typed on the Thai layout put back.
///
/// # Safety
/// `engine` came from `rt_engine_new`.
#[no_mangle]
pub unsafe extern "C" fn rt_set_options(engine: *mut Engine, spelling: bool, addresses: bool) {
    if let Some(e) = engine.as_mut() {
        e.spelling = spelling;
    }
    policy::set_fixes_addresses(addresses);
}

/// Keep learned words in the file at `path`, and load them. `reversed`:
/// learn a word flipped back with Shift+Backspace; `typed`: learn an English
/// word typed three times.
///
/// # Safety
/// `path` is NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn rt_learn_open(path: *const c_char) {
    if let Some(p) = text(path) {
        learn::open(p.into());
    }
}

#[no_mangle]
pub extern "C" fn rt_learn_set(reversed: bool, typed: bool) {
    learn::set(reversed, typed);
}

/// Every learned word, one per line. Release with `rt_string_free`.
#[no_mangle]
pub extern "C" fn rt_learn_list() -> *mut c_char {
    let mut list = learn::list().join("\n");
    let out = owned_string(&list);
    list.zeroize();
    out
}

#[no_mangle]
pub extern "C" fn rt_learn_count() -> u32 {
    learn::count() as u32
}

/// Make `lines` (one word per line) the whole list. Returns how many lines
/// were not a word; `kept` gets how many words the list has.
///
/// # Safety
/// `lines` is NUL-terminated UTF-8; `kept` is writable or NULL.
#[no_mangle]
pub unsafe extern "C" fn rt_learn_replace(lines: *const c_char, kept: *mut u32) -> u32 {
    let lines: Vec<&str> = text(lines).map(|t| t.lines().collect()).unwrap_or_default();
    let (k, skipped) = learn::replace(&lines);
    if let Some(kept) = kept.as_mut() {
        *kept = k as u32;
    }
    skipped as u32
}

/// Learn `word` now. Returns it as learned, or NULL when it is not one word.
///
/// # Safety
/// `word` is NUL-terminated UTF-8. Release the result with `rt_string_free`.
#[no_mangle]
pub unsafe extern "C" fn rt_learn_add(word: *const c_char) -> *mut c_char {
    text(word).and_then(learn::add).map_or(ptr::null_mut(), |w| owned_string(&w))
}

/// The word `rt_learn_add` would learn from a selection, or NULL.
///
/// # Safety
/// `selection` is NUL-terminated UTF-8. Release the result with `rt_string_free`.
#[no_mangle]
pub unsafe extern "C" fn rt_learn_candidate(selection: *const c_char) -> *mut c_char {
    text(selection).and_then(learn::candidate).map_or(ptr::null_mut(), |w| owned_string(&w))
}

#[no_mangle]
pub extern "C" fn rt_learn_clear() {
    learn::clear();
}

/// Words flipped back lately while learning them is off, newest first, one
/// per line, or NULL. Release with `rt_string_free`.
#[no_mangle]
pub extern "C" fn rt_learn_reversed() -> *mut c_char {
    owned_string(&learn::reversed().join("\n"))
}

/// Keep one of `rt_learn_reversed` as typed from now on.
///
/// # Safety
/// `word` is NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn rt_learn_keep(word: *const c_char) {
    if let Some(w) = text(word) {
        learn::keep_as_typed(w);
    }
}

/// What the palette can do to a selection (`palette::TransformKind`).
pub const RT_TRANSFORM_REPAIR: i32 = 0;
pub const RT_TRANSFORM_NORMALIZE: i32 = 1;
pub const RT_TRANSFORM_SPACING: i32 = 2;
pub const RT_TRANSFORM_ERA: i32 = 3;
pub const RT_TRANSFORM_NUMBER_WORDS: i32 = 4;
pub const RT_TRANSFORM_BAHT_WORDS: i32 = 5;
pub const RT_TRANSFORM_DIGITS: i32 = 6;
pub const RT_TRANSFORM_UPPER: i32 = 7;
pub const RT_TRANSFORM_LOWER: i32 = 8;
pub const RT_TRANSFORM_TITLE: i32 = 9;
pub const RT_TRANSFORM_SWAP_CASE: i32 = 10;
/// Every character to the other layout.
pub const RT_TRANSFORM_FLIP: i32 = 11;

/// `text` changed as `kind` says. Release the result with `rt_string_free`.
///
/// # Safety
/// `input` is NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn rt_transform(kind: i32, input: *const c_char) -> *mut c_char {
    use righttype::layout as l;
    use righttype::thai_text as t;
    let Some(input) = text(input) else {
        return ptr::null_mut();
    };
    let mut out = match kind {
        RT_TRANSFORM_REPAIR => righttype::repair::repair(input, dict::english(), dict::thai()).text,
        RT_TRANSFORM_NORMALIZE => t::normalize(input),
        RT_TRANSFORM_SPACING => t::tidy_spacing(input),
        RT_TRANSFORM_ERA => t::swap_era(input),
        RT_TRANSFORM_NUMBER_WORDS => t::number_words(input),
        RT_TRANSFORM_BAHT_WORDS => t::baht_words(input),
        RT_TRANSFORM_DIGITS => l::swap_digits(input),
        RT_TRANSFORM_UPPER => l::upper_case(input),
        RT_TRANSFORM_LOWER => l::lower_case(input),
        RT_TRANSFORM_TITLE => l::title_case(input),
        RT_TRANSFORM_SWAP_CASE => l::swap_case(input),
        RT_TRANSFORM_FLIP => auto_convert(input),
        _ => input.to_string(),
    };
    let result = CString::new(out.as_str()).map_or(ptr::null_mut(), CString::into_raw);
    out.zeroize();
    result
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
        mode: Mode,
        /// The last Suggest hint shown.
        hint: String,
        /// The last macro's steps.
        steps: String,
    }

    impl Box {
        fn new(layout: InputLayout, mode: Mode) -> Self {
            let mut e = Engine::new();
            e.learns = false;
            Box { e, screen: String::new(), layout, mode, hint: String::new(), steps: String::new() }
        }

        fn apply(&mut self, a: RtAction) {
            if !a.hint.is_null() {
                self.hint = unsafe { CStr::from_ptr(a.hint).to_str().unwrap().to_string() };
            }
            if !a.steps.is_null() {
                self.steps = unsafe { CStr::from_ptr(a.steps).to_str().unwrap().to_string() };
            }
            // Never delete more than this box typed: that would be the
            // typist's own text from before.
            assert!(
                a.backspaces as usize <= self.screen.chars().count(),
                "{} backspaces over {:?}",
                a.backspaces,
                self.screen
            );
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
            match self.e.key(k, self.layout, self.mode) {
                Some(a) if a.swallow => self.apply(a),
                Some(a) => {
                    self.apply(a);
                    self.screen.push(produced);
                }
                None => self.screen.push(produced),
            }
        }

        fn backspace(&mut self) {
            match self.e.backspace(self.mode) {
                Some(a) => self.apply(a),
                None => {
                    self.screen.pop();
                }
            }
        }

        fn boundary(&mut self, b: char) {
            if b == '\t' {
                if let Some(a) = self.e.tab() {
                    self.apply(a);
                    return;
                }
            }
            match self.e.boundary(b, self.layout, self.mode) {
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
                    ' ' | '\n' | '\t' => self.boundary(c),
                    _ => self.key(c),
                }
            }
            &self.screen
        }
    }

    fn manual(layout: InputLayout) -> Box {
        Box::new(layout, Mode::Manual)
    }
    fn semi(layout: InputLayout) -> Box {
        Box::new(layout, Mode::SemiAuto)
    }
    fn auto(layout: InputLayout) -> Box {
        Box::new(layout, Mode::Auto)
    }
    fn suggest(layout: InputLayout) -> Box {
        Box::new(layout, Mode::Suggest)
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
    fn suggest_shows_the_fix_and_tab_takes_it() {
        let mut b = suggest(Us);
        assert_eq!(b.keys("l;ylfu "), "l;ylfu ");
        assert_eq!(b.hint, "สวัสดี");
        assert_eq!(b.keys("\t"), "สวัสดี ");
        assert_eq!(b.layout, Thai);
        // Shift+Backspace flips the fix back.
        assert_eq!(b.keys("^"), "l;ylfu ");
    }

    #[test]
    fn suggest_hint_goes_with_the_next_key() {
        let mut b = suggest(Us);
        b.keys("l;ylfu a");
        // Tab after another key is a Tab.
        assert_eq!(b.keys("\t"), "l;ylfu a\t");
    }

    #[test]
    fn suggest_hints_thai_mid_word_and_tab_flips_it() {
        let mut b = suggest(Us);
        assert_eq!(b.keys("l;ylfu8iy["), "l;ylfu8iy[");
        assert_eq!(b.hint, "สวัสดีครับ");
        assert_eq!(b.keys("\t"), "สวัสดีครับ");
    }

    #[test]
    fn suggest_leaves_english_alone() {
        let mut b = suggest(Us);
        assert_eq!(b.keys("hello world \t"), "hello world \t");
        assert!(b.hint.is_empty());
    }

    fn add(b: &mut Box, trigger: &str, text: &str, scope: i32) -> i32 {
        let t = CString::new(trigger).unwrap();
        let x = CString::new(text).unwrap();
        unsafe { rt_snippet_add(&mut b.e, t.as_ptr(), x.as_ptr(), scope) }
    }

    #[test]
    fn a_snippet_trigger_becomes_its_text_on_either_keyboard() {
        let mut b = auto(Us);
        assert_eq!(add(&mut b, ";addr", "123 Main St", 2), 0);
        assert_eq!(b.keys("my ;addr "), "my 123 Main St ");
        let mut b = manual(Thai);
        add(&mut b, ";addr", "123 Main St", 2);
        assert_eq!(b.keys(";addr "), "123 Main St ");
    }

    #[test]
    fn a_trigger_is_not_shown_as_thai_while_typed() {
        // `;today` spells Thai keys; Auto would otherwise rewrite it mid-word.
        let mut b = auto(Us);
        add(&mut b, "l;ylfu", "hello", 1);
        assert_eq!(b.keys("l;ylfu"), "l;ylfu");
        assert_eq!(b.keys(" "), "hello ");
    }

    #[test]
    fn a_snippet_fills_its_date_fields() {
        let mut b = manual(Us);
        add(&mut b, ";y", "{iso}", 2);
        let typed = b.keys(";y ").to_string();
        assert_eq!(typed.len(), "2026-10-29 ".len());
        assert!(typed.starts_with("20"));
    }

    #[test]
    fn a_macro_snippet_leaves_its_steps_to_the_app() {
        let mut b = manual(Us);
        assert_eq!(add(&mut b, ";sig", "{กด Cmd+B}Bold{กด Cmd+B}{รอ 100}\nline", 2), 0);
        assert_eq!(b.keys("x ;sig "), "x ");
        assert_eq!(b.steps, "K91,66\nTBold\nK91,66\nW100\nK13\nTline");
        // Steps Windows has and a Mac does not are refused.
        assert_eq!(add(&mut b, ";h", "{สไตล์ Heading 1}x", 2), RT_SNIP_MAC_UNSUPPORTED);
        assert_eq!(add(&mut b, ";k", "{กด Ctrl+Nope}", 2), 5);
        assert_eq!(add(&mut b, "x", "text", 2), 1);
    }

    #[test]
    fn a_typo_of_your_own_is_put_right_when_the_word_ends() {
        let mut b = semi(Us);
        add(&mut b, "teh", "the", 3);
        assert_eq!(b.keys("teh cat "), "the cat ");
        let mut b = manual(Us);
        add(&mut b, "teh", "the", 3);
        assert_eq!(b.keys("teh "), "teh ");
    }

    #[test]
    fn transforms_change_a_selection() {
        let t = |kind, s: &str| {
            let c = CString::new(s).unwrap();
            let out = unsafe { rt_transform(kind, c.as_ptr()) };
            let r = unsafe { CStr::from_ptr(out).to_str().unwrap().to_string() };
            unsafe { rt_string_free(out) };
            r
        };
        assert_eq!(t(RT_TRANSFORM_REPAIR, "l;ylfu hello"), "สวัสดี hello");
        assert_eq!(t(RT_TRANSFORM_UPPER, "abc"), "ABC");
        assert_eq!(t(RT_TRANSFORM_DIGITS, "123"), "๑๒๓");
        assert_eq!(t(RT_TRANSFORM_ERA, "2026"), "2569");
        assert_eq!(t(RT_TRANSFORM_FLIP, "hello"), "้ำสสน");
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








    // --- Suggest, more cases.

    #[test]
    fn suggest_offers_nothing_after_return() {
        let mut b = suggest(Us);
        b.keys("l;ylfu");
        // (The hint shown while the word was typed is not the one at Return.)
        b.hint.clear();
        assert_eq!(b.keys("\n"), "l;ylfu\n");
        assert!(b.hint.is_empty());
        assert_eq!(b.keys("\t"), "l;ylfu\n\t");
    }

    #[test]
    fn suggest_hint_goes_with_backspace_and_reset() {
        let mut b = suggest(Us);
        b.keys("l;ylfu <");
        assert_eq!(b.keys("\t"), "l;ylfu\t");
        let mut b = suggest(Us);
        b.keys("l;ylfu ");
        b.e.reset(true);
        assert_eq!(b.keys("\t"), "l;ylfu \t");
    }

    #[test]
    fn suggest_offers_english_typed_on_thai() {
        let mut b = suggest(Thai);
        assert_eq!(b.keys("hello "), "้ำสสน ");
        assert_eq!(b.hint, "hello");
        assert_eq!(b.keys("\t"), "hello ");
        assert_eq!(b.layout, Us);
    }

    #[test]
    fn suggest_takes_only_the_last_word() {
        let mut b = suggest(Us);
        b.keys("l;ylfu l;ylfu ");
        assert_eq!(b.keys("\t"), "l;ylfu สวัสดี ");
    }

    #[test]
    fn suggest_leaves_a_word_flipped_by_hand() {
        let mut b = suggest(Us);
        b.hint.clear();
        assert_eq!(b.keys("l;ylfu^ "), "สวัสดี ");
        assert_eq!(b.keys("\t"), "สวัสดี \t");
    }

    // --- Snippets, more cases.

    #[test]
    fn snippet_scopes_follow_the_keyboard() {
        // Thai: only with the Thai keyboard on.
        let mut b = manual(Us);
        add(&mut b, ";addr", "ADDR", 0);
        assert_eq!(b.keys(";addr "), ";addr ");
        let mut b = manual(Thai);
        add(&mut b, ";addr", "ADDR", 0);
        assert_eq!(b.keys(";addr "), "ADDR ");
        // English: only with the English keyboard on.
        let mut b = manual(Thai);
        add(&mut b, ";addr", "ADDR", 1);
        assert_eq!(b.keys(";addr "), "วฟกกพ ");
        let mut b = manual(Us);
        add(&mut b, ";addr", "ADDR", 1);
        assert_eq!(b.keys(";addr "), "ADDR ");
    }

    #[test]
    fn snippets_work_in_every_mode_and_after_return() {
        for mode in [Mode::Manual, Mode::SemiAuto, Mode::Auto, Mode::Suggest] {
            let mut b = Box::new(Us, mode);
            add(&mut b, ";sig", "Best,\nThe team", 2);
            assert_eq!(b.keys("x ;sig\n"), "x Best,\nThe team\n");
        }
    }

    #[test]
    fn typos_of_your_own_ignore_english_case() {
        let mut b = semi(Us);
        add(&mut b, "teh", "the", 3);
        assert_eq!(b.keys("Teh "), "the ");
    }

    #[test]
    fn snippet_problems_are_named() {
        let check = |t: &str, x: &str| {
            let t = CString::new(t).unwrap();
            let x = CString::new(x).unwrap();
            unsafe { rt_snippet_check(t.as_ptr(), x.as_ptr(), 2) }
        };
        assert_eq!(check(";ok", "text"), 0);
        assert_eq!(check("x", "text"), 1);
        assert_eq!(check(&"x".repeat(33), "text"), 1);
        assert_eq!(check("a b", "text"), 2);
        assert_eq!(check(";ok", "   "), 3);
        assert_eq!(check(";ok", &"x".repeat(1001)), 4);
        assert_eq!(check(";ok", "{รอ 99999}"), 5);
        assert_eq!(check(";ok", "{คำสั่ง Bold}"), RT_SNIP_MAC_UNSUPPORTED);
    }

    #[test]
    fn macro_steps_take_mac_key_names() {
        let mut b = manual(Us);
        assert_eq!(add(&mut b, ";m", "{กด Option+Left}{กด ⌘+S}{คลิปบอร์ด}{กด Return}", 2), 0);
        b.keys(";m ");
        assert_eq!(b.steps, "K18,37\nK91,83\nC\nK13");
    }

    #[test]
    fn no_more_than_the_most_snippets_are_kept() {
        let mut b = manual(Us);
        for i in 0..snippets::MAX_SNIPPETS + 5 {
            add(&mut b, &format!(";s{i}"), "x", 2);
        }
        assert_eq!(b.e.snippets.len(), snippets::MAX_SNIPPETS);
    }

    #[test]
    fn a_snippet_preview_fills_its_fields() {
        let x = CString::new("{iso} {nope}").unwrap();
        let out = unsafe { rt_snippet_preview(x.as_ptr()) };
        let got = unsafe { CStr::from_ptr(out).to_str().unwrap().to_string() };
        unsafe { rt_string_free(out) };
        assert!(got.ends_with(" {nope}") && got.len() == "2026-10-29 {nope}".len(), "{got}");
    }

    // --- Transforms, every kind.

    #[test]
    fn every_transform_gives_what_upstream_expects() {
        let t = |kind, s: &str| {
            let c = CString::new(s).unwrap();
            let out = unsafe { rt_transform(kind, c.as_ptr()) };
            let r = unsafe { CStr::from_ptr(out).to_str().unwrap().to_string() };
            unsafe { rt_string_free(out) };
            r
        };
        assert_eq!(t(RT_TRANSFORM_NORMALIZE, "เเมว"), "แมว");
        assert_eq!(t(RT_TRANSFORM_ERA, "พ.ศ. 2569"), "ค.ศ. 2026");
        assert_eq!(t(RT_TRANSFORM_NUMBER_WORDS, "21"), "ยี่สิบเอ็ด");
        assert_eq!(t(RT_TRANSFORM_BAHT_WORDS, "1,250.50"), "หนึ่งพันสองร้อยห้าสิบบาทห้าสิบสตางค์");
        assert_eq!(t(RT_TRANSFORM_DIGITS, "๑๒๓"), "123");
        assert_eq!(t(RT_TRANSFORM_LOWER, "ABC"), "abc");
        assert_eq!(t(RT_TRANSFORM_TITLE, "hello world"), "Hello World");
        assert_eq!(t(RT_TRANSFORM_SWAP_CASE, "hELLO wORLD"), "Hello World");
        assert_eq!(t(RT_TRANSFORM_FLIP, "้ำสสน"), "hello");
        assert_eq!(t(99, "as is"), "as is");
        // Spacing and repair leave clean text as it is.
        assert_eq!(t(RT_TRANSFORM_SPACING, "สวัสดี"), "สวัสดี");
        assert_eq!(t(RT_TRANSFORM_REPAIR, "hello สวัสดี"), "hello สวัสดี");
    }

    // --- The C API takes NULL and bad text without falling over.

    #[test]
    fn the_c_api_survives_null_and_bad_utf8() {
        let mut out = RtAction::empty();
        let bad = [0xFFu8, 0xFE, 0];
        let bad = bad.as_ptr() as *const c_char;
        unsafe {
            assert!(!rt_key(ptr::null_mut(), 'a' as u32, 0, RT_MODE_AUTO, &mut out));
            assert!(!rt_backspace(ptr::null_mut(), RT_MODE_AUTO, &mut out));
            assert!(!rt_boundary(ptr::null_mut(), ' ' as u32, 0, RT_MODE_AUTO, &mut out));
            assert!(!rt_tab(ptr::null_mut(), &mut out));
            assert!(!rt_layout_changed(ptr::null_mut(), &mut out));
            rt_flip(ptr::null_mut(), &mut out);
            rt_reset(ptr::null_mut(), true);
            rt_snippets_clear(ptr::null_mut());
            rt_action_clear(ptr::null_mut());
            rt_string_free(ptr::null_mut());
            assert!(rt_repair(ptr::null()).is_null());
            assert!(rt_repair(bad).is_null());
            assert!(rt_transform(0, bad).is_null());
            assert!(rt_learn_add(bad).is_null());
            assert!(rt_learn_candidate(ptr::null()).is_null());
            assert_eq!(rt_snippet_check(ptr::null(), bad, 2), 3);
            assert_eq!(rt_snippet_add(ptr::null_mut(), bad, bad, 2), 3);
            // A key that is not a character.
            let e = rt_engine_new();
            assert!(!rt_key(e, 0xD800, 0, RT_MODE_AUTO, &mut out));
            rt_engine_free(e);
        }
    }

    // --- Properties over random typing.

    fn random_keys(seed: u64, rounds: usize, alphabet: &[u8], mut each: impl FnMut(usize, Vec<char>)) {
        let mut state = seed;
        let mut next = || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for round in 0..rounds {
            let len = 3 + (next() % 40) as usize;
            let keys = (0..len).map(|_| alphabet[(next() % alphabet.len() as u64) as usize] as char).collect();
            each(round, keys);
        }
    }

    /// What plain typing (no RightType) leaves on screen.
    fn plain(keys: &[char], layout: InputLayout) -> String {
        let mut screen = String::new();
        for &k in keys {
            match k {
                '<' => {
                    screen.pop();
                }
                ' ' | '\n' | '\t' => screen.push(k),
                _ => screen.push(match layout {
                    InputLayout::UsQwerty => k,
                    InputLayout::ThaiKedmanee => en_to_th(&k.to_string()).chars().next().unwrap(),
                }),
            }
        }
        screen
    }

    #[test]
    fn manual_and_suggest_never_change_text_by_themselves() {
        // No Tab and no Shift+Backspace: whatever is typed stays as typed.
        const KEYS: &[u8] = b"l;yfu8i[mjohkdrtgpbnvsaecwq,.'<< \n";
        for mode in [Mode::Manual, Mode::Suggest] {
            for layout in [Us, Thai] {
                random_keys(0x1234 + mode as u64, 400, KEYS, |round, keys| {
                    let mut b = Box::new(layout, mode);
                    for &k in &keys {
                        match k {
                            '<' => b.backspace(),
                            ' ' | '\n' => b.boundary(k),
                            _ => b.key(k),
                        }
                    }
                    assert_eq!(b.screen, plain(&keys, layout), "{mode:?} {layout:?} round {round}: {keys:?}");
                });
            }
        }
    }


    #[test]
    fn no_mode_deletes_more_than_it_typed() {
        // `Box::apply` asserts it on every action, Tabs and flips included.
        const KEYS: &[u8] = b"l;yfu8i[mjohkdrtgpbnvsaecwq,.'<<^^\t \n";
        for mode in [Mode::Manual, Mode::SemiAuto, Mode::Auto, Mode::Suggest] {
            for layout in [Us, Thai] {
                random_keys(0x9abc + mode as u64, 600, KEYS, |_, keys| {
                    let mut b = Box::new(layout, mode);
                    add(&mut b, ";l", "snippet", 2);
                    let seq: String = keys.iter().collect();
                    b.keys(&seq);
                });
            }
        }
    }

    #[test]
    fn shift_backspace_right_after_any_fix_puts_the_keys_back() {
        // Semi-auto and Auto fix at the boundary; one ⇧⌫ undoes it.
        for mode in [Mode::SemiAuto, Mode::Auto] {
            for (start, word) in [(Us, "l;ylfu"), (Us, "-v[8hk"), (Thai, "hello"), (Thai, "world")] {
                let mut b = Box::new(start, mode);
                let typed = plain(&word.chars().collect::<Vec<_>>(), start);
                b.keys(word);
                b.keys(" ");
                assert_ne!(b.screen, format!("{typed} "), "{mode:?} fixes {word}");
                b.keys("^");
                assert_eq!(b.screen, format!("{typed} "), "{mode:?} {word}");
            }
        }
    }
}
