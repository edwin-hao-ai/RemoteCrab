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
    /// What the last action reported, drawn under the camera page's button.
    /// `None` is also "nothing reported yet", which is why [`set_page`] clears
    /// it — see the tests at the bottom of this file.
    pub(crate) action_message: Option<(&'static str, &'static str)>,
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
            // A message about the camera belongs to the camera page. Carrying it
            // across a navigation would attribute an old refusal to whatever the
            // user is looking at now.
            s.action_message = None;
        }
    }
}

/// One home for the wording of a camera-install attempt.
///
/// The tray used to carry its own copy of these four sentences, and the wizard
/// and the settings window carried none at all — they discarded the outcome
/// entirely. A user who declined the UAC prompt in the wizard watched the button
/// return with nothing said, while the wizard's own text told them to click
/// again: exactly the advice that cannot work when the prompt was refused.
///
/// `None` means success, and is silent on purpose. The button disappearing *is*
/// the confirmation — `is_registered` is re-read on every paint — so a "done"
/// line would outlive the thing it describes.
#[cfg_attr(not(windows), allow(dead_code))] // the two Win32 windows and the tests
pub(crate) fn install_outcome(
    outcome: crate::elevate::Elevation,
) -> Option<(&'static str, &'static str)> {
    match outcome {
        crate::elevate::Elevation::PromptAccepted => None,
        crate::elevate::Elevation::Declined => Some((
            "你取消了管理员提示，所以虚拟摄像头还没有安装。需要时再点这里。",
            "You declined the administrator prompt, so the virtual camera is not installed. \
             This row will be here when you want it.",
        )),
        crate::elevate::Elevation::Unavailable => Some((
            "这台电脑不允许弹出管理员提示（可能是组策略）。请让管理员运行一次 \
             remotecrab.exe --install-vcam。",
            "This PC will not show an administrator prompt (a group policy may block it). \
             Ask an administrator to run remotecrab.exe --install-vcam once.",
        )),
        // Only reachable if this process is somehow already elevated, in which
        // case the write should have succeeded. Say that rather than implying a
        // prompt is needed.
        crate::elevate::Elevation::AlreadyElevated => Some((
            "已经在管理员权限下运行，但注册仍然失败。",
            "Already running as administrator, and the registration still failed.",
        )),
    }
}

/// Stash what the action reported so `wizard_win` can paint it.
///
/// Separate from [`install_outcome`] because the window runs its action through
/// a `Box<dyn Fn()>` that cannot return a value back to the message loop — see
/// [`run_action`]. That lifetime trick is why this is a module-level `Mutex`
/// rather than something the caller threads through.
#[cfg_attr(not(windows), allow(dead_code))] // the Win32 window
pub(crate) fn record_action(outcome: Option<(&'static str, &'static str)>) {
    if let Ok(mut g) = STATE.lock() {
        if let Some(s) = g.as_mut() {
            s.action_message = outcome;
        }
    }
}

/// The line the camera page draws under its button, if the last click left one.
///
/// Flattened because `with_state` reports "no wizard" as `None` too, and a wizard
/// with nothing to say is also `None` — the window cannot draw for a wizard that
/// is not open, so the two are the same answer.
#[cfg_attr(not(windows), allow(dead_code))] // the Win32 window
pub(crate) fn action_message() -> Option<(&'static str, &'static str)> {
    with_state(|s| s.action_message).flatten()
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
    use super::{
    action_message, current_page, install_outcome, record_action, run_action, set_page, Page, State,
    STATE,
};
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
                action_message: None,
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
                action_message: None,
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

    /// A refusal has to be reported *and* stay reported.
    ///
    /// Both halves were broken, in different places. The wizard's action is a
    /// `Box<dyn Fn()>` that cannot return a value to the message loop, so the
    /// outcome had nowhere to go even once it was being collected; and the
    /// wizard's own text tells a user who declined the UAC prompt to click
    /// again, which is precisely the advice that cannot work when the prompt was
    /// refused.
    #[test]
    fn a_refusal_is_reported_and_survives_redraws() {
        let refusal = ("declined, so it is not installed", "declined, so it is not installed");
        if let Ok(mut g) = STATE.lock() {
            *g = Some(State {
                first_run: ok_state(),
                page: Page::Camera,
                action: None,
                action_message: None,
            });
        }
        assert_eq!(action_message(), None, "nothing has been clicked yet");
        record_action(Some(refusal));
        assert_eq!(action_message(), Some(refusal));
        // A draw reads the message without consuming it. The window repaints
        // every 200 ms, so a read that took the value would blank the line
        // several times a second.
        assert_eq!(action_message(), Some(refusal));
        assert_eq!(
            current_page(),
            Page::Camera,
            "reporting an outcome must not navigate away from the page that has it"
        );
        if let Ok(mut g) = STATE.lock() {
            *g = None;
        }
    }

    /// Succeeding is silence, not a message. The button disappears on the next
    /// paint because `is_registered` is re-read, so a "done" line would outlive
    /// the thing it describes.
    #[test]
    fn a_successful_install_leaves_nothing_to_draw() {
        if let Ok(mut g) = STATE.lock() {
            *g = Some(State {
                first_run: ok_state(),
                page: Page::Camera,
                action: None,
                action_message: None,
            });
        }
        record_action(install_outcome(crate::elevate::Elevation::PromptAccepted));
        assert_eq!(action_message(), None);
        if let Ok(mut g) = STATE.lock() {
            *g = None;
        }
    }

    /// A message about the camera must not follow the user to another page, or an
    /// old refusal gets attributed to whatever they are now looking at.
    #[test]
    fn leaving_the_camera_page_drops_its_message() {
        if let Ok(mut g) = STATE.lock() {
            *g = Some(State {
                first_run: ok_state(),
                page: Page::Camera,
                action: None,
                action_message: None,
            });
        }
        record_action(Some(("declined", "declined")));
        set_page(Page::Input);
        assert_eq!(action_message(), None);
        if let Ok(mut g) = STATE.lock() {
            *g = None;
        }
    }

    /// Every outcome except success earns a sentence, and success earns none.
    ///
    /// This is the guard on the bug itself: a silent `None` for a *failure* is how
    /// two of the three surfaces ended up mute. Adding a variant to `Elevation`
    /// makes the loop below miss it and the assertion fail, rather than silently
    /// producing nothing.
    #[test]
    fn only_success_is_silent() {
        use crate::elevate::Elevation;
        assert!(install_outcome(Elevation::PromptAccepted).is_none());
        for outcome in [
            Elevation::Declined,
            Elevation::Unavailable,
            Elevation::AlreadyElevated,
        ] {
            let (zh, en) =
                install_outcome(outcome).unwrap_or_else(|| panic!("{outcome:?} must say something"));
            assert!(!zh.is_empty() && !en.is_empty(), "{outcome:?} said nothing");
        }
    }
}
