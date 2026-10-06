//! The logon task: how RemoteCrab starts itself at login **with the privileges it
//! needs**.
//!
//! The Run key cannot do that. It starts a process at whatever integrity level
//! Explorer hands it, which is medium, and a medium process cannot send input to
//! a window that is running as administrator. That is User Interface Privilege
//! Isolation, and it is not something the receiver can work around from inside
//! itself: `SendInput` simply does nothing to a higher-integrity window. The old
//! answer was to tell the user to "run it once as administrator", which fixes the
//! next launch and not the one after it.
//!
//! A scheduled task with run level *highest* starts elevated at logon with no
//! prompt, because the Task Scheduler holds the token. Creating the task needs
//! administrator rights once; after that the machine boots into a receiver that
//! can drive every window. That is the same shape as the camera registration —
//! one elevated action, taken by the installer, buying a permanent property.
//!
//! `schtasks.exe` rather than the Task Scheduler COM API. The API is the
//! documented way and it is several hundred lines of plumbing to express four
//! fields; `schtasks` is a stable system binary that takes them as arguments, and
//! the argument vectors are built by the pure functions below so that what gets
//! asked for is checked by a test rather than by hoping.

use std::process::Command;

/// The task's name.
///
/// One task, so the name is also its identity: creating it twice replaces it, and
/// removing it cannot take anything else with it.
pub const TASK_NAME: &str = "RemoteCrab";

/// `CREATE_NO_WINDOW`. Without it, a console window flashes open and shut every
/// time this runs from a program that has no console of its own.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// The command the task should run: this executable, quoted.
///
/// Quoted because an install path with a space in it is the normal case here, not
/// the edge case — `C:\Program Files\RemoteCrab\` — and `schtasks` splits `/tr` on
/// spaces.
fn exe_command() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    Some(format!("\"{}\"", exe.display()))
}

/// The arguments that create the task.
///
/// `/sc onlogon` fires it at logon; `/rl highest` is the whole point — the task
/// runs with the highest privileges the account has, which is what lets the
/// receiver drive elevated windows; `/f` replaces an existing task, so an upgrade
/// that only changed the install path is not a failure.
fn create_args(exe: &str) -> Vec<String> {
    ["/create", "/tn", TASK_NAME, "/tr", exe, "/sc", "onlogon", "/rl", "highest", "/f"]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

/// The arguments that remove the task.
fn delete_args() -> Vec<String> {
    ["/delete", "/tn", TASK_NAME, "/f"]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

fn run(args: &[String]) -> Option<std::process::Output> {
    let mut command = Command::new("schtasks");
    command.args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command.output().ok()
}

/// Is the task registered?
///
/// Asked of the scheduler rather than remembered in a file of our own. The user
/// can delete the task from Task Scheduler, and a settings window that insists
/// the setting is on because a flag we wrote says so is the stale-tick bug this
/// project keeps meeting.
pub fn is_installed() -> bool {
    run(&["/query".to_string(), "/tn".to_string(), TASK_NAME.to_string()])
        .is_some_and(|o| o.status.success())
}

/// Register the logon task. Needs administrator rights.
pub fn create() -> Result<(), String> {
    let exe = exe_command().ok_or("could not determine the executable path")?;
    let output = run(&create_args(&exe)).ok_or("could not run schtasks.exe")?;
    if output.status.success() {
        Ok(())
    } else {
        Err(describe(&output))
    }
}

/// Remove the logon task.
///
/// Succeeds when there is no task to remove, so that uninstalling on a machine
/// where the user deleted it by hand is not a failed uninstall.
pub fn remove() -> Result<(), String> {
    if !is_installed() {
        return Ok(());
    }
    let output = run(&delete_args()).ok_or("could not run schtasks.exe")?;
    if output.status.success() {
        Ok(())
    } else {
        Err(describe(&output))
    }
}

/// What went wrong, as much of it as fits on a line of a log.
///
/// The message comes from `schtasks` in the console's **OEM code page**, so it is
/// decoded as that and not as UTF-8. `from_utf8_lossy` on a Chinese Windows turns
/// "拒绝访问" into a row of replacement characters, which is a diagnostic that
/// cannot be read at exactly the moment someone needs to read it. The exit code is
/// printed alongside the message because that part is never ambiguous.
fn describe(output: &std::process::Output) -> String {
    let text = decode_console(&output.stderr);
    let line = text
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("no message");
    format!(
        "schtasks exited with {}: {line}",
        output
            .status
            .code()
            .map(|c| c.to_string())
            .unwrap_or_else(|| "no code".to_string())
    )
}

/// Decode text a console program wrote, in the OEM code page.
#[cfg(windows)]
fn decode_console(bytes: &[u8]) -> String {
    use windows::Win32::Globalization::{MultiByteToWideChar, CP_OEMCP};
    if bytes.is_empty() {
        return String::new();
    }
    let flags = Default::default();
    // The first call is the size query; passing no output buffer is how the API
    // says "tell me how much room".
    let needed = unsafe { MultiByteToWideChar(CP_OEMCP, flags, bytes, None) };
    if needed <= 0 {
        return String::from_utf8_lossy(bytes).into_owned();
    }
    let mut wide = vec![0u16; needed as usize];
    let written = unsafe { MultiByteToWideChar(CP_OEMCP, flags, bytes, Some(&mut wide)) };
    String::from_utf16_lossy(&wide[..written.max(0) as usize])
}

#[cfg(not(windows))]
fn decode_console(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[cfg(test)]
mod tests {
    use super::{create_args, delete_args, TASK_NAME};

    /// The four fields that matter, pinned. `/rl highest` is the one that makes
    /// the task worth having: without it the task starts a medium process at logon
    /// and the receiver is exactly as unable to drive elevated windows as the Run
    /// key made it.
    #[test]
    fn the_task_is_created_at_logon_with_the_highest_run_level() {
        let args = create_args("\"C:\\Program Files\\RemoteCrab\\remotecrab.exe\"");
        assert!(args.windows(2).any(|w| w == ["/sc", "onlogon"]));
        assert!(args.windows(2).any(|w| w == ["/rl", "highest"]));
        assert!(args.contains(&"/f".to_string()));
        assert!(args.windows(2).any(|w| w == ["/tn", TASK_NAME]));
    }

    /// The path goes in as one argument and keeps its quotes. `schtasks` splits
    /// `/tr` on spaces, so an unquoted `C:\Program Files\...` creates a task that
    /// runs `C:\Program`.
    #[test]
    fn the_executable_is_passed_quoted() {
        let args = create_args("\"C:\\Program Files\\RemoteCrab\\remotecrab.exe\"");
        let tr = args.iter().position(|a| a == "/tr").expect("/tr") + 1;
        assert_eq!(
            args[tr],
            "\"C:\\Program Files\\RemoteCrab\\remotecrab.exe\""
        );
    }

    /// Removal names the same task, and is forced: a task somebody has left
    /// running must not turn an uninstall into an error.
    #[test]
    fn removal_uses_the_same_name_and_does_not_ask() {
        let args = delete_args();
        assert!(args.windows(2).any(|w| w == ["/tn", TASK_NAME]));
        assert!(args.contains(&"/f".to_string()));
    }

    /// Whichever way the task is touched, it is the same task.
    #[test]
    fn both_operations_name_one_task() {
        let created = create_args("x");
        let deleted = delete_args();
        assert_eq!(
            created.iter().position(|a| a == TASK_NAME),
            deleted.iter().position(|a| a == TASK_NAME)
        );
    }
}
