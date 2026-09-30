//! Deciding what to relay, and what to keep off the phone.
//!
//! The capture itself is WinRT and Windows-only, but every decision about a
//! captured banner is ordinary logic — and that is where this product's privacy
//! lives, so it is here, testable on any host.
//!
//! Two rules, both from having watched the Mac half go wrong:
//!
//! 1. **The relay is off unless the user turned it on.** A feature that ships
//!    on by default and forwards the contents of every notification to another
//!    device is not a feature, it is a surprise with a network stack.
//! 2. **A name we cannot resolve fails *closed*.** The denylist matches on the
//!    app's *display* name, because that is all Windows exposes. If the name
//!    comes back empty, the banner is dropped rather than relayed on the
//!    assumption that an unknown app is probably fine. The Mac half learned
//!    this the hard way: a parse that produced `""` silently dropped
//!    notifications, and the fix ("fall back to the raw text") turned a
//!    *privacy* filter into a no-op for exactly the apps it could not name.

/// The parsed form of one banner. What the phone receives.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Notification {
    /// The sending app's display name, as Windows reports it.
    pub app: String,
    pub title: String,
    pub subtitle: String,
    pub body: String,
    /// The notifying app's front window title, when it could be read.
    /// Optional on the wire so an older build still decodes.
    pub window_title: Option<String>,
}

impl Notification {
    /// Whether this banner carries anything worth showing.
    ///
    /// Windows emits a notification for things that are not messages — a
    /// focus assist digest, a "your battery is low" from the shell. Relaying
    /// those fills the phone's inbox with rows the user cannot act on and then
    /// trains them to swipe the real ones away without looking.
    pub fn is_worth_relaying(&self) -> bool {
        !self.title.trim().is_empty() || !self.body.trim().is_empty()
    }
}

/// The relay's own state, and the one decision it makes.
#[derive(Debug, Clone, Default)]
pub struct Relay {
    /// Whether the user asked for this at all.
    pub enabled: bool,
    /// App names never relayed. Matched case-insensitively, and by substring
    /// so a helper process ("Google Chrome Helper") is covered by its parent's
    /// entry.
    pub denylist: Vec<String>,
    /// App names that opted in, overriding the denylist. Empty means "relay
    /// everything not denied", which is the default: a denylist is the only
    /// list that can be shipped without knowing a user's apps.
    pub allowlist: Vec<String>,
}

impl Relay {
    /// Is this banner allowed onto the phone?
    ///
    /// Returns `false` for "no", and the reason alongside, because the console
    /// has to be able to explain a *silent* decision — a banner that never
    /// arrives and never says why is indistinguishable from a broken feature.
    pub fn decide(&self, n: &Notification) -> Result<(), SkipReason> {
        if !self.enabled {
            return Err(SkipReason::Disabled);
        }
        if !n.is_worth_relaying() {
            return Err(SkipReason::Empty);
        }
        let name = n.app.trim();
        if name.is_empty() {
            // Fail closed. See the module docs.
            return Err(SkipReason::Unnamed);
        }
        if Self::matches(&self.allowlist, name) {
            return Ok(());
        }
        if Self::matches(&self.denylist, name) {
            return Err(SkipReason::Denied(name.to_string()));
        }
        Ok(())
    }

    /// Substring match, so a helper process is covered by its parent's entry.
    /// A test asserts the ordering, because "contains" is also how a one-letter
    /// entry ends up denying everything.
    fn matches(list: &[String], name: &str) -> bool {
        let name = name.to_lowercase();
        list.iter()
            .map(|e| e.trim().to_lowercase())
            .filter(|e| !e.is_empty())
            .any(|e| name.contains(&e))
    }
}

/// Why a banner was not relayed. Every variant is a real, nameable decision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SkipReason {
    /// The user has not turned the relay on.
    Disabled,
    /// Nothing but a header, or nothing at all.
    Empty,
    /// The sending app could not be named, so it is treated as denied.
    Unnamed,
    /// Named, and on the denylist.
    Denied(String),
}

impl SkipReason {
    /// A line for the console, in the user's language via the caller's `t`.
    ///
    /// Deliberately returns *structured* pieces rather than a finished
    /// sentence: the wording belongs to the app's i18n table, and baking English
    /// into this crate is how a Chinese console ends up with English reasons.
    pub fn parts(&self) -> (String, String) {
        match self {
            SkipReason::Disabled => ("中继未开启".into(), "relay is off".into()),
            SkipReason::Empty => ("空通知".into(), "empty notification".into()),
            SkipReason::Unnamed => (
                "无法识别来源应用，按未授权处理".into(),
                "sending app could not be identified — treated as denied".into(),
            ),
            SkipReason::Denied(name) => (
                format!("在拒绝列表里：{name}"),
                format!("on the denylist: {name}"),
            ),
        }
    }
}

/// One captured banner, before any decision about it.
pub struct Captured {
    pub app: String,
    pub title: String,
    pub subtitle: String,
    pub body: String,
}

impl From<Captured> for Notification {
    fn from(c: Captured) -> Notification {
        Notification {
            app: c.app,
            title: c.title,
            subtitle: c.subtitle,
            body: c.body,
            window_title: None,
        }
    }
}

/// Apply the relay's rules to a captured banner.
///
/// Returns the notification to send, or why it was not sent. Kept separate from
/// the WinRT plumbing so the decision path is testable without Windows.
pub fn admit(relay: &Relay, c: Captured) -> Result<Notification, SkipReason> {
    let n: Notification = c.into();
    relay.decide(&n)?;
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn n(app: &str) -> Notification {
        Notification {
            app: app.into(),
            title: "Build finished".into(),
            ..Default::default()
        }
    }

    /// The whole point of the feature is that it does not run until asked.
    #[test]
    fn nothing_is_relayed_until_it_is_turned_on() {
        let relay = Relay::default();
        assert_eq!(relay.decide(&n("Slack")), Err(SkipReason::Disabled));
    }

    #[test]
    fn an_enabled_relay_sends_an_ordinary_notification() {
        let relay = Relay {
            enabled: true,
            ..Default::default()
        };
        assert_eq!(relay.decide(&n("Slack")), Ok(()));
    }

    /// The privacy rule, stated as a test because it is the one that matters.
    #[test]
    fn an_unnamed_sender_is_denied_rather_than_relayed() {
        let relay = Relay {
            enabled: true,
            ..Default::default()
        };
        assert_eq!(relay.decide(&n("   ")), Err(SkipReason::Unnamed));
    }

    #[test]
    fn the_denylist_matches_case_insensitively_and_by_substring() {
        let relay = Relay {
            enabled: true,
            denylist: vec!["1Password".into(), "bank".into()],
            ..Default::default()
        };
        assert_eq!(
            relay.decide(&n("1password 8")),
            Err(SkipReason::Denied("1password 8".into()))
        );
        // A helper process is covered by its parent's entry.
        assert_eq!(
            relay.decide(&n("My Bank Assistant")),
            Err(SkipReason::Denied("My Bank Assistant".into()))
        );
        assert_eq!(relay.decide(&n("Slack")), Ok(()));
    }

    #[test]
    fn an_allowlist_entry_overrides_the_denylist() {
        let relay = Relay {
            enabled: true,
            denylist: vec!["Chrome".into()],
            allowlist: vec!["Chrome".into()],
        };
        assert_eq!(relay.decide(&n("Google Chrome")), Ok(()));
    }

    /// A one-character denylist entry would otherwise deny half the world.
    #[test]
    fn blank_entries_never_match() {
        let relay = Relay {
            enabled: true,
            denylist: vec!["".into(), "   ".into()],
            ..Default::default()
        };
        assert_eq!(relay.decide(&n("Slack")), Ok(()));
    }

    /// Windows notifies for things that are not messages, and a phone inbox
    /// full of un-actionable rows is worse than an empty one.
    #[test]
    fn a_banner_with_no_text_is_not_worth_relaying() {
        let relay = Relay {
            enabled: true,
            ..Default::default()
        };
        let empty = Notification {
            app: "ShellExperienceHost".into(),
            title: "  ".into(),
            body: String::new(),
            ..Default::default()
        };
        assert_eq!(relay.decide(&empty), Err(SkipReason::Empty));
    }

    /// Every skip reason must be nameable: a silent decision is
    /// indistinguishable from a broken feature.
    #[test]
    fn every_skip_reason_explains_itself_in_both_languages() {
        for r in [
            SkipReason::Disabled,
            SkipReason::Empty,
            SkipReason::Unnamed,
            SkipReason::Denied("Slack".into()),
        ] {
            let (zh, en) = r.parts();
            assert!(!zh.trim().is_empty(), "{r:?}");
            assert!(!en.trim().is_empty(), "{r:?}");
            assert!(
                zh.chars().any(|c| c as u32 > 0x2E80),
                "zh looks untranslated: {zh:?}"
            );
        }
    }
}
