//! One receiver per PC.
//!
//! Without this, a double-click while the `Run` key had already started it
//! gives the user **two tray icons and two receivers fighting over one iPhone**
//! — one of them silently losing every race and retrying forever. On a Mac
//! this is invisible (one menu bar item); on Windows it is two icons and a
//! baffling "sometimes it's busy" report.
//!
//! `CreateMutexW` is the Windows mechanism, and it is the right one: the
//! kernel drops the handle when the process dies for any reason, so a crashed
//! instance does not block the next launch. A lock *file* would.

/// Held for the life of the process. Dropping it releases the mutex.
pub struct Instance {
    #[cfg(windows)]
    handle: windows::Win32::Foundation::HANDLE,
    /// Whether we are the first instance. A second one says so and exits
    /// rather than starting a rival receiver.
    primary: bool,
}

impl Instance {
    pub fn is_primary(&self) -> bool {
        self.primary
    }
}

/// The decision, separated from the mechanism.
///
/// "Did someone already own it?" is the part worth testing, and the part that
/// is easy to get wrong; `CreateMutexW` is just how Windows answers it. Keeping
/// them apart means the rule is exercised on every platform, not only on the
/// one where the answer happens to be a syscall.
fn is_primary(already_taken: bool) -> bool {
    !already_taken
}

/// Take the per-user instance mutex, or report that another copy owns it.
///
/// The name carries the user id so two people signed into the same PC do not
/// collide — a named mutex is a machine-global object, not a per-session one.
pub fn acquire() -> Instance {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS};
        use windows::Win32::System::Threading::CreateMutexW;

        let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".into());
        let name = format!("Local\\RemoteCrab-{user}");
        let wide: Vec<u16> = std::ffi::OsStr::new(&name)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();

        // SAFETY: a plain named-mutex create. `lpMutexAttributes = None` asks
        // for default security, which for a `Local\` name is the creating
        // user's own session.
        let handle = unsafe { CreateMutexW(None, true, windows::core::PCWSTR(wide.as_ptr())) };
        let already = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
        Instance {
            handle: handle.unwrap_or_default(),
            primary: is_primary(already),
        }
    }
    #[cfg(not(windows))]
    {
        // The cross build exists to type-check `#[cfg(windows)]` code and to
        // run these tests; it is never shipped, so there is no second process
        // to exclude. A process-local flag stands in for the mutex so the
        // *rule* is still exercised.
        static PRIMARY_CLAIMED: std::sync::atomic::AtomicBool =
            std::sync::atomic::AtomicBool::new(false);
        let first = !PRIMARY_CLAIMED.swap(true, std::sync::atomic::Ordering::SeqCst);
        Instance {
            primary: is_primary(!first),
        }
    }
}

impl Drop for Instance {
    fn drop(&mut self) {
        #[cfg(windows)]
        {
            use windows::Win32::Foundation::CloseHandle;
            // SAFETY: we own this handle; it is closed exactly once, here.
            unsafe {
                let _ = CloseHandle(self.handle);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Two copies of the receiver must not both claim to be primary: they
    /// would fight over one iPhone, and the loser retries forever, which reads
    /// to a user as "it is randomly busy".
    ///
    /// Acquiring twice in one process is the same shape as launching twice. On
    /// Windows this genuinely trips the `ERROR_ALREADY_EXISTS` path; elsewhere
    /// a process-local flag stands in, so the rule is still checked.
    #[test]
    fn exactly_one_acquisition_is_primary() {
        let first = acquire();
        let second = acquire();
        assert!(first.is_primary(), "nothing else holds the mutex yet");
        assert!(
            !second.is_primary(),
            "two copies of the receiver would fight over the same iPhone"
        );
    }

    #[test]
    fn the_rule_reads_the_platform_answer_correctly() {
        assert!(
            is_primary(false),
            "nobody held it, so this process is first"
        );
        assert!(
            !is_primary(true),
            "somebody held it, so this process is not"
        );
    }
}
