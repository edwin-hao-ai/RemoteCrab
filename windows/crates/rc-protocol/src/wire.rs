//! Rust port of `RemoteCrabCore/Networking/IBWire.swift`.
//!
//! Length-prefixed binary framing used between the iOS sender and the
//! receiver over a Bonjour-discovered TCP connection:
//!
//! ```text
//! ┌──────────────────────────────────────────────────────────────┐
//! │ [4 bytes BE length, includes 1-byte kind][1 byte kind][payload] │
//! └──────────────────────────────────────────────────────────────┘
//! ```
//!
//! The first frame on every connection is a `clientHello` from the
//! receiver (kind `0x0A`); the iOS side answers with `sessionReply`
//! (kind `0x0B`) before sending any stream data.

use serde::Serialize;

use crate::events::*;
use crate::protocol::{NalFrame, NalKind, StreamMetadata};

/// Maximum accepted frame length (64 MiB). Guards against corrupt length
/// values turning into an infinite loop / huge allocation.
pub const MAX_FRAME_LEN: u32 = 64 * 1024 * 1024;

/// Frame kind byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Kind {
    Metadata = 0x00,
    Video = 0x01,
    Sps = 0x02,
    Pps = 0x03,
    Touch = 0x04,
    Key = 0x05,
    Audio = 0x06,
    FeatureControl = 0x07,
    FeatureState = 0x08,
    Ping = 0x09,
    ClientHello = 0x0A,
    SessionReply = 0x0B,
    AppList = 0x0C,
    AppListRequest = 0x0D,
    ActivateApp = 0x0E,
    FileOffer = 0x0F,
    FileChunk = 0x10,
    FileComplete = 0x11,
    FileAck = 0x12,
    ClipboardSet = 0x13,
    TextCommand = 0x14,
    CameraCommand = 0x15,
    QuitApp = 0x16,
    WindowListRequest = 0x17,
    WindowList = 0x18,
    SystemCommand = 0x19,
    // App-window mirror (the iOS/Mac screen-share feature). The Windows
    // receiver does not implement the mirror yet, but it MUST recognise
    // these kinds: an unknown byte falls through to `Video`, and a mirror
    // NAL would then be fed to the camera decoder, corrupting the stream.
    ScreenVideo = 0x1A,
    ScreenSps = 0x1B,
    ScreenPps = 0x1C,
    ScreenControl = 0x1D,
    ScreenInput = 0x1E,
    ScreenInfo = 0x1F,
    InstalledAppsRequest = 0x20,
    InstalledApps = 0x21,
}

impl Kind {
    /// True for the app-window mirror kinds (0x1A–0x1F). Callers should
    /// ignore these until the mirror is implemented — never treat them as
    /// camera video.
    pub fn is_screen_mirror(self) -> bool {
        matches!(
            self,
            Kind::ScreenVideo
                | Kind::ScreenSps
                | Kind::ScreenPps
                | Kind::ScreenControl
                | Kind::ScreenInput
                | Kind::ScreenInfo
        )
    }

    /// Mirror of `Kind(rawValue:) ?? .video` — an unknown kind byte is
    /// treated as a video frame rather than aborting the stream.
    pub fn from_u8_or_video(byte: u8) -> Kind {
        match byte {
            0x00 => Kind::Metadata,
            0x01 => Kind::Video,
            0x02 => Kind::Sps,
            0x03 => Kind::Pps,
            0x04 => Kind::Touch,
            0x05 => Kind::Key,
            0x06 => Kind::Audio,
            0x07 => Kind::FeatureControl,
            0x08 => Kind::FeatureState,
            0x09 => Kind::Ping,
            0x0A => Kind::ClientHello,
            0x0B => Kind::SessionReply,
            0x0C => Kind::AppList,
            0x0D => Kind::AppListRequest,
            0x0E => Kind::ActivateApp,
            0x0F => Kind::FileOffer,
            0x10 => Kind::FileChunk,
            0x11 => Kind::FileComplete,
            0x12 => Kind::FileAck,
            0x13 => Kind::ClipboardSet,
            0x14 => Kind::TextCommand,
            0x15 => Kind::CameraCommand,
            0x16 => Kind::QuitApp,
            0x17 => Kind::WindowListRequest,
            0x18 => Kind::WindowList,
            0x19 => Kind::SystemCommand,
            0x1A => Kind::ScreenVideo,
            0x1B => Kind::ScreenSps,
            0x1C => Kind::ScreenPps,
            0x1D => Kind::ScreenControl,
            0x1E => Kind::ScreenInput,
            0x1F => Kind::ScreenInfo,
            0x20 => Kind::InstalledAppsRequest,
            0x21 => Kind::InstalledApps,
            _ => Kind::Video,
        }
    }
}

/// One decoded frame.
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub kind: Kind,
    pub payload: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Prepend the 4-byte big-endian length (kind byte + payload) and the kind.
pub fn encode_frame(kind: Kind, payload: &[u8]) -> Vec<u8> {
    let length = 1u32 + payload.len() as u32;
    let mut out = Vec::with_capacity(4 + length as usize);
    out.extend_from_slice(&length.to_be_bytes());
    out.push(kind as u8);
    out.extend_from_slice(payload);
    out
}

fn encode_json<T: Serialize>(kind: Kind, value: &T) -> Result<Vec<u8>, serde_json::Error> {
    let payload = serde_json::to_vec(value)?;
    Ok(encode_frame(kind, &payload))
}

/// Encode a video / SPS / PPS NAL frame.
pub fn encode_nal(frame: &NalFrame) -> Vec<u8> {
    let kind = match frame.kind {
        NalKind::Video => Kind::Video,
        NalKind::Sps => Kind::Sps,
        NalKind::Pps => Kind::Pps,
    };
    encode_frame(kind, &frame.data)
}

/// Encode a mirrored-window NAL frame (kinds `0x1A`–`0x1C`).
pub fn encode_screen_nal(frame: &NalFrame) -> Vec<u8> {
    let kind = match frame.kind {
        NalKind::Video => Kind::ScreenVideo,
        NalKind::Sps => Kind::ScreenSps,
        NalKind::Pps => Kind::ScreenPps,
    };
    encode_frame(kind, &frame.data)
}

/// Encode a ping frame. Payload is the 8-byte big-endian sender timestamp
/// in microseconds; the iPhone echoes it back verbatim.
pub fn encode_ping(sent_micros: u64) -> Vec<u8> {
    encode_frame(Kind::Ping, &sent_micros.to_be_bytes())
}

/// Encode a raw file chunk (payload is the bytes verbatim).
pub fn encode_file_chunk(data: &[u8]) -> Vec<u8> {
    encode_frame(Kind::FileChunk, data)
}

macro_rules! json_codec {
    ($enc:ident, $dec:ident, $kind:expr, $ty:ty) => {
        pub fn $enc(value: &$ty) -> Result<Vec<u8>, serde_json::Error> {
            encode_json($kind, value)
        }
        pub fn $dec(frame: &Frame) -> Result<$ty, serde_json::Error> {
            serde_json::from_slice(&frame.payload)
        }
    };
}

json_codec!(encode_metadata, decode_metadata, Kind::Metadata, StreamMetadata);
json_codec!(encode_touch, decode_touch, Kind::Touch, TouchEvent);
json_codec!(encode_key, decode_key, Kind::Key, KeyEvent);
json_codec!(encode_audio, decode_audio, Kind::Audio, AudioPacket);
json_codec!(
    encode_feature_control,
    decode_feature_control,
    Kind::FeatureControl,
    FeatureControl
);
json_codec!(
    encode_feature_state,
    decode_feature_state,
    Kind::FeatureState,
    FeatureStateSnapshot
);
json_codec!(
    encode_client_hello,
    decode_client_hello,
    Kind::ClientHello,
    ClientHello
);
json_codec!(
    encode_session_reply,
    decode_session_reply,
    Kind::SessionReply,
    SessionReply
);
json_codec!(encode_app_list, decode_app_list, Kind::AppList, AppList);
json_codec!(
    encode_app_list_request,
    decode_app_list_request,
    Kind::AppListRequest,
    AppListRequest
);
json_codec!(
    encode_activate_app,
    decode_activate_app,
    Kind::ActivateApp,
    ActivateApp
);
json_codec!(
    encode_window_list_request,
    decode_window_list_request,
    Kind::WindowListRequest,
    WindowListRequest
);
json_codec!(
    encode_window_list,
    decode_window_list,
    Kind::WindowList,
    WindowList
);
json_codec!(encode_file_offer, decode_file_offer, Kind::FileOffer, FileOffer);
json_codec!(
    encode_file_complete,
    decode_file_complete,
    Kind::FileComplete,
    FileComplete
);
json_codec!(encode_file_ack, decode_file_ack, Kind::FileAck, FileAck);
json_codec!(encode_clipboard, decode_clipboard, Kind::ClipboardSet, Clipboard);
json_codec!(
    encode_text_command,
    decode_text_command,
    Kind::TextCommand,
    TextCommandMessage
);
json_codec!(
    encode_camera_command,
    decode_camera_command,
    Kind::CameraCommand,
    CameraCommand
);
json_codec!(encode_quit_app, decode_quit_app, Kind::QuitApp, QuitApp);
json_codec!(
    encode_system_command,
    decode_system_command,
    Kind::SystemCommand,
    SystemCommand
);
json_codec!(
    encode_screen_control,
    decode_screen_control,
    Kind::ScreenControl,
    ScreenControl
);
json_codec!(
    encode_screen_input,
    decode_screen_input,
    Kind::ScreenInput,
    ScreenInput
);
json_codec!(
    encode_screen_info,
    decode_screen_info,
    Kind::ScreenInfo,
    ScreenInfo
);
json_codec!(
    encode_installed_apps,
    decode_installed_apps,
    Kind::InstalledApps,
    InstalledApps
);
json_codec!(
    encode_installed_apps_request,
    decode_installed_apps_request,
    Kind::InstalledAppsRequest,
    InstalledAppsRequest
);

// ---------------------------------------------------------------------------
// Decoding — incremental parser
// ---------------------------------------------------------------------------

/// Incremental parser. Feed incoming bytes; receive zero or more complete
/// frames back. Holds the trailing partial frame across calls.
///
/// Efficient variant of the Swift `IBWire.Parser`: a read cursor avoids
/// re-copying the whole buffer per frame, with amortized compaction.
#[derive(Debug, Default)]
pub struct Parser {
    buffer: Vec<u8>,
    pos: usize,
    frames_parsed: usize,
}

impl Parser {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn frames_parsed(&self) -> usize {
        self.frames_parsed
    }

    /// Append bytes and return any complete frames extracted.
    pub fn append(&mut self, data: &[u8]) -> Vec<Frame> {
        self.buffer.extend_from_slice(data);
        let mut out = Vec::new();
        while let Some(frame) = self.try_parse_next() {
            out.push(frame);
        }
        out
    }

    /// Drop all buffered state.
    pub fn reset(&mut self) {
        self.buffer.clear();
        self.pos = 0;
        self.frames_parsed = 0;
    }

    fn try_parse_next(&mut self) -> Option<Frame> {
        let available = self.buffer.len() - self.pos;
        if available < 4 {
            return None;
        }

        let header = &self.buffer[self.pos..self.pos + 4];
        let length = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
        if !(1..=MAX_FRAME_LEN).contains(&length) {
            // Refuse frames larger than 64 MiB (or a zero length) —
            // protects against an infinite loop from corrupt values.
            self.buffer.clear();
            self.pos = 0;
            return None;
        }

        let total = 4 + length as usize;
        if available < total {
            return None;
        }

        let kind_byte = self.buffer[self.pos + 4];
        let payload = self.buffer[self.pos + 5..self.pos + total].to_vec();
        self.pos += total;
        self.frames_parsed += 1;

        // Compact once the consumed prefix dominates the buffer.
        if self.pos >= 64 * 1024 && self.pos * 2 >= self.buffer.len() {
            self.buffer.drain(..self.pos);
            self.pos = 0;
        }

        Some(Frame {
            kind: Kind::from_u8_or_video(kind_byte),
            payload,
        })
    }
}

/// Decode a `.ping` payload into the sender timestamp (up to 8 bytes BE).
pub fn decode_ping(frame: &Frame) -> u64 {
    let mut value: u64 = 0;
    for &byte in frame.payload.iter().take(8) {
        value = (value << 8) | byte as u64;
    }
    value
}
