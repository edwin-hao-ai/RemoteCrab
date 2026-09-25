//! Rust port of `RemoteCrabCore/Networking/IBProtocol.swift`.

use serde::{Deserialize, Serialize};

use crate::base64_serde;

/// Bonjour / DNS-SD service type used by RemoteCrab. Always use the exact
/// same string on both the publishing (iOS) and browsing (receiver) sides.
pub struct ServiceType;
impl ServiceType {
    /// The DNS-SD service type advertised by the iOS app.
    pub const TCP: &'static str = "_remotecrab._tcp";
    pub const DOMAIN: &'static str = "local.";
}

/// Connection / stream metadata exchanged at the start of every session
/// (kind `0x00`, the first frame the iOS sender emits after a connection
/// is accepted).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamMetadata {
    #[serde(default = "default_version")]
    pub version: i64,
    pub device_name: String,
    pub width: i64,
    pub height: i64,
    pub fps: i64,
    pub bitrate_bps: i64,
    #[serde(default = "default_codec")]
    pub codec: String,
    /// H.264 SPS NAL unit (base64).
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "base64_serde::opt"
    )]
    pub sps: Option<Vec<u8>>,
    /// H.264 PPS NAL unit (base64).
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "base64_serde::opt"
    )]
    pub pps: Option<Vec<u8>>,
}

fn default_version() -> i64 {
    1
}
fn default_codec() -> String {
    "h264".to_string()
}

impl StreamMetadata {
    /// Human-readable resolution label, e.g. `"1080p"`.
    pub fn resolution_label(&self) -> String {
        match self.height {
            2160 => "4K".to_string(),
            1440 => "1440p".to_string(),
            1080 => "1080p".to_string(),
            720 => "720p".to_string(),
            480 => "480p".to_string(),
            _ => format!("{}x{}", self.width, self.height),
        }
    }
}

/// One H.264 video frame ready to ship over the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum NalKind {
    Video = 0x01,
    Sps = 0x02,
    Pps = 0x03,
}

/// A NAL unit plus its kind and timestamp.
#[derive(Debug, Clone, PartialEq)]
pub struct NalFrame {
    pub kind: NalKind,
    /// Annex-B NAL unit (the iOS encoder strips the start code; the wire
    /// carries the raw NAL and the receiver re-wraps it for its decoder).
    pub data: Vec<u8>,
    pub timestamp_micros: u64,
}
