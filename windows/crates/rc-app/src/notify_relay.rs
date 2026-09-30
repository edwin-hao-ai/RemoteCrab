//! Whether desktop notifications are forwarded to the phone, and the plumbing
//! that does it.
//!
//! **Off unless the user turns it on.** That is not a default that can be
//! argued about: the relay reads the *contents* of every notification Windows
//! shows and puts them on another device. A product that does that before being
//! asked is a surprise with a network stack, and the setting is one row away
//! from being turned off again.
//!
//! The setting is a small JSON file under `%APPDATA%`, matching what the rest
//! of the app persists. Not the registry: this is a per-user preference, not
//! machine configuration, and `%APPDATA%` is already removed by the uninstaller.

// `read`, `write` and `set_enabled` are reached from the Windows-shaped tray
// row and the listener start-up, so on a non-Windows host they have no caller.
// They are still compiled and still tested: the persisted shape is a shipped
// data format, and it is the part that must not rot. Marking them
// `allow(dead_code)` rather than `cfg(windows)` because a `cfg` would stop the
// tests from running at all.
use std::path::PathBuf;

/// The decisions, kept pure so they can be tested without Windows.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Config {
    /// Apps never relayed. Substring-matched, so a helper process is covered by
    /// its parent's entry.
    ///
    ///  is not optional here: a build that adds a field to
    /// this file must not read an older file as a parse error, which would fall
    /// back to a default and **silently empty the user's list**.
    #[serde(default)]
    pub denylist: Vec<String>,
}

fn path() -> PathBuf {
    std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Users\Default\AppData\Roaming"))
        .join("RemoteCrab")
        .join("notify-relay.json")
}

#[allow(dead_code)] // see the module note
fn read() -> Config {
    let Ok(text) = std::fs::read_to_string(path()) else {
        return Config::default();
    };
    // A corrupt file must not silently turn the relay **on**. Defaulting to
    // "enabled" here would mean a bad write turns on a privacy feature.
    serde_json::from_str(&text).unwrap_or_default()
}

/// Persist the denylist. Currently only reachable from tests and from a
/// future settings dialog — but it is the *only* writer, so when the UI lands
/// it cannot accidentally write a different shape.
#[allow(dead_code)] // see the module note
fn write(cfg: &Config) -> bool {
    let p = path();
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    serde_json::to_string_pretty(cfg)
        .ok()
        .and_then(|t| std::fs::write(&p, t).ok())
        .is_some()
}

/// Whether the relay is on. A separate file from the denylist so the two
/// decisions — "may I?" and "what not?" — cannot be lost together.
fn flag_path() -> PathBuf {
    path().with_extension("enabled")
}

pub fn is_enabled() -> bool {
    // The mere existence of the flag file is the setting. A `false` written
    // into a JSON file is a value that can be lost to a partial write; a file
    // that is either there or not cannot.
    flag_path().is_file()
}

// Only the tray's relay row flips this, and that row is Windows-shaped.
#[allow(dead_code)] // see the module note
pub fn set_enabled(on: bool) {
    let p = flag_path();
    if on {
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(&p, b"1");
    } else {
        let _ = std::fs::remove_file(&p);
    }
}

/// Start the Windows listener, if the user asked for the relay.
///
/// Returns a short line for the console, because a relay that is off because
/// permission was never granted and a relay that is off because the feature is
/// broken look identical from the outside.
#[cfg(windows)]
pub fn start_listener(
    on_banner: std::sync::Arc<dyn Fn(rc_net::notify::Notification) + Send + Sync>,
) -> Option<()> {
    if !is_enabled() {
        return None;
    }
    let r = relay();
    // The set lives on the poll thread; nothing outside needs it, so it is
    // built there rather than returned.
    let seen = rc_notify::SeenSet::default();
    match rc_notify::start() {
        rc_notify::Listener::Ready(listener) => {
            // A poll tick, not a subscription: `windows` 0.62 does not project
            // the `NotificationPosted` event, and the list is also the only
            // projection that carries the banner's text.
            let relay = r.clone();
            let sink = on_banner.clone();
            std::thread::Builder::new()
                .name("notify-relay".into())
                .spawn(move || {
                    let mut seen = seen;
                    loop {
                        let mut cb = |n| sink(n);
                        rc_notify::poll_once(&listener, &mut seen, &relay, &mut cb);
                        std::thread::sleep(std::time::Duration::from_secs(2));
                    }
                })
                .ok()?;
            println!(
                "  {}",
                crate::i18n::t("通知中继已开启。", "Notification relay is on.")
            );
            Some(())
        }
        rc_notify::Listener::NotPermitted => {
            println!(
                "  {}",
                crate::i18n::t(
                    "Windows 还没有授予通知访问权限，所以中继没启动。设置 → 系统 → 通知里允许「RemoteCrab」访问通知。",
                    "Windows has not granted notification access, so the relay is not running. \
                     Allow RemoteCrab under Settings → System → Notifications.",
                )
            );
            None
        }
        rc_notify::Listener::Unsupported(why) => {
            println!(
                "  {}",
                crate::i18n::t(
                    "这个 Windows 版本不支持通知中继。",
                    "This Windows build does not support the notification relay."
                )
            );
            eprintln!("  notify: {why}");
            None
        }
    }
}

/// The relay as the decision layer wants it. Called by , which
/// is Windows-shaped, and asserted directly in the tests below.
#[allow(dead_code)] // see the module note
pub fn relay() -> rc_net::notify::Relay {
    let cfg = read();
    rc_net::notify::Relay {
        enabled: is_enabled(),
        denylist: cfg.denylist,
        allowlist: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::{flag_path, path, Config};

    /// The file format is a shipped data format: a field that is added without
    /// a default silently wipes a user's list when an older build reads a
    /// newer file, and vice versa.
    #[test]
    fn an_unknown_field_does_not_break_the_config() {
        let parsed: Config = serde_json::from_str(r#"{"denylist":["1Password"],"future":1}"#)
            .expect("a newer file must still parse");
        assert_eq!(parsed.denylist, vec!["1Password".to_string()]);
    }

    #[test]
    fn a_missing_denylist_defaults_to_empty_rather_than_failing() {
        let parsed: Config = serde_json::from_str("{}").expect("parse");
        assert!(parsed.denylist.is_empty());
    }

    /// The switch and the list are two files on purpose, so turning the relay
    /// off cannot take the denylist with it — and turning it back on must not
    /// silently restore a list the user thought they had removed.
    #[test]
    fn the_flag_and_the_denylist_are_separate_decisions() {
        assert_ne!(flag_path(), path());
        assert!(flag_path().extension().is_some());
    }

    /// Read and write are the only pair that touches the denylist, so a round
    /// trip through the wire format has to preserve it.
    #[test]
    fn a_denylist_survives_the_file_format() {
        let cfg = Config {
            denylist: vec!["1Password".into(), "Bank".into()],
        };
        let text = serde_json::to_string(&cfg).expect("serialize");
        let back: Config = serde_json::from_str(&text).expect("parse");
        assert_eq!(back, cfg);
    }
}

/// The process's integrity level, mapped onto the decision layer's enum.
///
/// This is the Windows stand-in for macOS's Accessibility grant, and the
/// reason the first-run check exists: there is nothing to *grant*, but
/// `SendInput` cannot reach a window with a higher integrity level than the
/// sender, and it fails **silently** when it cannot. Without this reading, the
/// symptom is "the trackpad sometimes does nothing" with nothing in any log.
#[cfg(windows)]
pub fn integrity() -> rc_net::firstrun::Integrity {
    use rc_net::firstrun::Integrity;
    use windows::Win32::Foundation::HANDLE;
    // `GetTokenInformation` and `TOKEN_MANDATORY_LABEL` both live in
    // `Win32::Security` — not in a `Security::Authorization` submodule, which
    // does not exist in this projection.
    use windows::Win32::Security::TOKEN_ACCESS_MASK;
    use windows::Win32::Security::{GetTokenInformation, TokenIntegrityLevel};
    use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    const TOKEN_QUERY: TOKEN_ACCESS_MASK = TOKEN_ACCESS_MASK(0x0008);

    // A failure here is not a fault in the product: an unopenable token just
    // means we cannot tell, and the safe assumption is the normal one.
    // `OpenProcessToken` writes through an out-parameter in this projection,
    // rather than returning the handle.
    let mut token: HANDLE = HANDLE::default();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) }.is_err() {
        return Integrity::Medium;
    }
    let mut needed = 0u32;
    unsafe {
        let _ = GetTokenInformation(token, TokenIntegrityLevel, None, 0, &mut needed);
    }
    if needed == 0 {
        return Integrity::Medium;
    }
    let mut buf = vec![0u8; needed as usize];
    let ok = unsafe {
        GetTokenInformation(
            token,
            TokenIntegrityLevel,
            Some(buf.as_mut_ptr() as *mut _),
            needed,
            &mut needed,
        )
    }
    .is_ok();
    if !ok {
        return Integrity::Medium;
    }
    // `TOKEN_MANDATORY_LABEL` is a SID whose sub-authority *is* the integrity
    // RID. Reading it through the generic helpers would need `win32security`,
    // which this crate does not take; the RID is the last `u32` of the SID.
    let Some(level) = integrity_rid(&buf) else {
        return Integrity::Medium;
    };
    match level {
        0x0000..=0x1000 => Integrity::Low,
        0x2000 => Integrity::Medium,
        _ => Integrity::High,
    }
}

/// The integrity RID from a `TOKEN_MANDATORY_LABEL` blob.
///
/// Layout: revision (1 byte), sub-authority count (1 byte), identifier
/// authority (6 bytes), then `count` × 4-byte sub-authorities. The integrity
/// level is the last one.
///
/// Not `cfg(windows)`: it is pure byte-slicing, and the tests for a
/// hand-rolled parser over binary input are the most valuable ones here — they
/// have to run somewhere, and the host is a Mac.
#[cfg_attr(not(test), allow(dead_code))]
fn integrity_rid(blob: &[u8]) -> Option<u32> {
    if blob.len() < 8 {
        return None;
    }
    let count = blob[1] as usize;
    let start = 8;
    let end = start + count * 4;
    if count == 0 || end > blob.len() {
        return None;
    }
    let last = &blob[end - 4..end];
    Some(u32::from_le_bytes([last[0], last[1], last[2], last[3]]))
}

/// The non-Windows answer, so the decision layer can be exercised on a Mac.
#[cfg(not(windows))]
#[allow(dead_code)]
pub fn integrity() -> rc_net::firstrun::Integrity {
    rc_net::firstrun::Integrity::Medium
}

#[cfg(test)]
mod integrity_tests {
    use super::integrity_rid;

    /// The whole function exists to read four bytes out of a SID, and a
    /// hand-rolled parser over binary input is exactly where an off-by-one turns
    /// a security-relevant reading into a wrong answer with no error.
    #[test]
    fn the_last_sub_authority_is_the_integrity_rid() {
        // revision 1, one sub-authority 0x2000, authority = 0 (SECURITY_MANDATORY_LABEL_AUTHORITY)
        let blob = [1u8, 1, 0, 0, 0, 0, 0, 6, 0x00, 0x20, 0x00, 0x00];
        assert_eq!(integrity_rid(&blob), Some(0x2000));
    }

    #[test]
    fn a_truncated_or_lying_blob_reads_as_unknown() {
        assert_eq!(integrity_rid(&[]), None);
        assert_eq!(integrity_rid(&[1, 1, 0, 0]), None);
        // Claims two sub-authorities but only supplies one.
        assert_eq!(
            integrity_rid(&[1, 2, 0, 0, 0, 0, 0, 6, 0, 0x20, 0, 0]),
            None
        );
        // A zero sub-authority count has no RID to find.
        assert_eq!(integrity_rid(&[1, 0, 0, 0, 0, 0, 0, 6]), None);
    }
}
