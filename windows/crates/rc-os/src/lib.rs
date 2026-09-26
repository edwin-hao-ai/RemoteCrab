//! `rc-os` — Windows integration for the receiver.
//!
//! Everything here is a thin, side-effecting shim over Win32 so the app can
//! react to iPhone events: clipboard sync, file receive, system keys, app
//! list, and selection rewrite. The pure logic (text transforms, file-name
//! sanitising, path planning) lives in testable free functions.

pub mod files;
pub mod thumbnail;

#[cfg(windows)]
pub mod clipboard;
#[cfg(windows)]
pub mod system_keys;
#[cfg(windows)]
pub mod apps;
#[cfg(windows)]
pub mod windows;
#[cfg(windows)]
pub mod selection;

/// Where received files land: `%USERPROFILE%\Downloads\RemoteCrab`.
pub fn incoming_directory() -> std::path::PathBuf {
    let home = std::env::var_os("USERPROFILE")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    home.join("Downloads").join("RemoteCrab")
}
