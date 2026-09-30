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

fn path() -> Option<PathBuf> {
    app_data_dir().map(|d| d.join("notify-relay.json"))
}

#[allow(dead_code)] // see the module note
fn read() -> Config {
    let Some(p) = path() else {
        return Config::default();
    };
    let Ok(text) = std::fs::read_to_string(p) else {
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
    let Some(p) = path() else {
        return false;
    };
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
fn flag_path() -> Option<PathBuf> {
    path().map(|p| p.with_extension("enabled"))
}

pub fn is_enabled() -> bool {
    // The mere existence of the flag file is the setting. A `false` written
    // into a JSON file is a value that can be lost to a partial write; a file
    // that is either there or not cannot.
    flag_path().is_some_and(|p| p.is_file())
}

// Only the tray's relay row flips this, and that row is Windows-shaped.
#[allow(dead_code)] // see the module note
pub fn set_enabled(on: bool) {
    let Some(p) = flag_path() else {
        return;
    };
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

/// The relay as the decision layer wants it. Called by `start_listener`, which
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
        // Off Windows there is no app data directory, so the flag path is
        // absent — and that is correct, not a failure: the setting simply does
        // not exist on this platform.
        if let Some(p) = flag_path() {
            assert!(p.extension().is_some());
            assert_ne!(p, path().expect("a path when a flag path exists"));
        }
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

/// Has the setup wizard been opened on this machine?
///
/// A flag file next to the relay's, rather than a field in its JSON: the two
/// decisions are unrelated, and putting "seen the wizard" into the denylist file
/// means a corrupt relay config could also make the wizard reappear forever.
#[allow(dead_code)] // see the module note
pub fn wizard_seen() -> bool {
    app_data_dir()
        .map(|d| d.join("wizard-seen"))
        .is_some_and(|p| p.is_file())
}

/// Record that the wizard has been shown. Written on open, not on completion:
/// a user who quits halfway has still been introduced, and a wizard that comes
/// back after a quit is a nag.
#[allow(dead_code)] // see the module note
pub fn mark_wizard_seen() {
    if let Some(dir) = app_data_dir() {
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join("wizard-seen"), b"1");
    }
}

/// The current denylist, read fresh.
///
/// This is the user-facing control for a privacy feature, so it has a
/// round-trip: read here, written through [`set_denylist`], and validated by
/// `rc_net::settings::NameList` before it ever reaches the file. A filter a user
/// cannot edit is a filter nobody trusts to be doing anything.
#[allow(dead_code)] // called by the settings window, which is Windows-shaped
pub fn denylist() -> Vec<String> {
    read().denylist
}

/// Replace the denylist.
///
/// The one writer, so a settings dialog cannot persist a different shape than
/// the one the tests know. The caller is expected to have validated through
/// `NameList` already; the write is not re-validated, because a silently
/// dropped entry here would be a privacy setting that appears to be set and is
/// not.
#[allow(dead_code)] // called by the settings window, which is Windows-shaped
pub fn set_denylist(items: Vec<String>) {
    write(&Config { denylist: items });
}

/// The chosen video quality, read fresh.
#[allow(dead_code)] // called by the settings window, which is Windows-shaped
pub fn quality() -> rc_net::settings::Quality {
    quality_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|t| parse_quality(&t))
        .unwrap_or_default()
}

/// Three integers, or the default. Anything else is "automatic" — a settings
/// file that cannot be read must not become a resolution the user never chose.
fn parse_quality(text: &str) -> rc_net::settings::Quality {
    use rc_net::settings::Quality;
    let mut it = text.split_whitespace();
    let mut next = move || it.next()?.parse::<i32>().ok();
    let got = (next(), next(), next());
    match got {
        (Some(width), Some(height), Some(fps)) => {
            // Sanity bounds, not a whitelist: the settings window offers a
            // fixed list, but the file can be edited by hand or written by a
            // future build. `999 999 999` parses fine and would ask the phone to
            // stream a resolution that does not exist, which looks like a broken
            // camera rather than a bad setting.
            let plausible = (160..=7680).contains(&width)
                && (120..=4320).contains(&height)
                && (1..=240).contains(&fps);
            if plausible {
                Quality { width, height, fps }
            } else {
                Quality::default()
            }
        }
        _ => Quality::default(),
    }
}

/// Store the chosen quality.
///
/// Three integers on one line, not a serialized struct: a struct gains a field
/// someday, and a file holding a struct breaks the moment it does.
#[allow(dead_code)] // called by the settings window, which is Windows-shaped
pub fn set_quality(q: rc_net::settings::Quality) {
    if let Some(p) = quality_path() {
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(p, format!("{} {} {}", q.width, q.height, q.fps));
    }
}

/// Where the app keeps its files, from `%APPDATA%`.
///
/// Returns `None` off Windows rather than falling back to a literal Windows
/// path: the fallback was the source of a test that genuinely created
/// `crates/rc-app/C:\Users\Default\AppData\Roaming` in the source tree,
/// because `%APPDATA%` is unset on a Mac and the fallback was a real path.
///
/// A missing directory is not an error here: the caller writes, and a failed
/// write is reported by the write itself. A read on a machine with no app data
/// simply yields the default.
fn app_data_dir() -> Option<std::path::PathBuf> {
    std::env::var_os("APPDATA")
        .map(std::path::PathBuf::from)
        .map(|d| d.join("RemoteCrab"))
}

#[allow(dead_code)] // Windows-shaped callers
fn quality_path() -> Option<std::path::PathBuf> {
    app_data_dir().map(|d| d.join("quality"))
}

#[cfg(test)]
mod quality_tests {
    use super::parse_quality;
    use rc_net::settings::Quality;

    /// A stored quality has to come back identical.
    ///
    /// Windows-only, and honestly so: the file lives under `%APPDATA%`, which
    /// does not exist on the Mac where this would otherwise run — so the test
    /// would be asserting against a write that silently did nothing, and
    /// "passing" by reading back the default. That is a test that cannot fail.
    /// The persistence *format* is covered on any host by the parse below.
    #[cfg(windows)]
    #[test]
    fn a_quality_round_trips_through_its_file() {
        use super::{quality, set_quality};
        for (q, _, _) in Quality::CHOICES {
            set_quality(*q);
            assert_eq!(quality(), *q, "{q:?} did not survive");
        }
    }

    /// A malformed file must read as "automatic", never as a nonsense
    /// resolution the user never chose. Testable anywhere, because it is the
    /// *parsing* that matters rather than the writing.
    #[test]
    fn a_junk_quality_file_reads_as_automatic() {
        for junk in [
            "",
            "   ",
            "abc",
            "1280",
            "1280 720",
            "1280 720 x",
            // Parses as three integers and is still nonsense.
            "999 999 999",
            "0 0 0",
            "-1 -1 -1",
            "1280 720 0",
        ] {
            let parsed = parse_quality(junk);
            assert_eq!(parsed, Quality::default(), "junk={junk:?}");
        }
    }

    /// A well-formed file parses to exactly what it says.
    #[test]
    fn a_good_quality_file_parses() {
        assert_eq!(
            parse_quality("1920 1080 60"),
            Quality {
                width: 1920,
                height: 1080,
                fps: 60
            }
        );
        // Trailing junk is ignored rather than fatal, so a future version that
        // appends a field does not lose the user's setting.
        assert_eq!(
            parse_quality("1280 720 30 60"),
            Quality {
                width: 1280,
                height: 720,
                fps: 30
            }
        );
    }

    /// The default has to be "automatic" for a machine that has never set one.
    #[test]
    fn the_default_is_automatic() {
        assert_eq!(Quality::default().width, 0);
        assert_eq!(Quality::default().index(), 0);
    }
}
