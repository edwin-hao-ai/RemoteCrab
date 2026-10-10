//! Windows half: liveness by **audio endpoint enumeration**.
//!
//! A PortCls audio driver is kernel-mode and cannot create a `\\.\pipe\…` (that
//! was a user-mode `vdisplay`/`vcam` idiom). What it *does* provide is a capture
//! endpoint named "RemoteCrab Microphone"; the app asks the audio stack for it.
//! That is also exactly what the user would check by hand, and it needs no
//! admin.
//!
//! Uses the MME (`waveIn*`) enumeration rather than `IMMDeviceEnumerator`: it is
//! one call per device, needs no COM apartment, and sees every capture endpoint
//! including a virtual one.

use windows::Win32::Media::Audio::{waveInGetDevCapsW, waveInGetNumDevs, WAVEINCAPSW};

/// The friendly name the driver gives its capture endpoint.
pub const DEVICE_NAME: &str = "RemoteCrab Microphone";

/// Whether an rc-vmic capture endpoint is present.
pub fn available() -> bool {
    let count = unsafe { waveInGetNumDevs() };
    for id in 0..count {
        let mut caps = WAVEINCAPSW::default();
        let rc = unsafe {
            waveInGetDevCapsW(id as usize, &mut caps, std::mem::size_of::<WAVEINCAPSW>() as u32)
        };
        if rc != 0 {
            continue;
        }
        // `WAVEINCAPSW` is packed, so the array must be copied out before it is
        // referenced (an unaligned field reference is E0793).
        if pname(&{ caps.szPname }).eq_ignore_ascii_case(DEVICE_NAME) {
            return true;
        }
    }
    false
}

/// The fixed-size `szPname` up to its NUL, trimmed.
fn pname(raw: &[u16]) -> String {
    let end = raw.iter().position(|&c| c == 0).unwrap_or(raw.len());
    String::from_utf16_lossy(&raw[..end]).trim().to_string()
}
