//! Virtual camera (Media Foundation, Windows 11 22H2+).
//!
//! `MFCreateVirtualCamera` registers a **session-scoped software camera**
//! backed by a COM media source the caller provides (`sourceId` = its CLSID).
//! Unlike a DirectShow filter, this needs **no driver, no admin, no signing**
//! — the camera exists only while this app runs.
//!
//! Pieces:
//! - [`shm`]    — the shared-memory frame ring (BGRA, double-buffered).
//! - [`writer`] — the app side: owns the mapping, publishes frames.
//! - [`win`]    — `MFCreateVirtualCamera` + `Start`/`Stop`.
//! - `rc-vcam-source` (separate cdylib) — the in-proc COM `IMFMediaSource`
//!   that the consuming app (Camera.exe, Zoom, OBS) activates by CLSID.
//!
//! ## Registration
//!
//! The CLSID must resolve to the source DLL for *other* processes to load it,
//! so we register machine-wide under `HKLM\Software\Classes\CLSID\{...}`.
//! **HKLM is mandatory**: the Frame Server runs as `LocalService` and never
//! sees `HKCU`. It needs an elevated run once; [`win::install_source`] is a
//! no-op afterwards (it re-reads HKLM first), and [`win::uninstall_source`]
//! undoes it.

pub mod shm;

#[cfg(windows)]
pub mod writer;

#[cfg(not(windows))]
pub fn run_spike(_name: &str, _seconds: u64) -> Result<(), String> {
    Err("rc-vcam is Windows-only".to_string())
}

// The error type is deliberately **not** Windows-only: it is pure data, and
// the UI logic that branches on `is_fixable_by_elevating` is worth testing on
// any host. Only the calls that touch the registry are gated.
mod error;
#[cfg(windows)]
mod win;

pub use error::VcamError;

#[cfg(windows)]
pub use win::{
    install_source, is_registered, registered_dll, run_spike, source_dll_path, start_camera,
    uninstall_source, StartOutcome, VirtualCamera,
};

/// Convert a Rust string to a NUL-terminated wide string.
#[cfg(windows)]
pub fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Convert a NUL-terminated wide buffer back to a `String` (stops at NUL).
#[cfg(windows)]
pub fn from_wide(w: &[u16]) -> String {
    let end = w.iter().position(|&c| c == 0).unwrap_or(w.len());
    String::from_utf16_lossy(&w[..end])
}
