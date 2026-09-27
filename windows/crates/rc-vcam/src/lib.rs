//! Virtual-camera spike (Media Foundation, Windows 11 22H2+).
//!
//! `MFCreateVirtualCamera` registers a **session-scoped software camera**
//! backed by a COM media source the caller provides (`sourceId` = its CLSID).
//! This crate is the honest first step: it checks whether the OS supports the
//! software-camera type, creates the camera, starts it, and keeps it alive so
//! the Windows Camera app can list it. The media source itself (the frames)
//! is the next step — see `docs/WINDOWS_HANDOFF.md` §5a.

#[cfg(not(windows))]
pub fn run_spike(_name: &str, _seconds: u64) -> Result<(), String> {
    Err("rc-vcam is Windows-only".to_string())
}

#[cfg(windows)]
mod win;

#[cfg(windows)]
pub use win::run_spike;
