//! Capturing Windows notifications and relaying them to the phone.
//!
//! Windows exposes notifications through the WinRT
//! `UserNotificationListener`, which is a *push* API: you ask for permission
//! once, and it calls you back when a banner arrives. That is a different shape
//! from the Mac half, which polls the accessibility tree because macOS has no
//! notification API at all — so this is not a port, it is a second
//! implementation of the same idea.
//!
//! The consequence worth writing down: **the permission prompt is real**. The
//! listener cannot be created without the user granting notification access in
//! Windows Settings, and there is no way to fake it. So the tray has to lead
//! with that, and the console has to be able to say "you have not granted this
//! yet" — which is a different message from "there are no notifications".
//!
//! Everything about *what* to send lives in [`crate::notify`], which is pure and
//! tested on any host. This file is only the Windows-shaped part.

pub use rc_net::notify::{admit, Captured, Notification, Relay, SkipReason};

/// Why the relay is not running. Distinct states, because they need different
/// sentences and only one of them is the user's fault.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NotAvailable {
    /// The user has not granted notification access in Windows Settings. There
    /// is a Settings pane for it, and saying so is the entire recovery.
    NotPermitted,
    /// The listener could not be created at all — an older Windows build, or a
    /// policy that removed the API.
    Unsupported(String),
}

impl NotAvailable {
    /// The Windows Settings URI for notification access, so the app can offer
    /// to open it. A user who is told to go look for a setting will not find
    /// it; a user who is handed the pane will.
    pub fn settings_uri() -> &'static str {
        "ms-settings:notifications"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn captured(app: &str) -> Captured {
        Captured {
            app: app.into(),
            title: "Deploy finished".into(),
            subtitle: String::new(),
            body: "12 tests passed".into(),
        }
    }

    #[test]
    fn a_captured_banner_becomes_the_wire_shape() {
        let relay = Relay {
            enabled: true,
            ..Default::default()
        };
        let n = admit(&relay, captured("GitHub Desktop")).expect("relayed");
        assert_eq!(n.app, "GitHub Desktop");
        assert_eq!(n.body, "12 tests passed");
        // Optional on the wire, so an older phone build still decodes.
        assert_eq!(n.window_title, None);
    }

    /// The Windows-specific hazard: Windows can report an app with no display
    /// name, and relaying that would leak its contents with nothing to filter
    /// on. It has to be dropped, not guessed at.
    #[test]
    fn a_banner_from_an_unnamed_app_is_not_relayed() {
        let relay = Relay {
            enabled: true,
            ..Default::default()
        };
        assert_eq!(admit(&relay, captured("")), Err(SkipReason::Unnamed));
    }

    #[test]
    fn denial_carries_the_name_so_the_console_can_explain_it() {
        let relay = Relay {
            enabled: true,
            denylist: vec!["1Password".into()],
            ..Default::default()
        };
        assert_eq!(
            admit(&relay, captured("1Password")),
            Err(SkipReason::Denied("1Password".into()))
        );
    }

    /// "You have not granted this" and "there is nothing to send" are
    /// different problems, so they must not share a reason.
    #[test]
    fn not_permitted_is_not_the_same_as_unsupported() {
        assert_ne!(
            NotAvailable::NotPermitted,
            NotAvailable::Unsupported("x".into())
        );
        assert!(NotAvailable::settings_uri().starts_with("ms-settings:"));
    }
}
