//! The settings window's model: what it shows, and what each control does.
//!
//! Pure and tested on any host, like the wizard. The Win32 file only draws it.
//!
//! This exists because three of the Mac's settings had no Windows equivalent at
//! all, and one of them was a privacy control: the notification relay's
//! **denylist** was readable and writable in code with no way for a user to
//! reach it. A filter nobody can edit is a filter nobody trusts.
//!
//! Sections, in the order the Mac's `PreferencesView` uses:
//!
//! 1. **Notifications** — the relay switch, and the denylist, editable.
//! 2. **Connection** — the paired phones, with forget and disconnect.
//! 3. **Camera** — whether the virtual camera is registered.
//! 4. **Video** — the resolution the phone should stream.

/// One editable list of app names.
///
/// Separate from the relay's `Relay` type because this is a *user-facing list*:
/// adding an entry is a decision, and the rules about what a valid entry is
/// belong to the editor rather than to the matcher.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NameList {
    items: Vec<String>,
}

impl NameList {
    pub fn new(items: Vec<String>) -> Self {
        // Duplicates would match the same app twice and show twice, which reads
        // as a bug in the editor.
        let mut v: Vec<String> = Vec::new();
        for it in items {
            let t = it.trim().to_string();
            if !t.is_empty() && !v.iter().any(|e| e.eq_ignore_ascii_case(&t)) {
                v.push(t);
            }
        }
        NameList { items: v }
    }

    pub fn items(&self) -> &[String] {
        &self.items
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// Add an entry, or report why not.
    pub fn add(&mut self, raw: &str) -> Result<(), AddError> {
        let t = raw.trim();
        if t.is_empty() {
            return Err(AddError::Empty);
        }
        if self.items.iter().any(|e| e.eq_ignore_ascii_case(t)) {
            return Err(AddError::Duplicate);
        }
        self.items.push(t.to_string());
        Ok(())
    }

    /// Remove by name. Returns whether anything was removed, so the caller can
    /// tell a real removal from a click on a stale row.
    pub fn remove(&mut self, name: &str) -> bool {
        let before = self.items.len();
        self.items.retain(|e| !e.eq_ignore_ascii_case(name));
        self.items.len() != before
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AddError {
    Empty,
    Duplicate,
}

impl AddError {
    /// A sentence for the user, in the app's own words.
    ///
    /// Both languages, because this is the one place a user types something and
    /// gets told it was wrong — the moment where a missing translation is most
    /// visible and most annoying.
    pub fn message(&self) -> (&'static str, &'static str) {
        match self {
            AddError::Empty => ("名字不能为空。", "The name cannot be empty."),
            AddError::Duplicate => ("已经在列表里了。", "That is already in the list."),
        }
    }
}

/// Why the denylist cannot be typed into: the explanation, without the window.
pub fn denylist_footer(len: usize) -> (&'static str, &'static str) {
    match len {
        0 => (
            "目前没有排除任何应用，Windows 上所有通知都会转发（默认关闭中继）。",
            "Nothing is excluded yet, so every Windows notification would be relayed (the relay is off by default).",
        ),
        _ => (
            "名字里包含这段文字的应用会被排除（不区分大小写）。",
            "Any app whose name contains this text is excluded (case-insensitive).",
        ),
    }
}

/// The resolution the phone should stream, as a closed set.
///
/// A closed set rather than a free-form bitrate, because a user asked to
/// "choose a quality" wants a choice, and a number they have to compute is not
/// one. `0` means "let the phone decide", which is the default and the only
/// honest answer when we cannot see what the network will do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Quality {
    pub width: i32,
    pub height: i32,
    pub fps: i32,
}

impl Quality {
    pub const CHOICES: &'static [(Quality, &'static str, &'static str)] = &[
        (
            Quality {
                width: 0,
                height: 0,
                fps: 0,
            },
            "自动",
            "Automatic",
        ),
        (
            Quality {
                width: 1280,
                height: 720,
                fps: 30,
            },
            "720p",
            "720p",
        ),
        (
            Quality {
                width: 1920,
                height: 1080,
                fps: 30,
            },
            "1080p",
            "1080p",
        ),
        (
            Quality {
                width: 1920,
                height: 1080,
                fps: 60,
            },
            "1080p 60",
            "1080p 60",
        ),
    ];

    /// The index of `self` in [`Quality::CHOICES`], falling back to automatic.
    pub fn index(&self) -> usize {
        Self::CHOICES
            .iter()
            .position(|(q, _, _)| q == self)
            .unwrap_or(0)
    }

    pub fn from_index(i: usize) -> Quality {
        Self::CHOICES
            .get(i)
            .map(|(q, _, _)| *q)
            .unwrap_or(Self::default())
    }

    /// What the choice is called, in the language the caller is drawing in.
    ///
    /// The parameter is the whole fix: this used to return the *Chinese* half
    /// unconditionally, so an English user's Settings window read
    /// `Quality: 自动 (click to change)`. The tuple has carried both languages
    /// all along; only the accessor was monolingual.
    pub fn label(&self, chinese: bool) -> &'static str {
        let (_, zh, en) = Self::CHOICES[self.index()];
        if chinese {
            zh
        } else {
            en
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{AddError, NameList, Quality};

    #[test]
    fn a_blank_entry_is_refused() {
        let mut l = NameList::default();
        assert_eq!(l.add("   "), Err(AddError::Empty));
        assert!(l.is_empty());
    }

    /// A duplicate would match the same app twice and render twice, which reads
    /// as a broken editor rather than as a redundant entry.
    #[test]
    fn a_duplicate_is_refused_case_insensitively() {
        let mut l = NameList::default();
        l.add("1Password").expect("first");
        assert_eq!(l.add("1password"), Err(AddError::Duplicate));
        assert_eq!(l.items().len(), 1);
    }

    #[test]
    fn removal_is_case_insensitive_and_reports_whether_it_removed() {
        let mut l = NameList::new(vec!["Slack".into(), "1Password".into()]);
        assert!(l.remove("1password"));
        assert!(
            !l.remove("1password"),
            "a second click on a stale row removes nothing"
        );
        assert!(l.remove("slack"));
        assert!(l.is_empty());
    }

    /// Constructing from a stored file must not produce duplicates either, or a
    /// file edited by hand grows a list that matches everything twice.
    #[test]
    fn loading_tolerates_mess() {
        let l = NameList::new(vec![
            "Slack".into(),
            "slack".into(),
            "  ".into(),
            "Mail".into(),
        ]);
        assert_eq!(l.items(), &["Slack".to_string(), "Mail".to_string()]);
    }

    /// Both languages, because this is where a user types something and is told
    /// it was wrong.
    #[test]
    fn every_refusal_explains_itself_in_both_languages() {
        for e in [AddError::Empty, AddError::Duplicate] {
            let (zh, en) = e.message();
            assert!(!zh.trim().is_empty());
            assert!(!en.trim().is_empty());
        }
    }

    /// The footer has to say something different when the list is empty,
    /// because "nothing excluded" and "three apps excluded" are different
    /// states that a user must be able to tell apart.
    #[test]
    fn the_footer_distinguishes_empty_from_populated() {
        let (zh0, en0) = super::denylist_footer(0);
        let (zh1, en1) = super::denylist_footer(3);
        assert_ne!(zh0, zh1);
        assert_ne!(en0, en1);
    }

    /// The first choice is "automatic", and it must be what an unknown stored
    /// value falls back to: guessing a resolution the user never asked for is
    /// worse than letting the phone decide.
    #[test]
    fn quality_round_trips_and_falls_back_to_automatic() {
        for (q, _, _) in Quality::CHOICES {
            assert_eq!(Quality::from_index(q.index()), *q);
        }
        assert_eq!(Quality::from_index(999), Quality::default());
        assert_eq!(Quality::from_index(0), Quality::default());
        assert_eq!(Quality::default().index(), 0);
    }
}
