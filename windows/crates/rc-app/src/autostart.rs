//! Start-at-login, from the user's side.
//!
//! The mechanism is the logon task (`rc_os::logon_task`), and the reason is the
//! one thing this product cannot work around from inside itself: a medium-integrity
//! process cannot send input to a window that is running as administrator. The
//! Run key cannot start an elevated process; a scheduled task with run level
//! *highest* can, at logon, with no prompt.
//!
//! The cost is that the setting now needs an administrator to change. Saying so is
//! this module's job — the library underneath reports what the scheduler says, and
//! the decision to raise a prompt, and the fact that a prompt the user refused is a
//! **normal outcome rather than an error**, belongs here next to the other
//! elevation.

use crate::elevate::{self, Elevation};

/// Is the receiver set to start at login?
///
/// Asked of the scheduler every time rather than cached. A remembered answer is
/// how a settings window comes to insist the setting is on long after the user
/// deleted the task by hand.
pub fn is_enabled() -> bool {
    rc_os::autostart::is_enabled()
}

/// Turn start-at-login on or off, asking for the rights to do it.
///
/// Returns whether the setting now matches the request.
pub fn set(on: bool) -> bool {
    if elevate::is_elevated() {
        // Already able to change it, so change it here rather than starting a
        // second copy of ourselves to do the same one-line job.
        return rc_os::autostart::set_enabled(on);
    }

    let flag = flag_for(on);
    match elevate::run_elevated(flag) {
        // `ShellExecuteW` does not wait for the child, so the answer is read back
        // from the scheduler. Believing the accepted prompt would put a tick on
        // screen for something that has not happened yet, which is the stale tick
        // this project keeps meeting from the other direction.
        Elevation::PromptAccepted => wait_until(on),
        // Everything else is "the setting did not change": a refused prompt and a
        // policy that blocks elevation are both normal, and neither is a success.
        _ => is_enabled() == on,
    }
}

/// The one-shot flag that does this job when the app is re-launched elevated.
///
/// One place, because three things have to agree on these strings: this module
/// raises the prompt with them, `args` parses them, and the MSI's custom actions
/// pass them. A rename that stopped at two of the three would be a toggle that
/// silently does nothing, or an installer that silently does nothing.
fn flag_for(on: bool) -> &'static str {
    if on {
        "--install-logon-task"
    } else {
        "--remove-logon-task"
    }
}

/// Poll the scheduler until it agrees, or give up and report what it says.
///
/// Two seconds, in tenths: the elevated copy is a process start plus one
/// `schtasks` call, and a UI thread waiting longer than this for a checkbox is
/// worse than a checkbox that catches up on the next rebuild.
fn wait_until(on: bool) -> bool {
    for _ in 0..20 {
        if is_enabled() == on {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    is_enabled() == on
}

#[cfg(test)]
mod tests {
    use super::flag_for;

    /// The strings the installer passes and this module raises a prompt with are
    /// the same two. Written down rather than derived, because deriving them from
    /// the function under test is how a test comes to agree with a bug.
    #[test]
    fn the_flags_are_the_ones_the_installer_uses() {
        assert_eq!(flag_for(true), "--install-logon-task");
        assert_eq!(flag_for(false), "--remove-logon-task");
    }

    /// The two must not be the same string, which is the mistake that would make
    /// "turn it off" quietly turn it on.
    #[test]
    fn on_and_off_are_different_flags() {
        assert_ne!(flag_for(true), flag_for(false));
    }
}
