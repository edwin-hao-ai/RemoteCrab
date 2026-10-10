//! `rc-testkit` — a fake iPhone.
//!
//! Speaks the exact receiver-role protocol the real iOS app does, so the
//! whole handshake / ping / streaming / pairing path can be exercised
//! without a phone or a Mac. Used by `rc-net` integration tests and by the
//! app's "demo" mode.

use std::net::SocketAddr;

use rc_protocol::{
    decode_client_hello, decode_client_proof, decode_feature_control, decode_key, decode_ping,
    decode_touch, encode_feature_state, encode_metadata, encode_nal, encode_ping,
    encode_session_reply,
    encode_touch, ClientHello, FeatureStateSnapshot, KeyEvent, NalFrame, NalKind, SessionReply,
    SessionReplyResult, StreamMetadata, Surface, TouchEvent, TouchPhase,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

#[derive(Debug, Clone)]
pub struct FakeIphoneConfig {
    /// What to answer the first `clientHello` with.
    pub reply: SessionReplyResult,
    /// Token to issue when the reply is `accepted`.
    pub token: Option<String>,
    /// Send `featureState` + `metadata` once accepted.
    pub send_metadata: bool,
    /// Echo every ping (the real phone does).
    pub echo_pings: bool,
    /// Stream real H.264 video frames (`sps`/`pps`/`video`). Off by default
    /// so protocol tests stay deterministic; on for the preview self-test.
    pub stream_video: bool,
    pub video_frames: usize,
    /// Drop the connection after this many video frames. `None` keeps it open.
    ///
    /// This exists because a scenario named `drop` needs to actually drop. The
    /// phone-sim had `Drop => {}` — an empty arm, identical to the happy path —
    /// so every "verify the receiver reconnects" run had been passing without the
    /// disconnect ever happening. Reconnect behaviour cannot be tested against a
    /// tool that never disconnects; worse, it looks tested.
    pub drop_after_frames: Option<usize>,
    /// The secret this fake phone holds, when it is a phone that can prove
    /// itself.
    ///
    /// `None` is a phone older than the identity exchange: it answers with no
    /// MAC at all, and the receiver is expected to record the session as
    /// **unauthenticated** rather than to refuse it. `Some(secret)` makes it
    /// answer the challenge, and a secret that differs from the receiver's
    /// stored token is how a test plays an **impostor** standing on the phone's
    /// port.
    pub peer_auth_token: Option<String>,
    /// Advertise + use the sealed transport (F1). Requires `peer_auth_token`
    /// (the key comes from the token). Off by default so the many cleartext
    /// tests stay cleartext — turn it on to prove the receiver seals/opens.
    pub transport: bool,
}

impl Default for FakeIphoneConfig {
    fn default() -> Self {
        FakeIphoneConfig {
            reply: SessionReplyResult::Accepted,
            token: Some("test-token".to_string()),
            send_metadata: true,
            echo_pings: true,
            stream_video: false,
            video_frames: 0,
            drop_after_frames: None,
            peer_auth_token: None,
            transport: false,
        }
    }
}

/// A running fake iPhone. Dropping it stops the listener.
pub struct FakeIphone {
    pub addr: SocketAddr,
    /// The `clientHello` from the (first) receiver to connect.
    pub hellos: mpsc::UnboundedReceiver<ClientHello>,
    /// Everything else the receiver sent (featureControl, touch, …).
    pub inbound: mpsc::UnboundedReceiver<Frame2>,
    /// Frames this fake phone sends *to* the receiver.
    out_tx: tokio::sync::broadcast::Sender<Vec<u8>>,
}

impl FakeIphone {
    /// Send a frame to the receiver, the way the phone would.
    ///
    /// The mirror of [`FakeIphone::inbound`]: that is what the receiver said to
    /// us, this is what we say to it. Without it a test could prove the receiver
    /// *received* a touch but never that it did anything with it — which is the
    /// whole question for input, clipboard, files and commands, and the reason
    /// none of those had been exercised against the shipped binary.
    ///
    /// Delivery is best-effort: a receiver that has gone away is not an error
    /// here, and a test that cares checks the consequence (the clipboard
    /// changed, the file appeared) rather than the send.
    ///
    /// Returns whether the frame reached the connection's writer, so a caller
    /// driving the receiver can tell "queued" from "there was nobody to queue
    /// it to".
    pub fn send(&self, frame: Vec<u8>) -> bool {
        self.out_tx.send(frame).is_ok()
    }
}

/// A lightly-typed view of a frame the receiver sent us.
#[derive(Debug, Clone)]
pub enum Frame2 {
    ClientHello(ClientHello),
    FeatureControl(rc_protocol::FeatureControl),
    Touch(TouchEvent),
    Key(KeyEvent),
    /// A ping, with the timestamp the receiver put in it — so a caller can
    /// measure the round trip itself rather than only seeing that one happened.
    Ping(u64),
    /// A relayed notification (0x22), the phone's copy of what a receiver sent.
    Notification(rc_protocol::Notification),
    /// A command result (0x23).
    CommandResult(rc_protocol::CommandResult),
    /// Anything else, by kind byte.
    Other(u8),
}

impl FakeIphone {
    /// Bind on a random localhost port and serve one connection.
    pub async fn start(config: FakeIphoneConfig) -> std::io::Result<FakeIphone> {
        Self::start_on(config, 0).await
    }

    /// Bind a **chosen** port, so a receiver in another process can be pointed
    /// at it.
    ///
    /// The in-process tests use `start()` and never care which port they got.
    /// Testing the *shipped binary* needs a known one: there is no way to ask a
    /// running receiver "connect to whatever port the fake phone picked".
    ///
    /// Port `0` still means "any", so this is `start()` with a number.
    pub async fn start_on(config: FakeIphoneConfig, port: u16) -> std::io::Result<FakeIphone> {
        let listener = TcpListener::bind(("127.0.0.1", port)).await?;
        let addr = listener.local_addr()?;
        let (hello_tx, hellos) = mpsc::unbounded_channel();
        let (in_tx, inbound) = mpsc::unbounded_channel();
        // `broadcast`, not `mpsc`: the accept loop hands a receiver to every
        // connection, and an `mpsc::UnboundedReceiver` cannot be cloned.
        let (out_tx, _) = tokio::sync::broadcast::channel(64);

        // The tracker the accept loop subscribes from; `FakeIphone` keeps the
        // original so the caller can send.
        let out_tx_for_serve = out_tx.clone();
        tokio::spawn(async move {
            // A `Pending` reply needs a second, delayed `accepted`.
            while let Ok((stream, _)) = listener.accept().await {
                let cfg = config.clone();
                let hello_tx = hello_tx.clone();
                let in_tx = in_tx.clone();
                let out_rx = out_tx_for_serve.subscribe();
                tokio::spawn(async move {
                    serve(stream, cfg, hello_tx, in_tx, out_rx).await;
                });
            }
        });

        Ok(FakeIphone {
            addr,
            hellos,
            inbound,
            out_tx,
        })
    }

    /// **Phone-initiated**: dial a receiver's knock port instead of listening.
    ///
    /// Sends `hello` as the first frame (the real phone's `phoneHello`, kind
    /// `0x27`), then runs the *same* phone logic as [`start_on`] on that socket
    /// — the receiver answers with `clientHello` and the handshake proceeds with
    /// the roles unchanged. This is what lets the phone-initiated path be
    /// exercised against the shipped binary without a phone.
    pub async fn dial(
        config: FakeIphoneConfig,
        addr: SocketAddr,
        hello: Option<rc_protocol::PhoneHello>,
    ) -> std::io::Result<FakeIphone> {
        let mut stream = TcpStream::connect(addr).await?;
        if let Some(h) = hello {
            let frame = rc_protocol::encode_phone_hello(&h)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            stream.write_all(&frame).await?;
            stream.flush().await?;
        }
        let (hello_tx, hellos) = mpsc::unbounded_channel();
        let (in_tx, inbound) = mpsc::unbounded_channel();
        let (out_tx, _) = tokio::sync::broadcast::channel(64);
        let out_rx = out_tx.subscribe();
        tokio::spawn(async move {
            serve(stream, config, hello_tx, in_tx, out_rx).await;
        });
        Ok(FakeIphone {
            addr,
            hellos,
            inbound,
            out_tx,
        })
    }
}

/// Seal an outgoing frame if the session is sealed, else pass it through (F1).
/// The fake phone mirrors the real one: everything after the grant is sealed.
fn seal_out(sealer: &mut Option<rc_protocol::transport::Sealer>, frame: &[u8]) -> Vec<u8> {
    match sealer {
        Some(s) => rc_protocol::wire::seal_frame(frame, s),
        None => frame.to_vec(),
    }
}

async fn serve(
    mut stream: TcpStream,
    cfg: FakeIphoneConfig,
    hello_tx: mpsc::UnboundedSender<ClientHello>,
    in_tx: mpsc::UnboundedSender<Frame2>,
    mut out_rx: tokio::sync::broadcast::Receiver<Vec<u8>>,
) {
    let (mut rd, mut wr) = stream.split();
    let mut parser = rc_protocol::Parser::new();
    let mut buf = vec![0u8; 64 * 1024];

    // 1. Expect clientHello first.
    let mut hello: Option<ClientHello> = None;
    while hello.is_none() {
        let Ok(n) = rd.read(&mut buf).await else { return };
        if n == 0 {
            return;
        }
        for f in parser.append(&buf[..n]) {
            if f.kind == rc_protocol::Kind::ClientHello {
                hello = decode_client_hello(&f).ok();
            }
        }
    }
    let hello = hello.unwrap();
    // Cloned: the identity exchange below needs the hello's nonce and id.
    let _ = hello_tx.send(hello.clone());

    // 2. Reply.
    //
    // A phone that can prove itself does it *before* admitting the receiver:
    // it answers `pending` with its half of the challenge, waits for the
    // receiver's proof, checks it, and only then accepts. That order is the
    // whole point — the old protocol took a *presented* token as proof, and a
    // token on the wire is a badge anyone can copy.
    let secret = cfg.peer_auth_token.clone();
    let challenge = match (secret.as_deref(), hello.nonce.as_deref()) {
        (Some(secret), Some(client_nonce)) => {
            let server_nonce = rc_protocol::peer_auth::new_nonce();
            let mac = rc_protocol::peer_auth::server_mac(
                secret,
                &hello.id,
                client_nonce,
                &server_nonce,
            );
            Some((server_nonce, mac, client_nonce.to_string()))
        }
        _ => None,
    };

    // F1: when configured and this phone holds a token, both ends derive the
    // session key from that token + both handshake nonces and seal everything
    // after the grant. The version is advertised on the reply, the same place
    // the real phone advertises it. Cleartext otherwise.
    let transport_key: Option<[u8; 32]> = if cfg.transport {
        match (secret.as_deref(), hello.nonce.as_deref(), challenge.as_ref()) {
            (Some(secret), Some(client_nonce), Some((server_nonce, _, _))) => {
                Some(rc_protocol::transport::session_key(
                    secret,
                    client_nonce.as_bytes(),
                    server_nonce.as_bytes(),
                ))
            }
            _ => None,
        }
    } else {
        None
    };
    let transport_version = transport_key
        .as_ref()
        .map(|_| rc_protocol::transport::VERSION.to_string());
    let mut sealer: Option<rc_protocol::transport::Sealer> = None;
    let mut opener: Option<rc_protocol::transport::Opener> = None;

    // A phone in the middle of the exchange is `pending` by definition, whatever
    // the test asked for: it cannot accept until the receiver has answered.
    let result = if challenge.is_some() && cfg.reply == SessionReplyResult::Accepted {
        SessionReplyResult::Pending
    } else {
        cfg.reply
    };
    let reply = SessionReply {
        result,
        owner_name: if result == SessionReplyResult::Busy {
            Some("Another Mac".to_string())
        } else {
            None
        },
        token: if result == SessionReplyResult::Accepted {
            cfg.token.clone()
        } else {
            None
        },
        nonce: challenge.as_ref().map(|(n, _, _)| n.clone()),
        mac: challenge.as_ref().map(|(_, m, _)| m.clone()),
        capabilities: secret
            .as_ref()
            .map(|_| vec![rc_protocol::peer_auth::CAPABILITY.to_string()]),
        transport: transport_version.clone(),
    };
    if let Ok(frame) = encode_session_reply(&reply) {
        if wr.write_all(&frame).await.is_err() {
            return;
        }
    }

    if let Some((server_nonce, _, client_nonce)) = challenge {
        // 3. The receiver's proof, checked with the same secret. A wrong secret
        // here is an impostor, and the answer is `denied` — not a shrug.
        let expected =
            rc_protocol::peer_auth::client_mac(&secret.unwrap(), &hello.id, &client_nonce, &server_nonce);
        let mut proof_ok: Option<bool> = None;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        while proof_ok.is_none() {
            let read = tokio::time::timeout_at(deadline, rd.read(&mut buf)).await;
            let Ok(Ok(n)) = read else {
                eprintln!("[fakeiphone] challenge: no proof arrived before the deadline");
                return;
            };
            if n == 0 {
                eprintln!("[fakeiphone] challenge: the receiver hung up instead of proving itself");
                return;
            }
            for f in parser.append(&buf[..n]) {
                if f.kind == rc_protocol::Kind::ClientProof {
                    proof_ok = Some(
                        decode_client_proof(&f)
                            .map(|p| rc_protocol::peer_auth::matches(&expected, &p.mac))
                            .unwrap_or(false),
                    );
                }
            }
        }
        eprintln!("[fakeiphone] challenge: proof verified = {proof_ok:?}");
        let accepted = SessionReply {
            result: if proof_ok == Some(true) {
                SessionReplyResult::Accepted
            } else {
                SessionReplyResult::Denied
            },
            owner_name: None,
            // Issued only on the first pairing. Here the token was already
            // known to both sides, so there is nothing to hand over.
            token: None,
            // The accepted reply re-states the nonce + transport, exactly as
            // the real phone does — the receiver derives the key from them.
            nonce: Some(server_nonce.clone()),
            mac: None,
            capabilities: None,
            transport: transport_version.clone(),
        };
        if let Ok(frame) = encode_session_reply(&accepted) {
            let _ = wr.write_all(&frame).await;
        }
        if proof_ok != Some(true) {
            return;
        }
        // The grant is done: from here on the phone seals. Set the key the
        // instant the accepted reply is out, matching the real phone.
        if let Some(key) = transport_key {
            sealer = Some(rc_protocol::transport::Sealer::new(key));
            opener = Some(rc_protocol::transport::Opener::new(key));
            eprintln!("[fakeiphone] transport: sealed (aead-v1)");
        }
    } else if cfg.reply == SessionReplyResult::Pending {
        // Wait a moment, then accept (simulating the user tapping Allow).
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let accepted = SessionReply {
            result: SessionReplyResult::Accepted,
            owner_name: None,
            token: cfg.token.clone(),
            nonce: None,
            mac: None,
            capabilities: None,
            transport: None,
        };
        if let Ok(frame) = encode_session_reply(&accepted) {
            let _ = wr.write_all(&frame).await;
        }
    } else if cfg.reply != SessionReplyResult::Accepted {
        return;
    }

    // 3. Send metadata + a feature-state snapshot.
    if cfg.send_metadata {
        let md = StreamMetadata {
            version: 1,
            device_name: "Fake iPhone".to_string(),
            width: 1920,
            height: 1080,
            fps: 30,
            bitrate_bps: 4_000_000,
            codec: "h264".to_string(),
            sps: None,
            pps: None,
        };
        if let Ok(frame) = encode_metadata(&md) {
            let _ = wr.write_all(&seal_out(&mut sealer, &frame)).await;
        }
        let snap = FeatureStateSnapshot {
            camera_on: true,
            mic_on: false,
            voice_on: false,
            trackpad_on: true,
            keyboard_on: true,
            active_surface: Surface::Trackpad,
            camera_position: rc_protocol::CameraPosition::Back,
            screen_on: false,
            speaker_on: false,
            timestamp_micros: 123,
        };
        if let Ok(frame) = encode_feature_state(&snap) {
            let _ = wr.write_all(&seal_out(&mut sealer, &frame)).await;
        }
    }

    // 3b. Stream real H.264 (for the preview self-test).
    if cfg.stream_video && cfg.video_frames > 0 {
        let nals = encode_test_video(cfg.video_frames, 320, 180);
        for (i, nal) in nals.into_iter().enumerate() {
            // NAL type is the low 5 bits of the first byte.
            let nal_type = nal.first().map(|b| b & 0x1F).unwrap_or(1);
            let kind = match nal_type {
                7 => NalKind::Sps,
                8 => NalKind::Pps,
                _ => NalKind::Video,
            };
            let frame = encode_nal(&NalFrame {
                kind,
                data: nal,
                timestamp_micros: 0,
            });
            if wr.write_all(&seal_out(&mut sealer, &frame)).await.is_err() {
                return;
            }
            // Pace the stream roughly like the real 30 fps sender.
            tokio::time::sleep(std::time::Duration::from_millis(33)).await;
            // Vanish mid-stream, the way a phone walking out of range does.
            if cfg.drop_after_frames.is_some_and(|n| i + 1 >= n) {
                return;
            }
        }
    }

    // 4. Echo pings, forward receiver frames, and send whatever the caller
    //    queues with `FakeIphone::send`.
    loop {
        tokio::select! {
            read = rd.read(&mut buf) => {
                let Ok(n) = read else { break };
                if n == 0 {
                    break;
                }
                for raw in parser.append(&buf[..n]) {
            // F1: open sealed payloads once the transport is on. The handshake
            // frames above were read in the clear, before the grant.
            let f = match opener.as_mut() {
                Some(o) => match rc_protocol::wire::open_frame(raw, o) {
                    Ok(opened) => opened,
                    Err(_) => continue,
                },
                None => raw,
            };
            match f.kind {
                rc_protocol::Kind::Ping if cfg.echo_pings => {
                    let sent = decode_ping(&f);
                    let echo = encode_ping(sent);
                    if wr.write_all(&seal_out(&mut sealer, &echo)).await.is_err() {
                        return;
                    }
                }
                rc_protocol::Kind::FeatureControl => {
                    if let Ok(fc) = decode_feature_control(&f) {
                        let _ = in_tx.send(Frame2::FeatureControl(fc));
                    }
                }
                rc_protocol::Kind::Touch => {
                    if let Ok(t) = decode_touch(&f) {
                        let _ = in_tx.send(Frame2::Touch(t));
                    }
                }
                rc_protocol::Kind::Key => {
                    if let Ok(k) = decode_key(&f) {
                        let _ = in_tx.send(Frame2::Key(k));
                    }
                }
                rc_protocol::Kind::Ping => {
                    // The ping payload is a raw 8-byte big-endian timestamp.
                    if f.payload.len() >= 8 {
                        let mut b = [0u8; 8];
                        b.copy_from_slice(&f.payload[..8]);
                        let _ = in_tx.send(Frame2::Ping(u64::from_be_bytes(b)));
                    }
                }
                rc_protocol::Kind::Notification => {
                    if let Ok(n) = rc_protocol::decode_notification(&f) {
                        let _ = in_tx.send(Frame2::Notification(n));
                    }
                }
                rc_protocol::Kind::CommandResult => {
                    if let Ok(r) = rc_protocol::decode_command_result(&f) {
                        let _ = in_tx.send(Frame2::CommandResult(r));
                    }
                }
                rc_protocol::Kind::ClientHello => {
                    if let Ok(h) = decode_client_hello(&f) {
                        let _ = in_tx.send(Frame2::ClientHello(h));
                    }
                }
                other => {
                    let _ = in_tx.send(Frame2::Other(other as u8));
                }
            }
                }
            }
            // An `Err` means every sender is gone, which disables this branch
            // rather than ending the connection: the receiver may keep talking
            // after the test stopped sending.
            Ok(frame) = out_rx.recv() => {
                if std::env::var("RC_TESTKIT_TRACE").is_ok() {
                    eprintln!("[testkit] sending {} bytes to the receiver", frame.len());
                }
                if wr.write_all(&seal_out(&mut sealer, &frame)).await.is_err() {
                    return;
                }
            }
        }
    }
}

/// Convenience: build a one-frame video NAL burst (no real codec — the
/// payload is arbitrary bytes; receivers in tests just count frames).
pub fn fake_video_frames(count: usize) -> Vec<Vec<u8>> {
    (0..count)
        .map(|i| {
            encode_nal(&NalFrame {
                kind: NalKind::Video,
                data: vec![i as u8; 64],
                timestamp_micros: i as u64 * 33_000,
            })
        })
        .collect()
}

/// Encode a moving test pattern to real H.264 (Annex-B) using OpenH264, so
/// the `--selftest` path can exercise the *real* decode→render pipeline
/// without a phone. Returns individual NAL payloads (start codes stripped,
/// matching what the iOS encoder puts on the wire).
pub fn encode_test_video(frames: usize, width: usize, height: usize) -> Vec<Vec<u8>> {
    use openh264::encoder::Encoder;
    use openh264::formats::{RgbSliceU8, YUVBuffer};

    let mut encoder = match Encoder::new() {
        Ok(e) => e,
        Err(_) => return Vec::new(),
    };

    let mut nals = Vec::new();
    for f in 0..frames {
        // A moving vertical bar + colour gradient so the picture visibly changes.
        let mut rgb = vec![0u8; width * height * 3];
        for y in 0..height {
            for x in 0..width {
                let bar = ((x + f * 8) % width) < (width / 8);
                let idx = (y * width + x) * 3;
                if bar {
                    rgb[idx] = 250;
                    rgb[idx + 1] = 80;
                    rgb[idx + 2] = 40;
                } else {
                    let v = ((x * 255 / width) as u8).saturating_add(40);
                    rgb[idx] = v;
                    rgb[idx + 1] = (v / 2).saturating_add(60);
                    rgb[idx + 2] = 200u8.saturating_sub((x * 120 / width) as u8);
                }
            }
        }
        let yuv = YUVBuffer::from_rgb8_source(RgbSliceU8::new(&rgb, (width, height)));
        if let Ok(bitstream) = encoder.encode(&yuv) {
            nals.extend(split_annexb_public(&bitstream.to_vec()));
        }
    }
    nals
}

/// Split an Annex-B stream into NAL payloads (start codes removed).
pub fn split_annexb_public(data: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut i = 0;
    let mut start: Option<usize> = None;
    while i + 3 <= data.len() {
        let three = data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1;
        let four = i + 4 <= data.len()
            && data[i] == 0
            && data[i + 1] == 0
            && data[i + 2] == 0
            && data[i + 3] == 1;
        if three || four {
            if let Some(s) = start {
                if i > s {
                    out.push(data[s..i].to_vec());
                }
            }
            i += if three { 3 } else { 4 };
            start = Some(i);
        } else {
            i += 1;
        }
    }
    if let Some(s) = start {
        if s < data.len() {
            out.push(data[s..].to_vec());
        }
    }
    out
}

/// Convenience: a single touch frame.
pub fn touch_frame(phase: TouchPhase) -> Vec<u8> {
    encode_touch(&TouchEvent {
        phase,
        x: 0.5,
        y: 0.5,
        dx: 0.01,
        dy: 0.01,
        modifiers: 0,
        momentum: None,
        timestamp_micros: 0,
    })
    .unwrap()
}

/// Convenience: a metadata frame.
pub fn metadata_frame(device_name: &str) -> Vec<u8> {
    encode_metadata(&StreamMetadata {
        version: 1,
        device_name: device_name.to_string(),
        width: 1280,
        height: 720,
        fps: 30,
        bitrate_bps: 2_000_000,
        codec: "h264".to_string(),
        sps: None,
        pps: None,
    })
    .unwrap()
}
