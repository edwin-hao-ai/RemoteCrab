//! Crash visibility and single-instance: the two things standing between a
//! developer build and something you would let a customer install.
//!
//! **Why this file exists.** The release profile leaves `panic = "unwind"`
//! (deliberately — a tray app that vanishes with no dialog is worse than a
//! crash dialog), but nothing ever *caught* the unwind. A panic on a worker
//! thread wrote to stderr, which for a console-subsystem app launched from
//! Explorer or from the `Run` key goes nowhere. The tray thread is the worst
//! case: its message pump stops, the window is never destroyed, `NIM_DELETE`
//! never fires, Explorer keeps showing the icon, and the command channel — held
//! inside the window's `GWLP_USERDATA` — never closes. The user is left with a
//! **live, unclickable tray icon over a status that still says connected**,
//! for a program whose entire job is driving their PC.

use std::io::Write;
use std::path::PathBuf;

/// Where the log lives, and how it is found.
///
/// Resolution is its own decision, and a testable one: `%LOCALAPPDATA%` on
/// Windows, `~/Library/Logs/RemoteCrab` elsewhere. A relative path would be
/// worse than none — a program started from a different working directory
/// would scatter logs, and `RCVCAM_LOG` already demonstrated that failure by
/// writing a file literally named `1` into the CWD.
pub fn log_path() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Logs")));
    let dir = base
        .map(|b| b.join("RemoteCrab"))
        .unwrap_or_else(|| PathBuf::from("."));
    dir.join("RemoteCrab.log")
}

/// Cap the log. A crashed loop must not fill the disk, and the file is what a
/// support conversation needs — 256 KB is a few hundred panics' worth.
const MAX_LOG_BYTES: u64 = 256 * 1024;

/// Append one line, truncating first if the file has outgrown its cap.
///
/// Best-effort by construction: a failure to write a log line must never be
/// the reason the process dies, so every error here is swallowed on purpose.
pub fn log_line(line: &str) {
    let path = log_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    rotate_if_needed(&path);
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(f, "[{stamp}] {line}");
    }
}

/// Half of the previous file, kept — a crash loop should not lose the *most
/// recent* few lines to the rotation, which is the part that explains it.
fn rotate_if_needed(path: &std::path::Path) {
    let Ok(meta) = std::fs::metadata(path) else {
        return;
    };
    if meta.len() <= MAX_LOG_BYTES {
        return;
    }
    let keep = (MAX_LOG_BYTES / 2) as usize;
    if let Ok(bytes) = std::fs::read(path) {
        let start = bytes.len().saturating_sub(keep);
        let tail = &bytes[start..];
        let _ = std::fs::write(path, tail);
    }
}

/// Install a panic hook that writes to the log before the default one runs.
///
/// `catch_unwind` on its own would not be enough — the supervisor's own task
/// must keep running for the user to be able to reconnect, and a poisoned
/// mutex in a worker would take the tray thread with it. So: record it, and
/// let the default behaviour stand.
pub fn install_panic_hook() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let where_ = info
            .location()
            .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
            .unwrap_or_else(|| "unknown".to_string());
        let msg = info
            .payload()
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "<non-string payload>".to_string());
        log_line(&format!("PANIC at {where_}: {msg}"));
        previous(info);
    }));
}

/// A one-line description of the process's start, so a log found on a user's
/// machine says which build produced it.
pub fn log_startup(version: &str, argv: &[String]) {
    log_line(&format!(
        "RemoteCrab {version} starting ({} args, pid {})",
        argv.len(),
        std::process::id()
    ));
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The path must be absolute and under a per-user directory. A relative
    /// path is the bug `RCVCAM_LOG` shipped once already: the file ended up
    /// named `1` in whatever the current directory happened to be.
    #[test]
    fn the_log_path_is_not_relative() {
        let p = log_path();
        assert!(p.is_absolute(), "log path must be absolute, got {p:?}");
        assert!(p.ends_with("RemoteCrab.log"), "unexpected log name: {p:?}");
    }

    /// Rotation must keep the *tail*. A crash loop that overwrites the recent
    /// lines with the old ones loses exactly the evidence that explains it.
    #[test]
    fn rotation_keeps_the_most_recent_lines() {
        let dir = std::env::temp_dir().join(format!("rc-diag-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.log");

        let big = "x".repeat(MAX_LOG_BYTES as usize + 4096);
        std::fs::write(&path, &big).unwrap();
        std::fs::write(&path, format!("{big}NEEDLE")).unwrap();
        rotate_if_needed(&path);

        let after = std::fs::read_to_string(&path).unwrap();
        assert!(
            after.contains("NEEDLE"),
            "rotation dropped the newest bytes — that is the part that explains the crash"
        );
        assert!(
            after.len() as u64 <= MAX_LOG_BYTES,
            "rotation did not shrink it"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// A file under the cap is left completely alone — no rewrite, no
    /// truncation, and in particular the same bytes on disk.
    #[test]
    fn a_small_log_is_untouched() {
        let dir = std::env::temp_dir().join(format!("rc-diag2-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.log");
        std::fs::write(&path, "one\ntwo\n").unwrap();
        rotate_if_needed(&path);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "one\ntwo\n");
        let _ = std::fs::remove_file(&path);
    }
}
