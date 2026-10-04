//! Forensic probe: is the corruption in the *pixels* or in the *rendering*?
//!
//! The preview window showed heavy coloured speckle and horizontal streaks on a
//! 1080x1920 stream. Two very different bugs produce that picture:
//!
//!   * the decoded pixels are already wrong (transport, decoder, or the phone's
//!     encoder at a very low bitrate), or
//!   * the pixels are fine and the renderer is mis-laying them out (stride,
//!     row pitch, a buffer reused across sizes).
//!
//! A screenshot cannot tell those apart, so this does: it decodes the same live
//! stream and reports per-frame statistics that a healthy image cannot produce —
//! saturated pixels, huge neighbour-to-neighbour deltas, per-channel imbalance.
//!
//! It never opens a window and never touches the virtual camera, so what it
//! reports is the wire and the decoder, nothing else.

use std::collections::HashMap;

use rc_protocol::{Kind, Parser};
use rc_render::PreviewPipeline;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Per-frame health. Thresholds are deliberately loose — this is looking for
/// "obviously broken", not grading quality.
#[derive(Default)]
struct Stats {
    frames: u64,
    /// Pixels where any channel is 0 or 255 — a healthy video of a desk scene
    /// has some, but not many, and never in runs.
    saturated: u64,
    /// Horizontal neighbour deltas above 90. Clean video has edges; a corrupted
    /// frame has edges *everywhere*.
    harsh_h: u64,
    /// Same, vertically. Vertical streaks in the screenshot point here.
    harsh_v: u64,
    /// How many distinct rows look like a flat single colour — the horizontal
    /// banding signature.
    flat_rows: u64,
    /// Per-channel means, to catch a channel that is stuck or swapped.
    sum_r: u64,
    sum_g: u64,
    sum_b: u64,
}

impl Stats {
    fn add(&mut self, pixels: &[u32], w: u32, h: u32) {
        self.frames += 1;
        let (w, h) = (w as usize, h as usize);
        let at = |x: usize, y: usize| -> (u8, u8, u8) {
            let p = pixels[y * w + x];
            (((p >> 16) & 0xff) as u8, ((p >> 8) & 0xff) as u8, (p & 0xff) as u8)
        };
        for y in 0..h {
            let mut flat = true;
            let first = at(0, y);
            for x in 0..w {
                let (r, g, b) = at(x, y);
                if r == 0 || r == 255 || g == 0 || g == 255 || b == 0 || b == 255 {
                    self.saturated += 1;
                }
                if (r, g, b) != first {
                    flat = false;
                }
                self.sum_r += r as u64;
                self.sum_g += g as u64;
                self.sum_b += b as u64;
                if x > 0 {
                    let (pr, pg, pb) = at(x - 1, y);
                    let d = (r as i32 - pr as i32).abs()
                        + (g as i32 - pg as i32).abs()
                        + (b as i32 - pb as i32).abs();
                    if d > 90 {
                        self.harsh_h += 1;
                    }
                }
                if y > 0 {
                    let (ur, ug, ub) = at(x, y - 1);
                    let d = (r as i32 - ur as i32).abs()
                        + (g as i32 - ug as i32).abs()
                        + (b as i32 - ub as i32).abs();
                    if d > 90 {
                        self.harsh_v += 1;
                    }
                }
            }
            if flat {
                self.flat_rows += 1;
            }
        }
    }

    fn report(&self, w: u32, h: u32) {
        let px = (w as u64) * (h as u64);
        if px == 0 {
            return;
        }
        let pct = |n: u64| 100.0 * n as f64 / px as f64;
        let n = self.frames.max(1);
        println!("  frames analysed   : {}", self.frames);
        println!("  geometry          : {w}x{h}");
        println!(
            "  saturated pixels  : {:.2}%   (healthy desk scene: well under 1%)",
            pct(self.saturated / n)
        );
        println!(
            "  harsh horizontal  : {:.2}%   (edges only: under 2%)",
            pct(self.harsh_h / n)
        );
        println!(
            "  harsh vertical    : {:.2}%   (edges only: under 2%)",
            pct(self.harsh_v / n)
        );
        println!(
            "  flat rows         : {:.2}%   (banding signature: under 5%)",
            pct(self.flat_rows / n)
        );
        let (r, g, b) = (self.sum_r, self.sum_g, self.sum_b);
        let total = (r + g + b).max(1);
        println!(
            "  channel balance   : R {:.1}%  G {:.1}%  B {:.1}%",
            100.0 * r as f64 / total as f64,
            100.0 * g as f64 / total as f64,
            100.0 * b as f64 / total as f64
        );
        if pct(self.harsh_h / n) > 8.0 || pct(self.harsh_v / n) > 8.0 {
            println!("  VERDICT           : pixels are corrupt — the fault is upstream of the renderer");
        } else {
            println!("  VERDICT           : pixels look healthy — the fault is in the renderer");
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut addr = "127.0.0.1:8765".to_string();
    let mut seconds: u64 = 20;
    let mut argv = std::env::args().skip(1);
    while let Some(a) = argv.next() {
        match a.as_str() {
            "--connect" => addr = argv.next().ok_or("--connect needs an address")?,
            "--seconds" => {
                let v = argv.next().ok_or("--seconds needs a number")?;
                seconds = v.parse()?;
            }
            other => return Err(format!("unexpected argument {other:?}").into()),
        }
    }

    println!("rc-vcam-forensics — connecting to {addr}");
    let mut stream = tokio::net::TcpStream::connect(&addr).await?;
    let (mut rd, mut wr) = stream.split();

    // The framing is `[4-byte BE length][1-byte kind][payload]` and the handshake
// payload is JSON with required fields — hand-rolling either produces a frame
// the phone silently ignores, which looks exactly like "the probe is broken".
let hello = rc_protocol::wire::encode_client_hello(&rc_protocol::ClientHello {
        name: "forensics".into(),
        id: "forensics".into(),
        token: None,
        app_version: "0".into(),
        platform: Some("windows".into()),
    })
    .map_err(|e| format!("encode_client_hello: {e}"))?;
    wr.write_all(&hello).await?;
    println!("  handshake sent ({} bytes); decoding for {seconds}s", hello.len());

    let mut pipeline = PreviewPipeline::new()?;
    let mut parser = Parser::new();
    let mut stats = Stats::default();
    let mut buf = vec![0u8; 64 * 1024];
    let mut kinds: HashMap<u8, u64> = HashMap::new();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(seconds);

    while tokio::time::Instant::now() < deadline {
        let n = match tokio::time::timeout(
            std::time::Duration::from_millis(500),
            rd.read(&mut buf),
        )
        .await
        {
            Ok(Ok(0)) | Ok(Err(_)) => break,
            Ok(Ok(n)) => n,
            Err(_) => continue,
        };
        for f in parser.append(&buf[..n]) {
            *kinds.entry(f.kind as u8).or_default() += 1;
            match f.kind {
                // The handshake result decides everything that follows, and a
                // probe that silently reports "0 frames" without saying "the
                // phone is waiting for you to tap Allow" wastes the reader's
                // time instead of theirs.
                Kind::SessionReply => match rc_protocol::wire::decode_session_reply(&f) {
                    Ok(r) => println!("  sessionReply: {:?}", r.result),
                    Err(e) => println!("  sessionReply arrived but would not decode: {e}"),
                },
                Kind::FeatureState => {
                    // The single most useful thing this probe can say. A phone
                    // whose camera switch is off sends sps/pps and heartbeats and
                    // no video at all, which is indistinguishable from a decoder
                    // problem unless you read the flag. It is the first thing to
                    // check before blaming any of the code below.
                    if let Ok(s) = rc_protocol::wire::decode_feature_state(&f) {
                        println!(
                            "  featureState: camera_on={} mic_on={} position={:?}",
                            s.camera_on, s.mic_on, s.camera_position
                        );
                    }
                }
                Kind::Video | Kind::Sps | Kind::Pps => {
                    let kind = match f.kind {
                        Kind::Sps => rc_protocol::NalKind::Sps,
                        Kind::Pps => rc_protocol::NalKind::Pps,
                        _ => rc_protocol::NalKind::Video,
                    };
                    let pushed = pipeline.push(&rc_protocol::NalFrame {
                        kind,
                        data: f.payload.clone(),
                        timestamp_micros: 0,
                    });
                    if pushed {
                        if let Some(frame) = pipeline.latest() {
                            stats.add(&frame.pixels, frame.width, frame.height);
                        }
                    }
                }
                _ => {
                    let _ = f;
                }
            }
        }
    }

    println!("\nframes seen by kind:");
    let mut v: Vec<_> = kinds.into_iter().collect();
    v.sort();
    for (k, c) in v {
        let name = match k {
            0x00 => "metadata",
            0x01 => "video",
            0x02 => "sps",
            0x03 => "pps",
            0x04 => "touch",
            0x10 => "ping",
            0x13 => "featureState",
            _ => "other",
        };
        println!("  0x{k:02X} {name:<12} {c}");
    }
    println!("\ndecoded {} frame(s), refused {}", pipeline.frames_decoded(), pipeline.refused());
    if let Some(e) = pipeline.last_error() {
        println!("  last decoder error: {e}");
    }
    let (w, h) = pipeline.dimensions();
    println!();
    stats.report(w, h);
    Ok(())
}