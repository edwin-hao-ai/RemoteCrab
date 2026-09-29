//! Optional file logger for the COM server.
//!
//! The source runs inside *other* processes (our app, the Windows Frame
//! Server, the reader app), so console output is not visible. Set
//! `RCVCAM_LOG=<path>` to capture the activation/call sequence; when it is
//! unset or empty this compiles down to an env read that is cached, then
//! never opens or writes a file.

#![cfg(windows)]

use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;

/// `Some(path)` when logging was requested, `None` when it was not.
/// Resolved once per process; `None` short-circuits every later `log`.
fn log_path() -> Option<&'static PathBuf> {
    static PATH: OnceLock<Option<PathBuf>> = OnceLock::new();
    PATH.get_or_init(|| {
        std::env::var_os("RCVCAM_LOG")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    })
    .as_ref()
}

/// Appends one line to the file named by `RCVCAM_LOG`. No-op when unset.
pub fn log(msg: impl AsRef<str>) {
    let Some(path) = log_path() else { return };
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(f, "[pid {}] {}", std::process::id(), msg.as_ref());
    }
}
