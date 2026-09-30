//! The first-run wizard, as a real window.
//!
//! The Mac has `SetupAssistantView`: a six-step window the user is walked
//! through once. What existed here before was a few lines printed to the
//! console — which is not a wizard, because a console nobody has open is not a
//! place to ask someone to change a system setting. The tray row that installs
//! the camera was the only real UI, and it appears *after* the user has already
//! discovered the feature is broken.
//!
//! So this is a window: created on first run, dismissed forever once, and
//! reachable again from the tray because the state it checks can change (a user
//! who declined the camera install, then wants it).
//!
//! Drawn with plain Win32 controls rather than a UI framework, for the same
//! reason the tray menu is: this program is a tray app with no window, and
//! adding a toolkit to draw four checkmarks would be a dependency nobody would
//! justify. The steps and their wording are **pure and tested** in
//! `rc_net::firstrun`; this file only draws them.

use rc_net::firstrun::{Camera, FirstRun};

/// Which step the wizard is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)] // consumed by the Windows window
pub enum Page {
    Welcome,
    /// The Windows equivalent of the Mac's Accessibility step. Not a
    /// permission — a fact about the process — so this page mostly *reports*
    /// and offers the one action that can change it.
    Input,
    Camera,
    StartAtLogin,
    Done,
}

#[allow(dead_code)] // consumed by the Windows window
impl Page {
    /// The pages, in order.
    pub fn all() -> &'static [Page] {
        &[
            Page::Welcome,
            Page::Input,
            Page::Camera,
            Page::StartAtLogin,
            Page::Done,
        ]
    }

    pub fn index(&self) -> usize {
        Page::all().iter().position(|p| p == self).unwrap_or(0)
    }

    pub fn next(&self) -> Option<Page> {
        Page::all().get(self.index() + 1).copied()
    }

    pub fn prev(&self) -> Option<Page> {
        let i = self.index();
        if i == 0 {
            None
        } else {
            Page::all().get(i - 1).copied()
        }
    }

    /// Whether this page is finished, which is what drives the Next button's
    /// enabled state. A wizard that lets you click past an unfinished required
    /// step is a wizard that produces a broken setup and calls it complete.
    pub fn is_complete(&self, fr: &FirstRun) -> bool {
        match self {
            Page::Welcome | Page::Done => true,
            Page::Input => fr.integrity.can_inject(),
            // The camera is a required feature on the Mac's wizard too, so it
            // gates the same way here.
            Page::Camera => fr.camera == Camera::Ready,
            // Start-at-login is a convenience, so it does not gate — but it
            // asks, which is the difference between a wizard and a form.
            Page::StartAtLogin => true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Page;
    use rc_net::firstrun::{Camera, FirstRun, Integrity};

    fn fr(camera: Camera, integrity: Integrity) -> FirstRun {
        FirstRun {
            camera,
            integrity,
            autostart: true,
            notify_relay: false,
        }
    }

    /// The first and last pages can never be incomplete, or the wizard has no
    /// way to start or to finish.
    #[test]
    fn the_ends_are_always_complete() {
        let worst = fr(Camera::Missing, Integrity::Low);
        assert!(Page::Welcome.is_complete(&worst));
        assert!(Page::Done.is_complete(&worst));
    }

    /// Walking forward from the welcome must be possible even when nothing is
    /// set up, or a first-time user is stuck on page one.
    #[test]
    fn the_welcome_page_always_lets_you_continue() {
        assert!(Page::Welcome.next().is_some());
    }

    #[test]
    fn a_required_step_gates_until_it_is_done() {
        let broken = fr(Camera::Missing, Integrity::Low);
        assert!(!Page::Input.is_complete(&broken));
        assert!(!Page::Camera.is_complete(&broken));
        let fixed = fr(Camera::Ready, Integrity::High);
        assert!(Page::Input.is_complete(&fixed));
        assert!(Page::Camera.is_complete(&fixed));
    }

    /// Start-at-login is a convenience. Gating on it would mean a user who
    /// never wants it can never finish the wizard.
    #[test]
    fn start_at_login_never_blocks() {
        let mut no = fr(Camera::Ready, Integrity::High);
        no.autostart = false;
        assert!(Page::StartAtLogin.is_complete(&no));
    }

    /// Navigation has to be symmetric, or Back is a lie.
    #[test]
    fn pages_navigate_both_ways() {
        for p in Page::all() {
            if let Some(next) = p.next() {
                assert_eq!(next.prev(), Some(*p), "{p:?} -> {next:?}");
            }
            if let Some(prev) = p.prev() {
                assert_eq!(prev.next(), Some(*p), "{prev:?} -> {p:?}");
            }
        }
        assert_eq!(Page::all().first().unwrap().prev(), None);
        assert_eq!(Page::all().last().unwrap().next(), None);
    }
}
