//! The connect / retry policy: what to dial, when to give up, and what
//! to do when a link drops.
//!
//! Split out of `lib.rs`, which keeps the session *API* (`Session`,
//! `State`, `Config`). The supervisor owns no state of its own beyond the
//! connection it is currently running 鈥?every decision is driven by the
//! `State` it publishes, which is what makes the state machine in
//! `lib.rs` the single description of what the app is doing.

use std::collections::VecDeque;
use std::time::Duration;

use rc_discovery::{DiscoveredPhone, DiscoveryEvent};
use rc_protocol::{
    decode_session_reply, encode_camera_command, encode_client_hello, encode_feature_control,
    encode_ping, ClientHello, FeatureControl, FeatureStateSnapshot, Frame, Kind, Parser,
    SessionReplyResult,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{broadcast, mpsc, watch};

use super::dispatch::{dispatch_frame, next_frame};
use super::{emit, set_state};
use super::token::TokenStore;
use super::{
    Command, Config, ConnEndKind, ConnMsg, Event, State, Target, BUSY_RETRY_DELAY,
    DIRECT_DIAL_TIMEOUT, FALLBACK_TICK, HANDSHAKE_TIMEOUT, PING_INTERVAL, PONG_TIMEOUT,
    RECONNECT_DELAY,
};

pub(crate) struct ActiveConn {
    outbound_tx: mpsc::UnboundedSender<Vec<u8>>,
}

enum Action {
    Cmd(Command),
    Conn(ConnMsg),
    Discovery(DiscoveryEvent),
    FallbackTick,
    Reconnect,
}

pub(crate) async fn supervisor(
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
pub(crate) fn maybe_autoconnect(
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
pub(crate) fn start_connection(
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
pub(crate) async fn run_connection(
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
    // Distinguishes "the phone hung up" from "a reply arrived but would not
    // decode" — collapsing both into one message sends you hunting for a
    // backgrounded app when the real cause is wire drift.
    let mut reply_failed_to_decode = false;
    let reply = tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
        loop {
            match next_frame(&mut read_half, &mut parser, &mut queue, &mut buf).await {
                Some(f) if f.kind == Kind::SessionReply => {
                    match decode_session_reply(&f) {
                        Ok(reply) => break Some(reply),
                        Err(e) => {
                            eprintln!(
                                "[net] sessionReply arrived but would not decode ({e}) — \
                                 this build and the iOS app disagree on the wire format"
                            );
                            reply_failed_to_decode = true;
                            break None;
                        }
                    }
                }
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
        Ok(None) if reply_failed_to_decode => return ConnEndKind::Lost,
        Ok(None) => {
            // Not a "backgrounded app" story: the iOS app only calls
            // `startListener()` from `startStreaming()` (CaptureEngine.swift),
            // so the port is not bound at all until the user presses Start
            // on the phone — and it stays bound after that via `applyKeepAlive`.
            eprintln!(
                "[net] the iPhone closed the connection before answering — usually the \
                 RemoteCrab app has not been started on the phone (Start binds port 8765)"
            );
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



pub(crate) fn now_micros() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0)
}

