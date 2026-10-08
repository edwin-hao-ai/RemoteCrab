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
    // App-window mirror (the screen-share feature). The Windows receiver
    // **does** implement this now — see `rc-mirror` and the `mirror` modules in
    // `rc-app` — but the recognition requirement outlives that: an unknown byte
    // falls through to `Video`, so a mirror NAL would be fed to the camera
    // decoder and corrupt the stream. That is true for a build with the mirror
    // compiled out, and it is why this comment used to say "does not implement
    // yet" without the note going stale being harmless.
    ScreenVideo = 0x1A,
    ScreenSps = 0x1B,
    ScreenPps = 0x1C,
    ScreenControl = 0x1D,
    ScreenInput = 0x1E,
    ScreenInfo = 0x1F,
    InstalledAppsRequest = 0x20,
    InstalledApps = 0x21,
    // Mac → iPhone notification relay (`IBNotification`, JSON). The Windows
    // receiver **relays notifications now** (`rc-app`'s `notify_relay`), and the
    // recognition requirement is the same as above: an unknown byte decodes as
    // `Video`, and this JSON payload would be handed to the H.264 decoder.
    Notification = 0x22,
    // Mac → iPhone command outcome (`IBCommandResult`, JSON). The Windows
    // receiver **does not send these yet** — a current limitation, not a design
    // one — but it must still recognise the kind: an unknown byte decodes as
    // `Video` and this JSON would go to the H.264 decoder.
    CommandResult = 0x23,
    /// receiver → iPhone: the computer's own audio, for playback on the
    /// phone speaker ("use the iPhone as the speaker"). The Windows
    /// receiver sends these once it has loopback capture; it MUST
    /// recognise the kind even before that, for the same reason as
    /// 0x1A–0x23: an unknown byte falls through to `Video`, and this JSON
    /// payload would then be handed to the H.264 decoder.
    SpeakerAudio = 0x24,
    /// receiver → iPhone: "send a keyframe next".
    ///
    /// The standard mitigation for a decoder that has lost its reference frames,
    /// from OpenH264's own issue tracker (#1998, #1163): once the receiver knows
    /// it cannot decode what it is being sent, the only recovery is a fresh IDR,
    /// and waiting for the next scheduled one can be seconds away. Without this
    /// the receiver has no way to ask, and a stream that lost a P-frame stays
    /// wrong until the phone's keyframe interval happens to elapse.
    ///
    /// Purely additive: an older phone ignores an unknown kind, and it is the
    /// receiver that sends it, so an older receiver never emits it. The iOS side
    /// implements the handling (it was once claimed missing; it is not).
    RequestKeyframe = 0x25,
    /// receiver → iPhone: this machine's answer to the phone's half of the
    /// authentication challenge (`ClientProof`, JSON).
    ///
    /// Purely additive in the same way as `RequestKeyframe`: only the receiver
    /// sends it, and only to a phone that asked for it by sending a MAC first.
    /// An older phone ignores an unknown kind, so nothing about this can break
    /// a connection that was working.
    ClientProof = 0x26,
    /// iPhone → receiver: the phone's identity handshake, sent as the FIRST frame
    /// on a phone-initiated TCP connection (`PhoneHello`, JSON, kind `0x27`).
    ///
    /// The mirror of `ClientHello` with the roles reversed: when the phone dials
    /// the receiver there is no inbound `clientHello` for it to read, so the
    /// phone introduces itself first and the receiver looks up the pairing token
    /// by `phoneId`. Purely additive: only a phone that supports phone-initiated
    /// connections sends it, and an older receiver that does not recognise the
    /// byte drops it as `Kind::Unknown` rather than handing the JSON to the
    /// H.264 decoder.
    PhoneHello = 0x27,
    /// A byte this build does not recognise.
    ///
    /// Not a real wire kind — it is what the parser produces instead of
    /// guessing. This used to be `Kind::Video`, which meant every kind a given
    /// build had not heard of was handed to the H.264 decoder. A build that
    /// forgot to register one kind would misroute it rather than drop it, and
    /// the symptom was a corrupt preview with no error. `Kind::Unknown` is
    /// ignored by every consumer, and it mirrors the Swift side's `.unknown`.
    Unknown = 0xFF,
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

    /// The kind for a byte, or [`Kind::Unknown`] when this build does not know
    /// it — the mirror of Swift's `Kind(rawValue:) ?? .unknown`. An unrecognised
    /// byte must never become `Video` (see the note on [`Kind::Unknown`]).
    pub fn from_u8(byte: u8) -> Kind {
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
            0x22 => Kind::Notification,
            0x23 => Kind::CommandResult,
            0x24 => Kind::SpeakerAudio,
            0x25 => Kind::RequestKeyframe,
            0x26 => Kind::ClientProof,
            0x27 => Kind::PhoneHello,
            _ => Kind::Unknown,
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

/// Ask the phone for a keyframe as its next picture.
///
/// Empty payload, so it cannot be confused with a neighbouring kind and cannot
/// be mis-parsed by an older phone: it arrives as a frame with a known length
/// and no body, which every parser in the tree already skips.
pub fn encode_request_keyframe() -> Vec<u8> {
    encode_frame(Kind::RequestKeyframe, &[])
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
json_codec!(encode_speaker_audio, decode_speaker_audio, Kind::SpeakerAudio, AudioPacket);
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
json_codec!(
    encode_client_proof,
    decode_client_proof,
    Kind::ClientProof,
    ClientProof
);
json_codec!(
    encode_phone_hello,
    decode_phone_hello,
    Kind::PhoneHello,
    PhoneHello
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
    encode_command_result,
    decode_command_result,
    Kind::CommandResult,
    CommandResult
);
json_codec!(
    encode_notification,
    decode_notification,
    Kind::Notification,
    Notification
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
    /// Times the framing had to be recovered from a corrupt length.
    resyncs: u64,
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
        self.resyncs = 0;
    }

    /// How many times the stream had to be resynchronised.
    ///
    /// A non-zero count means bytes were lost or corrupted in transit and the
    /// decoder was handed a stream with a hole in it. It used to be
    /// unobservable: the parser cleared its whole buffer and said nothing, so the
    /// picture froze and every counter on the console still said "streaming".
    pub fn resyncs(&self) -> u64 {
        self.resyncs
    }

    fn try_parse_next(&mut self) -> Option<Frame> {
        // A corrupt length desynchronises the framing: the bytes after it are
        // still real frames, they are just no longer at a frame boundary. The
        // old response was `self.buffer.clear()`, which threw away every
        // complete frame already received behind the corruption, silently — the
        // stream then froze with the console still reporting "streaming".
        //
        // Instead, skip forward a byte at a time until a position that parses as
        // a header is found. That recovers everything after the damage rather
        // than everything up to it, and the count makes the loss visible.
        loop {
            let available = self.buffer.len() - self.pos;
            if available < 4 {
                return None;
            }

            let header = &self.buffer[self.pos..self.pos + 4];
            let length = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
            if !(1..=MAX_FRAME_LEN).contains(&length) {
                // 0, or larger than the 64 MiB cap. Either way this cannot be a
                // frame header, so the next one is at least one byte away.
                self.resyncs += 1;
                self.pos += 1;
                continue;
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

            return Some(Frame {
                kind: Kind::from_u8(kind_byte),
                payload,
            });
        }
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

#[cfg(test)]
mod resync_tests {
    use super::{encode_frame, Kind, Parser, MAX_FRAME_LEN};

    fn frame(kind: Kind, payload: &[u8]) -> Vec<u8> {
        encode_frame(kind, payload)
    }

    /// The failure this fixes, and the reason it was worth fixing: one corrupt
    /// length used to throw away **every** complete frame already received
    /// behind it. The picture then froze with the console still reporting
    /// "streaming" and no counter anywhere saying why.
    ///
    /// Against the old `self.buffer.clear()` this test fails with 0 frames
    /// recovered; here it must find the frame on the far side.
    #[test]
    fn a_corrupt_length_does_not_swallow_the_frames_behind_it() {
        let mut good = frame(Kind::Metadata, b"before");
        // A length that cannot be right: over the 64 MiB cap.
        good.extend_from_slice(&[0xFF, 0xFF, 0xFF, 0xFF]);
        good.extend_from_slice(frame(Kind::Video, b"after").as_slice());

        let mut parser = Parser::new();
        let frames = parser.append(&good);

        let videos: Vec<_> = frames.iter().filter(|f| f.kind == Kind::Video).collect();
        assert_eq!(
            videos.len(),
            1,
            "the frame after the corruption must survive, got {:?}",
            frames.iter().map(|f| f.kind).collect::<Vec<_>>()
        );
        assert_eq!(videos[0].payload, b"after");
        assert!(parser.resyncs() > 0, "the recovery must be counted");
    }

    /// And the loss has to be visible rather than silent. A stream that resyncs
    /// is a stream with a hole in it, which is a different situation from one
    /// that never lost anything, and only the counter tells them apart.
    #[test]
    fn recovery_is_counted_so_the_loss_is_not_silent() {
        let mut stream = frame(Kind::Video, b"a");
        stream.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // length 0
        stream.extend_from_slice(frame(Kind::Video, b"b").as_slice());

        let mut parser = Parser::new();
        let frames = parser.append(&stream);
        assert_eq!(frames.len(), 2, "both good frames survive: {frames:?}");
        assert!(
            parser.resyncs() >= 1,
            "a zero length is corruption and must be counted"
        );
    }

    /// A clean stream must not report any resyncs. Without this the recovery
    /// could fire on well-formed input and the counter would be noise.
    #[test]
    fn a_clean_stream_reports_no_resyncs() {
        let mut stream = Vec::new();
        for i in 0..10u8 {
            stream.extend_from_slice(&frame(Kind::Video, &[i; 4]));
        }
        let mut parser = Parser::new();
        let frames = parser.append(&stream);
        assert_eq!(frames.len(), 10);
        assert_eq!(parser.resyncs(), 0, "nothing was corrupt");
    }

    /// A frame split across reads must still work, and must not be mistaken for
    /// corruption while its header is only half present. This is the case a
    /// naive resync breaks: `00 00 00 20` arriving as `00 00` looks like a
    /// zero-length frame if the parser does not insist on four bytes first.
    #[test]
    fn a_frame_arriving_in_pieces_is_not_mistaken_for_corruption() {
        let whole = frame(Kind::Video, &[7u8; 300]);
        let mut parser = Parser::new();
        for chunk in whole.chunks(7) {
            parser.append(chunk);
        }
        let frames = parser.append(&[]);
        assert_eq!(parser.frames_parsed(), 1);
        assert_eq!(parser.resyncs(), 0, "a split frame is not corruption");
        assert_eq!(frames.len(), 0);
        assert_eq!(parser.frames_parsed(), 1);
    }

    /// A length at the cap is legal; one past it is not. If the boundary is
    /// wrong, a legitimate maximum-size frame gets discarded as garbage.
    #[test]
    fn the_length_cap_boundary_is_respected() {
        // Exactly the cap: a header claiming the maximum must be treated as a
        // real frame awaiting its payload, not as corruption.
        let mut parser = Parser::new();
        let header = MAX_FRAME_LEN.to_be_bytes();
        parser.append(&header);
        assert_eq!(
            parser.resyncs(),
            0,
            "the maximum legal length must not be counted as corruption"
        );

        // One past it.
        let mut parser = Parser::new();
        parser.append(&(MAX_FRAME_LEN + 1).to_be_bytes());
        assert!(
            parser.resyncs() > 0,
            "one past the cap cannot be a frame and must be recovered from"
        );
    }

    /// `reset` has to clear the new counter too, or a reconnect inherits the
    /// previous link's damage report.
    #[test]
    fn reset_clears_the_resync_count() {
        let mut stream = frame(Kind::Video, b"a");
        stream.extend_from_slice(&[0, 0, 0, 0]);
        let mut parser = Parser::new();
        parser.append(&stream);
        assert!(parser.resyncs() > 0);
        parser.reset();
        assert_eq!(parser.resyncs(), 0);
    }
}

#[cfg(test)]
mod phone_hello_kind_tests {
    use super::{Kind, Parser};

    /// `PhoneHello` is a fresh slot immediately after `ClientProof` (0x26), and
    /// it is the FIRST frame a phone sends when IT started the connection. If it
    /// ever fell through to `Kind::Video` the receiver would hand this JSON to
    /// the H.264 decoder — the exact failure `Kind::Unknown` exists to prevent
    /// (lesson 152).
    #[test]
    fn phone_hello_is_0x27_and_does_not_fall_through_to_video() {
        assert_eq!(Kind::PhoneHello as u8, 0x27);
        assert_eq!(Kind::from_u8(0x27), Kind::PhoneHello);
        assert_eq!(Kind::from_u8(0x25), Kind::RequestKeyframe);
        // An unknown byte must NOT become Video.
        assert!(matches!(Kind::from_u8(0xEE), Kind::Unknown));
        assert_ne!(Kind::from_u8(0xEE), Kind::Video);
    }

    /// It has to survive the parser, or the phone's handshake never reaches the
    /// receiver at all.
    #[test]
    fn phone_hello_survives_the_parser() {
        let frame = super::encode_frame(Kind::PhoneHello, b"{}");
        let mut parser = Parser::new();
        let frames = parser.append(&frame);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].kind, Kind::PhoneHello);
        assert_eq!(frames[0].payload, b"{}");
    }
}

#[cfg(test)]
mod speaker_audio_kind_tests {
    use super::{encode_request_keyframe, Kind, Parser};

    /// 0x24 is frozen on the wire. If it changes, an older iPhone that knows
    /// kinds only up to 0x23 will not recognise it — it now decodes as
    /// `Kind::Unknown` and is dropped, rather than being handed to the H.264
    /// decoder as corrupt video.
    #[test]
    fn speaker_audio_kind_is_frozen_at_0x24() {
        assert_eq!(Kind::SpeakerAudio as u8, 0x24);
        assert_eq!(Kind::from_u8(0x24), Kind::SpeakerAudio);
    }

    /// An unrecognised byte must NOT become `Video`. That fallback is what
    /// turns a forgotten kind into corrupt video instead of an ignored frame:
    /// a newer phone sending a JSON kind this build has not heard of would
    /// have its payload handed to the H.264 decoder. `Kind::Unknown` is dropped
    /// by every consumer, and it matches the Swift side's `Kind.unknown`.
    #[test]
    fn unknown_kind_is_not_video() {
        assert_eq!(Kind::from_u8(0x7F), Kind::Unknown);
        assert_eq!(Kind::from_u8(0xFF), Kind::Unknown);
        assert_ne!(Kind::from_u8(0x7F), Kind::Video);
    }

    #[test]
    fn speaker_audio_is_distinct_from_microphone_audio() {
        assert_ne!(Kind::SpeakerAudio, Kind::Audio);
        assert_eq!(Kind::from_u8(0x06), Kind::Audio);
    }

    /// Every kind in the enum must be reachable from its byte. A kind added
    /// to the enum but not to `from_u8` compiles fine and then silently
    /// decodes as `Unknown` — dropped rather than handled. That is a safe
    /// failure, but it is still a bug, which is why this is pinned.
    #[test]
    fn every_declared_kind_is_reachable_from_its_byte() {
        let kinds = [
            Kind::Metadata, Kind::Video, Kind::Sps, Kind::Pps, Kind::Touch,
            Kind::Key, Kind::Audio, Kind::FeatureControl, Kind::FeatureState,
            Kind::Ping, Kind::ClientHello, Kind::SessionReply, Kind::AppList,
            Kind::AppListRequest, Kind::ActivateApp, Kind::FileOffer,
            Kind::FileChunk, Kind::FileComplete, Kind::FileAck,
            Kind::ClipboardSet, Kind::TextCommand, Kind::CameraCommand,
            Kind::QuitApp, Kind::WindowListRequest, Kind::WindowList,
            Kind::SystemCommand, Kind::ScreenVideo, Kind::ScreenSps,
            Kind::ScreenPps, Kind::ScreenControl, Kind::ScreenInput,
            Kind::ScreenInfo, Kind::InstalledAppsRequest, Kind::InstalledApps,
            Kind::Notification, Kind::CommandResult, Kind::SpeakerAudio,
            Kind::RequestKeyframe, Kind::PhoneHello,
        ];
        for k in kinds {
            assert_eq!(Kind::from_u8(k as u8), k, "kind {:?} is not reachable", k);
        }
    }

    /// `requestKeyframe` is the first kind the receiver sends that the phone is
    /// expected to act on rather than merely receive. If its byte ever collides
    /// with something else, the phone silently does the wrong thing instead of
    /// ignoring it — so the byte and the empty payload are both pinned.
    #[test]
    fn request_keyframe_is_kind_0x25_with_an_empty_payload() {
        assert_eq!(Kind::RequestKeyframe as u8, 0x25);
        assert_eq!(Kind::from_u8(0x25), Kind::RequestKeyframe);

        let frame = encode_request_keyframe();
        // [4-byte BE length][kind] — a length of exactly 1 means a kind byte
        // and nothing else.
        assert_eq!(frame.len(), 5);
        assert_eq!(&frame[..4], &[0, 0, 0, 1]);
        assert_eq!(frame[4], 0x25);
    }

    /// It has to survive a round trip through the parser, or the phone never
    /// sees it. An empty payload is the easy thing to get wrong.
    #[test]
    fn request_keyframe_survives_the_parser() {
        let mut parser = Parser::new();
        let frames = parser.append(&encode_request_keyframe());
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].kind, Kind::RequestKeyframe);
        assert!(frames[0].payload.is_empty());
    }
}
