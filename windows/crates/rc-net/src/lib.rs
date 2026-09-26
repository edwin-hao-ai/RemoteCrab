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

pub mod token;

use std::collections::VecDeque;
use std::path::PathBuf;
use std::time::Duration;

use rc_discovery::{DiscoveredPhone, DiscoveryEvent};
use rc_protocol::{
    decode_activate_app, decode_audio, decode_clipboard, decode_feature_state, decode_file_complete,
    decode_file_offer, decode_key, decode_metadata, decode_quit_app, decode_screen_control,
    decode_screen_input, decode_session_reply, decode_system_command, decode_text_command,
    decode_touch, encode_client_hello, encode_feature_control, encode_ping, encode_camera_command,
    ActivateApp, ClientHello, Feature, FeatureControl, FeatureStateSnapshot, Frame, Kind, NalFrame,
    NalKind, Parser, QuitApp, ScreenControl, ScreenInput, SessionReplyResult, StreamMetadata,
    TouchEvent,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{broadcast, mpsc, watch};

use token::{TokenStore, default_token_path};

/// mDNS service type (matches the iOS advertiser exactly).
pub const SERVICE_TYPE: &str = "_remotecrab._tcp.local.";
pub const DEFAULT_PORT: u16 = rc_discovery::DEFAULT_PORT;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(6);
const PING_INTERVAL: Duration = Duration::from_secs(2);
const PONG_TIMEOUT: Duration = Duration::from_secs(8);
const DIRECT_DIAL_TIMEOUT: Duration = Duration::from_secs(8);
const RECONNECT_DELAY: Duration = Duration::from_secs(3);
/// Slower than the normal reconnect — we're waiting for a human on another
/// computer to disconnect, so retrying hard would just be noise.
const BUSY_RETRY_DELAY: Duration = Duration::from_secs(10);
const FALLBACK_TICK: Duration = Duration::from_secs(5);

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Connection state — same vocabulary as the Mac's `ReceiverSession.State`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum State {
    Searching,
    Connecting { name: String },
    Handshaking { name: String },
    AwaitingApproval { name: String },
    /// Another computer owns the iPhone. We keep retrying automatically.
    Busy { owner: String },
    Streaming { name: String, latency_ms: i64 },
    Error(String),
}

impl State {
    /// The status-pill label (mirrors `IBStatusPill.Status.label`).
    pub fn pill_label(&self) -> &'static str {
        match self {
            State::Searching => "LOOKING",
            State::Connecting { .. } | State::Handshaking { .. } | State::AwaitingApproval { .. } => {
                "CONNECTING"
            }
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
}

impl Session {
    /// Start the session (spawns the supervisor task). Must be called from
    /// within a Tokio runtime.
    pub fn spawn(config: Config) -> Session {
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let (events_tx, _) = broadcast::channel(1024);
        let (state_tx, state_rx) = watch::channel(State::Searching);

        tokio::spawn(supervisor(
            config,
            cmd_rx,
            events_tx.clone(),
            state_tx,
        ));

        Session {
            cmd_tx,
            events_tx,
            state_rx,
        }
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
enum Command {
    Connect { id: String },
    ConnectManual { host: String, port: u16 },
    Disconnect,
    Retry,
    SetFeature { feature: Feature, enabled: bool },
    SwitchCamera,
    SendFrame(Vec<u8>),
}

#[derive(Debug)]
enum ConnMsg {
    /// Emitted once the handshake is accepted, so the supervisor can
    /// remember the working address for the direct-IP fast path.
    Connected { host: String },
    End(ConnEndKind),
}

#[derive(Debug)]
enum ConnEndKind {
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
enum Target {
    Phone(DiscoveredPhone),
    Manual { host: String, port: u16, name: String },
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

    fn token_key(&self) -> String {
        self.name()
    }
}

struct ActiveConn {
    outbound_tx: mpsc::UnboundedSender<Vec<u8>>,
}

enum Action {
    Cmd(Command),
    Conn(ConnMsg),
    Discovery(DiscoveryEvent),
    FallbackTick,
    Reconnect,
}

async fn supervisor(
    config: Config,
    mut cmd_rx: mpsc::UnboundedReceiver<Command>,
    events_tx: broadcast::Sender<Event>,
    state_tx: watch::Sender<State>,
) {
    let mut tokens = TokenStore::load(config.token_path.clone());
    let mut discovered: Vec<DiscoveredPhone> = Vec::new();
    let mut discovery_rx = rc_discovery::browse(&config.service_type).ok();
    let mut discovery_active = discovery_rx.is_some();

    // Recreated per connection; a keepalive sender prevents `recv()` from
    // returning `None` (which would busy-loop the select).
    let (_boot_tx, mut conn_rx) = mpsc::unbounded_channel::<ConnMsg>();
    let mut conn_keepalive: Option<mpsc::UnboundedSender<ConnMsg>> = None;

    let mut active: Option<ActiveConn> = None;
    let mut target: Option<Target> = None;
    let mut suppress_auto = false;
    let mut reconnect_at: Option<tokio::time::Instant> = None;

    let mut tick = tokio::time::interval(FALLBACK_TICK);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    // Mirror of the last `featureState` snapshot, so `SwitchCamera` can
    // derive the next position. Fed from the broadcast the connection task
    // publishes to.
    let mut feature_state: Option<FeatureStateSnapshot> = None;
    let mut events_for_mirror = events_tx.subscribe();

    loop {
        let mut action: Option<Action> = None;

        tokio::select! {
            cmd = cmd_rx.recv() => {
                action = cmd.map(Action::Cmd);
            }
            ev = events_for_mirror.recv() => {
                if let Ok(Event::FeatureState(s)) = ev {
                    feature_state = Some(s);
                }
                continue;
            }
            msg = conn_rx.recv() => {
                action = msg.map(Action::Conn);
            }
            ev = discovery_rx.as_mut().unwrap().recv(), if discovery_active => {
                match ev {
                    Some(e) => action = Some(Action::Discovery(e)),
                    None => discovery_active = false,
                }
            }
            _ = tick.tick() => {
                action = Some(Action::FallbackTick);
            }
            _ = tokio::time::sleep_until(reconnect_at.unwrap_or_else(tokio::time::Instant::now)), if reconnect_at.is_some() => {
                action = Some(Action::Reconnect);
            }
        }

        let Some(action) = action else { continue };

        match action {
            Action::Cmd(Command::Connect { id }) => {
                if let Some(phone) = discovered.iter().find(|p| p.id == id).cloned() {
                    suppress_auto = false;
                    reconnect_at = None;
                    start_connection(
                        &config,
                        &mut tokens,
                        &events_tx,
                        &state_tx,
                        &mut active,
                        &mut conn_rx,
                        &mut conn_keepalive,
                        Target::Phone(phone),
                    );
                }
            }
            Action::Cmd(Command::ConnectManual { host, port }) => {
                suppress_auto = false;
                reconnect_at = None;
                let name = format!("iPhone ({host})");
                start_connection(
                    &config,
                    &mut tokens,
                    &events_tx,
                    &state_tx,
                    &mut active,
                    &mut conn_rx,
                    &mut conn_keepalive,
                    Target::Manual { host, port, name },
                );
            }
            Action::Cmd(Command::Disconnect) => {
                active = None; // drops outbound_tx → the conn task ends
                target = None;
                suppress_auto = true;
                reconnect_at = None;
                set_state(&state_tx, &events_tx, State::Searching);
            }
            Action::Cmd(Command::Retry) => {
                suppress_auto = false;
                reconnect_at = None;
                if let Some(t) = target.clone() {
                    start_connection(
                        &config,
                        &mut tokens,
                        &events_tx,
                        &state_tx,
                        &mut active,
                        &mut conn_rx,
                        &mut conn_keepalive,
                        t,
                    );
                }
            }
            Action::Cmd(Command::SetFeature { feature, enabled }) => {
                if let Some(conn) = &active {
                    if let Ok(frame) = encode_feature_control(&FeatureControl { feature, enabled })
                    {
                        let _ = conn.outbound_tx.send(frame);
                    }
                }
            }
            Action::Cmd(Command::SwitchCamera) => {
                if let Some(conn) = &active {
                    let next = feature_state
                        .as_ref()
                        .map(|s| s.camera_position.toggled())
                        .unwrap_or(rc_protocol::CameraPosition::Front);
                    if let Ok(frame) =
                        encode_camera_command(&rc_protocol::CameraCommand { position: next })
                    {
                        let _ = conn.outbound_tx.send(frame);
                    }
                }
            }
            Action::Cmd(Command::SendFrame(frame)) => {
                if let Some(conn) = &active {
                    let _ = conn.outbound_tx.send(frame);
                }
            }
            Action::Conn(ConnMsg::Connected { host }) => {
                tokens.set_last_phone_host(&host);
            }
            Action::Conn(ConnMsg::End(kind)) => {
                active = None;
                match kind {
                    ConnEndKind::Lost | ConnEndKind::HandshakeTimeout => {
                        if !suppress_auto {
                            reconnect_at = Some(tokio::time::Instant::now() + RECONNECT_DELAY);
                        }
                    }
                    ConnEndKind::Busy { owner } => {
                        // Not fatal — another computer is using the iPhone.
                        // Keep retrying (the iPhone releases the session the
                        // moment that computer disconnects), and tell the
                        // user exactly who holds it.
                        if !suppress_auto {
                            reconnect_at =
                                Some(tokio::time::Instant::now() + BUSY_RETRY_DELAY);
                        }
                        set_state(
                            &state_tx,
                            &events_tx,
                            State::Busy { owner },
                        );
                    }
                    ConnEndKind::Denied => {
                        suppress_auto = true;
                        reconnect_at = None;
                        set_state(
                            &state_tx,
                            &events_tx,
                            State::Error("The iPhone denied the connection".to_string()),
                        );
                    }
                }
            }
            Action::Discovery(DiscoveryEvent::Found(phone)) => {
                if !discovered.iter().any(|p| p.id == phone.id) {
                    discovered.push(phone);
                }
                emit(&events_tx, Event::Discovered(discovered.clone()));
                maybe_autoconnect(
                    &config,
                    &mut tokens,
                    &events_tx,
                    &state_tx,
                    &mut active,
                    &mut conn_rx,
                    &mut conn_keepalive,
                    &mut target,
                    &discovered,
                    suppress_auto,
                    reconnect_at,
                );
            }
            Action::Discovery(DiscoveryEvent::Lost(id)) => {
                discovered.retain(|p| p.id != id);
                emit(&events_tx, Event::Discovered(discovered.clone()));
            }
            Action::Reconnect => {
                reconnect_at = None;
                if let Some(t) = target.clone() {
                    start_connection(
                        &config,
                        &mut tokens,
                        &events_tx,
                        &state_tx,
                        &mut active,
                        &mut conn_rx,
                        &mut conn_keepalive,
                        t,
                    );
                }
            }
            Action::FallbackTick => {
                if active.is_none() && !suppress_auto && discovered.is_empty() {
                    // Direct-IP fallback, in order of cost:
                    //   1. the last address we successfully connected to
                    //   2. the iPhone-hotspot gateway (172.20.10.1)
                    //   3. a /24 sweep of our own subnet for anything on 8765
                    // (3) is what makes this work on guest WiFi / mesh APs
                    // where mDNS multicast is silently dropped. It cannot
                    // defeat true AP isolation — nothing can.
                    let mut candidates: Vec<String> = Vec::new();
                    if let Some(h) = tokens.last_phone_host() {
                        candidates.push(h);
                    }
                    candidates.push(rc_discovery::HOTSPOT_GATEWAY.to_string());

                    let mut hit: Option<String> = None;
                    for host in &candidates {
                        if rc_discovery::probe_tcp(
                            host,
                            config.default_port,
                            Duration::from_millis(2500),
                        )
                        .await
                        {
                            hit = Some(host.clone());
                            break;
                        }
                    }

                    if hit.is_none() {
                        for ip in rc_discovery::local_ipv4_addresses() {
                            let found = rc_discovery::scan_subnet_for_port(
                                &ip,
                                config.default_port,
                                Duration::from_millis(250),
                                128,
                            )
                            .await;
                            if let Some(host) = found.into_iter().next() {
                                hit = Some(host);
                                break;
                            }
                        }
                    }

                    if let Some(host) = hit {
                        target = Some(Target::Manual {
                            host: host.clone(),
                            port: config.default_port,
                            name: format!("iPhone ({host})"),
                        });
                        start_connection(
                            &config,
                            &mut tokens,
                            &events_tx,
                            &state_tx,
                            &mut active,
                            &mut conn_rx,
                            &mut conn_keepalive,
                            target.clone().unwrap(),
                        );
                    }
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn maybe_autoconnect(
    config: &Config,
    tokens: &mut TokenStore,
    events_tx: &broadcast::Sender<Event>,
    state_tx: &watch::Sender<State>,
    active: &mut Option<ActiveConn>,
    conn_rx: &mut mpsc::UnboundedReceiver<ConnMsg>,
    conn_keepalive: &mut Option<mpsc::UnboundedSender<ConnMsg>>,
    target: &mut Option<Target>,
    discovered: &[DiscoveredPhone],
    suppress_auto: bool,
    reconnect_at: Option<tokio::time::Instant>,
) {
    if active.is_some() || suppress_auto || reconnect_at.is_some() || target.is_some() {
        return;
    }
    // Prefer a paired phone; otherwise dial the first discovered one — the
    // iPhone gates access itself (accepted/pending/busy).
    let chosen = discovered
        .iter()
        .find(|p| tokens.token_for(&p.name).is_some())
        .or_else(|| discovered.first())
        .cloned();
    if let Some(phone) = chosen {
        start_connection(
            config,
            tokens,
            events_tx,
            state_tx,
            active,
            conn_rx,
            conn_keepalive,
            Target::Phone(phone),
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn start_connection(
    config: &Config,
    tokens: &mut TokenStore,
    events_tx: &broadcast::Sender<Event>,
    state_tx: &watch::Sender<State>,
    active: &mut Option<ActiveConn>,
    conn_rx: &mut mpsc::UnboundedReceiver<ConnMsg>,
    conn_keepalive: &mut Option<mpsc::UnboundedSender<ConnMsg>>,
    target: Target,
) {
    let name = target.name();
    set_state(state_tx, events_tx, State::Connecting { name: name.clone() });

    let (msg_tx, msg_rx) = mpsc::unbounded_channel::<ConnMsg>();
    *conn_rx = msg_rx;
    *conn_keepalive = Some(msg_tx.clone());

    let (out_tx, out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    *active = Some(ActiveConn { outbound_tx: out_tx });

    let token = tokens.token_for(&target.token_key());
    let pc_id = tokens.pc_id().to_string();
    let pc_name = tokens.pc_name().to_string();
    let config = config.clone();
    let events_tx = events_tx.clone();
    let state_tx = state_tx.clone();

    tokio::spawn(async move {
        let kind = run_connection(
            config, target, token, pc_id, pc_name, out_rx, &events_tx, &state_tx, &msg_tx,
        )
        .await;
        let _ = msg_tx.send(ConnMsg::End(kind));
    });
}

#[allow(clippy::too_many_arguments)]
async fn run_connection(
    config: Config,
    target: Target,
    token: Option<String>,
    pc_id: String,
    pc_name: String,
    mut outbound_rx: mpsc::UnboundedReceiver<Vec<u8>>,
    events_tx: &broadcast::Sender<Event>,
    state_tx: &watch::Sender<State>,
    msg_tx: &mpsc::UnboundedSender<ConnMsg>,
) -> ConnEndKind {
    let name = target.name();
    let Some((host, port)) = target.host_port() else {
        // No resolved address yet (mDNS still resolving) — retry shortly.
        return ConnEndKind::Lost;
    };

    // --- TCP connect (with the direct-dial timeout) ---------------------
    let stream = match tokio::time::timeout(
        DIRECT_DIAL_TIMEOUT,
        TcpStream::connect((host.as_str(), port)),
    )
    .await
    {
        Ok(Ok(s)) => s,
        _ => return ConnEndKind::Lost,
    };
    let (mut read_half, mut write_half) = stream.into_split();

    // --- Handshake: clientHello → sessionReply --------------------------
    set_state(state_tx, events_tx, State::Handshaking { name: name.clone() });

    let hello = ClientHello {
        name: pc_name,
        id: pc_id,
        token,
        app_version: config.app_version.clone(),
        platform: Some("windows".to_string()),
    };
    let Ok(frame) = encode_client_hello(&hello) else {
        return ConnEndKind::Lost;
    };
    if write_half.write_all(&frame).await.is_err() {
        return ConnEndKind::Lost;
    }

    let mut parser = Parser::new();
    let mut queue: VecDeque<Frame> = VecDeque::new();
    let mut buf = vec![0u8; 64 * 1024];

    // Frames that arrive interleaved with the handshake (e.g. the iPhone's
    // first `metadata` / `featureState`) must be dispatched, not dropped.
    eprintln!("[net] TCP connected to {host}:{port}, sending clientHello…");
    let reply = tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
        loop {
            match next_frame(&mut read_half, &mut parser, &mut queue, &mut buf).await {
                Some(f) if f.kind == Kind::SessionReply => break decode_session_reply(&f).ok(),
                Some(f) => {
                    eprintln!("[net] pre-handshake frame: {:?} ({} bytes)", f.kind, f.payload.len());
                    dispatch_frame(&f, events_tx);
                }
                None => break None,
            }
        }
    })
    .await;

    let reply = match reply {
        Ok(Some(r)) => r,
        Ok(None) => {
            eprintln!("[net] connection closed before sessionReply");
            return ConnEndKind::Lost;
        }
        Err(_) => {
            eprintln!("[net] no sessionReply within {HANDSHAKE_TIMEOUT:?} — the iPhone app may be waiting for you to tap Allow, or it's not the RemoteCrab iOS app");
            return ConnEndKind::HandshakeTimeout;
        }
    };
    eprintln!("[net] sessionReply: {:?}", reply.result);

    // The token the iPhone issued (when accepted) is persisted by the
    // supervisor via the `FeatureState`/`Metadata` path; we only need to
    // know the handshake succeeded here.
    let _accepted_token = match reply.result {
        SessionReplyResult::Accepted => reply.token,
        SessionReplyResult::Pending => {
            // The iPhone shows an approval card; when approved it sends a
            // second `sessionReply accepted` on the same socket. No timeout.
            set_state(
                state_tx,
                events_tx,
                State::AwaitingApproval { name: name.clone() },
            );
            let pending = tokio::time::timeout(Duration::from_secs(120), async {
                loop {
                    match next_frame(&mut read_half, &mut parser, &mut queue, &mut buf).await {
                        Some(f) if f.kind == Kind::SessionReply => {
                            break decode_session_reply(&f).ok()
                        }
                        Some(f) => dispatch_frame(&f, events_tx),
                        None => break None,
                    }
                }
            })
            .await;
            match pending {
                Ok(Some(r)) if r.result == SessionReplyResult::Accepted => r.token,
                Ok(Some(r)) if r.result == SessionReplyResult::Denied => {
                    return ConnEndKind::Denied;
                }
                Ok(Some(r)) if r.result == SessionReplyResult::Busy => {
                    return ConnEndKind::Busy {
                        owner: r
                            .owner_name
                            .unwrap_or_else(|| "another computer".to_string()),
                    };
                }
                _ => return ConnEndKind::Lost,
            }
        }
        SessionReplyResult::Busy => {
            let owner = reply
                .owner_name
                .unwrap_or_else(|| "another computer".to_string());
            return ConnEndKind::Busy { owner };
        }
        SessionReplyResult::Denied => {
            return ConnEndKind::Denied;
        }
    };

    // --- Streaming ------------------------------------------------------
    // Remember the address that worked, so the next launch can dial it
    // directly even if mDNS stays silent.
    let _ = msg_tx.send(ConnMsg::Connected { host: host.clone() });
    set_state(
        state_tx,
        events_tx,
        State::Streaming {
            name: name.clone(),
            latency_ms: 0,
        },
    );

    // Any frames already buffered from the handshake read (the iPhone
    // typically packs `metadata` + `featureState` right behind the
    // `sessionReply`) must be dispatched before we wait on new bytes.
    while let Some(f) = queue.pop_front() {
        dispatch_frame(&f, events_tx);
    }

    let mut ping = tokio::time::interval(PING_INTERVAL);
    ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    ping.tick().await; // consume the immediate first tick

    let mut last_pong = tokio::time::Instant::now();
    let mut last_latency: i64 = 0;

    loop {
        tokio::select! {
            read = read_half.read(&mut buf) => {
                match read {
                    Ok(0) | Err(_) => return ConnEndKind::Lost,
                    Ok(n) => {
                        for f in parser.append(&buf[..n]) {
                            if f.kind == Kind::Ping {
                                let sent = rc_protocol::decode_ping(&f);
                                let now_micros = now_micros();
                                let rtt = (now_micros.saturating_sub(sent) / 1000) as i64;
                                last_latency = rtt;
                                last_pong = tokio::time::Instant::now();
                                emit(events_tx, Event::Latency(rtt));
                                set_state(state_tx, events_tx, State::Streaming { name: name.clone(), latency_ms: rtt });
                            } else {
                                dispatch_frame(&f, events_tx);
                            }
                        }
                    }
                }
            }
            out = outbound_rx.recv() => {
                match out {
                    Some(frame) => {
                        if write_half.write_all(&frame).await.is_err() {
                            return ConnEndKind::Lost;
                        }
                    }
                    None => return ConnEndKind::Lost, // supervisor dropped us
                }
            }
            _ = ping.tick() => {
                if last_pong.elapsed() > PONG_TIMEOUT {
                    return ConnEndKind::Lost;
                }
                let frame = encode_ping(now_micros());
                if write_half.write_all(&frame).await.is_err() {
                    return ConnEndKind::Lost;
                }
                let _ = last_latency;
            }
        }
    }
}

async fn next_frame(
    read_half: &mut tokio::net::tcp::OwnedReadHalf,
    parser: &mut Parser,
    queue: &mut VecDeque<Frame>,
    buf: &mut [u8],
) -> Option<Frame> {
    loop {
        if let Some(f) = queue.pop_front() {
            return Some(f);
        }
        let n = read_half.read(buf).await.ok()?;
        if n == 0 {
            return None;
        }
        for f in parser.append(&buf[..n]) {
            queue.push_back(f);
        }
    }
}

fn dispatch_frame(frame: &Frame, events_tx: &broadcast::Sender<Event>) {
    match frame.kind {
        Kind::Metadata => {
            if let Ok(m) = decode_metadata(frame) {
                emit(events_tx, Event::Metadata(m));
            }
        }
        // App-window mirror: the iPhone drives it with `screenControl` /
        // `screenInput` (kinds 0x1D/0x1E); the receiver answers with
        // `screenSps`/`screenPps`/`screenVideo`/`screenInfo` (0x1A–0x1C/0x1F)
        // via `send_frame`. The video kinds are decoded here.
        Kind::ScreenControl => {
            if let Ok(c) = decode_screen_control(frame) {
                emit(events_tx, Event::ScreenControl(c));
            }
        }
        Kind::ScreenInput => {
            if let Ok(i) = decode_screen_input(frame) {
                emit(events_tx, Event::ScreenInput(i));
            }
        }
        k if k.is_screen_mirror() => {}
        Kind::Video | Kind::Sps | Kind::Pps => {
            let kind = match frame.kind {
                Kind::Sps => NalKind::Sps,
                Kind::Pps => NalKind::Pps,
                _ => NalKind::Video,
            };
            emit(
                events_tx,
                Event::Video(NalFrame {
                    kind,
                    data: frame.payload.clone(),
                    timestamp_micros: 0,
                }),
            );
        }
        Kind::Touch => {
            if let Ok(t) = decode_touch(frame) {
                emit(events_tx, Event::Touch(t));
            }
        }
        Kind::Key => {
            if let Ok(k) = decode_key(frame) {
                emit(events_tx, Event::Key(k));
            }
        }
        Kind::Audio => {
            if let Ok(a) = decode_audio(frame) {
                emit(events_tx, Event::Audio(a));
            }
        }
        Kind::FeatureState => {
            if let Ok(s) = decode_feature_state(frame) {
                emit(events_tx, Event::FeatureState(s));
            }
        }
        Kind::ClipboardSet => {
            if let Ok(c) = decode_clipboard(frame) {
                emit(events_tx, Event::Clipboard(c));
            }
        }
        Kind::TextCommand => {
            if let Ok(c) = decode_text_command(frame) {
                emit(events_tx, Event::TextCommand(c));
            }
        }
        Kind::SystemCommand => {
            if let Ok(c) = decode_system_command(frame) {
                emit(events_tx, Event::SystemCommand(c));
            }
        }
        Kind::ActivateApp => {
            if let Ok(a) = decode_activate_app(frame) {
                emit(events_tx, Event::ActivateApp(a));
            }
        }
        Kind::QuitApp => {
            if let Ok(q) = decode_quit_app(frame) {
                emit(events_tx, Event::QuitApp(q));
            }
        }
        Kind::AppListRequest => {
            // The iPhone wants a fresh app list; the app layer answers.
            emit(events_tx, Event::AppListRequested);
        }
        Kind::WindowListRequest => {
            emit(events_tx, Event::WindowListRequested);
        }
        Kind::InstalledAppsRequest => {
            emit(events_tx, Event::InstalledAppsRequested);
        }
        Kind::AppList => {
            if let Ok(list) = rc_protocol::decode_app_list(frame) {
                emit(events_tx, Event::AppList(list));
            }
        }
        Kind::WindowList => {
            if let Ok(list) = rc_protocol::decode_window_list(frame) {
                emit(events_tx, Event::WindowList(list));
            }
        }
        Kind::FileOffer => {
            if let Ok(o) = decode_file_offer(frame) {
                emit(events_tx, Event::FileOffer(o));
            }
        }
        Kind::FileChunk => emit(events_tx, Event::FileChunk(frame.payload.clone())),
        Kind::FileComplete => {
            if let Ok(c) = decode_file_complete(frame) {
                emit(events_tx, Event::FileComplete(c));
            }
        }
        _ => {}
    }
}

fn set_state(state_tx: &watch::Sender<State>, events_tx: &broadcast::Sender<Event>, s: State) {
    let _ = state_tx.send(s.clone());
    emit(events_tx, Event::State(s));
}

fn emit(events_tx: &broadcast::Sender<Event>, e: Event) {
    let _ = events_tx.send(e);
}

fn now_micros() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0)
}


#[cfg(test)]
mod dispatch_tests {
    //! Regression: `activateApp` (0x0E) and `quitApp` (0x16) used to fall
    //! through `dispatch_frame`'s catch-all, so the iPhone's app switcher
    //! silently did nothing on Windows.
    use super::*;
    use rc_protocol::{encode_activate_app, encode_quit_app, ActivateApp, QuitApp};

    fn parse_one(bytes: Vec<u8>) -> Frame {
        let mut parser = Parser::new();
        let mut frames = parser.append(&bytes);
        assert_eq!(frames.len(), 1, "expected exactly one frame");
        frames.remove(0)
    }

    #[test]
    fn activate_app_is_dispatched_not_dropped() {
        let bytes = encode_activate_app(&ActivateApp {
            id: "pid:42".to_string(),
            window_title: None,
        })
        .unwrap();
        let (tx, mut rx) = broadcast::channel(16);
        dispatch_frame(&parse_one(bytes), &tx);
        match rx.try_recv() {
            Ok(Event::ActivateApp(a)) => assert_eq!(a.id, "pid:42"),
            other => panic!("expected ActivateApp, got {other:?}"),
        }
    }

    #[test]
    fn quit_app_is_dispatched_not_dropped() {
        let bytes = encode_quit_app(&QuitApp {
            id: "pid:7".to_string(),
            force: true,
        })
        .unwrap();
        let (tx, mut rx) = broadcast::channel(16);
        dispatch_frame(&parse_one(bytes), &tx);
        match rx.try_recv() {
            Ok(Event::QuitApp(q)) => {
                assert_eq!(q.id, "pid:7");
                assert!(q.force);
            }
            other => panic!("expected QuitApp, got {other:?}"),
        }
    }
}
#[cfg(test)]
mod screen_dispatch_tests {
    //! `screenControl`/`screenInput` used to fall through the mirror
    //! catch-all, so the iPhone's mirror did nothing on Windows.
    use super::*;
    use rc_protocol::{
        encode_screen_control, encode_screen_input, ScreenControlCommand, ScreenInputAction,
    };

    fn parse_one(bytes: Vec<u8>) -> Frame {
        let mut parser = Parser::new();
        let mut frames = parser.append(&bytes);
        assert_eq!(frames.len(), 1);
        frames.remove(0)
    }

    #[test]
    fn screen_control_and_input_are_dispatched() {
        let control = ScreenControl {
            command: ScreenControlCommand::Select,
            window_id: Some("42:7".to_string()),
            max_pixel: Some(1920),
        };
        let input = ScreenInput {
            action: ScreenInputAction::DragMove,
            u: 0.5,
            v: 0.25,
            dx: -0.1,
            dy: 0.1,
            modifiers: 8,
            click_count: 2,
            timestamp_micros: 99,
        };
        let (tx, mut rx) = broadcast::channel(16);
        dispatch_frame(&parse_one(encode_screen_control(&control).unwrap()), &tx);
        dispatch_frame(&parse_one(encode_screen_input(&input).unwrap()), &tx);
        match rx.try_recv() {
            Ok(Event::ScreenControl(c)) => assert_eq!(c, control),
            other => panic!("expected ScreenControl, got {other:?}"),
        }
        match rx.try_recv() {
            Ok(Event::ScreenInput(i)) => assert_eq!(i, input),
            other => panic!("expected ScreenInput, got {other:?}"),
        }
    }
}
