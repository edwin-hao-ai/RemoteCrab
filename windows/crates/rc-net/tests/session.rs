//! End-to-end session tests: `rc-net` (receiver) against `rc-testkit`
//! (fake iPhone) over a real TCP socket. No phone or Mac required.

use std::time::Duration;

use rc_net::{Config, Event, Session, State};
use rc_protocol::{Feature, SessionReplyResult};
use rc_testkit::{FakeIphone, FakeIphoneConfig};

fn test_config() -> Config {
    Config {
        app_version: "0.1.0-test".to_string(),
        service_type: "_remotecrab._tcp.local.".to_string(),
        default_port: rc_net::DEFAULT_PORT,
        // Keep tests hermetic — never touch the real %APPDATA% token file.
        token_path: None,
    }
}

async fn wait_for_state(
    session: &Session,
    pred: impl Fn(&State) -> bool,
    timeout: Duration,
) -> Option<State> {
    let mut rx = session.state();
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if pred(&rx.borrow()) {
            return Some(rx.borrow().clone());
        }
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return None;
        }
        if tokio::time::timeout(remaining, rx.changed()).await.is_err() {
            return None;
        }
    }
}

#[tokio::test]
async fn handshake_accepted_reaches_streaming() {
    let phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(test_config());

    session.connect_manual("127.0.0.1", phone.addr.port());

    let state = wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await;
    assert!(
        state.is_some(),
        "expected Streaming, got {:?}",
        session.state().borrow()
    );
    assert_eq!(state.unwrap().pill_label(), "LIVE");
}

#[tokio::test]
async fn client_hello_carries_pc_identity_and_windows_platform() {
    let mut phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", phone.addr.port());

    let hello = tokio::time::timeout(Duration::from_secs(5), phone.hellos.recv())
        .await
        .expect("hello timeout")
        .expect("hello channel closed");

    assert_eq!(hello.platform.as_deref(), Some("windows"));
    assert!(!hello.id.is_empty(), "pc id must be set");
    assert!(!hello.name.is_empty(), "pc name must be set");
    assert_eq!(hello.app_version, "0.1.0-test");
}

#[tokio::test]
async fn metadata_and_feature_state_are_delivered() {
    let phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(test_config());
    // Subscribe before connecting and keep draining, so no broadcast frame
    // is missed between the handshake and the assertion loop.
    let mut events = session.subscribe();

    let (collected_tx, mut collected_rx) = tokio::sync::mpsc::unbounded_channel();
    tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(e) => {
                    if collected_tx.send(e).is_err() {
                        return;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
                Err(_) => {}
            }
        }
    });

    session.connect_manual("127.0.0.1", phone.addr.port());

    let mut got_metadata = false;
    let mut got_feature_state = false;
    let mut seen: Vec<String> = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < deadline && !(got_metadata && got_feature_state) {
        match tokio::time::timeout(Duration::from_millis(500), collected_rx.recv()).await {
            Ok(Some(Event::Metadata(m))) => {
                seen.push(format!("Metadata({})", m.device_name));
                assert_eq!(m.device_name, "Fake iPhone");
                assert_eq!(m.resolution_label(), "1080p");
                got_metadata = true;
            }
            Ok(Some(Event::FeatureState(s))) => {
                seen.push("FeatureState".to_string());
                assert!(s.camera_on);
                assert!(s.trackpad_on);
                got_feature_state = true;
            }
            Ok(Some(other)) => seen.push(format!("{other:?}")),
            _ => {}
        }
    }
    assert!(got_metadata, "metadata not delivered; saw {seen:?}");
    assert!(
        got_feature_state,
        "featureState not delivered; saw {seen:?}"
    );
}

#[tokio::test]
async fn ping_produces_a_latency_reading() {
    let phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(test_config());
    let mut events = session.subscribe();
    session.connect_manual("127.0.0.1", phone.addr.port());

    // Wait for the ping loop to produce at least one RTT sample.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    let mut latency: Option<i64> = None;
    while tokio::time::Instant::now() < deadline && latency.is_none() {
        if let Ok(Ok(Event::Latency(ms))) =
            tokio::time::timeout(Duration::from_millis(500), events.recv()).await
        {
            latency = Some(ms);
        }
    }
    let latency = latency.expect("no latency sample within 8s");
    assert!(latency >= 0, "latency must be non-negative, got {latency}");
}

#[tokio::test]
async fn set_feature_sends_feature_control_to_the_phone() {
    let mut phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", phone.addr.port());
    wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await
    .expect("did not reach streaming");

    session.set_feature(Feature::Camera, false);

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut seen = false;
    while tokio::time::Instant::now() < deadline && !seen {
        if let Ok(Some(rc_testkit::Frame2::FeatureControl(fc))) =
            tokio::time::timeout(Duration::from_millis(500), phone.inbound.recv()).await
        {
            assert_eq!(fc.feature, Feature::Camera);
            assert!(!fc.enabled);
            seen = true;
        }
    }
    assert!(seen, "featureControl was not received by the phone");
}

#[tokio::test]
async fn pending_reply_goes_to_awaiting_approval_then_streams() {
    let phone = FakeIphone::start(FakeIphoneConfig {
        reply: SessionReplyResult::Pending,
        ..Default::default()
    })
    .await
    .unwrap();
    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", phone.addr.port());

    let awaiting = wait_for_state(
        &session,
        |s| matches!(s, State::AwaitingApproval { .. }),
        Duration::from_secs(5),
    )
    .await;
    assert!(awaiting.is_some(), "expected AwaitingApproval");

    // The fake phone auto-accepts after 300 ms.
    let streaming = wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await;
    assert!(streaming.is_some(), "expected Streaming after approval");
}

#[tokio::test]
async fn busy_reply_shows_the_owner_and_keeps_retrying() {
    let phone = FakeIphone::start(FakeIphoneConfig {
        reply: SessionReplyResult::Busy,
        ..Default::default()
    })
    .await
    .unwrap();
    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", phone.addr.port());

    // Busy is NOT fatal: the state names the owner so the UI can tell the
    // user where to disconnect, and the session keeps retrying.
    let busy = wait_for_state(
        &session,
        |s| matches!(s, State::Busy { .. }),
        Duration::from_secs(5),
    )
    .await
    .expect("expected a Busy state");
    if let State::Busy { owner } = busy {
        assert_eq!(owner, "Another Mac");
    }
    assert_eq!(session.state().borrow().pill_label(), "IN USE");

    // It must not have parked in a permanent Error.
    assert!(!matches!(*session.state().borrow(), State::Error(_)));
}

#[tokio::test]
async fn handshake_timeout_when_the_phone_never_replies() {
    // A bare listener that accepts but never sends a sessionReply.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        // Hold the socket open without replying.
        let _stream = stream;
        tokio::time::sleep(Duration::from_secs(30)).await;
    });

    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", port);

    // It should pass through Handshaking and recover (Lost → reconnect),
    // i.e. it must NOT remain stuck in Handshaking forever.
    wait_for_state(
        &session,
        |s| matches!(s, State::Handshaking { .. }),
        Duration::from_secs(3),
    )
    .await;

    // See the note in `link_loss_reconnects_on_its_own`: this asserts
    // "eventually leaves the handshake", not "within 12 seconds".
    let recovered = wait_for_state(
        &session,
        |s| matches!(s, State::Connecting { .. } | State::Handshaking { .. }),
        Duration::from_secs(30),
    )
    .await;
    assert!(recovered.is_some(), "session never left the handshake");
}

#[tokio::test]
async fn disconnect_returns_to_searching() {
    let phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", phone.addr.port());
    wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await
    .expect("did not reach streaming");

    session.disconnect();
    let searching = wait_for_state(
        &session,
        |s| matches!(s, State::Searching),
        Duration::from_secs(3),
    )
    .await;
    assert!(searching.is_some(), "expected Searching after disconnect");

    // The explicit disconnect must STAY disconnected. Dropping the connection
    // task makes it emit `ConnMsg::End(Lost)`, and the End handler used to
    // rewrite the state to `Error("The connection was lost")` right after — so
    // the user who pressed Disconnect was told the link had dropped. Wait past
    // the End event so this assertion can see that rewrite, which the old
    // `wait_for_state`-only form raced (it caught `Searching` before the End
    // landed about two runs in three).
    tokio::time::sleep(Duration::from_millis(600)).await;
    let settled = session.state().borrow().clone();
    assert!(
        matches!(settled, State::Searching),
        "an explicit disconnect must not be rewritten as a lost connection; got {settled:?}"
    );
}

#[tokio::test]
async fn a_phone_that_hangs_up_does_not_leave_us_claiming_to_stream() {
    // The manual-connect case, which is the one that used to lie.
    //
    // `--connect <ip>` suppresses auto-reconnect on purpose: the user named an
    // address, so hammering it forever is wrong. But suppressing the *retry* also
    // meant nothing ever moved the state off `Streaming` — so after the phone
    // walked out of range the tray said "streaming" indefinitely, with no error
    // and nothing to act on. `disconnect_returns_to_searching` above cannot catch
    // it: that path has a next iteration which sets `Searching`, and this one
    // has none.
    let phone = FakeIphone::start(FakeIphoneConfig {
        stream_video: true,
        video_frames: 30,
        drop_after_frames: Some(5),
        ..FakeIphoneConfig::default()
    })
    .await
    .unwrap();
    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", phone.addr.port());
    wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await
    .expect("did not reach streaming");

    // The phone hangs up. An honest "lost" must follow promptly. Waiting only
    // for "not Streaming" would pass on a retry that eventually reconnects,
    // which is a different and much less interesting outcome — the failure is
    // the case where nothing can be retried and the UI must say so.
    let after = wait_for_state(
        &session,
        |s| matches!(s, State::Error(_)),
        Duration::from_secs(5),
    )
    .await;
    assert!(
        after.is_some(),
        "no error after the phone hung up — the state stays Streaming, so the UI \
         claims a live session that does not exist"
    );
}

#[tokio::test]
async fn an_unreachable_phone_is_not_reported_as_a_lost_connection() {
    // The wording regression this pins. Reporting "the connection was lost" for
    // a phone that was never reachable sends the user to check their WiFi, their
    // router and their firewall — none of which is the problem — while the actual
    // answer is "the iPhone is not on this network, or is not running".
    //
    // Nothing is listening on this port, so the TCP connect fails and we never
    // reach `Streaming`.
    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", 9);
    let state = wait_for_state(
        &session,
        |s| matches!(s, State::Error(_)),
        Duration::from_secs(8),
    )
    .await;
    let Some(State::Error(why)) = state else {
        panic!("expected an error for an unreachable phone");
    };
    assert!(
        why.contains("Could not reach") || why.contains("not reach"),
        "an unreachable phone must not be described as a lost connection: {why}"
    );
    assert!(
        !why.contains("lost"),
        "says 'lost' about a connection that never existed: {why}"
    );
}

#[tokio::test]
async fn link_loss_reconnects_on_its_own() {
    // A phone that completes the handshake and then immediately hangs up.
    //
    // This is the field case: a WiFi blip, the iPhone locking, the laptop
    // changing AP. The receiver used to notice the loss, set a 3 s reconnect
    // timer, and then find `target == None` — because only the subnet-sweep
    // path ever recorded what it was dialing — so it silently never came back.
    use rc_protocol::{encode_session_reply, Kind, SessionReply, SessionReplyResult};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let connects = Arc::new(AtomicUsize::new(0));
    let counter = connects.clone();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            counter.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(async move {
                let (mut rd, mut wr) = stream.into_split();
                let mut parser = rc_protocol::Parser::new();
                let mut buf = vec![0u8; 4096];
                let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
                loop {
                    let Ok(n) = rd.read(&mut buf).await else {
                        return;
                    };
                    if parser
                        .append(&buf[..n])
                        .iter()
                        .any(|f| f.kind == Kind::ClientHello)
                    {
                        break;
                    }
                    if tokio::time::Instant::now() > deadline {
                        return;
                    }
                }
                let reply = SessionReply {
                    result: SessionReplyResult::Accepted,
                    owner_name: None,
                    token: Some("test-token".to_string()),
                    nonce: None,
                    mac: None,
                    capabilities: None,
                };
                let _ = wr.write_all(&encode_session_reply(&reply).unwrap()).await;
                // `stream` drops here — the link dies without a FIN handshake
                // the receiver can interpret as "the user left".
            });
        }
    });

    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", port);

    // Generous, because the assertion is "it re-dials", not "it re-dials
    // within N seconds": the receiver waits RECONNECT_DELAY (3 s) first, and
    // this file shares a machine with every other test binary when the whole
    // workspace runs in parallel. A tight budget here reads as a product
    // regression when it is only the test runner being slow.
    //
    // **The 30 s budget is also load-bearing in the other direction.** The
    // fake phone lives on loopback, and loopback is deliberately NOT persisted
    // as a phone address (`rc_discovery::is_usable_dial_address`). So the
    // direct-IP fallback has no candidate here and the *only* thing that can
    // produce a second connection is the reconnect path re-dialing the target
    // it already had. That is exactly what we want to test — an earlier
    // version cleared the target on the first failure, which silently disabled
    // reconnection, and this test kept passing because the fallback rescued it.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    while connects.load(Ordering::SeqCst) < 2 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the receiver gave up after a link drop instead of re-dialing (connects = {})",
            connects.load(Ordering::SeqCst)
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

// ---------------------------------------------------------------------------
// Pairing-token persistence — the cross-connection tests.
//
// The nine tests above all make EXACTLY ONE connection and stop. That is the
// blind spot that let the receiver ship while asking the iPhone for approval
// on *every* reconnect: the token the phone issues in `sessionReply` was
// assigned to `_accepted_token` and dropped on the floor, so the second
// `clientHello` went out tokenless and the phone answered `pending` again.
//
// Every test below spans a connection or a restart, because that is the only
// way to see this class of bug. (AGENTS.md rule 8.)
// ---------------------------------------------------------------------------

/// A config that persists to a real file, so the round-trip through
/// `serde` is actually exercised. The tests above pass `token_path: None`,
/// which keeps the store in memory and would hide a "never written" bug.
fn test_config_with_token_file(tag: &str) -> (Config, std::path::PathBuf) {
    let path = std::env::temp_dir().join(format!("rc-session-{}-{tag}.json", std::process::id()));
    let _ = std::fs::remove_file(&path);
    (
        Config {
            token_path: Some(path.clone()),
            ..test_config()
        },
        path,
    )
}

async fn recv_hello(phone: &mut FakeIphone) -> rc_protocol::ClientHello {
    tokio::time::timeout(Duration::from_secs(5), phone.hellos.recv())
        .await
        .expect("clientHello timeout")
        .expect("hello channel closed")
}

#[tokio::test]
async fn token_is_persisted_after_accepted() {
    let (config, path) = test_config_with_token_file("persist");
    // Default config answers `accepted` with token "test-token".
    let phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(config);
    session.connect_manual("127.0.0.1", phone.addr.port());
    wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await
    .expect("did not reach streaming");

    // The write happens on the supervisor task, just after the handshake.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let raw = loop {
        let raw = std::fs::read_to_string(&path).unwrap_or_default();
        if raw.contains("test-token") {
            break raw;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the token the phone issued was never written to {path:?}: {raw}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let _ = std::fs::remove_file(&path);
    assert!(raw.contains("test-token"), "{raw}");
}

#[tokio::test]
async fn second_connection_sends_the_stored_token() {
    let (config, path) = test_config_with_token_file("second");
    let mut phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(config);

    // Connection 1: tokenless is CORRECT — the phone has not issued one yet.
    session.connect_manual("127.0.0.1", phone.addr.port());
    let first = recv_hello(&mut phone).await;
    assert_eq!(
        first.token, None,
        "the first connection cannot carry a token"
    );

    wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await
    .expect("first session did not stream");

    // Connection 2: it MUST echo the token, or the phone shows the approval
    // card again and the user has to tap Allow every single time.
    session.disconnect();
    wait_for_state(
        &session,
        |s| matches!(s, State::Searching),
        Duration::from_secs(3),
    )
    .await;
    session.connect_manual("127.0.0.1", phone.addr.port());
    let second = recv_hello(&mut phone).await;
    let dump = std::fs::read_to_string(&path).unwrap_or_default();
    let _ = std::fs::remove_file(&path);
    assert_eq!(
        second.token.as_deref(),
        Some("test-token"),
        "the second clientHello must carry the token the phone issued.\nstore = {dump}"
    );
}

#[tokio::test]
async fn token_survives_a_restart() {
    let (config, path) = test_config_with_token_file("restart");
    let mut phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();

    {
        let session = Session::spawn(config.clone());
        session.connect_manual("127.0.0.1", phone.addr.port());
        let _ = recv_hello(&mut phone).await;
        wait_for_state(
            &session,
            |s| matches!(s, State::Streaming { .. }),
            Duration::from_secs(5),
        )
        .await
        .expect("first session did not stream");
        session.disconnect();
    }
    // A brand-new process reading the same file. This is the case that matters
    // in the field: the user relaunches the tray app, and the iPhone must not
    // ask them to approve a computer they already approved.
    let session = Session::spawn(config);
    session.connect_manual("127.0.0.1", phone.addr.port());
    let after_restart = recv_hello(&mut phone).await;
    let _ = std::fs::remove_file(&path);
    assert_eq!(
        after_restart.token.as_deref(),
        Some("test-token"),
        "a relaunched receiver must still know its token"
    );
}

#[tokio::test]
async fn token_is_rekeyed_to_the_phones_reported_name() {
    // The token arrives keyed by a *provisional* name — the mDNS instance
    // name, or `iPhone (<ip>)` for a direct dial. Those are two different keys
    // for one physical device, so without a rekey the direct-IP path (the only
    // one that works when mDNS is dead) can never be paired silently. The
    // phone tells us its real name in `metadata`; that is the stable key.
    let (config, path) = test_config_with_token_file("rekey");
    let phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(config);
    session.connect_manual("127.0.0.1", phone.addr.port());
    wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await
    .expect("did not stream");

    // The fake phone reports `device_name: "Fake iPhone"`.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let raw = loop {
        let raw = std::fs::read_to_string(&path).unwrap_or_default();
        if raw.contains("Fake iPhone") {
            break raw;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the token was never rekeyed to the phone's real name: {raw}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let _ = std::fs::remove_file(&path);
    assert!(
        raw.contains("Fake iPhone"),
        "the token must be keyed by the device name from metadata, got: {raw}"
    );
}

#[tokio::test]
async fn direct_dial_after_an_mdns_session_still_carries_the_token() {
    // The rekey must not break the provisional key: a *different* connection
    // path (mDNS here, direct IP next) has to find the same token. This is the
    // TUN scenario — mDNS dies, the sweep dials the IP, and if the token is
    // stranded under the other name the user gets an approval card anyway.
    let (config, path) = test_config_with_token_file("crosskey");
    let mut phone = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(config);

    session.connect_manual("127.0.0.1", phone.addr.port());
    let _ = recv_hello(&mut phone).await;
    wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await
    .expect("did not stream");

    session.disconnect();
    wait_for_state(
        &session,
        |s| matches!(s, State::Searching),
        Duration::from_secs(3),
    )
    .await;
    // Same address, so the IP→name map learned from `metadata` applies.
    session.connect_manual("127.0.0.1", phone.addr.port());
    let second = recv_hello(&mut phone).await;
    let _ = std::fs::remove_file(&path);
    assert_eq!(
        second.token.as_deref(),
        Some("test-token"),
        "the IP learned from metadata must resolve back to the same token"
    );
}

// ---------------------------------------------------------------------------
// Identity — the exchange that stops a stranger on the same WiFi from being
// taken for the phone.
//
// The receiver used to accept any `sessionReply accepted` at its word, so
// anything that could bind the phone's port could then drive this machine's
// keyboard. These tests are the three shapes that matters: a phone that proves
// itself, a phone that cannot, and something that is not the phone at all.
//
// All three need a *paired* receiver first, because the exchange only happens
// when there is a token to key it with — which is the trust-on-first-use window
// and is one pairing rather than every reconnect.
// ---------------------------------------------------------------------------

/// Pair the receiver with a phone that does not do the exchange, so the next
/// connection has a token to be challenged with.
///
/// Returns nothing; the caller re-reads the same token file with a second
/// `Session`, which is also what makes the test cover the store round-trip.
async fn pair_once(config: &Config, path: &std::path::Path) {
    let mut plain = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    {
        let session = Session::spawn(config.clone());
        session.connect_manual("127.0.0.1", plain.addr.port());
        let _ = recv_hello(&mut plain).await;
        wait_for_state(
            &session,
            |s| matches!(s, State::Streaming { .. }),
            Duration::from_secs(5),
        )
        .await
        .expect("the pairing session did not stream");
        session.disconnect();
    }
    assert!(
        std::fs::read_to_string(path).is_ok_and(|s| s.contains("test-token")),
        "pairing did not persist a token, so there is nothing to challenge with"
    );
}

#[tokio::test]
async fn a_phone_that_proves_itself_is_authenticated() {
    let (config, path) = test_config_with_token_file("peer-auth-ok");
    pair_once(&config, &path).await;

    let mut phone = FakeIphone::start(FakeIphoneConfig {
        peer_auth_token: Some("test-token".to_string()),
        ..FakeIphoneConfig::default()
    })
    .await
    .unwrap();

    let session = Session::spawn(config);
    session.connect_manual("127.0.0.1", phone.addr.port());
    let hello = recv_hello(&mut phone).await;

    assert!(
        hello.nonce.is_some(),
        "the receiver must offer its half of the challenge"
    );
    assert!(
        hello
            .capabilities
            .as_ref()
            .is_some_and(|c| c.iter().any(|k| k == rc_protocol::peer_auth::CAPABILITY)),
        "and must say it can do this: {:?}",
        hello.capabilities
    );

    let state = wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await
    .expect("the authenticated session never reached streaming");
    let _ = std::fs::remove_file(&path);
    match state {
        State::Streaming { authenticated, .. } => assert!(
            authenticated,
            "a phone that answered the challenge must be recorded as authenticated"
        ),
        other => panic!("expected Streaming, got {other:?}"),
    }
}

#[tokio::test]
async fn something_that_does_not_hold_the_token_is_refused() {
    let (config, path) = test_config_with_token_file("peer-auth-impostor");
    pair_once(&config, &path).await;

    // The same port, answered by a machine with the wrong secret. This is the
    // attacker the whole exchange exists for: it can be reached, it speaks the
    // protocol, and it would have been believed before.
    let mut impostor = FakeIphone::start(FakeIphoneConfig {
        peer_auth_token: Some("not-the-real-token".to_string()),
        ..FakeIphoneConfig::default()
    })
    .await
    .unwrap();

    let session = Session::spawn(config);
    session.connect_manual("127.0.0.1", impostor.addr.port());
    let _ = recv_hello(&mut impostor).await;

    let state = wait_for_state(
        &session,
        |s| matches!(s, State::Error(_)),
        Duration::from_secs(5),
    )
    .await
    .expect("the impostor was not refused");

    // And it must not have been admitted on the way to that error.
    assert!(
        !matches!(&*session.state().borrow(), State::Streaming { .. }),
        "an impostor must never reach streaming"
    );
    let _ = std::fs::remove_file(&path);
    match state {
        State::Error(message) => assert_eq!(
            message, "Could not verify the iPhone",
            "the refusal must be worded as an identity problem, not as a refusal by the user"
        ),
        other => panic!("expected an error, got {other:?}"),
    }
}

#[tokio::test]
async fn a_phone_that_cannot_prove_itself_is_allowed_and_marked_unauthenticated() {
    let (config, path) = test_config_with_token_file("peer-auth-legacy");
    pair_once(&config, &path).await;

    // An app from before the exchange: it answers `accepted` with no MAC. It has
    // to keep working — refusing it would turn this into an outage on the day it
    // shipped, and the receiver cannot update the phone — but the session must
    // not be *called* authenticated.
    let mut legacy = FakeIphone::start(FakeIphoneConfig::default())
        .await
        .unwrap();
    let session = Session::spawn(config);
    session.connect_manual("127.0.0.1", legacy.addr.port());
    let _ = recv_hello(&mut legacy).await;

    let state = wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await
    .expect("a phone that cannot prove itself must still be able to connect");
    let _ = std::fs::remove_file(&path);
    match state {
        State::Streaming { authenticated, .. } => assert!(
            !authenticated,
            "a session with no proof must not be reported as authenticated"
        ),
        other => panic!("expected Streaming, got {other:?}"),
    }
}
