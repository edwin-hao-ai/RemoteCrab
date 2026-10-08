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
    decode_session_reply, encode_camera_command, encode_client_hello, encode_client_proof,
    encode_feature_control, encode_ping, ClientHello, ClientProof, FeatureControl,
    FeatureStateSnapshot, Frame, Kind, Parser, SessionReply, SessionReplyResult, StreamMetadata,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{broadcast, mpsc, watch};

use super::dispatch::{dispatch_frame, next_frame};
use super::ping::PingProbe;
use super::token::TokenStore;
use super::{emit, set_health, set_state, Health};
use super::{
    Command, Config, ConnEndKind, ConnMsg, Event, State, Target, DIRECT_DIAL_TIMEOUT,
    DISCOVERY_RETRY, FALLBACK_TICK, HANDSHAKE_TIMEOUT, PING_INTERVAL, PONG_TIMEOUT,
    RECONNECT_DELAY, STANDBY_RETRY_DELAY,
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
    health_tx: watch::Sender<Health>,
) {
    let mut tokens = TokenStore::load(config.token_path.clone());
    let mut discovered: Vec<DiscoveredPhone> = Vec::new();
    // A browse that fails to start used to be swallowed with `.ok()`, which
    // left mDNS dead for the whole process lifetime with nothing in the log —
    // the receiver simply never found anything again and looked like a network
    // fault. Report it, and keep trying: the usual causes (the daemon losing
    // its socket, an adapter appearing) clear on their own.
    let (mut discovery_rx, browse_error) = match rc_discovery::browse(&config.service_type) {
        Ok(rx) => (Some(rx), None),
        Err(e) => (None, Some(e.to_string())),
    };
    let mut discovery_active = discovery_rx.is_some();
    if let Some(e) = &browse_error {
        eprintln!(
            "[net] mDNS browse could not start ({e}) — discovery is off for now, \
             retrying every {}s; direct-IP fallback is unaffected",
            DISCOVERY_RETRY.as_secs()
        );
    }
    let mut next_discovery_retry: Option<tokio::time::Instant> = if discovery_active {
        None
    } else {
        Some(tokio::time::Instant::now() + DISCOVERY_RETRY)
    };

    // Recreated per connection; a keepalive sender prevents `recv()` from
    // returning `None` (which would busy-loop the select).
    let (_boot_tx, mut conn_rx) = mpsc::unbounded_channel::<ConnMsg>();
    let mut conn_keepalive: Option<mpsc::UnboundedSender<ConnMsg>> = None;

    let mut active: Option<ActiveConn> = None;
    let mut target: Option<Target> = None;
    let mut suppress_auto = false;
    // Set by `Command::Disconnect` and cleared by the next attempt. Dropping
    // the connection task is what produces the `ConnMsg::End(Lost)` below, so
    // without this the state machine rewrites the user's explicit disconnect
    // as a dropped connection (see the `End(Lost)` arm).
    let mut explicit_disconnect = false;
    let mut reconnect_at: Option<tokio::time::Instant> = None;
    // `/24` sweep pacing — see `sweep_interval`.
    let mut last_sweep_at: Option<tokio::time::Instant> = None;
    let mut sweep_misses: u32 = 0;
    // `host:port` of the last endpoint that completed a handshake. Shown in
    // the "why isn't this connecting" panel so the user can check the phone
    // by hand if they want to, without the product ever offering them an
    // address box.
    let mut last_endpoint: Option<String> = None;
    // The target that just failed, and how many times in a row it has.
    //
    // A single failure must NOT clear the target: `Action::Reconnect` re-dials
    // from it, so clearing on the first failure silently disables reconnection
    // and only the fallback can rescue the session. What has to end the retries
    // is the *second* consecutive failure of the same address — at that point
    // the address is not going to work, and the fallbacks must be allowed to
    // rotate to a different one.
    let mut failed_target: Option<Target> = None;
    // Whether the connection currently being driven ever reached `Streaming`.
    //
    // A `Cell`, because the handshake runs in an inner loop that also owns the
    // `set_state(Streaming)` call, and the `Lost` branch that needs to read this
    // is in the outer loop. Sharing one cell is clearer than threading a `&mut`
    // through two nested loops that already borrow half the supervisor.
    //
    // It exists because "the connection was lost" and "could not reach the
    // iPhone" are different problems with different fixes, and the current state
    // cannot tell them apart: `active` is already cleared by the time the `Lost`
    // branch runs.
    let ever_streamed = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    if let Some(h) = tokens.last_phone_host() {
        let port = tokens.last_phone_port().unwrap_or(config.default_port);
        last_endpoint = Some(format!("{h}:{port}"));
    }

    let mut tick = tokio::time::interval(FALLBACK_TICK);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    // Mirror of the last `featureState` snapshot, so `SwitchCamera` can
    // derive the next position. Fed from the broadcast the connection task
    // publishes to.
    let mut feature_state: Option<FeatureStateSnapshot> = None;
    // The phone's self-reported device name, learned from `metadata`. Kept
    // because the token and the name arrive on different channels in an
    // arbitrary order, and each needs to be able to finish the other's work.
    let mut learned_name: Option<String> = None;
    let mut events_for_mirror = events_tx.subscribe();

    loop {
        // Republish what we already know, before blocking again, so the
        // "why isn't this connecting?" panel can answer from memory instead of
        // probing the network (a browse would take 6 s and freeze the menu).
        set_health(
            &health_tx,
            Health {
                state: state_tx.borrow().clone(),
                discovered: discovered.iter().map(|p| p.name.clone()).collect(),
                last_endpoint: last_endpoint.clone(),
                fallback_misses: sweep_misses,
                mdns_alive: discovery_active,
            },
        );

        let mut action: Option<Action> = None;

        tokio::select! {
            cmd = cmd_rx.recv() => {
                action = cmd.map(Action::Cmd);
            }
            ev = events_for_mirror.recv() => {
                match ev {
                    Ok(Event::FeatureState(s)) => feature_state = Some(s),
                    // The phone tells us its own name in `metadata`. That is
                    // the stable identity for its pairing token, so move the
                    // token onto it and remember the address → name mapping.
                    // Without this, the same device is keyed twice — once by
                    // mDNS instance name, once by IP — and whichever path we
                    // did not use has no token, so the phone asks for approval
                    // all over again.
                    Ok(Event::Metadata(md)) => {
                        learn_phone_identity(&mut tokens, &mut learned_name, target.as_ref(), &md);
                    }
                    // Everything else is the app layer's business, and this
                    // subscription exists only for the two events above.
                    Ok(_) => {}
                    Err(_) => continue,
                }
                continue;
            }
            msg = conn_rx.recv() => {
                action = msg.map(Action::Conn);
            }
            // `pending()` rather than `.unwrap()`: the two variables are kept in
            // step today, so the unwrap cannot fire — but it is an unwrap inside a
            // `select!` arm, where a panic is an abort of the whole supervisor, and
            // the condition it would be reporting (browsing active with no
            // receiver) is not worth that. A never-ready future parks the arm
            // instead of either panicking or spinning on a channel that is gone.
            ev = async {
                match discovery_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            }, if discovery_active => {
                match ev {
                    Some(e) => action = Some(Action::Discovery(e)),
                    // The daemon closed the channel. Same treatment as a
                    // failure to start: notice it, and rebuild.
                    None => {
                        eprintln!("[net] mDNS browse channel closed — restarting it");
                        discovery_active = false;
                        discovery_rx = None;
                        next_discovery_retry =
                            Some(tokio::time::Instant::now() + DISCOVERY_RETRY);
                    }
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
                    explicit_disconnect = false;
                    reconnect_at = None;
                    start_connection(
                        &config,
                        &mut tokens,
                        &events_tx,
                        &state_tx,
                        &mut active,
                        &mut conn_rx,
                        &mut conn_keepalive,
                        &mut target,
                        Target::Phone(phone),
                    );
                }
            }
            Action::Cmd(Command::ConnectManual { host, port }) => {
                suppress_auto = false;
                explicit_disconnect = false;
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
                    &mut target,
                    Target::Manual { host, port, name },
                );
            }
            Action::Cmd(Command::Disconnect) => {
                active = None; // drops outbound_tx → the conn task ends
                target = None;
                suppress_auto = true;
                explicit_disconnect = true;
                reconnect_at = None;
                set_state(&state_tx, &events_tx, State::Searching);
            }
            Action::Cmd(Command::Retry) => {
                suppress_auto = false;
                explicit_disconnect = false;
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
                        &mut target,
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
            Action::Cmd(Command::ForgetPhone(name)) => {
                // Both halves, in one place and one save. Forgetting only the
                // token would leave the address→name mapping behind, and that is
                // how a *re-paired* phone inherits the old phone's identity: the
                // map still says "192.168.1.5 is Dana's iPhone", so the next
                // handshake rekeys the new token onto the old name.
                tokens.forget(&name);
                tokens.forget_addresses_for(&name);
            }
            Action::Cmd(Command::SendFrame(frame)) => {
                if let Some(conn) = &active {
                    let _ = conn.outbound_tx.send(frame);
                }
            }
            Action::Conn(ConnMsg::Accepted {
                host,
                port,
                token,
                key,
}) => {
                  tokens.remember_endpoint(&host, port);
                  last_endpoint = Some(format!("{host}:{port}"));
                  // The handshake completed, so this connection *did* stream.
                  // `ConnMsg::End` arrives with no such news, and by then the
                  // state has been cleared — so this is the only place the
                  // supervisor can learn "it dropped" as opposed to "it never
                  // answered". Those need different words and different user
                  // actions, and one message for both is how you end up telling
                  // someone to check their WiFi when the phone was never there.
                  ever_streamed.store(true, std::sync::atomic::Ordering::Relaxed);
                if let Some(token) = token {
                    if !key.is_empty() && !token.is_empty() {
                        tokens.set_token(&key, &token);
                        // `metadata` may have been processed before this
                        // message (different channel, `select!` order), in
                        // which case the rekey above had no token to move yet.
                        settle_token_key(&mut tokens, &learned_name, &key);
                    }
                }
            }
            Action::Conn(ConnMsg::End(kind)) => {
                active = None;
                // Read before clearing: this branch needs to know whether the
                // connection that just ended had reached `Streaming`.
                let reason = if ever_streamed.load(std::sync::atomic::Ordering::Relaxed) {
                    "The connection was lost"
                } else {
                    "Could not reach the iPhone"
                };
                ever_streamed.store(false, std::sync::atomic::Ordering::Relaxed);
                match kind {
                    ConnEndKind::Lost | ConnEndKind::HandshakeTimeout => {
                        // First failure of this address: keep it, so the
                        // reconnect loop re-dials it. Most drops are a WiFi
                        // blip and the same address is correct.
                        //
                        // Second consecutive failure: the address is not going
                        // to work, so release it and let the fallbacks rotate
                        // to a different candidate. Without this the receiver
                        // hammers one dead address every 3 s forever — the exit
                        // from that deadlock.
                        // Compare the *address*, not the struct: a
                        // re-resolved mDNS record for the same phone is the
                        // same thing to re-dial, and comparing the whole target
                        // would call it a different address and rotate away
                        // from a phone that is merely being re-announced.
                        if failed_target.as_ref().and_then(Target::host_port)
                            == target.as_ref().and_then(Target::host_port)
                        {
                            target = None;
                        }
                        failed_target = target.clone().or(failed_target);
// The session is over, so whatever the state said a moment ago is
                        // now false. `Streaming` is a claim rather than a
                        // description, and leaving it there means the tray says
                        // "streaming" forever: no error, nothing to act on.
                        //
                        // The retry below may be about to overwrite this with
                        // `Connecting`, which is fine and honest; but there are
                        // paths where it cannot — the target was just cleared,
                        // and with `--connect` there is no discovery to find
                        // another one. `rc-phone-sim --scenario drop` reproduces
                        // exactly that.
                        //
                        // The one End that must NOT become an error is the one
                        // an explicit `Disconnect` produced by dropping the task:
                        // the user asked to stop, and telling them the link was
                        // lost is a lie. Keep the `Searching` the command set.
                        if explicit_disconnect {
                            explicit_disconnect = false;
                        } else {
                            set_state(&state_tx, &events_tx, State::Error(reason.to_string()));
                        }
                        if !suppress_auto {
                            reconnect_at = Some(tokio::time::Instant::now() + RECONNECT_DELAY);
                        }
                    }
                    ConnEndKind::Busy { owner } => {
                        // Not fatal — the phone is set to serve another
                        // computer. Stand by: the fast loop stops and only a
                        // 60 s safety net remains, so we neither fight for the
                        // session nor spam it. A knock still dials at once.
                        if !suppress_auto {
                            reconnect_at = Some(tokio::time::Instant::now() + STANDBY_RETRY_DELAY);
                        }
                        set_state(&state_tx, &events_tx, State::Busy { owner });
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
                    ConnEndKind::Impersonated => {
                        // Stops for good rather than retrying: whatever answered
                        // will answer again, and a reconnect loop against an
                        // impostor is the receiver being used as a hammer.
                        suppress_auto = true;
                        reconnect_at = None;
                        set_state(
                            &state_tx,
                            &events_tx,
                            State::Error("Could not verify the iPhone".to_string()),
                        );
                    }
                    ConnEndKind::Off => {
                        // Deliberately **not** `suppress_auto`: re-picking this
                        // computer on the phone (or a knock) brings it back by
                        // itself. Same 60 s standby as `busy`.
                        if !suppress_auto {
                            reconnect_at = Some(tokio::time::Instant::now() + STANDBY_RETRY_DELAY);
                        }
                        set_state(
                            &state_tx,
                            &events_tx,
                            State::Error("The iPhone disconnected this computer".to_string()),
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
                        &mut target,
                        t,
                    );
                }
            }
            Action::FallbackTick => {
                // Discovery first: it is the primary path, and it is the one
                // that can be *restored*. Everything below is a fallback for
                // when it is unavailable.
                if !discovery_active
                    && next_discovery_retry.is_none_or(|t| t <= tokio::time::Instant::now())
                {
                    next_discovery_retry = Some(tokio::time::Instant::now() + DISCOVERY_RETRY);
                    match rc_discovery::browse(&config.service_type) {
                        Ok(rx) => {
                            eprintln!("[net] mDNS browse running again");
                            discovery_rx = Some(rx);
                            discovery_active = true;
                        }
                        Err(e) => eprintln!("[net] mDNS still unavailable: {e}"),
                    }
                }
                if fallback_allowed(active.is_some(), suppress_auto, target.is_some()) {
                    // Direct-IP fallback, in order of cost:
                    //   1. the last address we successfully connected to
                    //   2. the iPhone-hotspot gateway (172.20.10.1)
                    //   3. a /24 sweep of our own subnet for anything on 8765
                    // (3) is what makes this work on guest WiFi / mesh APs
                    // where mDNS multicast is silently dropped. It cannot
                    // defeat true AP isolation — nothing can.
                    let port = tokens.last_phone_port().unwrap_or(config.default_port);
                    let mut candidates: Vec<String> = Vec::new();
                    if let Some(h) = tokens.last_phone_host() {
                        if rc_discovery::is_usable_dial_address(&h) {
                            candidates.push(h);
                        } else {
                            // Written before the check existed. Drop it from
                            // the running too, so one bad file heals instead of
                            // being re-dialed until the user clears it by hand.
                            eprintln!("[net] ignoring the stored address {h} — not a LAN address");
                        }
                    }
                    // The hotspot gateway is a dial target only when we are a
                    // client of the hotspot ourselves. From any other network it
                    // is an unrelated address, and probing it every tick is what
                    // put `正在连接 iPhone (172.20.10.1)` in the log on a machine
                    // whose phone was on 192.168.31.x the whole time.
                    if rc_discovery::on_iphone_hotspot() {
                        candidates.push(rc_discovery::HOTSPOT_GATEWAY.to_string());
                    }

                    let mut hit: Option<String> = None;
                    for host in &candidates {
                        if rc_discovery::probe_tcp(host, port, Duration::from_millis(2500)).await {
                            hit = Some(host.clone());
                            break;
                        }
                    }

                    if hit.is_none() {
                        // 254 connects per sweep, so it is rate-limited and
                        // backs off while the LAN stays empty.
                        let elapsed = last_sweep_at
                            .map(|t| t.elapsed())
                            .unwrap_or(Duration::from_secs(u64::MAX / 2));
                        if elapsed >= sweep_interval(sweep_misses) {
                            last_sweep_at = Some(tokio::time::Instant::now());
                            for ip in sweep_targets(&rc_discovery::local_ipv4_addresses()) {
                                let found = rc_discovery::scan_subnet_for_port(
                                    &ip,
                                    port,
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
                    }
                    sweep_misses = if hit.is_some() { 0 } else { sweep_misses + 1 };

                    if let Some(host) = hit {
                        start_connection(
                            &config,
                            &mut tokens,
                            &events_tx,
                            &state_tx,
                            &mut active,
                            &mut conn_rx,
                            &mut conn_keepalive,
                            &mut target,
                            Target::Manual {
                                host: host.clone(),
                                port,
                                name: format!("iPhone ({host})"),
                            },
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
            target,
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
    current: &mut Option<Target>,
    next: Target,
) {
    // Record what we are working on BEFORE spawning the task. This assignment
    // used to be missing on every path except the subnet sweep, so
    // `Action::Reconnect` found `None` and did nothing: a link drop on a
    // phone we reached by mDNS (or by hand) never reconnected, and the
    // fallbacks were gated off by the stale `discovered` list. Doing it here,
    // in the one function that starts a connection, makes it impossible to
    // forget again.
    *current = Some(next.clone());

    let name = next.name();
    set_state(
        state_tx,
        events_tx,
        State::Connecting { name: name.clone() },
    );

    let (msg_tx, msg_rx) = mpsc::unbounded_channel::<ConnMsg>();
    *conn_rx = msg_rx;
    *conn_keepalive = Some(msg_tx.clone());

    let (out_tx, out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    *active = Some(ActiveConn {
        outbound_tx: out_tx,
    });

    // Read the token under the *resolved* key: the phone's real name when we
    // have learned it for this address, otherwise the provisional one.
    let token = tokens.token_for(&tokens.resolve_key(&next.token_key(), next.ip()));
    let pc_id = tokens.pc_id().to_string();
    let pc_name = tokens.pc_name().to_string();
    let token_key = tokens.resolve_key(&next.token_key(), next.ip());
    let config = config.clone();
    let events_tx = events_tx.clone();
let state_tx = state_tx.clone();

      tokio::spawn(async move {
        let kind = run_connection(
            config,
            next,
            token,
            token_key,
            pc_id,
            pc_name,
            out_rx,
            &events_tx,
            &state_tx,
&msg_tx,
          )
          .await;
          let _ = msg_tx.send(ConnMsg::End(kind));
    });
}

/// Fold a `metadata` frame into the identity we store.
///
/// Two facts arrive over two different channels — the device name on
/// `Event::Metadata`, the token on `ConnMsg::Accepted` — and `select!` picks
/// whichever is ready, so either can land first. Both sides therefore settle
/// the same key: this records the name and moves the token if it is already
/// there, and [`settle_token_key`] does the mirror image when the token
/// arrives second. Doing it one-way only is a race, and a race here is exactly
/// how a paired device ends up tokenless forever.
fn learn_phone_identity(
    tokens: &mut TokenStore,
    learned: &mut Option<String>,
    target: Option<&Target>,
    md: &StreamMetadata,
) {
    let Some(target) = target else { return };
    let name = md.device_name.trim();
    if name.is_empty() {
        return;
    }
    *learned = Some(name.to_string());
    if let Some(ip) = target.ip() {
        tokens.set_phone_name_for_ip(ip, name);
    }
    tokens.rekey_token(&target.token_key(), name);
}

/// The mirror of [`learn_phone_identity`]: a token just arrived under
/// `provisional`, and we may already know the phone's real name.
fn settle_token_key(tokens: &mut TokenStore, learned: &Option<String>, provisional: &str) {
    let Some(real) = learned else { return };
    tokens.rekey_token(provisional, real);
}

/// Connect to `host:port`, pinned to the physical adapter that shares the
/// phone's subnet when there is one.
///
/// This is the fix for "it connects sometimes": a TUN proxy (Clash / Mihomo /
/// sing-box and most accelerators) takes over the default route, so a dial to a
/// phone **on the same WiFi** is pulled into the tunnel and dropped. From the
/// app that is indistinguishable from the phone being off, which is why users
/// never find the switch. Binding the socket to the interface that actually
/// shares the phone's subnet is the one thing the tunnel cannot intercept.
///
/// Falls back to an ordinary unbound connect whenever we cannot name such an
/// interface — before this existed every dial was unbound, so the fallback is
/// exactly the old behaviour rather than a regression. That covers: a phone on
/// another subnet (the routing table knows better than we do), a hostname that
/// does not resolve, and every non-Windows build.
async fn dial(host: &str, port: u16) -> std::io::Result<TcpStream> {
    match rc_discovery::connect_bound(host, port).await {
        Ok(stream) => Ok(stream),
        Err(e) => {
            // Worth a line: this is the path that exists to work around a
            // tunnel, so a failure here is the one a user would be asked to
            // report.
            eprintln!("[net] could not dial {host}:{port} ({e}) — falling back to the default route");
            TcpStream::connect((host, port)).await
        }
    }
}

/// What the phone's half of the challenge turned out to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Challenge {
    /// It proved itself, and has been answered.
    Proven,
    /// It does not do this at all — an app older than this build.
    NotOffered,
    /// It offered a proof and this receiver has no token to check it against.
    NoKey,
    /// It offered a proof that did not check out.
    Failed,
}

/// Check the phone's half of the challenge and answer it.
///
/// Four outcomes rather than a `bool`, because three of them are not failures and
/// only one is an attack. The words the user sees, and whether the receiver ever
/// dials again, depend on telling them apart.
///
/// `Err(())` is a link problem while answering, which the caller reports as a lost
/// connection rather than as an identity failure: conflating the two would make a
/// WiFi blip read as an impostor.
async fn answer_challenge(
    token: Option<&str>,
    pc_id: &str,
    client_nonce: &str,
    reply: &SessionReply,
    write_half: &mut tokio::net::tcp::OwnedWriteHalf,
) -> Result<Challenge, ()> {
    let (Some(server_nonce), Some(presented)) = (reply.nonce.as_deref(), reply.mac.as_deref())
    else {
        return Ok(Challenge::NotOffered);
    };
    let Some(token) = token else {
        return Ok(Challenge::NoKey);
    };

    let expected = crate::peer_auth::server_mac(token, pc_id, client_nonce, server_nonce);
    if !crate::peer_auth::matches(&expected, presented) {
        return Ok(Challenge::Failed);
    }

    // Ours, under the client label. This is what lets the phone stop showing its
    // approval card for a machine it has already paired with.
    let proof = ClientProof {
        mac: crate::peer_auth::client_mac(token, pc_id, client_nonce, server_nonce),
    };
    let frame = encode_client_proof(&proof).map_err(|_| ())?;
    write_half.write_all(&frame).await.map_err(|_| ())?;
    Ok(Challenge::Proven)
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn run_connection(
    config: Config,
    target: Target,
    token: Option<String>,
    token_key: String,
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
    let stream = match tokio::time::timeout(DIRECT_DIAL_TIMEOUT, dial(host.as_str(), port)).await {
        Ok(Ok(s)) => s,
        _ => return ConnEndKind::Lost,
    };
    let (mut read_half, mut write_half) = stream.into_split();

    // --- Handshake: clientHello → sessionReply --------------------------
    set_state(
        state_tx,
        events_tx,
        State::Handshaking { name: name.clone() },
    );

    // This connection's half of the challenge. New every time, which is what
    // makes a MAC copied from an earlier session useless to a listener.
    let client_nonce = crate::peer_auth::new_nonce();
    // Kept: the hello takes ownership of the token, and the challenge needs it
    // afterwards to check what the phone sends back.
    let stored_token = token.clone();

    let hello = ClientHello {
        name: pc_name,
        // Cloned: the challenge below needs the id after the hello has taken it.
        id: pc_id.clone(),
        token,
        nonce: Some(client_nonce.clone()),
        app_version: config.app_version.clone(),
        platform: Some("windows".to_string()),
        // What this receiver can be relied on for. The phone reads this before
        // it sends a `requestId`, so `commandResult` here is the difference
        // between the launch/quit/desktop buttons reporting success and doing
        // nothing visible. `latencyProbe` because `rc-net::ping` echoes a probe
        // this side did not originate, which is how the phone measures its own
        // round trip.
        capabilities: Some(vec![
            "latencyProbe".to_string(),
            "commandResult".to_string(),
            // What this receiver can do about identity. A phone that can do it
            // too answers with the same word and a MAC; one that cannot is
            // simply never authenticated, which the session state records.
            crate::peer_auth::CAPABILITY.to_string(),
        ]),
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
                Some(f) if f.kind == Kind::SessionReply => match decode_session_reply(&f) {
                    Ok(reply) => break Some(reply),
                    Err(e) => {
                        eprintln!(
                            "[net] sessionReply arrived but would not decode ({e}) — \
                                 this build and the iOS app disagree on the wire format"
                        );
                        reply_failed_to_decode = true;
                        break None;
                    }
                },
                Some(f) => {
                    eprintln!(
                        "[net] pre-handshake frame: {:?} ({} bytes)",
                        f.kind,
                        f.payload.len()
                    );
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

    // --- Identity -------------------------------------------------------
    //
    // Done before the decision below, because a phone that proves itself is
    // admitted *by* the proof, and a phone that fails to is not admitted at all.
    let authenticated = match answer_challenge(
        stored_token.as_deref(),
        &pc_id,
        &client_nonce,
        &reply,
        &mut write_half,
    )
    .await
    {
        Ok(Challenge::Proven) => true,
        Ok(Challenge::NotOffered) => {
            // Deliberately not fatal. The alternative is refusing every phone
            // whose app predates this build, which turns a security improvement
            // into an outage on the day it ships — and the receiver has no way
            // to update the phone. The session is marked unauthenticated
            // instead, and `State::Streaming` carries that to the user.
            eprintln!(
                "[auth] the phone did not offer a proof of identity. Anyone listening on this \
                 network could have answered in its place — updating the iOS app closes this."
            );
            false
        }
        Ok(Challenge::NoKey) => {
            // The phone says it knows us and this machine has nothing to check
            // it against: a pairing that was lost, not an attack. Say which.
            eprintln!(
                "[auth] the phone offered a proof and this receiver has no token for it — \
                 re-pair from the phone to restore a recognised connection"
            );
            false
        }
        Ok(Challenge::Failed) => {
            eprintln!(
                "[auth] REFUSED: something answered on this phone's port that does not hold the \
                 pairing token"
            );
            return ConnEndKind::Impersonated;
        }
        Err(()) => return ConnEndKind::Lost,
    };

    // The token the phone issued when it accepted us. This MUST travel back
    // to the supervisor and be persisted: it is the only thing that makes the
    // next `clientHello` acceptable without a human tapping Allow. It used to
    // be bound to `_accepted_token` and dropped on the floor, so the receiver
    // asked the iPhone for approval on *every* reconnect for the life of the
    // install.
    let accepted_token = match reply.result {
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
        // The phone's user disconnected this computer. Not a refusal — they
        // turned *this* machine off from a list — so it must not wear the denied
        // copy, which reads as something the user did wrong.
        //
        // A slow retry rather than none: the iPhone clears the `off` state as
        // soon as its user picks a computer, so this is what makes re-picking
        // this PC recover without anyone walking to the machine. Matches the
        // Mac receiver; the previous behaviour (stop until a manual Retry, with
        // a `TODO(Windows)` where this comment is) left the phone's own
        // "choose a computer" screen looking broken.
        SessionReplyResult::Off => {
            return ConnEndKind::Off;
        }
    };

    // --- Streaming ------------------------------------------------------
    // Remember the address, port and token that worked, so the next launch
    // can dial it directly (even if mDNS stays silent) and be recognised
    // without another approval prompt.
    let _ = msg_tx.send(ConnMsg::Accepted {
        host: host.clone(),
        port,
        token: accepted_token,
        key: token_key,
    });
    set_state(
        state_tx,
        events_tx,
        State::Streaming {
            name: name.clone(),
            latency_ms: 0,
            authenticated,
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
    // Our own outstanding latency probe, so an inbound ping can be told apart
    // from the phone's. Both ends originate probes now, and `now - sent` across
    // two machines' clocks is the offset between them, not a round trip — see
    // the `ping` module.
    let mut probe = PingProbe::new();

    loop {
        tokio::select! {
            read = read_half.read(&mut buf) => {
                match read {
                    Ok(0) | Err(_) => return ConnEndKind::Lost,
                    Ok(n) => {
                        let before = parser.resyncs();
                        for f in parser.append(&buf[..n]) {
                            if f.kind == Kind::Ping {
                                let sent = rc_protocol::decode_ping(&f);
                                // ANY ping proves the link is alive, so the
                                // pong watchdog is satisfied either way.
                                last_pong = tokio::time::Instant::now();
                                if !probe.is_own_echo(sent) {
                                    // The phone originated this one, so the
                                    // phone is the one waiting to measure.
                                    // Echoing it is what lets its latency
                                    // readout exist at all.
                                    //
                                    // It must NOT fall through to the maths
                                    // below: `now - sent` is the CLOCK OFFSET
                                    // between the two machines, which can be
                                    // hours, and that is what the status line
                                    // used to show. The iOS app started sending
                                    // probes of its own, so before this existed
                                    // every phone-initiated probe was reported
                                    // as a multi-hour "latency".
                                    if write_half.write_all(&encode_ping(sent)).await.is_err() {
                                        return ConnEndKind::Lost;
                                    }
                                } else if let Some(rtt) =
                                    probe.round_trip_ms(sent, now_micros())
                                {
                                    last_latency = rtt;
                                    emit(events_tx, Event::Latency(rtt));
                                    set_state(
                                        state_tx,
                                        events_tx,
                                        State::Streaming {
                                            name: name.clone(),
                                            latency_ms: rtt,
                                            authenticated,
                                        },
                                    );
                                }
                            } else {
                                dispatch_frame(&f, events_tx);
                            }
                        }
                        // Say so when the wire was damaged. A corrupt length
                        // means bytes were lost or reordered in transit, so the
                        // decoder is being handed a stream with a hole in it —
                        // which looks exactly like "the picture froze" and used
                        // to be reported by nothing at all.
                        if parser.resyncs() != before {
                            eprintln!(
                                "[net] wire resynchronised {} time(s) — data was lost or reordered; \
                                 frames already received behind the damage were recovered",
                                parser.resyncs() - before
                            );
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
                let frame = encode_ping(probe.make_probe(now_micros()));
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

// ---------------------------------------------------------------------------
// Fallback policy — pure, so the rules are testable without a network.
//
// The fallbacks exist because mDNS silently fails on some networks (a TUN-mode
// VPN, guest WiFi, AP isolation). The bug this replaces gated them on
// `discovered.is_empty()`, so a single stale Bonjour record disabled the
// direct-IP path *permanently* and the receiver re-dialled one dead address
// until the user intervened. The Mac had already fixed the equivalent
// deadlock (lesson 21(b)); the Windows port shipped with the pre-fix logic.
// ---------------------------------------------------------------------------

/// May the direct-IP fallbacks run on this tick?
///
/// Deliberately **not** "the discovery list is empty". The question is
/// "are we already working on something?", because a phone we are currently
/// dialing is a phone the fallbacks must not second-guess. A discovered
/// record we have given up on is handled separately, by clearing the target
/// when the dial fails.
pub(crate) fn fallback_allowed(active: bool, suppress_auto: bool, has_target: bool) -> bool {
    !active && !suppress_auto && !has_target
}

/// How long to wait before the next `/24` sweep, given how many sweeps in a
/// row have found nothing.
///
/// A sweep is 254 TCP connects. Running one every tick would be a small
/// denial-of-service against the user's own LAN, so an empty LAN backs off.
///
/// The cap used to be 60 s, and the comment said that was a "heartbeat". It is
/// not: measured on this box with no phone present, a 60 s sweep of a /24 kept
/// the process at **5.6% of one core indefinitely** — a tray app that runs all
/// day on a laptop, burning a measurable slice of a core to look for something
/// that is not there.
///
/// The backoff is now geometric up to 15 minutes. That keeps the two properties
/// that matter: a phone that has just arrived is still found within seconds (the
/// fast rungs and mDNS cover that), and a LAN that has been empty for a while
/// stops costing anything. Any success resets the count to zero, so nothing
/// here slows down discovery after a hit.
pub(crate) fn sweep_interval(consecutive_misses: u32) -> Duration {
    const FIRST: Duration = Duration::from_secs(15);
    const MAX: Duration = Duration::from_secs(15 * 60);
    match consecutive_misses {
        0 => FIRST,
        1 => Duration::from_secs(30),
        2 => Duration::from_secs(60),
        3 => Duration::from_secs(180),
        4 => Duration::from_secs(300),
        n if n < 12 => Duration::from_secs(n as u64 * 60),
        _ => MAX,
    }
}

/// Turn this machine's addresses into subnets worth sweeping.
///
/// The filter is the point. A TUN-mode VPN (Clash / Mihomo / sing-box — and
/// most Chinese "加速器") owns the default route, so
/// [`rc_discovery::local_ipv4_addresses`] reports the *tunnel's* address rather
/// than the WiFi NIC's. Sweeping `198.18.0.0/24` (Clash's fake-IP pool) probes
/// 254 addresses that do not exist and never touches the real LAN, which is
/// why the sweep came up empty on 2026-09-29 while the phone was sitting on the
/// same WiFi. Ranges that no real home/office LAN uses are dropped; loopback
/// is kept deliberately, because the simulator e2e and the loopback fallback
/// test both live there.
pub(crate) fn sweep_targets(local_addrs: &[String]) -> Vec<String> {
    local_addrs
        .iter()
        .filter(|a| match a.parse::<std::net::Ipv4Addr>() {
            Ok(ip) => !is_tunnel_range(ip),
            // Not an IPv4 literal (a hostname, an IPv6 form) — let the caller
            // try it rather than silently dropping a possible answer.
            Err(_) => true,
        })
        .cloned()
        .collect()
}

/// Address ranges that are never a real phone on a real LAN.
fn is_tunnel_range(ip: std::net::Ipv4Addr) -> bool {
    let o = ip.octets();
    match o {
        // 169.254.0.0/16 — link-local / DHCP-less adapters (Hyper-V, WSL, VPN).
        [169, 254, _, _] => true,
        // 198.18.0.0/15 — RFC 2544 benchmarking, de facto the Clash/Mihomo
        // fake-IP pool.
        [198, 18 | 19, _, _] => true,
        // 100.64.0.0/10 — CGNAT; several TUN implementations hand out
        // addresses from here.
        [100, 64..=127, _, _] => true,
        [0, 0, 0, 0] => true,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_idle_unencumbered_receiver_may_fall_back() {
        assert!(fallback_allowed(false, false, false));
    }

    /// The regression. A phone that was discovered but will not answer must
    /// not disable the fallbacks for the rest of the session — that was the
    /// "re-dial one dead address forever" deadlock.
    #[test]
    fn being_busy_is_the_only_thing_that_blocks_the_fallback() {
        assert!(!fallback_allowed(true, false, false), "a live connection");
        assert!(!fallback_allowed(false, true, false), "user said stop");
        assert!(
            !fallback_allowed(false, false, true),
            "already dialing something"
        );
    }

    /// Standby, not a fast loop: after `busy`/`off` a non-current computer
    /// waits ≥ 60 s between safety-net re-dials (and longer than the normal 3 s
    /// reconnect), so a phone that is set to another computer is not spammed.
    #[test]
    fn standby_retry_is_a_slow_safety_net_not_a_fast_loop() {
        assert!(STANDBY_RETRY_DELAY >= Duration::from_secs(60));
        assert!(STANDBY_RETRY_DELAY > RECONNECT_DELAY);
    }

    #[test]
    fn the_sweep_backs_off_and_never_below_the_floor() {
        assert_eq!(sweep_interval(0), Duration::from_secs(15));
        assert_eq!(sweep_interval(1), Duration::from_secs(30));
        assert_eq!(sweep_interval(2), Duration::from_secs(60));
        assert_eq!(sweep_interval(99), Duration::from_secs(15 * 60), "capped");
    }

    /// The property the 5.6%-of-a-core measurement demands: the wait has to
    /// actually grow, or a tray app that runs all day keeps sweeping a /24 for
    /// a phone that is simply not there. It also has to stay *bounded*, so a LAN
    /// that empties for a week still finds a phone that comes back.
    #[test]
    fn an_absent_phone_stops_costing_anything_and_still_gets_found() {
        // Monotonic: every miss waits at least as long as the one before.
        let mut prev = sweep_interval(0);
        for misses in 1..40 {
            let now = sweep_interval(misses);
            assert!(
                now >= prev,
                "backoff shrank at {misses}: {now:?} after {prev:?}"
            );
            prev = now;
        }
        // …and it settles rather than climbing forever.
        assert_eq!(sweep_interval(11), Duration::from_secs(11 * 60));
        assert_eq!(sweep_interval(12), Duration::from_secs(15 * 60), "capped");
        assert_eq!(sweep_interval(u32::MAX), Duration::from_secs(15 * 60));
        // A sweep still happens, so a phone that comes back is still found.
        assert!(sweep_interval(u32::MAX) <= Duration::from_secs(15 * 60));
    }

    /// Any hit must put discovery straight back to its fast rung — otherwise
    /// backing off harder would also delay reconnecting to a phone we already
    /// know about.
    #[test]
    fn a_hit_resets_the_backoff_to_the_fastest_rung() {
        assert_eq!(sweep_interval(0), Duration::from_secs(15));
    }

    /// The regression that made the 2026-09-29 bring-up fail: with Mihomo in
    /// TUN mode the only address the OS reports is the tunnel's fake-IP, and
    /// sweeping that pool finds nothing on a perfectly healthy LAN.
    #[test]
    fn a_tunnel_address_is_never_swept() {
        let addrs: Vec<String> = ["198.18.0.2", "100.64.0.1", "169.254.7.7", "0.0.0.0"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert!(
            sweep_targets(&addrs).is_empty(),
            "tunnel / link-local addresses must not become sweep targets: {:?}",
            sweep_targets(&addrs)
        );
    }

    /// A real WiFi address still gets swept, and so does loopback — the
    /// simulator e2e runs the receiver against a listener on 127.0.0.1.
    #[test]
    fn real_and_loopback_addresses_are_swept() {
        let addrs: Vec<String> = ["192.168.31.159", "127.0.0.1", "10.0.0.7"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(sweep_targets(&addrs), addrs);
    }

    /// A hostname is not a tunnel range, and dropping it would lose a real
    /// candidate — pass it through for the caller to try.
    #[test]
    fn a_non_ipv4_candidate_is_passed_through() {
        let addrs = vec!["myphone.local".to_string()];
        assert_eq!(sweep_targets(&addrs), addrs);
    }
}
