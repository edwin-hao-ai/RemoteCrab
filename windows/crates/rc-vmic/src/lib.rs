//! Virtual microphone (the phone's mic as a *selectable* Windows input device).
//!
//! Unlike the virtual camera (`rc-vcam`), Windows has **no user-mode way** to
//! add an audio input device: one needs a signed PortCls / sysvad-class kernel
//! driver (`windows/drivers/rc-vmic/`). This crate is the **receiver half** of
//! that contract — a byte ring the phone's PCM is written into, which the driver
//! drains at the rate the audio engine asks for.
//!
//! So the phone-as-microphone feature has two paths:
//!
//! - **Path A — no driver (ships today).** Play the phone's mic into an already
//!   installed virtual audio cable (VB-CABLE, VoiceMeeter, …) via
//!   `rc-audio::pick_virtual_cable`, so a meeting app can select that cable's
//!   capture endpoint. Free, signed, zero install here — see `rc-app` and the
//!   first-run wizard's "Virtual microphone" page.
//! - **Path B — the driver.** Feed this ring; "RemoteCrab Microphone" then shows
//!   up in every app's input list with no third-party cable.
//!
//! Liveness is the **capture endpoint itself**: a PortCls driver is kernel-mode
//! and cannot create a `\\.\pipe\…` (that is a user-mode idiom), so `available()`
//! asks the audio stack whether a capture device named "RemoteCrab Microphone"
//! exists. The app feeds the ring only when it does.

pub mod shm;

#[cfg(windows)]
pub mod writer;

#[cfg(windows)]
pub mod win;

#[cfg(not(windows))]
mod stub;

#[cfg(windows)]
pub use writer::AudioWriter;
#[cfg(windows)]
pub use win::{available, DEVICE_NAME};
#[cfg(not(windows))]
pub use stub::{available, DEVICE_NAME};

/// Convert a Rust string to a NUL-terminated wide string.
#[cfg(windows)]
pub fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}
