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

        if data.pc_id.is_empty() {
            data.pc_id = generate_id();
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

    pub fn last_phone_host(&self) -> Option<String> {
        self.data.last_phone_host.clone()
    }

    pub fn set_last_phone_host(&mut self, host: &str) {
        self.data.last_phone_host = Some(host.to_string());
        self.save();
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
        store.forget("iPhone");
        assert_eq!(store.token_for("iPhone"), None);
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
}
