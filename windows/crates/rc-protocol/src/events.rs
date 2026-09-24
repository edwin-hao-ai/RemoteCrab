//! Rust port of `RemoteCrabCore/Networking/IBEvents.swift` +
//! `State/TextTransform.swift` + `State/FeatureStore.swift` payloads.
//!
//! JSON field names are matched **exactly** to what the iOS sender emits
//! (Swift's default synthesized `Codable` key names, i.e. the property
//! names verbatim). Enum raw values are matched to the Swift `String`
//! raw values. Do not rename fields — the wire is the contract.

use serde::{Deserialize, Serialize};

use crate::base64_serde;

// ---------------------------------------------------------------------------
// Touch
// ---------------------------------------------------------------------------

/// A single touch / mouse event captured on the iPhone and shipped to the
/// receiver, which injects it via the platform's input API.
///
/// Coordinates are normalized to `0..1` against the iPhone screen. The
/// receiver treats `move` as a *relative* delta (joystick-style) — see the
/// Mac's `CGEventInjector` for the exact semantics.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TouchEvent {
    pub phase: TouchPhase,
    #[serde(default)]
    pub x: f32,
    #[serde(default)]
    pub y: f32,
    #[serde(default)]
    pub dx: f32,
    #[serde(default)]
    pub dy: f32,
    #[serde(default)]
    pub modifiers: u8,
    /// True when this `.scroll` comes from the iOS-side momentum glide
    /// (finger already lifted). Optional for wire compatibility with
    /// older senders.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub momentum: Option<bool>,
    #[serde(default)]
    pub timestamp_micros: u64,
}

impl TouchEvent {
    pub fn has_command(&self) -> bool {
        self.modifiers & Modifier::COMMAND != 0
    }
    pub fn has_shift(&self) -> bool {
        self.modifiers & Modifier::SHIFT != 0
    }
    pub fn has_option(&self) -> bool {
        self.modifiers & Modifier::OPTION != 0
    }
    pub fn has_control(&self) -> bool {
        self.modifiers & Modifier::CONTROL != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TouchPhase {
    /// single-finger tap-down = left mouse down
    Down,
    /// single-finger drag = mouse move
    Move,
    /// single-finger tap-up = left mouse up
    Up,
    /// two-finger tap-down = right mouse down
    RightDown,
    /// two-finger tap-up = right mouse up
    RightUp,
    /// two-finger drag = scroll wheel
    Scroll,
    /// tap (down + up in same spot) = left click
    Click,
    /// double-tap-hold / long-press: begin drag (left button held)
    DragStart,
    /// two-finger pinch; `dx` = scale delta (+0.01 = +1%)
    Pinch,
    /// `dx`/`dy` = unit direction vector (up = (0,1))
    ThreeFingerSwipe,
    /// three-finger tap = middle click
    ThreeFingerTap,
    /// deep press (majorRadius) = right click
    ForceClick,
}

/// Modifier bitmask carried by `TouchEvent` / `KeyEvent`.
pub struct Modifier;
impl Modifier {
    pub const NONE: u8 = 0;
    pub const SHIFT: u8 = 1;
    pub const CONTROL: u8 = 2;
    pub const OPTION: u8 = 4;
    pub const COMMAND: u8 = 8;
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

/// A single key event from the iPhone keyboard.
///
/// `.down`/`.up` carry a macOS `CGKeyCode` (virtual keycode); the receiver
/// maps it to its own key representation. `.text` carries a UTF-8 string
/// already translated by the iOS IME.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyEvent {
    pub action: KeyAction,
    /// macOS `CGKeyCode`, present for `.down` / `.up`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keycode: Option<u16>,
    /// Present for `.text`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default)]
    pub modifiers: u8,
    #[serde(default)]
    pub timestamp_micros: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum KeyAction {
    Down,
    Up,
    /// batch of typed characters (finalized after IME)
    Text,
}

// ---------------------------------------------------------------------------
// Audio
// ---------------------------------------------------------------------------

/// Wire value for raw Int16 PCM payloads.
pub const AUDIO_CODEC_PCM: &str = "pcm";
/// Wire value for Opus payloads (48 kHz mono).
pub const AUDIO_CODEC_OPUS: &str = "opus";

/// A single audio frame from the iPhone microphone. `opus_data` carries
/// one Opus packet (typically 20 ms at 48 kHz) when `codec == "opus"`, or
/// raw Int16 interleaved PCM when `codec == "pcm"`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioPacket {
    #[serde(with = "base64_serde")]
    pub opus_data: Vec<u8>,
    #[serde(default = "default_sample_rate")]
    pub sample_rate: i64,
    #[serde(default = "default_channels")]
    pub channels: i64,
    #[serde(default)]
    pub timestamp_micros: u64,
    /// `"pcm"` (legacy default) or `"opus"`. Older builds omit the key
    /// entirely, so decoding must default to `"pcm"`.
    #[serde(default = "default_audio_codec")]
    pub codec: String,
}

fn default_sample_rate() -> i64 {
    48_000
}
fn default_channels() -> i64 {
    1
}
fn default_audio_codec() -> String {
    AUDIO_CODEC_PCM.to_string()
}

// ---------------------------------------------------------------------------
// Feature control / state
// ---------------------------------------------------------------------------

/// The independently toggleable capabilities of the iPhone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Feature {
    Camera,
    Microphone,
    Voice,
    Trackpad,
    Keyboard,
}

/// Receiver → iPhone: toggle a feature remotely (kind `0x07`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FeatureControl {
    pub feature: Feature,
    pub enabled: bool,
}

/// Which physical camera the iPhone streams from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CameraPosition {
    Front,
    #[default]
    Back,
}

impl CameraPosition {
    pub fn toggled(self) -> Self {
        match self {
            CameraPosition::Back => CameraPosition::Front,
            CameraPosition::Front => CameraPosition::Back,
        }
    }
}

/// Receiver → iPhone: switch the streaming camera (kind `0x15`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CameraCommand {
    pub position: CameraPosition,
}

/// Which interaction surface currently occupies the iPhone screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Surface {
    Trackpad,
    Keyboard,
    CameraPreview,
}

/// iPhone → receiver: full feature-state snapshot (kind `0x08`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeatureStateSnapshot {
    pub camera_on: bool,
    pub mic_on: bool,
    pub voice_on: bool,
    pub trackpad_on: bool,
    pub keyboard_on: bool,
    pub active_surface: Surface,
    /// Defaults to `.back` when absent so snapshots from older builds
    /// still decode.
    #[serde(default)]
    pub camera_position: CameraPosition,
    #[serde(default)]
    pub timestamp_micros: u64,
}

// ---------------------------------------------------------------------------
// Handshake / pairing
// ---------------------------------------------------------------------------

/// Receiver → iPhone: identity handshake, first frame on every connection
/// (kind `0x0A`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientHello {
    pub name: String,
    /// Stable per-machine UUID, persisted across launches.
    pub id: String,
    /// Pairing token issued by the iPhone on first approval. `None` on the
    /// very first connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    #[serde(default)]
    pub app_version: String,
    /// Which OS this receiver runs on (`"macos"` | `"windows"` | `"linux"`).
    ///
    /// ADDITIVE / OPTIONAL: the current iOS build ignores unknown JSON
    /// keys, so sending this is harmless and decoding an absent value
    /// defaults to `None`. Windows uses it (once iOS learns to read it) to
    /// present the right modifier symbols + shortcut chords.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
}

/// iPhone → receiver: the ownership decision for a `clientHello`
/// (kind `0x0B`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionReplyResult {
    /// This receiver now owns the session.
    Accepted,
    /// The iPhone is showing an approval prompt; wait (do not retry).
    Pending,
    /// Another receiver already owns the session.
    Busy,
    /// The request was explicitly denied.
    Denied,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionReply {
    pub result: SessionReplyResult,
    /// Present for `.busy` — the human name of the owner.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_name: Option<String>,
    /// Present for `.accepted` — the pairing token to persist.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

// ---------------------------------------------------------------------------
// App switcher
// ---------------------------------------------------------------------------

/// One switchable application on the receiver machine.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppInfo {
    pub id: String,
    pub name: String,
    pub pid: i32,
    pub is_active: bool,
    /// PNG of the app's icon (base64). Only populated when the iPhone
    /// explicitly asks.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "base64_serde::opt"
    )]
    pub icon_png: Option<Vec<u8>>,
}

/// Receiver → iPhone: current list of running regular apps (kind `0x0C`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppList {
    pub apps: Vec<AppInfo>,
}

/// iPhone → receiver: ask for a fresh app list (kind `0x0D`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct AppListRequest {}

/// iPhone → receiver: bring the identified app to the front (kind `0x0E`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivateApp {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
}

/// iPhone → receiver: quit the identified app (kind `0x16`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuitApp {
    pub id: String,
    #[serde(default)]
    pub force: bool,
}

// ---------------------------------------------------------------------------
// Window list
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowInfo {
    pub id: String,
    pub app_id: String,
    pub app_name: String,
    pub title: String,
    pub is_active: bool,
    #[serde(default)]
    pub width: f64,
    #[serde(default)]
    pub height: f64,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "base64_serde::opt"
    )]
    pub snapshot_jpeg: Option<Vec<u8>>,
}

/// Receiver → iPhone: current window list (kind `0x18`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowList {
    pub windows: Vec<WindowInfo>,
    pub can_capture: bool,
}

/// iPhone → receiver: ask for a fresh window list (kind `0x17`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct WindowListRequest {}

// ---------------------------------------------------------------------------
// File transfer
// ---------------------------------------------------------------------------

/// iPhone → receiver: begin a file transfer (kind `0x0F`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FileOffer {
    pub id: String,
    pub name: String,
    pub size: i64,
}

/// iPhone → receiver: the transfer finished (kind `0x11`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FileComplete {
    pub id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FileAckStatus {
    Progress,
    Saved,
    Error,
}

/// Receiver → iPhone: transfer feedback (kind `0x12`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileAck {
    pub id: String,
    pub status: FileAckStatus,
    pub received_bytes: i64,
    /// Absolute path on the receiver once saved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

/// Either direction: replace the peer's clipboard text (kind `0x13`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Clipboard {
    pub text: String,
}

// ---------------------------------------------------------------------------
// Text command (selection rewrite)
// ---------------------------------------------------------------------------

/// Deterministic, offline transforms applied to the peer's current
/// selection (no cloud, no LLM).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextCommand {
    Uppercase,
    Lowercase,
    Capitalize,
    TrimWhitespace,
    StripNewlines,
    BulletList,
}

impl TextCommand {
    /// Port of `TextTransform.apply`.
    pub fn apply(self, text: &str) -> String {
        match self {
            TextCommand::Uppercase => text.to_uppercase(),
            TextCommand::Lowercase => text.to_lowercase(),
            TextCommand::Capitalize => capitalize_words(text),
            TextCommand::TrimWhitespace => text.trim().to_string(),
            TextCommand::StripNewlines => text
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .collect::<Vec<_>>()
                .join(" "),
            TextCommand::BulletList => text
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .map(|l| format!("• {l}"))
                .collect::<Vec<_>>()
                .join("\n"),
        }
    }
}

/// Approximates Swift's `String.capitalized` (first letter of each word
/// uppercased, the rest lowercased). Swift also breaks on punctuation;
/// this splits on whitespace, which covers the selection-rewrite cases.
fn capitalize_words(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut at_word_start = true;
    for ch in text.chars() {
        if ch.is_whitespace() {
            at_word_start = true;
            out.push(ch);
        } else if at_word_start {
            out.extend(ch.to_uppercase());
            at_word_start = false;
        } else {
            out.extend(ch.to_lowercase());
        }
    }
    out
}

/// iPhone → receiver: transform the receiver's current selection
/// (kind `0x14`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TextCommandMessage {
    pub command: TextCommand,
}

// ---------------------------------------------------------------------------
// System command
// ---------------------------------------------------------------------------

/// iPhone → receiver: a system-level action (kind `0x19`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SystemCommand {
    pub command: SystemCommandKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub argument: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SystemCommandKind {
    VolumeUp,
    VolumeDown,
    VolumeMute,
    BrightnessUp,
    BrightnessDown,
    MediaPlayPause,
    MediaNext,
    MediaPrevious,
    LaunchApp,
    #[serde(rename = "openURL")]
    OpenUrl,
}
