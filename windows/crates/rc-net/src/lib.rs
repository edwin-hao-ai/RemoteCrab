//! `rc-net` — the receiver-side session.
//!
//! Owns discovery, the TCP connection, the `clientHello`/`sessionReply`
//! handshake, the ping/RTT loop, reconnection and pairing-token persistence.
//! It mirrors the Mac receiver's `ReceiverSession` state machine so the UI
//! can show the exact same status vocabulary.
//!
//! It is intentionally decoupled from the OS and the GUI: it emits
//! [`Event`]s (video NALs, touch/key events, feature state, …) and accepts
//! [`Command`]s. The app layer decides what to do with them.

pub mod dispatch;
pub mod firstrun;
pub mod notify;
pub mod update_gate;
pub mod ping;
pub mod route;
mod supervisor;
pub mod token;

use std::path::PathBuf;
use std::time::Duration;

use rc_discovery::DiscoveredPhone;
use rc_protocol::{
    ActivateApp, Feature, FeatureStateSnapshot, NalFrame, Parser, QuitApp, ScreenControl,
    ScreenInput, StreamMetadata, TouchEvent,
};
use tokio::sync::{broadcast, mpsc, watch};

use token::default_token_path;

/// mDNS service type (matches the iOS advertiser exactly).
pub const SERVICE_TYPE: &str = "_remotecrab._tcp.local.";
pub const DEFAULT_PORT: u16 = rc_discovery::DEFAULT_PORT;

pub(crate) const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(6);
pub(crate) const PING_INTERVAL: Duration = Duration::from_secs(2);
pub(crate) const PONG_TIMEOUT: Duration = Duration::from_secs(8);
pub(crate) const DIRECT_DIAL_TIMEOUT: Duration = Duration::from_secs(8);
pub(crate) const RECONNECT_DELAY: Duration = Duration::from_secs(3);
/// Slower than the normal reconnect — we're waiting for a human on another
/// computer to disconnect, so retrying hard would just be noise.
pub(crate) const BUSY_RETRY_DELAY: Duration = Duration::from_secs(10);
pub(crate) const FALLBACK_TICK: Duration = Duration::from_secs(5);
/// How often to try to (re)start mDNS after it failed. Discovery is the
/// primary path, so it is worth retrying even though the direct-IP fallbacks
/// keep the product usable meanwhile.
pub(crate) const DISCOVERY_RETRY: Duration = Duration::from_secs(10);

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Connection state — same vocabulary as the Mac's `ReceiverSession.State`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum State {
    Searching,
    Connecting {
        name: String,
    },
    Handshaking {
        name: String,
    },
    AwaitingApproval {
        name: String,
    },
    /// Another computer owns the iPhone. We keep retrying automatically.
    Busy {
        owner: String,
    },
    Streaming {
        name: String,
        latency_ms: i64,
    },
    Error(String),
}

impl State {
    /// The status-pill label (mirrors `IBStatusPill.Status.label`).
    pub fn pill_label(&self) -> &'static str {
        match self {
            State::Searching => "LOOKING",
            State::Connecting { .. }
            | State::Handshaking { .. }
            | State::AwaitingApproval { .. } => "CONNECTING",
            State::Busy { .. } => "IN USE",
            State::Streaming { .. } => "LIVE",
            State::Error(_) => "OFFLINE",
        }
    }

    /// Latency to show next to the pill, when streaming with a known RTT.
    pub fn pill_latency_ms(&self) -> Option<i64> {
        match self {
            State::Streaming { latency_ms, .. } if *latency_ms > 0 => Some(*latency_ms),
            _ => None,
        }
    }

    /// The phone name carried by in-flight / live states, if any.
    pub fn phone_name(&self) -> Option<&str> {
        match self {
            State::Connecting { name }
            | State::Handshaking { name }
            | State::AwaitingApproval { name }
            | State::Streaming { name, .. } => Some(name),
            State::Searching | State::Busy { .. } | State::Error(_) => None,
        }
    }
}

/// Everything the app layer reacts to.
#[derive(Debug, Clone)]
pub enum Event {
    State(State),
    Discovered(Vec<DiscoveredPhone>),
    Metadata(StreamMetadata),
    Video(NalFrame),
    Audio(rc_protocol::AudioPacket),
    Touch(TouchEvent),
    Key(rc_protocol::KeyEvent),
    FeatureState(FeatureStateSnapshot),
    AppList(rc_protocol::AppList),
    WindowList(rc_protocol::WindowList),
    /// The iPhone asked for a fresh app list — the app layer answers with a
    /// `send_frame(encode_app_list(...))`.
    AppListRequested,
    WindowListRequested,
    /// The iPhone opened the launcher sheet — the app layer answers with
    /// `send_frame(encode_installed_apps(...))`.
    InstalledAppsRequested,
    FileOffer(rc_protocol::FileOffer),
    FileChunk(Vec<u8>),
    FileComplete(rc_protocol::FileComplete),
    Clipboard(rc_protocol::Clipboard),
    TextCommand(rc_protocol::TextCommandMessage),
    SystemCommand(rc_protocol::SystemCommand),
    /// The iPhone's app switcher wants an app brought to the front (kind
    /// `0x0E`). The app layer resolves the `pid:` id and calls
    /// `rc_os::apps::activate_id`.
    ActivateApp(ActivateApp),
    /// The iPhone asked for an app to quit (kind `0x16`).
    QuitApp(QuitApp),
    /// The iPhone started/stopped/pinned the app-window mirror (kind `0x1D`).
    ScreenControl(ScreenControl),
    /// One direct-manipulation input inside the mirrored window (kind `0x1E`).
    ScreenInput(ScreenInput),
    Latency(i64),
    /// A desktop notification to relay to the phone (kind `0x22`).
    ///
    /// Only produced when the user has turned the relay on — it is off by
    /// default, because forwarding the contents of every notification to
    /// another device is not a feature, it is a surprise with a network stack.
    Notification(rc_protocol::Notification),
}

#[derive(Debug, Clone)]
pub struct Config {
    pub app_version: String,
    pub service_type: String,
    pub default_port: u16,
    pub token_path: Option<PathBuf>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            app_version: env!("CARGO_PKG_VERSION").to_string(),
            service_type: SERVICE_TYPE.to_string(),
            default_port: DEFAULT_PORT,
            token_path: default_token_path(),
        }
    }
}

/// Handle to a running session. Cheap to clone via `Arc`, but the inner
/// channels are cheap too, so plain methods borrow `&self`.
#[derive(Clone)]
pub struct Session {
    cmd_tx: mpsc::UnboundedSender<Command>,
    events_tx: broadcast::Sender<Event>,
    state_rx: watch::Receiver<State>,
    health_rx: watch::Receiver<Health>,
}

impl Session {
    /// Start the session (spawns the supervisor task). Must be called from
    /// within a Tokio runtime.
    pub fn spawn(config: Config) -> Session {
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let (events_tx, _) = broadcast::channel(1024);
        let (state_tx, state_rx) = watch::channel(State::Searching);
        let (health_tx, health_rx) = watch::channel(Health::default());

        tokio::spawn(supervisor::supervisor(
            config,
            cmd_rx,
            events_tx.clone(),
            state_tx,
            health_tx,
        ));

        Session {
            cmd_tx,
            events_tx,
            state_rx,
            health_rx,
        }
    }

    /// What the receiver currently knows and has already tried. Cheap: no
    /// sockets, no browse, no timers — safe to call from a UI thread.
    pub fn health(&self) -> watch::Receiver<Health> {
        self.health_rx.clone()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events_tx.subscribe()
    }

    pub fn state(&self) -> watch::Receiver<State> {
        self.state_rx.clone()
    }

    pub fn connect_to(&self, id: &str) {
        let _ = self.cmd_tx.send(Command::Connect { id: id.to_string() });
    }

    pub fn connect_manual(&self, host: &str, port: u16) {
        let _ = self.cmd_tx.send(Command::ConnectManual {
            host: host.to_string(),
            port,
        });
    }

    pub fn disconnect(&self) {
        let _ = self.cmd_tx.send(Command::Disconnect);
    }

    pub fn retry_now(&self) {
        let _ = self.cmd_tx.send(Command::Retry);
    }

    pub fn set_feature(&self, feature: Feature, enabled: bool) {
        let _ = self.cmd_tx.send(Command::SetFeature { feature, enabled });
    }

    pub fn switch_camera(&self) {
        let _ = self.cmd_tx.send(Command::SwitchCamera);
    }

    /// Send a raw pre-encoded frame to the iPhone (used for replies such as
    /// `fileAck` / `clipboard` / `appList` that only the app can build).
    pub fn send_frame(&self, frame: Vec<u8>) {
        let _ = self.cmd_tx.send(Command::SendFrame(frame));
    }
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub(crate) enum Command {
    Connect { id: String },
    ConnectManual { host: String, port: u16 },
    Disconnect,
    Retry,
    SetFeature { feature: Feature, enabled: bool },
    SwitchCamera,
    SendFrame(Vec<u8>),
}

#[derive(Debug)]
pub(crate) enum ConnMsg {
    /// Emitted once the handshake is accepted, so the supervisor can persist
    /// the working endpoint AND the token the iPhone issued.
    ///
    /// The token is not optional in practice on a healthy pairing: the phone
    /// sends it with every `accepted` reply, and it is the only thing that
    /// stops the iPhone asking the user to approve this computer again on the
    /// next connect. It is `Option` because a `Pending` → `Denied` path (and
    /// legacy phones) may never hand one over.
    Accepted {
        host: String,
        port: u16,
        /// The phone's `sessionReply` token, if it issued one.
        token: Option<String>,
        /// The token key this connection resolved to, captured at spawn time
        /// so it can never disagree with the token it travels with.
        key: String,
    },
    End(ConnEndKind),
}

#[derive(Debug)]
pub(crate) enum ConnEndKind {
    /// Socket closed / errored — reconnect is allowed.
    Lost,
    /// Handshake never got a `sessionReply` — reconnect is allowed.
    HandshakeTimeout,
    /// Another computer owns the iPhone. Not fatal: we keep retrying so the
    /// moment it frees up we take over, and the UI shows who holds it.
    Busy { owner: String },
    /// The iPhone explicitly denied us — stop until a manual Retry.
    Denied,
}

#[derive(Debug, Clone)]
pub(crate) enum Target {
    Phone(DiscoveredPhone),
    Manual {
        host: String,
        port: u16,
        name: String,
    },
}

impl Target {
    fn name(&self) -> String {
        match self {
            Target::Phone(p) => p.name.clone(),
            Target::Manual { name, .. } => name.clone(),
        }
    }

    fn host_port(&self) -> Option<(String, u16)> {
        match self {
            Target::Phone(p) => p.host.clone().map(|h| (h, p.port)),
            Target::Manual { host, port, .. } => Some((host.clone(), *port)),
        }
    }

    /// The address we dial, when it is known. `None` while mDNS is still
    /// resolving.
    fn ip(&self) -> Option<&str> {
        match self {
            Target::Phone(p) => p.host.as_deref(),
            Target::Manual { host, .. } => Some(host.as_str()),
        }
    }

    /// The *provisional* token key: the mDNS instance name, or
    /// `iPhone (<ip>)` on a direct dial.
    ///
    /// It is provisional because the same device answers to two different
    /// names depending on how we reached it. Resolve it through
    /// [`TokenStore::resolve_key`] before reading or writing a token — and
    /// prefer `Target::Phone`'s instance name when present, since it is the
    /// only one the user ever sees.
    fn token_key(&self) -> String {
        self.name()
    }
}

pub(crate) fn set_state(
    state_tx: &watch::Sender<State>,
    events_tx: &broadcast::Sender<Event>,
    s: State,
) {
    let _ = state_tx.send(s.clone());
    emit(events_tx, Event::State(s));
}

/// A cheap, I/O-free snapshot of what the receiver knows and has tried.
///
/// This is the raw material for the "why isn't it connecting?" panel, so it
/// must never block: everything in here is a copy of state the supervisor is
/// already tracking, and the expensive probes (a 6 s mDNS browse, a TCP
/// connect) are the caller's job, run only when the user actually asks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Health {
    pub state: State,
    /// User-visible names of the phones mDNS has resolved this session.
    pub discovered: Vec<String>,
    /// `host:port` of the last endpoint that completed a handshake.
    pub last_endpoint: Option<String>,
    /// How many `/24` sweeps in a row have found nothing on our LAN.
    pub fallback_misses: u32,
    /// False once a browse has failed or its channel closed.
    pub mdns_alive: bool,
}

impl Default for Health {
    fn default() -> Self {
        Health {
            state: State::Searching,
            discovered: Vec::new(),
            last_endpoint: None,
            fallback_misses: 0,
            mdns_alive: false,
        }
    }
}

pub(crate) fn set_health(health_tx: &watch::Sender<Health>, h: Health) {
    let _ = health_tx.send(h);
}

pub(crate) fn emit(events_tx: &broadcast::Sender<Event>, e: Event) {
    let _ = events_tx.send(e);
}
