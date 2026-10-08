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
    /// The Windows key (⊞). Bit 16 — the original mask only defined
    /// 1/2/4/8, and `COMMAND` collapses into Ctrl, so there was no way
    /// to *hold* ⊞ and therefore no way to send ⊞E / ⊞R / ⊞D / ⊞L.
    /// Purely additive: an older receiver ignores it, a newer one that
    /// never sees it is unaffected.
    pub const META: u8 = 16;
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
    /// The iPhone is showing the receiver's mirrored screen. Without this
    /// variant a `featureControl {feature:"screen"}` frame fails to decode.
    Screen,
    /// The computer's audio plays out of the iPhone speaker. The iPhone owns
    /// the control today (the Mac shows a status row, not a toggle), but the
    /// Swift `IBFeature` has always had this case, so a `featureControl
    /// {feature:"speaker"}` from any future sender must decode here too rather
    /// than fail the frame.
    Speaker,
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
    /// The iPhone is on the screen-mirror surface. Missing this variant made
    /// the whole `featureState` snapshot fail to decode while mirroring.
    Screen,
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
    /// Whether the receiver's app-window mirror is live. Defaults to false
    /// for snapshots from builds that predate the mirror.
    #[serde(default)]
    pub screen_on: bool,
    /// Whether the phone wants this computer's audio played out of its own
    /// speaker (wire kind `0x24`, "use the iPhone as the speaker").
    ///
    /// Defaults to false for snapshots from phone builds that predate the
    /// feature. `#[serde(default)]` is load-bearing twice over here: the
    /// receiver's whole trigger for starting the capture is this one flag, and
    /// this struct has no other defaulted field that a missing key could hide
    /// behind. A snapshot that failed to decode would take the whole
    /// `featureState` frame — and with it camera, mic and mirror control —
    /// down to "no state at all", which is the failure mode the loader in this
    /// project is documented to swallow silently (rule 2).
    #[serde(default)]
    pub speaker_on: bool,
    #[serde(default)]
    pub timestamp_micros: u64,
}

// ---------------------------------------------------------------------------
// Handshake / pairing
// ---------------------------------------------------------------------------

/// Capability word for "this receiver can turn the phone into a second
/// display" (`screenControl(extend)`).
///
/// The single Rust definition of the wire string, referenced by `rc-net`'s
/// hello and by `rc-vdisplay`. The Mac half spells it once in
/// `IBClientHello.Capability.extendedDisplay`; the two must stay identical.
pub const CAP_EXTENDED_DISPLAY: &str = "extendedDisplay";

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
    ///
    /// Still sent, and still read by a phone that has not learned the exchange
    /// below. It is no longer what *proves* this receiver, though: a phone that
    /// supports `peerAuth` ignores it and demands the MAC instead. A secret you
    /// hand over is a badge, and anyone on the same network reads the same
    /// bytes — see `rc_net::peer_auth`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    /// This receiver's half of the challenge, base64.
    ///
    /// ADDITIVE / OPTIONAL. A phone that does not do the exchange ignores it; a
    /// phone that does echoes it back inside its MAC, which is what stops a
    /// recorded MAC from being replayed on a later connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nonce: Option<String>,
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
    /// Declared abilities, so the phone can rely on them.
    ///
    /// `commandResult` is the one that matters here: the phone deliberately does
    /// **not** send a `requestId` to a receiver that has not named it, so that an
    /// older receiver is never handed an answer it cannot produce. That means a
    /// receiver which answers commands but forgets to declare this is never asked
    /// — and the phone's buttons stay silent, which is what the user sees as
    /// "broken". `latencyProbe` is the other: this receiver echoes probes it did
    /// not originate (`rc-net::ping`), which is what lets the phone measure its
    /// own round trip.
    ///
    /// Strings rather than an enum so an unknown value from a newer phone decodes
    /// rather than failing the handshake.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<String>>,
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
    /// The user tapped Disconnect for this computer on the iPhone. Stop owning
    /// and do not auto-reconnect until the user picks it again — otherwise the
    /// receiver's own reconnect loop makes Disconnect look broken.
    Off,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionReply {
    pub result: SessionReplyResult,
    /// Present for `.busy` — the human name of the owner.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_name: Option<String>,
    /// Present for `.accepted` — the pairing token to persist.
    ///
    /// This is the trust-on-first-pair window and there is no way around it: the
    /// phone is handing out a secret to a machine it has not met, over a channel
    /// nobody has authenticated yet. Every connection *after* this one is
    /// protected by the MAC below, so the window is one pairing rather than
    /// every reconnect — which is the whole of the improvement.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    /// The phone's half of the challenge, base64. Player two.
    ///
    /// ADDITIVE. Absent from every phone that does not do the exchange, and
    /// absent means "this session is not authenticated" — not "skip the check".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nonce: Option<String>,
    /// HMAC-SHA256 the phone computed over both nonces and this receiver's id,
    /// keyed by the pairing token. Absent means the phone cannot do this.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mac: Option<String>,
    /// What the phone says it can do, so the receiver knows whether the MAC it
    /// is about to demand is a reasonable thing to expect.
    ///
    /// Strings rather than an enum, for the same reason `ClientHello` uses them:
    /// a phone newer than this build may name abilities that do not exist here,
    /// and one unknown word must not fail the handshake.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<String>>,
}

/// Receiver → iPhone: this machine's answer to the phone's half of the
/// challenge (kind `0x1E`).
///
/// Sent only after a `sessionReply` that carried a MAC. Its arrival is what lets
/// the phone stop showing its approval card and admit this computer without a
/// human tapping Allow — the proof *replaces* the tap for a machine that already
/// holds the token.
///
/// The phone must never accept a bare `clientHello` as evidence of anything.
/// Presenting a token is not proof of holding it: anyone on the same network can
/// read the same bytes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientProof {
    pub mac: String,
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
    ///
    /// The explicit `rename` is load-bearing: Swift's property is `iconPNG`,
    /// so the wire key is `iconPNG`. `rename_all = "camelCase"` would emit
    /// `iconPng`, the iPhone's decoder would find no key, and app icons
    /// would silently never appear.
    #[serde(
        rename = "iconPNG",
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
    /// Correlates the `commandResult` this request should produce.
    ///
    /// Optional in both directions on purpose, and the reason is compatibility:
    /// a phone that predates `commandResult` omits it, and the receiver then
    /// stays silent — which the phone reads as "that receiver is too old to
    /// confirm" rather than as a failure. An explicit `rename` rather than
    /// relying on the struct-level `camelCase`, so the field cannot drift if
    /// that attribute is ever removed.
    #[serde(default, rename = "requestId", skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

/// iPhone → receiver: quit the identified app (kind `0x16`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuitApp {
    pub id: String,
    #[serde(default)]
    pub force: bool,
    /// See [`ActivateApp::request_id`].
    #[serde(default, rename = "requestId", skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
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
    /// Explicit `rename`: Swift's property is `snapshotJPEG`, so the wire key
    /// is `snapshotJPEG` (camelCase would give `snapshotJpeg` → thumbnails
    /// would never reach the iPhone).
    #[serde(
        rename = "snapshotJPEG",
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

/// `'` and the typographic `’`, which Foundation treats as word-internal when
/// they follow a letter.
fn is_apostrophe(ch: char) -> bool {
    ch == '\'' || ch == '\u{2019}'
}

/// Swift's `String.capitalized`, which is what the Mac's
/// `TextTransform.capitalize` calls.
///
/// **The rule is "capitalize after anything that is not a letter", not
/// "after whitespace".** The first version of this split on whitespace only,
/// so the same selection came out differently depending on which machine
/// applied it: `hello-world` → `Hello-World` on macOS, `Hello-world` on
/// Windows. A user who capitalises a heading on one machine and re-applies it
/// after switching to the other was getting silently different text, and
/// nothing said so.
///
/// `Foundation` treats a word boundary as any non-alphanumeric, and leaves
/// both the boundary and the following character's other case alone. Digits
/// count as *continuing* a word, so `3d` is `3d` and not `3D` — which is what
/// the Mac does and therefore what this must do.
fn capitalize_words(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut at_word_start = true;
    for ch in text.chars() {
        if ch.is_alphabetic() {
            if at_word_start {
                out.extend(ch.to_uppercase());
            } else {
                out.extend(ch.to_lowercase());
            }
            at_word_start = false;
        } else {
            // Whether an apostrophe is word-internal depends on the character
            // *before* it, so this has to be read before the push below.
            let after_letter = out.chars().last().is_some_and(char::is_alphabetic);
            out.push(ch);
            // A digit continues the current word; so does an apostrophe that
            // follows a letter, because Foundation does not break a
            // contraction: "it's" capitalises to "It's", not "It'S". A
            // *leading* apostrophe does start a word, so `'quoted'` becomes
            // `'Quoted'`.
            at_word_start = !ch.is_numeric() && !(is_apostrophe(ch) && after_letter);
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
    /// See [`ActivateApp::request_id`].
    #[serde(default, rename = "requestId", skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
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
    /// Reveal the desktop (hide/minimize everything in front of it).
    ShowDesktop,
}

// ---------------------------------------------------------------------------
// App screen mirror (receiver ↔ iPhone) — kinds 0x1A–0x1F
// ---------------------------------------------------------------------------

/// Where the receiver is in serving a screen-mirror request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScreenStatus {
    /// A window is being streamed.
    Ok,
    /// The OS has not granted screen-recording permission.
    PermissionDenied,
    /// The frontmost app currently has no capturable window.
    NoWindow,
}

/// iPhone → receiver: control the screen mirror (kind `0x1D`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenControl {
    pub command: ScreenControlCommand,
    /// Pin a specific window (by `WindowInfo.id`); nil = follow frontmost app.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_id: Option<String>,
    /// The phone's preferred long-edge pixel cap (iPad 2560 / iPhone 1920).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_pixel: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ScreenControlCommand {
    Start,
    Stop,
    Select,
    /// Resume following the frontmost app (clear a pin).
    Follow,
    /// Extend the desktop with a virtual display and stream it.
    Extend,
}

/// iPhone → receiver: one direct-manipulation input (kind `0x1E`).
///
/// `u`/`v` are normalized `0...1` inside the mirrored window's content; the
/// phone computes them from its own zoom/pan state, so the receiver never
/// learns the phone's gesture state. `dx`/`dy` are normalized deltas for
/// `.scroll`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenInput {
    pub action: ScreenInputAction,
    #[serde(default)]
    pub u: f32,
    #[serde(default)]
    pub v: f32,
    #[serde(default)]
    pub dx: f32,
    #[serde(default)]
    pub dy: f32,
    #[serde(default)]
    pub modifiers: u8,
    /// 1 = single click, 2 = double (word), 3 = triple (paragraph).
    #[serde(default = "default_click_count")]
    pub click_count: i64,
    #[serde(default)]
    pub timestamp_micros: u64,
}

fn default_click_count() -> i64 {
    1
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScreenInputAction {
    /// Tap = absolute left click.
    Click,
    /// Begin an absolute left drag.
    DragStart,
    /// Continue the drag at a new `(u, v)`.
    DragMove,
    /// Release the left button.
    DragEnd,
    /// Two-finger tap / long press.
    RightClick,
    /// Two-finger drag at the view's pan boundary.
    Scroll,
}

/// Receiver → iPhone: the current mirror target + geometry (kind `0x1F`).
///
/// `origin_x/y` + `width/height` are the window's frame in screen points,
/// needed to translate the normalized `(u, v)` back to a global cursor
/// position. `pixel_width/height` is the encoded frame size.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenInfo {
    pub status: ScreenStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default)]
    pub origin_x: f64,
    #[serde(default)]
    pub origin_y: f64,
    #[serde(default)]
    pub width: f64,
    #[serde(default)]
    pub height: f64,
    #[serde(default)]
    pub pixel_width: i64,
    #[serde(default)]
    pub pixel_height: i64,
    #[serde(default = "default_shows_cursor")]
    pub shows_cursor: bool,
}

fn default_shows_cursor() -> bool {
    true
}

// ---------------------------------------------------------------------------
// Installed-app launcher (receiver ↔ iPhone) — kinds 0x20 / 0x21
// ---------------------------------------------------------------------------

/// Receiver → iPhone: one launch-able application the receiver can open on
/// demand. `id` is exactly what `SystemCommandKind::LaunchApp` expects as its
/// `argument` (bundle id on the Mac, `.lnk` path on Windows).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct InstalledApp {
    pub id: String,
    pub name: String,
    /// PNG of the app's icon (base64), so the iPhone's launcher can render
    /// a Dock-style grid of real icons. Absent when the receiver has none.
    ///
    /// Explicit `rename`: Swift's property is `iconPNG` (see the same note on
    /// `AppInfo::icon_png`).
    #[serde(
        rename = "iconPNG",
        default,
        skip_serializing_if = "Option::is_none",
        with = "base64_serde::opt"
    )]
    pub icon_png: Option<Vec<u8>>,
}

/// Receiver → iPhone: the launch-able app list (kind `0x21`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledApps {
    pub apps: Vec<InstalledApp>,
}

/// iPhone → receiver: ask for the installed-app list (kind `0x20`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct InstalledAppsRequest {}

#[cfg(test)]
mod capitalize_tests {
    use super::capitalize_words;

    /// These are the cases where the two receivers used to disagree, and a
    /// selection rewritten on the Mac and re-applied on Windows came out
    /// different for no visible reason.
    #[test]
    fn punctuation_starts_a_new_word_like_foundation_does() {
        assert_eq!(capitalize_words("hello-world"), "Hello-World");
        assert_eq!(capitalize_words("hello world"), "Hello World");
        assert_eq!(capitalize_words("a.b.c"), "A.B.C");
        assert_eq!(
            capitalize_words("it's here"),
            "It's Here",
            "a contraction is one word"
        );
        assert_eq!(
            capitalize_words("\u{2019}quoted"),
            "\u{2019}Quoted",
            "a leading apostrophe starts one"
        );
    }

    /// A digit continues the word, so `3d` stays `3d` — which is what the Mac
    /// does, and therefore what this must do.
    #[test]
    fn digits_continue_the_word() {
        assert_eq!(capitalize_words("3d model"), "3d Model");
        assert_eq!(capitalize_words("v2 release"), "V2 Release");
    }

    #[test]
    fn case_within_a_word_is_normalised() {
        assert_eq!(capitalize_words("hELLO wORLD"), "Hello World");
    }

    #[test]
    fn an_empty_selection_stays_empty() {
        assert_eq!(capitalize_words(""), "");
        assert_eq!(
            capitalize_words("   "),
            "   ",
            "whitespace is preserved verbatim"
        );
    }

    /// Non-ASCII letters count as letters, so a Chinese-adjacent or accented
    /// word does not get a capital applied to its first *punctuation*.
    #[test]
    fn non_ascii_letters_are_alphabetic() {
        assert_eq!(capitalize_words("élan-vital"), "Élan-Vital");
    }
}

/// receiver → iPhone: a relayed desktop notification (kind `0x22`).
///
/// Field-for-field the same as the Mac's `IBNotification`, because the phone
/// decodes one struct for both. `windowTitle` is optional on purpose: it needs
/// screen-recording permission to read, and a build that omits it must still
/// decode rather than fail the whole frame.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Notification {
    /// The sending app's **localized display name** — the only identity the
    /// platform exposes. Not a bundle id, not a path.
    pub app: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub subtitle: String,
    #[serde(default)]
    pub body: String,
    /// The notifying app's front window title, when it could be read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
}

/// receiver → iPhone: the outcome of a command the phone asked for (kind `0x23`).
///
/// Both receivers send this — the Mac for `launchApp` / `quitApp` /
/// `showDesktop`, Windows from the same three sites — and a receiver that stayed
/// silent made those buttons **do nothing visibly**, which the user reads as a
/// broken app rather than as a missing reply. (This doc used to say Windows did
/// not send it; the comment outlived the code.)
///
/// `request_id` is echoed back so the phone can match the answer to the button
/// that asked. `detail` is already localised on the sender where possible, so it
/// is passed through rather than re-worded here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandResult {
    pub request_id: String,
    pub status: CommandStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CommandStatus {
    Ok,
    /// The target app is no longer running.
    AppNotRunning,
    /// The permission the receiver needs is missing — on Windows, an
    /// integrity-level problem or a UAC prompt the user declined.
    NoPermission,
    /// The app is running but that window does not exist.
    NoWindow,
    Failed,
}

impl CommandStatus {
    /// Whether the command worked, for the case where the caller only needs a
    /// boolean.
    pub fn is_ok(&self) -> bool {
        matches!(self, CommandStatus::Ok)
    }

    /// The wire name, for a log line or a diagnostic.
    ///
    /// `Display` rather than leaving every caller to write `{:?}`: a status a
    /// user might have to read should not print as `AppNotRunning` in one place
    /// and `appNotRunning` in another.
    pub fn as_wire_name(&self) -> &'static str {
        match self {
            CommandStatus::Ok => "ok",
            CommandStatus::AppNotRunning => "appNotRunning",
            CommandStatus::NoPermission => "noPermission",
            CommandStatus::NoWindow => "noWindow",
            CommandStatus::Failed => "failed",
        }
    }
}

impl std::fmt::Display for CommandStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_wire_name())
    }
}

#[cfg(test)]
mod command_result_tests {
    use super::{ActivateApp, CommandResult, CommandStatus, QuitApp, SystemCommand};

    /// The wire values are the phone's contract, so they are asserted as
    /// literals rather than as `Debug` output.
    #[test]
    fn the_status_strings_match_the_phones() {
        for (json, expected) in [
            (r#""ok""#, CommandStatus::Ok),
            (r#""appNotRunning""#, CommandStatus::AppNotRunning),
            (r#""noPermission""#, CommandStatus::NoPermission),
            (r#""noWindow""#, CommandStatus::NoWindow),
            (r#""failed""#, CommandStatus::Failed),
        ] {
            let parsed: CommandStatus = serde_json::from_str(json).expect("parse");
            assert_eq!(parsed, expected, "{json}");
        }
    }

    /// A newer phone could send a status this build has never heard of. It must
    /// decode as *something* rather than failing the frame, or one unknown
    /// status would cost the user the reply entirely.
    #[test]
    fn an_unknown_status_is_rejected_rather_than_guessed() {
        // Serde's default is to refuse, which is the right failure here: a
        // guessed status could turn "no permission" into "ok".
        let parsed: Result<CommandStatus, _> = serde_json::from_str(r#""somethingNew""#);
        assert!(parsed.is_err());
    }

    #[test]
    fn detail_is_optional() {
        let result: CommandResult =
            serde_json::from_str(r#"{"requestId":"a1","status":"ok"}"#).expect("parse");
        assert_eq!(result.detail, None);
        assert!(result.status.is_ok());
    }

    /// The field is `requestId` on the wire. A `request_id` key decodes to nil
    /// and the reply cannot be matched to the button that asked for it.
    #[test]
    fn the_wire_key_is_camel_case() {
        let result: CommandResult =
            serde_json::from_str(r#"{"requestId":"a1","status":"failed"}"#).expect("parse");
        assert_eq!(result.request_id, "a1");
    }

    /// The *request* half of the same contract. The receiver can only answer a
    /// command if it can see the id, and the phone sends it under exactly this
    /// key (see `IBActivateApp.requestId`). An id that silently decodes to nil
    /// means the answer is never sent — which is the bug this exists to fix,
    /// wearing a different hat.
    #[test]
    fn a_command_request_carries_its_request_id() {
        let a: ActivateApp =
            serde_json::from_str(r#"{"id":"a.b","windowTitle":null,"requestId":"r1"}"#)
                .expect("parse ActivateApp");
        assert_eq!(a.request_id.as_deref(), Some("r1"));

        let q: QuitApp = serde_json::from_str(r#"{"id":"a.b","force":false,"requestId":"r2"}"#)
            .expect("parse QuitApp");
        assert_eq!(q.request_id.as_deref(), Some("r2"));

        let s: SystemCommand = serde_json::from_str(r#"{"command":"showDesktop","requestId":"r3"}"#)
            .expect("parse SystemCommand");
        assert_eq!(s.request_id.as_deref(), Some("r3"));
    }

    /// A phone that predates `commandResult` omits it, and that must not fail
    /// the frame — the command still has to run, just unacknowledged.
    #[test]
    fn a_command_without_a_request_id_still_parses() {
        let a: ActivateApp = serde_json::from_str(r#"{"id":"a.b"}"#).expect("parse");
        assert_eq!(a.request_id, None);

        let q: QuitApp = serde_json::from_str(r#"{"id":"a.b"}"#).expect("parse");
        assert_eq!(q.request_id, None);

        let s: SystemCommand = serde_json::from_str(r#"{"command":"volumeUp"}"#).expect("parse");
        assert_eq!(s.request_id, None);
    }
}
