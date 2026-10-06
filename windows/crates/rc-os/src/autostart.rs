//! "Start at login", which is the logon task rather than the Run key.
//!
//! This wrote `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` and documented
//! "no admin rights and no installer needed" as the virtue. That virtue was the
//! bug: the Run key starts the receiver at whatever integrity level Explorer hands
//! out, which is medium, and a medium process cannot send input to a window that is
//! running as administrator. So the receiver told people to "run it once as
//! administrator", which is advice about one launch rather than about the setting.
//!
//! The task is in [`crate::logon_task`]. This module is the two-function face the
//! app talks to — a query and a change — so that the app never has to know which
//! of the two mechanisms is in use.

/// Is the receiver registered to start at login?
pub fn is_enabled() -> bool {
    crate::logon_task::is_installed()
}

/// Enable or disable start-at-login. Returns whether the setting now matches.
///
/// Needs administrator rights, and reports that through its return value rather
/// than by raising a prompt: a library that opens a UAC dialog has taken a decision
/// that belongs to the application. The app calls this only from a process that is
/// already elevated — it raises the prompt itself, and the elevated copy it starts
/// is what arrives here.
pub fn set_enabled(on: bool) -> bool {
    let result = if on {
        crate::logon_task::create()
    } else {
        crate::logon_task::remove()
    };
    match result {
        // Read back rather than assumed: `schtasks` exiting 0 says it was asked
        // and did not refuse, and the scheduler is the only authority on whether
        // the task is there.
        Ok(()) => is_enabled() == on,
        Err(reason) => {
            eprintln!("autostart: {reason}");
            false
        }
    }
}
