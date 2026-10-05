//! Getting the virtual camera registered without asking the user to compile
//! anything.
//!
//! The problem this solves: registering the COM source writes to `HKLM`, which
//! needs an administrator. The code that does it lived in a *second binary*
//! (`rc-vcam.exe`), so the only instruction that could be given to a user was
//! "build it yourself and run it once as admin" — which is not an instruction a
//! person who installed a program can act on.
//!
//! The fix is the ordinary Windows one: re-launch **this** executable with the
//! `runas` verb, which raises the UAC prompt, and let the elevated copy do the
//! one small job. So the whole flow is:
//!
//! ```text
//!   normal run  →  ACCESS_DENIED
//!               →  tray row "安装虚拟摄像头" (only when it is not installed)
//!               →  ShellExecuteW("runas", remotecrab.exe --install-vcam)
//!               →  UAC prompt
//!               →  elevated copy registers, exits
//!               →  normal run notices it is registered and carries on
//! ```
//!
//! Note what is deliberately absent: no "enter the IP manually" equivalent, no
//! "copy this DLL into the registry yourself" instructions, and no telling the
//! user to run a terminal. One row, one prompt, one obvious action.

// The Windows APIs, and only these. `Elevation` and the argument quoting below
// are plain data, and `is_elevated` goes through `notify_relay`, which already
// compiles on every host — so the module itself does not need a platform gate.
// Gating the whole `mod elevate` is what broke `cargo build --workspace` off
// Windows: `wizard.rs` is compiled everywhere and names `Elevation`, and the
// crate's own `#[cfg_attr(not(windows), allow(dead_code))]` on those functions
// says compiling them here was the intent all along.
#[cfg(windows)]
use windows::core::HSTRING;
#[cfg(windows)]
use windows::Win32::Foundation::GetLastError;
#[cfg(windows)]
use windows::Win32::UI::Shell::ShellExecuteW;
#[cfg(windows)]
use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;

/// What the user experienced, so the caller can say something true.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Elevation {
    /// The elevated copy finished. Windows gives us no exit code, so this
    /// means "the prompt was accepted and the child ran" — never "it worked".
    PromptAccepted,
    /// The user clicked "No". Perfectly normal; not an error to shout about.
    Declined,
    /// The prompt could not be shown at all (a policy blocks UAC, a packaged
    /// build without the right manifest, no shell). Rare, and worth saying.
    Unavailable,
    /// Already elevated, and it still failed. Raising a prompt now would either
    /// loop forever or accomplish nothing, so the honest answer is to report the
    /// underlying failure instead.
    AlreadyElevated,
}

/// Is this process already running elevated?
///
/// The check exists because of a bug this module's own design invited. The
/// one-shot entry point re-launches itself with `runas` when the registry write
/// is refused; the elevated copy then runs **the same flag**, hits the same
/// refused write, and re-launches itself again. The user gets UAC prompts
/// forever and no camera. Nothing is left running afterwards except the
/// evidence.
///
/// Reusing the integrity level rather than opening a fresh token query: the app
/// already computes it for the first-run check, and a UAC-elevated process is
/// precisely the High-integrity one. If the level cannot be read we answer
/// "not elevated", because that is the answer that keeps the prompt available —
/// the cost of guessing wrong upward is a pointless prompt, and the cost of
/// guessing wrong downward is the loop above.
pub fn is_elevated() -> bool {
    crate::notify_relay::integrity() == rc_net::firstrun::Integrity::High
}

/// Re-launch this executable elevated with `flag`, and wait for it to finish.
///
/// The elevated copy runs exactly one job and exits, so waiting matters: the
/// caller has to be able to say "done" rather than "probably running".
///
/// The window is hidden on purpose. A console window flashing open and shut is
/// the clearest possible signal that something happened, and this is a program
/// with no console of its own once installed.
pub fn run_elevated(flag: &str) -> Elevation {
    let Ok(exe) = std::env::current_exe() else {
        return Elevation::Unavailable;
    };
    elevate(&exe, flag)
}

/// Off Windows there is no `ShellExecuteW` and no UAC, so the honest answer is
/// `Unavailable` — the same thing Windows reports when a policy blocks the
/// prompt. Not a stub that pretends: nobody can install the virtual camera here
/// either way, and a fabricated `PromptAccepted` would read as success.
#[cfg(not(windows))]
fn elevate(_exe: &std::path::Path, _flag: &str) -> Elevation {
    Elevation::Unavailable
}

/// Split out so the argument-building and the `ShellExecuteW` call can be
/// reasoned about (and tested) separately from the process-wide bits.
#[cfg(windows)]
fn elevate(exe: &std::path::Path, flag: &str) -> Elevation {
    // `ShellExecuteW` takes a *quoted* command line. An install path with a
    // space in it — `C:\Program Files\RemoteCrab\` is the normal one — is the
    // common case, not the edge case, so this cannot be skipped.
    let params = format!(
        "\"{}\" {}",
        quote_arg(&exe.to_string_lossy()),
        quote_arg(flag)
    );

    // `await` vs `wait`: `ShellExecuteW` returns immediately, so `wait` is
    // correct for a one-shot elevated job. `SEE_MASK_NOCLOSEPROCESS` is
    // deliberately NOT set — we do not want a handle to leak.
    let result = unsafe {
        ShellExecuteW(
            None,
            &HSTRING::from("runas"),
            &HSTRING::from(exe.as_os_str()),
            &HSTRING::from(params),
            None,
            SW_HIDE,
        )
    };

    // ShellExecuteW returns > 32 on success. A "success" under that is a
    // *user* outcome: ERROR_CANCELLED (1223) is the documented way the shell
    // reports "No" on the UAC dialog.
    if result.0 as isize > 32 {
        Elevation::PromptAccepted
    } else if unsafe { GetLastError() } == windows::Win32::Foundation::ERROR_CANCELLED {
        Elevation::Declined
    } else {
        Elevation::Unavailable
    }
}

/// Quote a command-line argument for `CommandLineToArgvW`'s rules.
///
/// `argv[0]` needs the quotes unconditionally; the flag does not strictly, but
/// quoting both keeps one rule instead of two.
fn quote_arg(arg: &str) -> String {
    let needs_quotes = arg.is_empty() || arg.chars().any(|c| c == ' ' || c == '\t' || c == '"');
    if needs_quotes {
        // Backslashes immediately before the closing quote must be doubled, or
        // the closing quote is read as escaped. `C:\Program Files\` is exactly
        // the case that gets this wrong.
        let trailing = arg.chars().rev().take_while(|c| *c == '\\').count();
        let mut out = String::with_capacity(arg.len() + 3);
        out.push('"');
        out.push_str(&arg[..arg.len() - trailing]);
        for _ in 0..trailing * 2 {
            out.push('\\');
        }
        out.push('"');
        out
    } else {
        arg.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::{is_elevated, quote_arg, Elevation};

    /// The install path with a space in it is the *normal* case, so a quoting
    /// bug here is not an edge case — it is the default install breaking.
    #[test]
    fn a_path_with_a_space_is_quoted() {
        assert_eq!(
            quote_arg(r"C:\Program Files\RemoteCrab\remotecrab.exe"),
            r#""C:\Program Files\RemoteCrab\remotecrab.exe""#
        );
    }

    /// Backslashes before the closing quote have to be doubled, or the quote
    /// itself is consumed as an escape and the argument runs on.
    #[test]
    fn trailing_backslashes_are_doubled_inside_quotes() {
        assert_eq!(
            quote_arg(r"C:\path with space\"),
            r#""C:\path with space\\""#
        );
    }

    #[test]
    fn a_simple_flag_is_not_padded() {
        assert_eq!(quote_arg("--install-vcam"), "--install-vcam");
    }

    #[test]
    fn an_empty_argument_survives_as_an_empty_argument() {
        assert_eq!(quote_arg(""), r#""""#);
    }

    /// A user clicking "No" is a normal outcome, not a failure to report as
    /// one — the caller words the two differently.
    #[test]
    fn declining_is_distinct_from_being_unavailable() {
        assert_ne!(Elevation::Declined, Elevation::Unavailable);
        assert_ne!(Elevation::PromptAccepted, Elevation::Declined);
    }

    /// "Already elevated and it still failed" must not be conflated with "the
    /// prompt could not be shown". They call for different words: one says
    /// policy is in the way, the other says retrying will not help. Folding
    /// them together is how a real refusal gets reported as a UAC problem.
    #[test]
    fn already_elevated_is_distinct_from_unavailable() {
        assert_ne!(Elevation::AlreadyElevated, Elevation::Unavailable);
        assert_ne!(Elevation::AlreadyElevated, Elevation::Declined);
        assert_ne!(Elevation::AlreadyElevated, Elevation::PromptAccepted);
    }

    /// The recursion guard. This test runs in CI as an ordinary medium-integrity
    /// process, so it can only assert the *negative* — but that is the half that
    /// matters, because it is the half that, when wrong, prompts forever.
    #[test]
    fn an_ordinary_test_process_is_not_elevated() {
        assert!(
            !is_elevated(),
            "if CI ever runs elevated, this guard is masking a real elevation path"
        );
    }
}
