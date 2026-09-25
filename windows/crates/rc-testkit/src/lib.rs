//! `rc-testkit` — a fake iPhone.
//!
//! Speaks the exact receiver-role protocol the real iOS app does, so the
//! whole handshake / ping / streaming / pairing path can be exercised
//! without a phone or a Mac. Used by `rc-net` integration tests and by the
//! app's "demo" mode.

use std::net::SocketAddr;

use rc_protocol::{
    decode_client_hello, decode_feature_control, decode_key, decode_ping, decode_touch,
    encode_feature_state, encode_metadata, encode_nal, encode_ping, encode_session_reply,
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
}

/// A lightly-typed view of a frame the receiver sent us.
#[derive(Debug, Clone)]
pub enum Frame2 {
    ClientHello(ClientHello),
    FeatureControl(rc_protocol::FeatureControl),
    Touch(TouchEvent),
    Key(KeyEvent),
    Other(u8),
}

impl FakeIphone {
    /// Bind on a random localhost port and serve one connection.
    pub async fn start(config: FakeIphoneConfig) -> std::io::Result<FakeIphone> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        let (hello_tx, hellos) = mpsc::unbounded_channel();
        let (in_tx, inbound) = mpsc::unbounded_channel();

        tokio::spawn(async move {
            // A `Pending` reply needs a second, delayed `accepted`.
            while let Ok((stream, _)) = listener.accept().await {
                let cfg = config.clone();
                let hello_tx = hello_tx.clone();
                let in_tx = in_tx.clone();
                tokio::spawn(async move {
                    serve(stream, cfg, hello_tx, in_tx).await;
                });
            }
        });

        Ok(FakeIphone {
            addr,
            hellos,
            inbound,
        })
    }
}

async fn serve(
    mut stream: TcpStream,
    cfg: FakeIphoneConfig,
    hello_tx: mpsc::UnboundedSender<ClientHello>,
    in_tx: mpsc::UnboundedSender<Frame2>,
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
    let _ = hello_tx.send(hello);

    // 2. Reply.
    let reply = SessionReply {
        result: cfg.reply,
        owner_name: if cfg.reply == SessionReplyResult::Busy {
            Some("Another Mac".to_string())
        } else {
            None
        },
        token: if cfg.reply == SessionReplyResult::Accepted {
            cfg.token.clone()
        } else {
            None
        },
    };
    if let Ok(frame) = encode_session_reply(&reply) {
        if wr.write_all(&frame).await.is_err() {
            return;
        }
    }

    if cfg.reply == SessionReplyResult::Pending {
        // Wait a moment, then accept (simulating the user tapping Allow).
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let accepted = SessionReply {
            result: SessionReplyResult::Accepted,
            owner_name: None,
            token: cfg.token.clone(),
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
            let _ = wr.write_all(&frame).await;
        }
        let snap = FeatureStateSnapshot {
            camera_on: true,
            mic_on: false,
            voice_on: false,
            trackpad_on: true,
            keyboard_on: true,
            active_surface: Surface::Trackpad,
            camera_position: rc_protocol::CameraPosition::Back,
            timestamp_micros: 123,
        };
        if let Ok(frame) = encode_feature_state(&snap) {
            let _ = wr.write_all(&frame).await;
        }
    }

    // 3b. Stream real H.264 (for the preview self-test).
    if cfg.stream_video && cfg.video_frames > 0 {
        let nals = encode_test_video(cfg.video_frames, 320, 180);
        for nal in nals {
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
            if wr.write_all(&frame).await.is_err() {
                return;
            }
            // Pace the stream roughly like the real 30 fps sender.
            tokio::time::sleep(std::time::Duration::from_millis(33)).await;
        }
    }

    // 4. Echo pings + forward receiver frames until the socket closes.
    while let Ok(n) = rd.read(&mut buf).await {
        if n == 0 {
            break;
        }
        for f in parser.append(&buf[..n]) {
            match f.kind {
                rc_protocol::Kind::Ping if cfg.echo_pings => {
                    let sent = decode_ping(&f);
                    let echo = encode_ping(sent);
                    if wr.write_all(&echo).await.is_err() {
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
