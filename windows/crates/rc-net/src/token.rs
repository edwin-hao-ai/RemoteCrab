//! Persisted pairing tokens + the machine identity the iOS app recognises.
//!
//! Mirrors the Mac receiver's `UserDefaults`-backed token store
//! (`remotecrab.mac.id` / a name→token map), but on Windows it is a small
//! JSON file under the app data directory.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TokenStoreData {
    /// Stable per-machine identity, persisted across launches. Must survive
    /// restarts or the iPhone treats us as a stranger (`pending`) every time.
    #[serde(default)]
    pub pc_id: String,
    #[serde(default)]
    pub pc_name: String,
    /// phone name → pairing token.
    #[serde(default)]
    pub tokens: HashMap<String, String>,
    /// Last address we successfully connected to (direct-IP fallback).
    #[serde(default)]
    pub last_phone_host: Option<String>,
    /// Port that address answered on.
    ///
    /// The iPhone prefers 8765 but falls back to a dynamic port when that is
    /// taken (`CaptureEngine.startListener`), so a hardcoded 8765 in the
    /// fallbacks cannot reach a phone that moved. Learned from whichever
    /// connection last worked.
    #[serde(default)]
    pub last_phone_port: Option<u16>,
    /// IP → the phone's self-reported device name.
    ///
    /// A token is keyed by a *provisional* name at handshake time (the mDNS
    /// instance name, or `iPhone (<ip>)` on a direct dial), which means the
    /// same physical device answers to two different keys depending on how we
    /// reached it — and the direct-IP path is the only one that works when
    /// mDNS is dead. `metadata` carries the real name, so we record the
    /// address → name mapping and the token follows it. Mirrors the Mac's
    /// `phoneNameByIP` (`ReceiverSession.rekeyDirectConnection`).
    #[serde(default)]
    pub phones_by_ip: HashMap<String, String>,
}

#[derive(Debug, Clone)]
pub struct TokenStore {
    path: Option<PathBuf>,
    data: TokenStoreData,
}

impl TokenStore {
    /// Load from `path` (creating defaults if missing). A `None` path keeps
    /// everything in memory (used by tests).
    pub fn load(path: Option<PathBuf>) -> Self {
        let mut data = path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|s| serde_json::from_str::<TokenStoreData>(&s).ok())
            .unwrap_or_default();

        // Adopt the machine-derived identity, but never at the cost of a working
        // pairing.
        //
        // The iPhone recognises us by this id, so changing it while a token is
        // live presents the phone with a stranger and forces the user through
        // approval again for no reason. With no pairing in flight there is
        // nothing to orphan, and preferring the machine id is the entire point —
        // it is what makes the next uninstall-and-reinstall a non-event.
        match machine_stable_id() {
            Some(machine) if data.tokens.is_empty() => data.pc_id = machine,
            None if data.pc_id.is_empty() => data.pc_id = generate_id(),
            _ => {}
        }
        if data.pc_name.is_empty() {
            data.pc_name = default_pc_name();
        }

        let mut store = TokenStore { path, data };
        store.save();
        store
    }

    pub fn pc_id(&self) -> &str {
        &self.data.pc_id
    }

    pub fn pc_name(&self) -> &str {
        &self.data.pc_name
    }

    pub fn token_for(&self, phone_name: &str) -> Option<String> {
        self.data.tokens.get(phone_name).cloned()
    }

    pub fn set_token(&mut self, phone_name: &str, token: &str) {
        self.data
            .tokens
            .insert(phone_name.to_string(), token.to_string());
        self.save();
    }

    pub fn forget(&mut self, phone_name: &str) {
        self.data.tokens.remove(phone_name);
        self.save();
    }

    /// The paired phones, in a stable order.
    ///
    /// A map has no order of its own, and a list that reshuffles between two
    /// openings of the same settings window reads as the app having lost
    /// something. Sorted by name, case-insensitively, because that is the order
    /// a person would keep them in.
    pub fn paired_phones(&self) -> Vec<String> {
        let mut names: Vec<String> = self.data.tokens.keys().cloned().collect();
        names.sort_by_key(|n| n.to_lowercase());
        names
    }

    /// Drop an address→name mapping along with its token.
    ///
    /// Called with the token, because a stale `phones_by_ip` entry is how a
    /// *re-paired* phone inherits the old one's identity: the map says
    /// "192.168.1.5 is Dana's iPhone" after the pairing was forgotten, so the
    /// next handshake rekeys the new token onto the old name.
    pub fn forget_addresses_for(&mut self, phone_name: &str) {
        let stale: Vec<String> = self
            .data
            .phones_by_ip
            .iter()
            .filter(|(_, n)| n.eq_ignore_ascii_case(phone_name))
            .map(|(ip, _)| ip.clone())
            .collect();
        for ip in stale {
            self.data.phones_by_ip.remove(&ip);
        }
        self.save();
    }

    pub fn last_phone_host(&self) -> Option<String> {
        self.data.last_phone_host.clone()
    }

    pub fn set_last_phone_host(&mut self, host: &str) {
        self.data.last_phone_host = Some(host.to_string());
        self.save();
    }

    /// The port the last successful connection used, or `None` if we have
    /// never connected. Callers fall back to [`super::DEFAULT_PORT`].
    pub fn last_phone_port(&self) -> Option<u16> {
        self.data.last_phone_port
    }

    pub fn set_last_phone_port(&mut self, port: u16) {
        self.data.last_phone_port = Some(port);
        self.save();
    }

    /// Remember a `host:port` pair as "the phone we are talking to".
    pub fn remember_endpoint(&mut self, host: &str, port: u16) {
        self.data.last_phone_host = Some(host.to_string());
        self.data.last_phone_port = Some(port);
        self.save();
    }

    /// The device name the phone reported for `ip`, if we have connected to
    /// that address before.
    pub fn name_for_ip(&self, ip: &str) -> Option<&str> {
        self.data.phones_by_ip.get(ip).map(String::as_str)
    }

    pub fn set_phone_name_for_ip(&mut self, ip: &str, name: &str) {
        self.data
            .phones_by_ip
            .insert(ip.to_string(), name.to_string());
        self.save();
    }

    /// Move a token from a provisional key to the phone's real name.
    ///
    /// Returns `true` if a token actually moved. Idempotent: re-running it
    /// with the same name is a no-op, so a phone that reports metadata on
    /// every connection does not rewrite the file every time.
    pub fn rekey_token(&mut self, from: &str, to: &str) -> bool {
        if from == to {
            return false;
        }
        let Some(token) = self.data.tokens.remove(from) else {
            return false;
        };
        self.data.tokens.insert(to.to_string(), token);
        self.save();
        true
    }

    /// The key a token should be read from / written to for a given
    /// provisional identity, resolved through the IP → name map when we know
    /// it. This is what makes a direct dial find a token that was originally
    /// stored under an mDNS instance name, and vice versa.
    pub fn resolve_key(&self, provisional: &str, ip: Option<&str>) -> String {
        ip.and_then(|ip| self.name_for_ip(ip))
            .unwrap_or(provisional)
            .to_string()
    }

    fn save(&mut self) {
        let Some(path) = &self.path else { return };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(&self.data) {
            let _ = std::fs::write(path, json);
        }
    }
}

/// An identity that belongs to *this machine*, not to this install.
///
/// `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid` is per-machine, already a
/// UUID, and survives the app-data directory being deleted. That last part is
/// the whole point: uninstalling removes `%APPDATA%\RemoteCrab`, so an id kept
/// only there is not per-machine at all — it is per-install. Reinstalling then
/// produces a fresh id, the iPhone still remembers the old one under the same
/// display name, and its computer list grows a second "Edwin" that the user
/// cannot remove from this side.
///
/// `None` off Windows, and on Windows if the key is unreadable, in which case
/// the caller falls back to [`generate_id`] — degraded, but no worse than
/// before.
#[cfg(windows)]
fn machine_stable_id() -> Option<String> {
    use windows::core::{HSTRING, PCWSTR};
    use windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};

    let subkey = HSTRING::from(r"SOFTWARE\Microsoft\Cryptography");
    let name = HSTRING::from("MachineGuid");

    let read = |buf: Option<*mut std::ffi::c_void>, bytes: &mut u32| unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(subkey.as_ptr()),
            PCWSTR(name.as_ptr()),
            RRF_RT_REG_SZ,
            None,
            buf,
            Some(bytes),
        )
    };

    // Size probe: a null buffer purely to learn how much is needed.
    let mut size: u32 = 0;
    let probe = read(None, &mut size);
    // FILE_NOT_FOUND just means this Windows has no MachineGuid — a "fall back",
    // not a fault worth surfacing.
    if probe != ERROR_SUCCESS && probe != ERROR_FILE_NOT_FOUND {
        return None;
    }
    if size == 0 {
        return None;
    }

    let mut buf = vec![0u16; (size / 2) as usize + 1];
    let mut out = size;
    if read(Some(buf.as_mut_ptr().cast()), &mut out) != ERROR_SUCCESS {
        return None;
    }
    // Trim the terminating NUL, and reject anything that is not a plausible
    // UUID: a half-read or empty value would otherwise go out to the phone as an
    // identity that looks real.
    let chars = (out as usize / 2).saturating_sub(1);
    let text = String::from_utf16_lossy(&buf[..chars.min(buf.len())]);
    let text = text.trim().to_string();
    let plausible = text.len() == 36 && text.chars().all(|c| c == '-' || c.is_ascii_hexdigit());
    plausible.then_some(text)
}

#[cfg(not(windows))]
fn machine_stable_id() -> Option<String> {
    None
}

/// A random-ish stable id (UUID v4 without the `uuid` dependency).
fn generate_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id();
    let mix = nanos ^ ((pid as u128) << 64);
    format!(
        "{:08x}-{:04x}-4{:03x}-{:04x}-{:012x}",
        (mix >> 96) as u32,
        (mix >> 80) as u16,
        (mix >> 64) as u16 & 0x0fff,
        (mix >> 48) as u16 & 0x3fff | 0x8000,
        (mix & 0xffff_ffff_ffff) as u64

    )
}

fn default_pc_name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "Windows PC".to_string())
}

/// The default on-disk location: `%APPDATA%\RemoteCrab\tokens.json`.
pub fn default_token_path() -> Option<PathBuf> {
    std::env::var_os("APPDATA").map(|base| Path::new(&base).join("RemoteCrab").join("tokens.json"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_round_trip_in_memory() {
        let mut store = TokenStore::load(None);
        assert!(!store.pc_id().is_empty());
        store.set_token("iPhone", "tok-1");
        assert_eq!(store.token_for("iPhone").as_deref(), Some("tok-1"));
        store.forget("iPhone");        assert_eq!(store.token_for("iPhone"), None);
    }

    #[test]
    fn persists_to_disk_and_reloads() {
        let dir = std::env::temp_dir().join(format!("rc-token-test-{}", std::process::id()));
        let path = dir.join("tokens.json");
        let _ = std::fs::remove_file(&path);

        let mut store = TokenStore::load(Some(path.clone()));
        let id = store.pc_id().to_string();
        store.set_token("Phone", "abc");

        let reloaded = TokenStore::load(Some(path.clone()));
        assert_eq!(reloaded.pc_id(), id);
        assert_eq!(reloaded.token_for("Phone").as_deref(), Some("abc"));

        let _ = std::fs::remove_file(&path);
    }

    /// A token file written by an OLDER build must load with nothing lost.
    ///
    /// `TokenStore::load` swallows every decode error and falls back to
    /// `default()`, so a new field without `#[serde(default)]` would silently
    /// wipe every paired token in the field — and the iPhone would go back to
    /// asking for approval on every reconnect. This is the regression test for
    /// that (AGENTS.md rule 2).
    #[test]
    fn an_older_token_file_loads_without_losing_anything() {
        let dir = std::env::temp_dir().join(format!("rc-token-old-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("tokens.json");
        // Exactly the shape on disk before this change: no port, no phone map.
        std::fs::write(
            &path,
            r#"{
              "pc_id": "11111111-2222-4333-8444-555555555555",
              "pc_name": "DESKTOP-OLD",
              "tokens": { "iPhone": "tok-1" },
              "last_phone_host": "192.168.1.5"
            }"#,
        )
        .unwrap();

        let store = TokenStore::load(Some(path.clone()));
        assert_eq!(store.pc_id(), "11111111-2222-4333-8444-555555555555");
        assert_eq!(store.pc_name(), "DESKTOP-OLD");
        assert_eq!(
            store.token_for("iPhone").as_deref(),
            Some("tok-1"),
            "an old file's pairing token must survive"
        );
        assert_eq!(store.last_phone_host().as_deref(), Some("192.168.1.5"));
        // Fields the old file never had must read as "unknown", not as a
        // default that would make the receiver dial a wrong port.
        assert!(store.last_phone_port().is_none());
        assert!(store.name_for_ip("192.168.1.5").is_none());

        let _ = std::fs::remove_file(&path);
    }
}

#[cfg(test)]
mod listing_tests {
    use super::TokenStore;

    /// The order has to be stable, or a settings window reorders itself between
    /// two openings and the user concludes something was lost.
    #[test]
    fn paired_phones_are_listed_in_a_stable_order() {
        let mut s = TokenStore::load(None);
        s.set_token("Zoe's iPhone", "t1");
        s.set_token("ana's iPad", "t2");
        s.set_token("Ben's phone", "t3");
        assert_eq!(
            s.paired_phones(),
            vec!["ana's iPad", "Ben's phone", "Zoe's iPhone"]
        );
        // Repeated calls agree with each other.
        assert_eq!(s.paired_phones(), s.paired_phones());
    }

    /// Forgetting a phone has to take its address mapping with it. A stale
    /// mapping is how a re-paired phone inherits the old one's identity: the
    /// map still says "192.168.1.5 is Dana's iPhone" after the pairing was
    /// dropped, so the next handshake rekeys the new token onto the old name.
    #[test]
    fn forgetting_a_phone_also_drops_its_addresses() {
        let mut s = TokenStore::load(None);
        s.set_token("Dana's iPhone", "t1");
        s.set_phone_name_for_ip("192.168.1.5", "Dana's iPhone");
        s.set_phone_name_for_ip("192.168.1.9", "Ben's phone");
        s.set_token("Ben's phone", "t2");

        s.forget("Dana's iPhone");
        s.forget_addresses_for("Dana's iPhone");

        assert_eq!(s.name_for_ip("192.168.1.5"), None);
        assert_eq!(
            s.name_for_ip("192.168.1.9"),
            Some("Ben's phone"),
            "another phone's address must survive"
        );
    }

    /// The id must belong to the machine, not to the install directory.
    ///
    /// Uninstalling deletes `%APPDATA%\RemoteCrab`. If the id were regenerated
    /// there, reinstalling would present the iPhone with a *new* computer wearing
    /// the *same* display name — and since the phone remembers the old one, its
    /// computer list grows a duplicate "Edwin" that nothing on this side can
    /// remove. That is not hypothetical: it is what happened the first time an
    /// uninstall cleaned the app data.
    ///
    /// Windows-only on purpose. Elsewhere there is no machine GUID to read, the
    /// fallback is a fresh id, and the duplicate would come back — so the test
    /// must not assert a promise the other platforms do not make. CI builds three
    /// OSes, and this would have been a red build nobody could act on.
    #[cfg(windows)]
    #[test]
    fn the_id_survives_the_app_data_being_deleted() {
        let first = TokenStore::load(None).pc_id().to_string();
        // A second store, as after an uninstall + reinstall: nothing carried
        // over except whatever the machine itself provides.
        let second = TokenStore::load(None).pc_id().to_string();
        assert_eq!(
            first, second,
            "a fresh token store produced a different identity — reinstalling will \
             show the phone a second computer with the same name"
        );
    }

    /// Off Windows the id *is* regenerated. Recording that as the documented
    /// fallback stops the Windows-only test above from looking, to whoever hits
    /// it on a Mac, like a platform bug — and tells whoever adds a stable source
    /// elsewhere to un-gate the stronger test.
    #[cfg(not(windows))]
    #[test]
    fn without_a_machine_guid_the_id_is_per_install() {
        let first = TokenStore::load(None).pc_id().to_string();
        let second = TokenStore::load(None).pc_id().to_string();
        assert_ne!(
            first, second,
            "this platform has no machine GUID, so a fresh id is the documented \
             fallback — if this now fails, a stable source was added and the \
             Windows-only test should be un-gated"
        );
    }

    /// Whatever the source, it has to look like an id. A half-read or empty
    /// value would otherwise be sent to the phone as an identity that appears
    /// real.
    #[test]
    fn the_id_looks_like_an_id() {
        let id = TokenStore::load(None).pc_id().to_string();
        assert_eq!(id.len(), 36, "{id}");
        assert!(
            id.chars().all(|c| c == '-' || c.is_ascii_hexdigit()),
            "{id}"
        );
    }

    /// A live pairing outranks the machine id.
    ///
    /// The phone recognises the computer by this id, so swapping it out from
    /// under a working token would make the user re-approve a machine they
    /// already approved — the exact "why is this asking again" experience the
    /// field's own doc comment says the id exists to prevent.
    #[cfg(windows)]
    #[test]
    fn a_working_pairing_keeps_the_id_it_was_approved_with() {
        let dir = std::env::temp_dir().join(format!("rc-id-keep-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("tokens.json");

        let mut first = TokenStore::load(Some(path.clone()));
        let approved_as = first.pc_id().to_string();
        first.set_token("Dana's iPhone", "tok-1");

        // Relaunch: the id on disk is whatever the pairing was approved with.
        let reloaded = TokenStore::load(Some(path));
        assert_eq!(
            reloaded.pc_id(),
            approved_as,
            "the id changed while a pairing was live — the phone would see a stranger"
        );
        assert_eq!(reloaded.token_for("Dana's iPhone").as_deref(), Some("tok-1"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// And once the pairing is gone, the next load takes the machine id — which
    /// is the state an uninstall leaves behind.
    #[cfg(windows)]
    #[test]
    fn an_unpaired_store_adopts_the_machine_id_even_if_one_was_stored() {
        let dir = std::env::temp_dir().join(format!("rc-id-migrate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("tokens.json");

        // A store left by an older build: a random id, and a pairing.
        std::fs::write(
            &path,
            r#"{"pc_id":"00000000-0000-4de4-98db-023a844ff7a4","pc_name":"Edwin",
                "tokens":{"Dana's iPhone":"tok-1"}}"#,
        )
        .expect("seed");

        let paired = TokenStore::load(Some(path.clone()));
        assert_eq!(paired.pc_id(), "00000000-0000-4de4-98db-023a844ff7a4");
        assert_eq!(paired.token_for("Dana's iPhone").as_deref(), Some("tok-1"));

        // After the user forgets the phone — or after an uninstall removed the
        // app data — the stored id no longer anchors anything.
        std::fs::write(&path, r#"{"pc_name":"Edwin","tokens":{}}"#).expect("seed");
        let unpaired = TokenStore::load(Some(path));
        assert_ne!(
            unpaired.pc_id(),
            "00000000-0000-4de4-98db-023a844ff7a4",
            "a stale per-install id survived; reinstalling would duplicate the computer again"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}