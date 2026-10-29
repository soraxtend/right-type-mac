//! Learned words, kept across launches (the Windows version's `learn.rs`,
//! without its sync folder).
//!
//! Learned words join the live dictionaries (`Dictionary::learn`), so every
//! decision sees them at once: an English word is held instead of turned into
//! Thai, a Thai word is left alone instead of turned into English. They are
//! kept one per line in a file the app names (`open`), in Application Support.
//!
//! Two ways in, each a setting:
//!
//! - `learn_now`: the typist flipped back one of RightType's own conversions
//!   with Shift+Backspace, an explicit "this was a real word". On by default.
//!   When off, the word is only kept in memory for the palette's "keep as
//!   typed" (`reversed`).
//! - `observe`: ordinary English typed on the English layout, after `REPEATS`
//!   sightings, so one-off typos do not stick. Off by default.
//!
//! Guards (privacy first): letters of one script only, bounded length, not
//! already known, never secret-shaped.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use righttype::{dict, secret};
use zeroize::Zeroize;

const MIN_LEN: usize = 3;
const MAX_LEN: usize = 20;
/// Thai words are written without spaces and run longer; still bounded.
const MIN_THAI_LEN: usize = 2;
const MAX_THAI_LEN: usize = 30;
const REPEATS: u8 = 3;
/// Words flipped back while learning was off, offered by the palette.
const REVERSED_CAP: usize = 5;

static LEARN_REVERSED: AtomicBool = AtomicBool::new(true);
static LEARN_TYPED: AtomicBool = AtomicBool::new(false);
static PATH: Mutex<Option<PathBuf>> = Mutex::new(None);
static LEARNED: Mutex<BTreeSet<String>> = Mutex::new(BTreeSet::new());
static PENDING: Mutex<BTreeMap<String, u8>> = Mutex::new(BTreeMap::new());
static REVERSED: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Use the list in `path` from now on, and load it.
pub fn open(path: PathBuf) {
    *PATH.lock().unwrap() = Some(path);
    let lines = read_file();
    let mut learned = LEARNED.lock().unwrap();
    learned.clear();
    for line in lines {
        if let Some(word) = explicit_key(&line) {
            teach(&word);
            learned.insert(word);
        }
    }
}

/// The two settings: learn words flipped back, learn words typed often.
pub fn set(reversed: bool, typed: bool) {
    LEARN_REVERSED.store(reversed, Ordering::Relaxed);
    LEARN_TYPED.store(typed, Ordering::Relaxed);
    if !typed {
        for (mut word, _) in std::mem::take(&mut *PENDING.lock().unwrap()) {
            word.zeroize();
        }
    }
}

/// The typist flipped back one of RightType's own conversions and this is the
/// word they kept.
pub fn learn_now(word: &str) {
    let word = word.trim().trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace());
    let mut key = if eligible_shape(word) {
        if dict::english().contains(word) {
            return;
        }
        word.to_ascii_lowercase()
    } else if eligible_thai_shape(word) {
        if dict::thai().contains(word) {
            return;
        }
        word.to_string()
    } else {
        return;
    };
    if LEARN_REVERSED.load(Ordering::Relaxed) {
        commit(&key);
        key.zeroize();
    } else {
        remember_reversed(key);
    }
}

/// A word typed on the English layout that RightType left alone. Learned
/// after `REPEATS` sightings, when that setting is on.
pub fn observe(word: &str) {
    if !LEARN_TYPED.load(Ordering::Relaxed) || !eligible_shape(word) {
        return;
    }
    let mut key = word.to_ascii_lowercase();
    if dict::english().contains(&key) {
        key.zeroize();
        return;
    }
    let ready = {
        let mut pending = PENDING.lock().unwrap();
        let count = pending.entry(key.clone()).or_insert(0);
        *count = count.saturating_add(1);
        let ready = *count >= REPEATS;
        if ready {
            if let Some((mut k, _)) = pending.remove_entry(&key) {
                k.zeroize();
            }
        }
        ready
    };
    if ready {
        commit(&key);
    }
    key.zeroize();
}

fn remember_reversed(word: String) {
    let mut list = REVERSED.lock().unwrap();
    if let Some(i) = list.iter().position(|w| *w == word) {
        list.remove(i).zeroize();
    }
    list.insert(0, word);
    while list.len() > REVERSED_CAP {
        if let Some(mut old) = list.pop() {
            old.zeroize();
        }
    }
}

/// Words flipped back lately while learning them was off, newest first.
pub fn reversed() -> Vec<String> {
    REVERSED.lock().unwrap().clone()
}

/// Keep one of `reversed` as typed from now on (the palette asked).
pub fn keep_as_typed(word: &str) {
    let mut list = REVERSED.lock().unwrap();
    if let Some(i) = list.iter().position(|w| w == word) {
        let mut w = list.remove(i);
        drop(list);
        commit(&w);
        w.zeroize();
    }
}

/// Learn `word` because the typist asked (Settings, the palette). Returns the
/// word as learned.
pub fn add(word: &str) -> Option<String> {
    let key = explicit_key(word)?;
    commit(&key);
    Some(key)
}

/// The word `add` would learn from a selection, if it is one word.
pub fn candidate(selection: &str) -> Option<String> {
    explicit_key(selection)
}

/// Every learned word, sorted.
pub fn list() -> Vec<String> {
    LEARNED.lock().unwrap().iter().cloned().collect()
}

/// Make `lines` the whole list (Settings' editor). Returns how many words
/// were kept and how many lines were not a word.
pub fn replace(lines: &[&str]) -> (usize, usize) {
    let mut kept = BTreeSet::new();
    let mut skipped = 0;
    for line in lines.iter().map(|l| l.trim()).filter(|l| !l.is_empty()) {
        match explicit_key(line) {
            Some(word) => {
                kept.insert(word);
            }
            None => skipped += 1,
        }
    }
    dict::english().forget_learned();
    dict::thai().forget_learned();
    for word in &kept {
        teach(word);
    }
    let count = kept.len();
    *LEARNED.lock().unwrap() = kept;
    write_file();
    (count, skipped)
}

/// Forget every learned word.
pub fn clear() {
    replace(&[]);
    for mut word in std::mem::take(&mut *REVERSED.lock().unwrap()) {
        word.zeroize();
    }
}

pub fn count() -> usize {
    LEARNED.lock().unwrap().len()
}

fn commit(word: &str) {
    if !LEARNED.lock().unwrap().insert(word.to_string()) {
        return;
    }
    teach(word);
    append(word);
}

/// Add a word to the live dictionary of its script.
fn teach(word: &str) {
    if word.chars().any(|c| c.is_ascii_alphanumeric()) {
        dict::english().learn(word);
    } else {
        dict::thai().learn(word);
    }
}

fn read_file() -> Vec<String> {
    PATH.lock()
        .unwrap()
        .as_ref()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|s| s.lines().map(|l| l.trim().to_string()).collect())
        .unwrap_or_default()
}

fn append(word: &str) {
    use std::io::Write;
    let Some(path) = PATH.lock().unwrap().clone() else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{word}");
    }
}

fn write_file() {
    let Some(path) = PATH.lock().unwrap().clone() else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let mut text: String = LEARNED.lock().unwrap().iter().map(|w| format!("{w}\n")).collect();
    let _ = std::fs::write(path, &text);
    text.zeroize();
}

fn eligible_shape(word: &str) -> bool {
    let len = word.chars().count();
    (MIN_LEN..=MAX_LEN).contains(&len)
        && word.bytes().all(|b| b.is_ascii_alphabetic())
        && !secret::is_secret_token(word)
}

fn eligible_thai_shape(word: &str) -> bool {
    let len = word.chars().count();
    (MIN_THAI_LEN..=MAX_THAI_LEN).contains(&len) && word.chars().all(is_thai_letter)
}

fn is_thai_letter(c: char) -> bool {
    ('\u{0E01}'..='\u{0E5B}').contains(&c)
}

/// A word the typist asked to learn, as it is kept, or `None`.
fn explicit_key(word: &str) -> Option<String> {
    let clean = word.trim().trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace());
    let len = clean.chars().count();
    if !(2..=32).contains(&len) {
        return None;
    }
    if clean.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') && !secret::is_secret_token(clean) {
        Some(clean.to_ascii_lowercase())
    } else if clean.chars().all(is_thai_letter) {
        Some(clean.to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_selection_is_a_candidate_only_when_it_is_one_word() {
        assert_eq!(candidate("Kubernetes").as_deref(), Some("kubernetes"));
        assert_eq!(candidate("  tokenizer, ").as_deref(), Some("tokenizer"));
        assert_eq!(candidate("ไลน์").as_deref(), Some("ไลน์"));
        for denied in ["", "a", "two words", "P@ssw0rd123", "ไลน์ x"] {
            assert!(candidate(denied).is_none(), "{denied:?}");
        }
    }

    #[test]
    fn learning_shape_rejects_secrets_and_mixed_scripts() {
        assert!(eligible_shape("kubernetes"));
        for denied in ["ab", "abc123", "l;ylfu", "สวัสดี", "thiswordisfarbeyondthelearningcap"] {
            assert!(!eligible_shape(denied), "{denied}");
        }
        assert!(eligible_thai_shape("ไลน์"));
        assert!(!eligible_thai_shape("ไลน์x"));
    }

    // One test for the file, as the list is shared by the whole process.
    #[test]
    fn learned_words_are_kept_in_the_file_and_reloaded() {
        let dir = std::env::temp_dir().join(format!("righttype-learn-{}", std::process::id()));
        let path = dir.join("learned.txt");
        let _ = std::fs::remove_file(&path);
        open(path.clone());
        set(true, true);

        learn_now("qzvxtestword");
        assert!(dict::english().contains("qzvxtestword"));
        for _ in 0..REPEATS {
            observe("Zqxtyped");
        }
        assert!(dict::english().contains("zqxtyped"));
        assert_eq!(add("ทดสอบคำใหม่ๆ").as_deref(), Some("ทดสอบคำใหม่ๆ"));
        let saved = std::fs::read_to_string(&path).unwrap();
        assert!(saved.contains("qzvxtestword\n") && saved.contains("zqxtyped\n"));

        // Off: flipped-back words wait in memory for the palette.
        set(false, false);
        learn_now("qzvxreverse");
        assert!(!dict::english().contains("qzvxreverse"));
        assert_eq!(reversed(), vec!["qzvxreverse".to_string()]);
        keep_as_typed("qzvxreverse");
        assert!(dict::english().contains("qzvxreverse"));

        // Another launch reads the file again.
        dict::english().forget_learned();
        dict::thai().forget_learned();
        open(path.clone());
        assert!(dict::english().contains("qzvxtestword"));
        assert!(dict::thai().contains("ทดสอบคำใหม่ๆ"));

        let (kept, skipped) = replace(&["qzvxtestword", "not a word", ""]);
        assert_eq!((kept, skipped), (1, 1));
        assert!(!dict::english().contains("zqxtyped"));
        clear();
        assert_eq!(count(), 0);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "");
        let _ = std::fs::remove_dir_all(dir);
        set(true, false);
    }
}
