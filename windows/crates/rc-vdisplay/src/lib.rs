//! `rc-vdisplay` — the receiver half of Windows **Extended Display**.
//!
//! The Mac turns the phone into a real second monitor through the private
//! `CGVirtualDisplay` API. Windows has no user-mode equivalent: a real extra
//! screen needs an **IddCx indirect display driver** (a UMDF driver, signed).
//! This crate is everything that does not require that driver to exist in
//! order to compile or be tested:
//!
//! * the capability string the phone gates its UI on ([`CAPABILITY`]),
//! * the **control pipe** contract the driver listens on (`PING`,
//!   `MONITOR <w> <h>`, `MONITOR OFF`),
//! * the **frame ring** the driver writes composed BGRA frames into and we
//!   read (the same double-buffered layout as the virtual camera), and
//! * [`available`] — whether such a driver is installed and answering.
//!
//! When the driver is absent, [`available`] is `false`, the receiver does not
//! advertise the capability, and the phone keeps the *Extended Display* row
//! hidden. The moment a signed driver is installed and answers `PING`, the row
//! appears and `screenControl(extend)` creates a real monitor.
//!
//! ## Why a pipe *and* a ring
//!
//! The ring is a latest-frame-wins slot: the driver stores each composed frame
//! and we pull the newest at our own cadence. That needs no handshake, but it
//! also cannot express "are you there?" or "create a monitor" — a stale ring
//! file from a crashed driver looks exactly like a live one. The control pipe
//! is the liveness signal and the command channel; the ring is only the pixels.

use std::path::PathBuf;

/// The capability a receiver names when it can back `screenControl(extend)`.
///
/// Shared wire string, defined once in `rc-protocol` so the receiver's hello
/// and this crate cannot disagree. The Mac has always been able to extend;
/// Windows names it only once the IddCx driver is installed.
pub const CAPABILITY: &str = rc_protocol::CAP_EXTENDED_DISPLAY;

/// Control-pipe protocol version the driver answers `PING` with.
///
/// Bumped only when the command grammar changes. The receiver refuses a driver
/// it does not understand rather than sending it commands it would mis-parse.
pub const PROTOCOL_VERSION: u32 = 1;

/// Fixed long edge the receiver asks the driver to create when the phone does
/// not send a `maxPixel` (older iOS build). 1080p-class, the phone's default.
pub const DEFAULT_LONG_EDGE: u32 = 1920;

/// Named control pipe the IddCx driver creates with a permissive DACL.
///
/// The driver runs in `WUDFHost` (a low-privilege service), so it is reachable
/// from the user session exactly like the virtual camera's `%ProgramData%`
/// ring. The name is deliberately under `RemoteCrab` so it is obvious in a
/// `pipelist` dump which product owns it.
#[cfg(windows)]
pub const PIPE_NAME: &str = r"\\.\pipe\RemoteCrabVDisplay";

/// Where the driver publishes composed frames.
///
/// A **file-backed** mapping under `%ProgramData%`, for the same reason the
/// virtual camera uses one: the driver lives in a service session and the
/// reader in the user session, and a path every session can open is the only
/// thing both can see. Distinct filename from the camera's `vcam-ring.bin`.
pub fn ring_file_path() -> PathBuf {
    let base = std::env::var_os("ProgramData")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("C:\\ProgramData"));
    base.join("RemoteCrab").join("vdisplay-ring.bin")
}

/// One composed desktop frame handed over by the driver.
#[derive(Debug, Clone, PartialEq)]
pub struct DisplayFrame {
    /// Frame width in pixels.
    pub width: u32,
    /// Frame height in pixels.
    pub height: u32,
    /// Writer's monotonic frame counter; a caller can skip a duplicate.
    pub seq: u64,
    /// Top-down BGRA pixels, `width * height * 4` bytes.
    pub bgra: Vec<u8>,
}

/// Parse a `PING` answer (`"PONG <version>"`) into the version.
///
/// Pure, so the grammar is pinned by a test rather than only exercised when a
/// real driver is present. `None` for anything that is not a well-formed PONG.
pub fn parse_pong(reply: &str) -> Option<u32> {
    reply.trim().strip_prefix("PONG ")?.trim().parse().ok()
}

/// Interpret a command answer: `"OK"` is success, anything else is an error
/// string the caller can surface. Pure, and tested.
pub fn parse_ack(reply: &str) -> Result<(), String> {
    let reply = reply.trim();
    if reply == "OK" {
        Ok(())
    } else if let Some(rest) = reply.strip_prefix("ERR ") {
        Err(rest.to_string())
    } else {
        Err(format!("unexpected driver reply: {reply}"))
    }
}

#[cfg(windows)]
mod win;
#[cfg(windows)]
pub use win::{available, find_monitor_rect, probe, set_monitor, DisplayReader};

#[cfg(not(windows))]
mod stub;
#[cfg(not(windows))]
pub use stub::{available, find_monitor_rect, probe, set_monitor, DisplayReader};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_string_is_the_agreed_word() {
        // Both wires key off this exact string. Changing it silently would
        // unhide a button the receiver cannot back (or hide one it can).
        assert_eq!(CAPABILITY, "extendedDisplay");
    }

    #[test]
    fn the_display_ring_is_not_the_camera_ring() {
        let p = ring_file_path();
        assert_eq!(p.file_name().unwrap(), "vdisplay-ring.bin");
        assert!(p.to_string_lossy().contains("RemoteCrab"));
        assert_ne!(
            p,
            rc_vcam::shm::ring_file_path(),
            "the two rings must never share a file"
        );
    }

    #[test]
    fn pong_is_parsed_only_when_well_formed() {
        assert_eq!(parse_pong("PONG 1"), Some(1));
        assert_eq!(parse_pong("PONG 12\n"), Some(12));
        assert_eq!(parse_pong("PONG"), None);
        assert_eq!(parse_pong("PONG "), None);
        assert_eq!(parse_pong("pong 1"), None);
        assert_eq!(parse_pong("HELLO"), None);
        assert_eq!(parse_pong(""), None);
    }

    #[test]
    fn ack_reports_ok_and_surfaces_driver_errors() {
        assert!(parse_ack("OK").is_ok());
        assert!(parse_ack("  OK\n").is_ok());
        assert_eq!(parse_ack("ERR no_room").unwrap_err(), "no_room");
        assert!(parse_ack("WHAT").is_err());
    }

    #[test]
    fn default_long_edge_is_a_sane_1080p_class_cap() {
        // The driver clamps to its own supported set; this is only the value
        // used when the phone (an older build) sends no `maxPixel`.
        assert!((640..=4096).contains(&DEFAULT_LONG_EDGE));
    }
}
