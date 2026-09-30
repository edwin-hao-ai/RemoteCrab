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

// ---------------------------------------------------------------------------
// The wizard's mutable state, kept out of the Win32 file on purpose.
//
// `wizard_win` is `cfg(windows)`, so anything tested only there runs on exactly
// one platform — and the bug this was written for (an action that was `take`n,
// so the button worked exactly once) is invisible to every test that does not
// click twice. The logic lives here; the window draws it.
// ---------------------------------------------------------------------------

/// What the window needs to draw itself, and the one action it can perform.
#[cfg_attr(not(windows), allow(dead_code))] // the Win32 window and the tests below
pub struct State {
    pub(crate) first_run: rc_net::firstrun::FirstRun,
    pub(crate) page: Page,
    pub(crate) action: Option<Box<dyn Fn() + Send + Sync>>,
}

/// The one window's state. A process is not going to run two wizards, and a
/// `Mutex` rather than `static mut` because the tray thread can raise the
/// window while the UI thread draws it.
#[cfg_attr(not(windows), allow(dead_code))] // the Win32 window and the tests below
pub(crate) static STATE: std::sync::Mutex<Option<State>> = std::sync::Mutex::new(None);

#[cfg_attr(not(windows), allow(dead_code))] // the Win32 window
pub(crate) fn with_state<R>(f: impl FnOnce(&State) -> R) -> Option<R> {
    STATE.lock().ok().and_then(|g| g.as_ref().map(f))
}

#[cfg_attr(not(windows), allow(dead_code))] // the Win32 window
pub(crate) fn set_page(p: Page) {
    if let Ok(mut g) = STATE.lock() {
        if let Some(s) = g.as_mut() {
            s.page = p;
        }
    }
}

#[cfg_attr(not(windows), allow(dead_code))] // the Win32 window
pub(crate) fn current_page() -> Page {
    with_state(|s| s.page).unwrap_or(Page::Welcome)
}

/// Run the action without the lock held.
///
/// It used to **take** the closure out of the state, so the button worked
/// exactly once: a user who declined the UAC prompt and clicked again got
/// nothing, with no explanation — while the wizard's own text tells them to
/// click again. Only reproducible on hardware, because there is no second UAC
/// prompt anywhere near the test suite.
#[cfg_attr(not(windows), allow(dead_code))] // the Win32 window
pub(crate) fn run_action() {
    // The reference is read out and called after the guard drops, so a UAC
    // dialog raised by the action cannot deadlock against this lock.
    type Action = dyn Fn() + Send + Sync;
    let ptr: Option<*const Action> = STATE
        .lock()
        .ok()
        .and_then(|g| g.as_ref()?.action.as_ref().map(|f| f as *const Action));
    if let Some(ptr) = ptr {
        // Safe: the state is process-wide, outlives this call, and nothing
        // replaces the closure while the window is open.
        unsafe { (*ptr)() };
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

#[cfg(test)]
mod action_tests {
    use super::{current_page, run_action, set_page, Page, State, STATE};
    use rc_net::firstrun::{Camera, FirstRun, Integrity};
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A fully-satisfied state. `FirstRun` has no `Default`, deliberately:
    /// "the camera is fine" and "we never looked" are different answers.
    fn ok_state() -> FirstRun {
        FirstRun {
            camera: Camera::Ready,
            integrity: Integrity::Medium,
            autostart: true,
            notify_relay: false,
        }
    }

    /// The action used to be `take`n out of the state, so the button worked
    /// exactly once — and the wizard's own text tells a user who declined the
    /// UAC prompt to click it again. That combination is invisible to any test
    /// that does not click twice.
    #[test]
    fn the_action_survives_being_run() {
        static RUNS: AtomicUsize = AtomicUsize::new(0);
        if let Ok(mut g) = STATE.lock() {
            *g = Some(State {
                first_run: ok_state(),
                page: Page::Camera,
                action: Some(Box::new(|| {
                    RUNS.fetch_add(1, Ordering::Relaxed);
                })),
            });
        }
        run_action();
        run_action();
        run_action();
        assert_eq!(
            RUNS.load(Ordering::Relaxed),
            3,
            "the action must still be there after the first click"
        );
        if let Ok(mut g) = STATE.lock() {
            *g = None;
        }
    }

    /// With no action installed it is a no-op rather than a panic: the window
    /// can outlive the state it was built from.
    #[test]
    fn running_with_no_state_is_harmless() {
        if let Ok(mut g) = STATE.lock() {
            *g = None;
        }
        run_action();
        run_action();
    }

    /// And the page survives a draw, which is what the window does every 200 ms.
    #[test]
    fn the_page_is_stable_across_draws() {
        if let Ok(mut g) = STATE.lock() {
            *g = Some(State {
                first_run: ok_state(),
                page: Page::Welcome,
                action: None,
            });
        }
        set_page(Page::Camera);
        assert_eq!(current_page(), Page::Camera);
        set_page(Page::Input);
        assert_eq!(current_page(), Page::Input);
        if let Ok(mut g) = STATE.lock() {
            *g = None;
        }
    }
}
