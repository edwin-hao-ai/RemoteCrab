//! Removing RemoteCrab from a machine, completely.
//!
//! The product writes in four places, and an uninstall that misses any of them
//! leaves something behind that the next install trips over:
//!
//! | what | where | needs admin |
//! |---|---|---|
//! | start-at-login | `HKCU\…\Run\RemoteCrab` | no |
//! | app state | `%APPDATA%\RemoteCrab` | no |
//! | COM camera source | `HKLM\…\CLSID\{…}` | **yes** |
//! | camera ring buffer | `%ProgramData%\RemoteCrab\vcam-ring.bin` | yes |
//!
//! The ring file is the one that is easy to miss and awkward to leave: it is
//! created with a **NULL DACL** so the Frame Server can map it while running as
//! `LocalService`. A file that permissive is not removed by an ordinary user, so
//! skipping it leaves a world-writable buffer behind and the next install
//! inherits whatever was in it.
//!
//! Only the paths, the bookkeeping and the filesystem half live here — they are
//! pure enough to test on any host. The COM registration needs `rc-vcam`, which
//! is a Windows-only dependency of the *app*, so `main.rs` calls that itself.

use std::path::{Path, PathBuf};

/// What the uninstall managed to do, so the caller can be honest about it.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Removed {
    pub run_value: bool,
    pub app_data: bool,
    /// Not set here — `rc-app` fills this in, because deleting the CLSID needs
    /// `rc-vcam` and administrator rights.
    pub clsid: bool,
    pub ring: bool,
}

impl Removed {
    /// Anything left that only an administrator can remove.
    pub fn needs_admin(&self) -> bool {
        !self.clsid || !self.ring
    }

    pub fn is_complete(&self) -> bool {
        !self.needs_admin()
    }
}

/// `%APPDATA%\RemoteCrab` — per-user state, no elevation needed.
pub fn appdata_dir() -> PathBuf {
    base("APPDATA", r"C:\Users\Default\AppData\Roaming").join("RemoteCrab")
}

/// `%ProgramData%\RemoteCrab\vcam-ring.bin` — the NULL-DACL frame ring.
pub fn ring_path() -> PathBuf {
    base("ProgramData", r"C:\ProgramData")
        .join("RemoteCrab")
        .join("vcam-ring.bin")
}

fn base(var: &str, fallback: &str) -> PathBuf {
    std::env::var_os(var)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(fallback))
}

/// The per-user half. Safe without administrator rights.
#[cfg(windows)]
pub fn remove_user_state() -> Removed {
    Removed {
        run_value: crate::autostart::set_enabled(false),
        app_data: remove_dir(&appdata_dir()),
        ..Default::default()
    }
}

/// The machine-wide half that does not need `rc-vcam`. Needs elevation, because
/// `%ProgramData%` is machine-wide.
#[cfg(windows)]
pub fn remove_machine_files() -> bool {
    remove_file(&ring_path())
}

#[cfg(not(windows))]
pub fn remove_user_state() -> Removed {
    Removed::default()
}

#[cfg(not(windows))]
pub fn remove_machine_files() -> bool {
    false
}

/// Delete a file, treating "already gone" as success.
///
/// This is the difference between an uninstall that is idempotent and one that
/// reports failure the second time a user runs it.
pub fn remove_file(path: &Path) -> bool {
    match std::fs::remove_file(path) {
        Ok(()) => true,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => true,
        Err(e) => {
            eprintln!("  could not remove {}: {e}", path.display());
            false
        }
    }
}

pub fn remove_dir(path: &Path) -> bool {
    match std::fs::remove_dir_all(path) {
        Ok(()) => true,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => true,
        Err(e) => {
            eprintln!("  could not remove {}: {e}", path.display());
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_left_behind_is_complete() {
        let done = Removed {
            run_value: true,
            app_data: true,
            clsid: true,
            ring: true,
        };
        assert!(done.is_complete());
        assert!(!done.needs_admin());
    }

    /// "Needs admin" must name the machine-wide bits, not guess. Half-done is
    /// not done: reporting otherwise is how a machine ends up with a live COM
    /// registration and no way to clear it.
    #[test]
    fn only_the_machine_wide_bits_need_an_administrator() {
        let user_only = Removed {
            run_value: true,
            app_data: true,
            clsid: false,
            ring: false,
        };
        assert!(user_only.needs_admin(), "per-user state is not enough");

        let clsid_only = Removed {
            clsid: true,
            ..user_only
        };
        assert!(clsid_only.needs_admin(), "the ring file still needs admin");

        let ring_only = Removed {
            ring: true,
            clsid: false,
            ..clsid_only
        };
        assert!(ring_only.needs_admin(), "the CLSID still needs admin");
    }

    /// The ring must live at a well-known machine path, never next to the exe:
    /// the Frame Server runs as LocalService and can only reach the former.
    #[test]
    fn the_ring_is_where_the_frame_server_can_reach_it() {
        let ring = ring_path();
        let text = ring.to_string_lossy().replace('\\', "/").to_lowercase();
        assert!(text.ends_with("remotecrab/vcam-ring.bin"), "{text}");
        assert!(
            text.contains("programdata"),
            "the ring must be under ProgramData, got {text}"
        );
    }

    #[test]
    fn app_state_is_per_user() {
        let dir = appdata_dir();
        let text = dir.to_string_lossy().replace('\\', "/").to_lowercase();
        assert!(text.ends_with("remotecrab"), "{text}");
        assert!(!text.contains("programdata"), "{text}");
    }

    /// An uninstall has to be safe to run twice, and a partially-removed
    /// machine must not report the second run as a fresh failure.
    #[test]
    fn removing_something_absent_counts_as_done() {
        let dir = std::env::temp_dir().join("remotecrab-uninstall-does-not-exist");
        assert!(remove_dir(&dir));
        assert!(remove_file(&dir.join("nope.bin")));
    }
}
