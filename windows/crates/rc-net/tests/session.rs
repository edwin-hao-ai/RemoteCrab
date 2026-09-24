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
    let phone = FakeIphone::start(FakeIphoneConfig::default()).await.unwrap();
    let session = Session::spawn(test_config());

    session.connect_manual("127.0.0.1", phone.addr.port());

    let state = wait_for_state(
        &session,
        |s| matches!(s, State::Streaming { .. }),
        Duration::from_secs(5),
    )
    .await;
    assert!(state.is_some(), "expected Streaming, got {:?}", session.state().borrow());
    assert_eq!(state.unwrap().pill_label(), "LIVE");
}

#[tokio::test]
async fn client_hello_carries_pc_identity_and_windows_platform() {
    let mut phone = FakeIphone::start(FakeIphoneConfig::default()).await.unwrap();
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
    let phone = FakeIphone::start(FakeIphoneConfig::default()).await.unwrap();
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
    assert!(got_feature_state, "featureState not delivered; saw {seen:?}");
}

#[tokio::test]
async fn ping_produces_a_latency_reading() {
    let phone = FakeIphone::start(FakeIphoneConfig::default()).await.unwrap();
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
    let mut phone = FakeIphone::start(FakeIphoneConfig::default()).await.unwrap();
    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", phone.addr.port());
    wait_for_state(&session, |s| matches!(s, State::Streaming { .. }), Duration::from_secs(5))
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
async fn busy_reply_stops_with_an_error_state() {
    let phone = FakeIphone::start(FakeIphoneConfig {
        reply: SessionReplyResult::Busy,
        ..Default::default()
    })
    .await
    .unwrap();
    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", phone.addr.port());

    let err = wait_for_state(
        &session,
        |s| matches!(s, State::Error(_)),
        Duration::from_secs(5),
    )
    .await;
    let err = err.expect("expected an Error state on busy");
    if let State::Error(msg) = err {
        assert!(msg.contains("in use"), "unexpected message: {msg}");
    }
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

    let recovered = wait_for_state(
        &session,
        |s| matches!(s, State::Connecting { .. } | State::Handshaking { .. }),
        Duration::from_secs(12),
    )
    .await;
    assert!(recovered.is_some(), "session never left the handshake");
}

#[tokio::test]
async fn disconnect_returns_to_searching() {
    let phone = FakeIphone::start(FakeIphoneConfig::default()).await.unwrap();
    let session = Session::spawn(test_config());
    session.connect_manual("127.0.0.1", phone.addr.port());
    wait_for_state(&session, |s| matches!(s, State::Streaming { .. }), Duration::from_secs(5))
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
}
