//! Forensic probe: is the corruption in the *pixels* or upstream of them?
//!
//! The preview window showed heavy coloured speckle and horizontal streaks on a
//! 1080x1920 stream. Two very different bugs produce that picture:
//!
//! * the phone encoded at too low a bitrate, so *every* frame is a bit soft
//!   and a bit blocky — nothing on this machine is broken; or
//! * individual frames are garbage and the next frame is fine again — a
//!   reference frame went missing between the camera and the decoder.
//!
//! The second one is the expensive mistake to make in either direction, because
//! a screenshot cannot tell them apart and a fixed threshold cannot either.
//!
//! # Why this tool has no magic threshold
//!
//! Its earlier version called a frame "corrupt" when more than 8% of its
//! horizontal neighbour pairs were high-contrast, and called a stream corrupt
//! when that averaged over 8%. That number was measured on a flat synthetic
//! pattern, and it is simply wrong for real video: `renderer_fidelity` — which
//! pushes a *provably* flawless 1080x1920 stream through this same decoder and
//! this same blit and confirms every stage is byte-faithful — measures
//! **12.31%** on a clean stream, because a real high-contrast scene simply has
//! that many edges. The old rule would have blamed the phone for a renderer bug
//! that does not exist, and it would have been believed, because the tool
//! prints a verdict in capitals.
//!
//! So the comparison is against the stream itself. See `rc_render::pixels`:
//! a uniform picture and a picture with lost reference frames are told apart by
//! whether a *few* frames tower over the stream's own median, not by whether
//! the whole stream is busy.
//!
//! It never opens a window and never touches the virtual camera, so what it
//! reports is the wire and the decoder, nothing else.

use std::collections::HashMap;
use std::time::Instant;

use rc_protocol::{Kind, Parser};
use rc_render::pixels::{harsh_h_percent, Pattern, StreamHealth};
use rc_render::PreviewPipeline;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// NAL unit types, from the low 5 bits of the header byte. Only the keyframe
/// type is named: every other slice is "a predicted frame", and naming the
/// ones this tool does not act on would only invite someone to act on them.
const NAL_IDR: u8 = 5;

/// How many times to retry a refused TCP connection before giving up. The
/// phone's listener comes and goes; 15 tries at two seconds covers a couple of
/// minutes of it being in the wrong state.
const CONNECT_ATTEMPTS: u32 = 15;

/// What arrived, counted as the receiver saw it. Every field here is a fact
/// about the wire; none of them is an inference.
#[derive(Default)]
struct Wire {
    video_nals: u64,
    sps: u64,
    pps: u64,
    idr_nals: u64,
    /// True once a keyframe has actually produced a picture. Its absence, when
    /// keyframes did arrive, is the one decoder fault that is not the network's.
    any_idr_decoded: bool,
    /// True once a keyframe has actually produced a picture.
    /// Video NALs the decoder produced no picture from, *after* the stream had
    /// already produced one. A decoder fed a P-slice with no reference behaves
    /// exactly this way, and it is the single most direct evidence of frame
    /// loss — the old probe could not see it at all, because it only counted
    /// kinds and every video NAL is the same kind.
    no_output_after_start: u64,
    bytes_total: u64,
    bytes_smallest: u64,
    bytes_largest: u64,
    /// Every video NAL size, for the distribution.
    sizes: Vec<u64>,
    /// Seconds actually observed, kept so the keyframe gap can be reported
    /// without re-deriving it from a possibly different elapsed time.
    gap_secs: f64,
}

impl Wire {
    fn note_video(&mut self, bytes: usize) {
        self.video_nals += 1;
        self.bytes_total += bytes as u64;
        self.sizes.push(bytes as u64);
        if self.bytes_largest == 0 || bytes as u64 > self.bytes_largest {
            self.bytes_largest = bytes as u64;
        }
        if self.bytes_smallest == 0 || (bytes as u64) < self.bytes_smallest {
            self.bytes_smallest = bytes as u64;
        }
    }

    /// Total stream rate, in the same kbps the receiver's status line prints,
    /// so the number here and the number there can be compared directly.
    fn kbps(&self, seconds: f64) -> f64 {
        if seconds <= 0.0 {
            return 0.0;
        }
        self.bytes_total as f64 * 8.0 / 1000.0 / seconds
    }

    /// Average seconds between keyframes, which the phone sets as
    /// `MaxKeyFrameInterval`.
    fn keyframe_gap_secs(&self) -> f64 {
        if self.idr_nals == 0 {
            return f64::INFINITY;
        }
        self.gap_secs / self.idr_nals as f64
    }
}

fn kind_name(k: u8) -> &'static str {
    match k {
        0x00 => "metadata",
        0x01 => "video",
        0x02 => "sps",
        0x03 => "pps",
        0x04 => "touch",
        0x05 => "key",
        0x06 => "audio",
        0x07 => "featureControl",
        0x08 => "featureState",
        0x09 => "ping",
        0x0A => "clientHello",
        0x0B => "sessionReply",
        0x0C => "appList",
        0x0F => "fileOffer",
        0x10 => "fileChunk",
        0x13 => "clipboardSet",
        0x19 => "systemCommand",
        0x24 => "speakerAudio",
        _ => "other",
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
    // The phone's listener is intermittent: measured on a real iPhone it
    // refused, accepted, then refused again within a minute. A tool that exits
    // on the first refusal turns a two-second retry into twenty minutes of
    // re-typing the command, and the failure looks like the tool is broken
    // rather than like the phone is between states.
    let mut stream = None;
    for attempt in 1..=CONNECT_ATTEMPTS {
        match tokio::net::TcpStream::connect(&addr).await {
            Ok(s) => {
                if attempt > 1 {
                    println!("  connected on attempt {attempt}");
                }
                stream = Some(s);
                break;
            }
            Err(e) => {
                if attempt == CONNECT_ATTEMPTS {
                    eprintln!(
                        "could not connect to {addr} after {attempt} attempts: {e}\n\
                         Is the app in the foreground on the same WiFi? The listener only runs \
                         while it is streaming."
                    );
                    std::process::exit(1);
                }
                println!("  attempt {attempt} refused ({e}); retrying");
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
        }
    }
    // `into_split`, not `split`: the latter resolves to `tokio::io::split`, whose
    // halves borrow the stream and so cannot outlive this binding.
    let s = stream.expect("connected above");
    let (mut rd, mut wr) = s.into_split();

    // The framing is `[4-byte BE length][1-byte kind][payload]` and the handshake
    // payload is JSON with required fields — hand-rolling either produces a frame
    // the phone silently ignores, which looks exactly like "the probe is broken".
    let hello = rc_protocol::wire::encode_client_hello(&rc_protocol::ClientHello {
        name: "forensics".into(),
        id: "forensics".into(),
        token: None,
        app_version: "0".into(),
        platform: Some("windows".into()),
        // What this probe can actually answer — deliberately not the identity
        // exchange. A probe that claimed `peerAuth` would be sent a challenge it
        // cannot complete and would never see a frame, which is the opposite of
        // what it is for.
        capabilities: Some(vec![
            "latencyProbe".to_string(),
            "commandResult".to_string(),
        ]),
        nonce: None,
    })
    .map_err(|e| format!("encode_client_hello: {e}"))?;
    wr.write_all(&hello).await?;
    println!("  handshake sent ({} bytes); decoding for {seconds}s", hello.len());
    println!("  (the phone treats this as a new computer and will ask you to allow it)");

    let mut pipeline = PreviewPipeline::new()?;
    let mut parser = Parser::new();
    let mut health = StreamHealth::new();
    let mut wire = Wire::default();
    let mut kinds: HashMap<u8, u64> = HashMap::new();
    let mut buf = vec![0u8; 64 * 1024];

    // For each decoded frame, the NAL type that produced it — so a spike can be
    // attributed to an IDR or to a P-slice. This is the whole point: corruption
    // that lands on P-frames and clears after an IDR is a lost reference frame,
    // and nothing else looks like that.
    let mut frame_source: Vec<u8> = Vec::new();
    let mut camera_on = None;
    // Kept for the no-frames verdict, which has to name the blocker rather than
    // describe the symptom.
    let mut session_reply: Option<rc_protocol::SessionReplyResult> = None;
    // The phone already names the computer holding the stream. Discarding it is
    // why this has been so expensive: the symptom is one word, `busy`, and the
    // only way to tell *which* machine to go and quit was to already know.
    let mut session_owner: Option<String> = None;
    // (width, height, fps) as advertised in the stream metadata.
    let mut advertised: Option<(u32, u32, u32)> = None;
    let mut advertised_kbps: Option<f64> = None;
    let mut started = false;

    let t0 = Instant::now();
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
                    Ok(r) => {
                        println!("  sessionReply: {:?}", r.result);
                        if let Some(owner) = &r.owner_name {
                            println!("    held by: {owner}");
                            session_owner = Some(owner.clone());
                        }
                        session_reply = Some(r.result);
                    }
                    Err(e) => println!("  sessionReply arrived but would not decode: {e}"),
                },
                Kind::FeatureState => {
                    // The single most useful thing this probe can say. A phone
                    // whose camera switch is off sends sps/pps and heartbeats and
                    // no video at all, which is indistinguishable from a decoder
                    // problem unless you read the flag. It is the first thing to
                    // check before blaming any of the code below.
                    if let Ok(s) = rc_protocol::wire::decode_feature_state(&f) {
                        camera_on = Some(s.camera_on);
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
                    match kind {
                        rc_protocol::NalKind::Sps => wire.sps += 1,
                        rc_protocol::NalKind::Pps => wire.pps += 1,
                        rc_protocol::NalKind::Video => {
                            wire.note_video(f.payload.len());
                            let nal_type = f.payload.first().map(|b| b & 0x1F).unwrap_or(0);
                            if nal_type == NAL_IDR {
                                wire.idr_nals += 1;
                            }
                        }
                    }

                    let pushed = pipeline.push(&rc_protocol::NalFrame {
                        kind,
                        data: f.payload.clone(),
                        timestamp_micros: 0,
                    });
                    if pushed {
                        if let Some(frame) = pipeline.latest() {
                            health.add(frame);
                            let nal_type = f.payload.first().map(|b| b & 0x1F).unwrap_or(0);
                            frame_source.push(nal_type);
                            if nal_type == NAL_IDR {
                                wire.any_idr_decoded = true;
                            }
                        }
                        started = true;
                    } else if started && kind == rc_protocol::NalKind::Video {
                        wire.no_output_after_start += 1;
                    }
                }
                Kind::Metadata => {
                    // What the phone *promised*. Held so the wire facts can be
                    // checked against it: a stream can decode cleanly and still
                    // be a small fraction of the one that was requested, which
                    // is a separate fault from a corrupt picture.
                    if let Ok(m) = rc_protocol::wire::decode_metadata(&f) {
                        println!(
                            "  metadata: {}x{} @ {}fps, claims {} kbps, codec {}",
                            m.width,
                            m.height,
                            m.fps,
                            m.bitrate_bps / 1000,
                            m.codec
                        );
                        advertised = Some((
                            m.width.max(0) as u32,
                            m.height.max(0) as u32,
                            m.fps.max(0) as u32,
                        ));
                        advertised_kbps = Some(m.bitrate_bps as f64 / 1000.0);
                    }
                }
                _ => {
                    let _ = f;
                }
            }
        }
    }

    let elapsed = t0.elapsed().as_secs_f64().max(0.001);
    wire.gap_secs = elapsed;
    let decoded = pipeline.frames_decoded();

    println!("\nframes seen by kind:");
    let mut v: Vec<_> = kinds.into_iter().collect();
    v.sort();
    for (k, c) in v {
        println!("  0x{k:02X} {:<15} {}", kind_name(k), c);
    }

    println!("\nthe wire:");
    println!("  sps / pps              : {} / {}", wire.sps, wire.pps);
    println!("  video NALs received    : {}", wire.video_nals);
    println!("  of those, keyframes    : {}", wire.idr_nals);
    println!(
        "  keyframe every         : {:.2}s on average",
        if wire.idr_nals == 0 {
            f64::INFINITY
        } else {
            elapsed / wire.idr_nals as f64
        }
    );
    println!(
        "  video bytes            : avg {}  min {}  max {}",
        wire.bytes_total.checked_div(wire.video_nals).unwrap_or(0),
        wire.bytes_smallest,
        wire.bytes_largest
    );
    println!(
        "  stream rate            : {:.0} kbps  (the receiver's own status line prints this)",
        wire.kbps(elapsed)
    );
    println!(
        "  frames decoded         : {decoded}  ({:.1} fps, wall clock)",
        decoded as f64 / elapsed
    );
    println!("  NALs refused           : {}", pipeline.refused());
    if let Some(e) = pipeline.last_error() {
        println!("  last decoder error     : {e}");
    }

    if decoded == 0 {
        println!("\nVERDICT: nothing decoded — there is no picture to judge.");
        // Name the blocker rather than the symptom. "Busy" is the single most common
        // reason this probe produces nothing, it has cost more time than any
        // actual bug in this file, and it is invisible from the outside: the
        // phone is streaming happily to a *different* client.
        //
        // A fact the probe actually observed outranks the handshake status, so
        // `camera_on=false` is reported as itself rather than as "accepted,
        // then nothing, check the camera switch".
        if camera_on == Some(false) {
            println!();
            println!("  THE CAMERA IS OFF ON THE PHONE — this is the whole answer.");
            println!("  The phone sends sps/pps and heartbeats anyway, so it looks like a");
            println!("  stream: metadata, one sps, one pps, pings, touches, and no video.");
            println!("  Turn the camera on in the app and re-run. Nothing about the decoder,");
            println!("  the renderer or the network can be judged until it is.");
            return Ok(());
        }
        match session_reply {
            Some(rc_protocol::SessionReplyResult::Busy) => {
                println!();
                println!("  THE PHONE IS HELD BY ANOTHER COMPUTER.");
                match &session_owner {
                    Some(name) => println!("  The phone says the owner is: {name}"),
                    None => println!(
                        "  The phone did not say who. Open the pairing list on the phone — it\n  \
                         shows the same thing."
                    ),
                }
                println!("  Go and QUIT RemoteCrab on that machine. Do not just disconnect it:");
                println!("  it reconnects and takes the phone back within seconds, which is how");
                println!("  three separate sessions lost this measurement. Every reading taken");
                println!("  while the phone is held is of nothing, including this one.");
            }
            Some(rc_protocol::SessionReplyResult::Pending) => {
                println!();
                println!("  The phone is waiting for you to approve this probe. It treats it as a");
                println!("  new computer, so tap Allow on the phone, then re-run.");
            }
            Some(rc_protocol::SessionReplyResult::Denied) => {
                println!();
                println!("  The phone refused this probe. Remove it from the paired computers on");
                println!("  the phone and try again.");
            }
            Some(rc_protocol::SessionReplyResult::Off) => {
                println!();
                println!("  The phone has this computer switched OFF — its user tapped Disconnect");
                println!("  for it. Not a refusal: pick this computer again on the phone's");
                println!("  \"choose a computer\" screen and re-run.");
            }
            Some(rc_protocol::SessionReplyResult::Accepted) => {
                println!();
                println!("  The phone accepted this probe, then sent no video. That is a different");
                println!("  fault from being refused: check the camera switch, and check whether");
                println!("  the app is actually streaming rather than sitting on the home screen.");
            }
            None => {
                if camera_on.is_none() {
                    println!();
                    println!("  No handshake reply and no featureState arrived at all. The app is");
                    println!("  probably not streaming — check it is in the foreground.");
                }
            }
        }
        return Ok(());
    }

    // The measurement that matters most, and the one the old probe could not
    // make: a P-slice arriving when the decoder has nothing to predict from.
    if wire.no_output_after_start > 0 {
        println!(
            "\n  ** {} video NAL(s) produced no picture after the stream had started.",
            wire.no_output_after_start
        );
        println!("     The decoder had no reference for them. That is frame loss, and it");
        println!("     cannot be a rendering problem: nothing was rendered.");
    }

    // The failure that cost three sessions, now nameable. When a keyframe itself
    // is refused the decoder has no picture to blame on the network, and it used
    // to show a plausible-looking wrong picture forever instead of saying so.
    if !wire.any_idr_decoded && wire.idr_nals > 0 {
        println!();
        println!("  ** NOT ONE KEYFRAME DECODED. Nothing about the network is at fault.");
        println!("     The decoder refused the self-contained pictures, so it could never");
        println!("     have produced a correct frame.");
        println!();
        println!("     The known cause is B-frames in the stream. This decoder calls");
        println!("     OpenH264's DecodeFrameNoDelay — \"no delay\" means no reordering — and a");
        println!("     stream carrying B-frames cannot be decoded that way. Measured on this");
        println!("     repo's own docs/demo/remotecrab-demo.mp4, which ffmpeg reads as 721 clean");
        println!("     frames: OpenH264 refused 694 of its 728 NALs. Re-encoding the same");
        println!("     picture with B-frames removed decoded 721/721, and with B-frames kept");
        println!("     but references reduced to 1 it still failed (33 frames). So it is the");
        println!("     B-frames, not the reference count.");
        println!();
        println!("     To confirm on a capture of this stream:");
        println!("       ffmpeg -i <capture>.mp4 -c copy -bsf:v h264_mp4toannexb -f h264 x.h264");
        println!("       ffprobe -v error -select_streams v:0 -show_entries \\");
        println!("         stream=has_b_frames,profile -of default=nw=1 x.h264");
        println!("     Anything other than has_b_frames=0 is the cause.");
        println!();
        println!("     The iOS encoder sets AllowFrameReordering:false and Main profile, which");
        println!("     should exclude B-frames, so if a live capture shows them the sender's");
        println!("     configuration is not taking effect. See docs/HANDOFF-WINDOWS-MSI.md.");
    }

    println!();
    let t = health.totals();
    let px = t.pixels.max(1) as f64;
    println!("the pixels (absolute numbers, scene dependent — read the pattern below):");
    println!("  frames analysed        : {}", health.frames());
    let (dw, dh) = pipeline.dimensions();
    println!("  geometry               : {dw}x{dh}");
    println!("  saturated pixels       : {:.2}%", 100.0 * t.saturated as f64 / px);
    println!("  harsh horizontal       : {:.2}%", harsh_h_percent(&t));
    println!("  harsh vertical         : {:.2}%", 100.0 * t.harsh_v as f64 / px);
    println!("  flat rows              : {:.2}%", 100.0 * t.flat_rows as f64 / px.max(1.0));
    let (r, g, b) = (t.sum_r, t.sum_g, t.sum_b);
    let sum = (r + g + b).max(1);
    println!(
        "  channel balance        : R {:.1}%  G {:.1}%  B {:.1}%",
        100.0 * r as f64 / sum as f64,
        100.0 * g as f64 / sum as f64,
        100.0 * b as f64 / sum as f64
    );

    // The wire facts are checked against what the phone *promised*, because a
    // stream can decode perfectly and still be nothing like the one that was
    // asked for. On 2026-10-04 this reported a healthy 307 frames and missed,
    // in the same breath, that the phone was sending 4 fps of a promised 30 at
    // an eighth of the promised rate. "The pixels are fine" is not the same
    // statement as "the stream is right".
    println!();
    if let Some((_, _, fps)) = advertised {
        let got = decoded as f64 / elapsed;
        let kbps = wire.kbps(elapsed);
        let mut flagged = false;
        if got < (fps as f64) / 2.0 {
            println!(
                "  ** the phone promised {fps} fps and delivered {got:.1} ({:.0}% of it)",
                100.0 * got / fps as f64
            );
            flagged = true;
        }
        if let Some(want_kbps) = advertised_kbps {
            if kbps > 0.0 && kbps < want_kbps * 0.5 {
                println!("  ** the phone advertised {want_kbps:.0} kbps and delivered {kbps:.0}");
                flagged = true;
            }
        }
        let gap = wire.keyframe_gap_secs();
        if gap < f64::INFINITY && gap > (fps as f64) * 2.5 {
            println!("  ** keyframes every {gap:.1}s, against a promised {fps} fps (one per second)");
            flagged = true;
        }
        if flagged {
            println!("     The pixels decoded, but the stream is not what was asked for. That is");
            println!("     an encoder or transport fault on the phone, and it is a different");
            println!("     problem from the picture being corrupt — report both, separately.");
        }
    }

    println!();
    println!("VERDICT:");
    let floor = rc_render::pixels::DETAIL_FLOOR_PERCENT;
    match health.pattern() {
        Pattern::TooFewFrames { seen } => {
            println!("  only {seen} frame(s) — too few to judge. Re-run with --seconds 30.");
        }
        Pattern::TooLittleDetail {
            edge_percent,
            mean_luma,
        } => {
            println!("  TOO LITTLE DETAIL TO JUDGE — and that is not a pass.");
            println!("  Edge energy is {edge_percent:.2}% of pixels, under the {floor:.0}% floor, and mean");
            println!("  luma is {mean_luma:.0}/255.");
            if mean_luma < 12.0 {
                println!("  The picture is essentially black, so the camera is delivering nothing or");
                println!("  is covered. Nothing downstream can be judged at all.");
            } else {
                println!("  The picture is bright but featureless — a blank wall, a closed lens, or");
                println!("  the camera aimed at nothing. A decoder cannot visibly corrupt an input");
                println!("  this smooth, so \"no frame stood out\" here says nothing about it.");
            }
            println!();
            println!("  Point the camera at something textured and high-contrast — a hand against");
            println!("  a desk, or a screen full of text — and re-run. That is the measurement that");
            println!("  can actually reproduce the artefact.");
        }
        Pattern::Uniform {
            median_harsh_h,
            median_harsh_v,
        } => {
            println!("  uniform. Every frame carries about the same amount of edge energy");
            println!("  (median {median_harsh_h:.2}% horizontal, {median_harsh_v:.2}% vertical), so");
            println!("  there is no frame standing out as broken.");
            if wire.no_output_after_start > 0 {
                println!();
                println!("  BUT: video NALs did arrive with no reference (see above), so some");
                println!("  pictures never existed to be judged. That is upstream frame loss.");
            } else {
                println!();
                println!("  What the picture looks like is then a question of quality, not of");
                println!("  corruption: this stream is uniformly soft or uniformly blocky, which");
                println!("  points at the phone's bitrate, not at anything on this machine.");
                println!("  (renderer_fidelity proves this machine is faithful — run it.)");
            }
        }
        Pattern::Spikes {
            frames,
            worst_ratio,
            ..
        } => {
            println!("  a few frames are broken and their neighbours are fine.");
            println!("  outliers (1-based frame index): {}", fmt_list(&frames));
            println!("  worst outlier is {worst_ratio:.1}x this stream's own median.");
            let idr_hits = frames
                .iter()
                .filter(|&&i| frame_source.get(i as usize - 1) == Some(&NAL_IDR))
                .count();
            println!(
                "  of those, {} came from a keyframe and {} from a predicted frame.",
                idr_hits,
                frames.len() - idr_hits
            );
            if idr_hits == 0 && !frames.is_empty() {
                println!();
                println!("  Not one broken frame came from a keyframe. A keyframe is self-contained,");
                println!("  so it cannot be mispredicted — that rules out bitrate as the cause and");
                println!("  leaves a missing reference frame, which points upstream of the decoder.");
            }
        }
    }
    Ok(())
}

fn fmt_list(v: &[u64]) -> String {
    if v.len() > 24 {
        format!("{:?} … ({} total)", &v[..24], v.len())
    } else {
        format!("{v:?}")
    }
}
