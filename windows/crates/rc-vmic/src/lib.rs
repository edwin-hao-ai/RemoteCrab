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
//! The driver exposes a control pipe `\\.\pipe\RemoteCrabVMic` it answers
//! `PING`→`PONG 1` on, so the app can offer Path B only when the driver is
//! installed (the same pattern as `rc-vdisplay`).

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
pub use win::{available, probe};
#[cfg(not(windows))]
pub use stub::{available, probe};

/// Control-pipe name the driver listens on. The audio never travels on the
/// pipe — it carries liveness (`PING`) only.
pub const PIPE_NAME: &str = r"\\.\pipe\RemoteCrabVMic";

/// Control-pipe protocol version the driver answers `PING` with.
pub const PROTOCOL_VERSION: u32 = 1;

/// Parse a `PING` answer (`"PONG <version>"`) into the version.
pub fn parse_pong(reply: &str) -> Option<u32> {
    reply.trim().strip_prefix("PONG ")?.trim().parse().ok()
}

/// Convert a Rust string to a NUL-terminated wide string.
#[cfg(windows)]
pub fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_pong_reads_the_version() {
        assert_eq!(parse_pong("PONG 1"), Some(1));
        assert_eq!(parse_pong("PONG 7\n"), Some(7));
        assert_eq!(parse_pong("PING"), None);
        assert_eq!(parse_pong("PONG"), None);
        assert_eq!(parse_pong("PONG x"), None);
    }
}
