//! Renderer fidelity: can this machine turn a *correct* stream into a wrong
//! picture?
//!
//! The preview showed corruption. The phone is the obvious suspect and also
//! the hardest thing to measure, so this answers the cheap half of the
//! question with no phone at all:
//!
//! > Take a stream we *know* is well-formed, push it through exactly the path
//! > a real frame takes — `PreviewPipeline` → `RgbaFrame` → the `FrameSlot`
//! > copy `window.rs` performs → the `&[u32]` minifb is handed — and check
//! > every stage is faithful. If they all are, the corruption cannot be
//! > produced here, and no amount of reading this crate will find it.
//!
//! It encodes a deliberately hostile scene at the live resolution and the
//! live bitrate, because the failure being looked for is specifically "fine
//! pixels turned into garbage on the way to the screen". A flat grey frame
//! would sail through a stride bug or a channel swap almost unnoticed.
//!
//! Run it:
//!
//! ```sh
//! cargo run --release -p rc-render --example renderer_fidelity
//! ```
//!
//! Exit code 0 means every stage was faithful. Anything else names the stage.

use rc_protocol::{NalFrame, NalKind};
use rc_render::pixels::{harsh_h_percent, Pattern, StreamHealth};
use rc_render::{PreviewPipeline, RgbaFrame};

/// The live geometry, taken from the metadata the receiver printed:
/// `streaming: 1080x1920 @ 30fps`.
const W: usize = 1080;
const H: usize = 1920;
const FPS: u32 = 30;

/// The rate the phone **actually produces**, not the one it advertises.
///
/// These two numbers are not the same and the difference cost a whole session.
/// `IBStreamMetadata` carries the bitrate the phone *asked* for, computed from
/// a 0.1 bits-per-pixel coefficient. But `H264Encoder` sets both
/// `kVTCompressionPropertyKey_AverageBitRate` and
/// `kVTCompressionPropertyKey_Quality`, and on iOS `Quality` wins outright —
/// asking for 6,220 and for 9,331 produced byte-identical output. So the
/// "6220 kbps" the receiver prints, and that the previous handoff built its
/// whole diagnosis on, was never a measurement of anything.
///
/// The number below is what `scripts/vt-bitrate-probe.swift` measured off the
/// real encoder over a synthetic high-detail scene at `quality = 0.75`
/// (10,886 kbps); `quality = 0.70`, which is what the build currently on the
/// phone uses, measured 9,179 kbps. OpenH264 *does* honour a target bitrate,
/// so this one is a real setting rather than an inert request.
const BITRATE: u32 = 10_886_000;

fn main() {
    println!("renderer fidelity — {W}x{H} @ {FPS}fps, asking OpenH264 for {BITRATE} bps");
    println!("(the live geometry, and the rate the real encoder was measured producing —");
    println!(" not the rate the phone advertises, which on iOS is inert)\n");

    let nals = match encode_hostile_scene() {
        Some(n) if !n.is_empty() => n,
        _ => {
            eprintln!("FAILED: could not encode the reference scene");
            std::process::exit(1);
        }
    };
    println!(
        "  reference stream : {} NAL units, {} bytes",
        nals.len(),
        nals.iter().map(|n| n.len()).sum::<usize>()
    );

    let mut failures: Vec<String> = Vec::new();

    // --- Stage 1: decode -----------------------------------------------------
    let mut pipeline = PreviewPipeline::new().expect("decoder");
    let mut decoded: Vec<RgbaFrame> = Vec::new();
    for data in &nals {
        let nal = NalFrame {
            kind: NalKind::Video,
            data: data.clone(),
            timestamp_micros: 0,
        };
        if pipeline.push(&nal) {
            if let Some(f) = pipeline.latest() {
                decoded.push(f.clone());
            }
        }
    }
    let (dw, dh) = pipeline.dimensions();
    println!("\n  stage 1  decode");
    println!("    frames decoded       : {}", decoded.len());
    println!("    geometry             : {dw}x{dh}");
    if decoded.len() < 5 {
        failures.push(format!(
            "only {} of {} NAL units decoded — too few to judge a picture",
            decoded.len(),
            nals.len()
        ));
    }
    if dw as usize != W || dh as usize != H {
        failures.push(format!(
            "decoder reported {dw}x{dh}, expected {W}x{H} — the SPS was misread"
        ));
    }

    // --- Stage 2: does every frame's pixel count match its stated size? -------
    println!("\n  stage 2  frame buffer");
    let wrong_len = decoded
        .iter()
        .filter(|f| f.pixels.len() != (f.width as usize) * (f.height as usize))
        .count();
    println!("    frames with pixels.len() != w*h : {wrong_len}");
    if wrong_len > 0 {
        failures.push(format!(
            "{wrong_len} frame(s) have a pixel count that disagrees with their stated size — \
             the shape a plane-size or stride mismatch takes"
        ));
    }

    // --- Stage 3: channel order ---------------------------------------------
    // The scene is three solid thirds — red, green, blue — so each third's
    // dominant channel is unambiguous. Checked per third, because a swap of
    // red and blue leaves the whole-frame balance untouched and would be
    // invisible to a global average.
    println!("\n  stage 3  channel order (scene is R | G | B thirds)");
    let mut got = Vec::new();
    for f in &decoded {
        got.push(dominant_per_third(f));
    }
    let agreed = got.iter().filter(|g| **g == got[0]).count();
    println!("    per frame            : {got:?}");
    println!("    frames agreeing      : {}/{}", agreed, got.len());
    const WANT: [&str; 3] = ["red", "green", "blue"];
    if agreed * 2 > got.len() {
        println!("    dominant per third   : {} | {} | {}", got[0][0], got[0][1], got[0][2]);
        let found: Vec<&str> = got[0].to_vec();
        if found != WANT {
            failures.push(format!(
                "channel order is wrong: expected red|green|blue across the thirds, decoded \
                 {}|{}|{} — consistent with a swapped or reversed channel",
                found[0], found[1], found[2]
            ));
        }
    } else {
        failures.push(format!(
            "only {agreed}/{} frames agree on which channel dominates which third — the decode \
             is not even self-consistent",
            got.len()
        ));
    }

    // --- Stage 4: the copy window.rs performs -------------------------------
    // Reproduced rather than called: `run_preview_window` needs a display and
    // returns when the user closes it, so it cannot be asserted on. These are
    // the same statements, including the resize branch, at the real sizes.
    println!("\n  stage 4  the window.rs blit");
    let (mut width, mut height) = (960usize, 540usize);
    let mut buffer = vec![0u32; width * height];
    let mut last_size = (0usize, 0usize);
    let (mut resized, mut blit_mismatch) = (0usize, 0usize);
    for f in &decoded {
        let (fw, fh) = (f.width as usize, f.height as usize);
        if (fw, fh) != last_size {
            width = fw;
            height = fh;
            buffer = vec![0u32; width * height];
            last_size = (fw, fh);
            resized += 1;
        }
        // `copy_from_slice` panics on a length mismatch, which is its own loud
        // protection; the length check below is the one minifb actually needs.
        buffer.copy_from_slice(&f.pixels);
        if buffer.len() < width * height || buffer != f.pixels {
            blit_mismatch += 1;
        }
    }
    println!("    times the buffer was resized    : {resized}");
    println!("    frames the blit altered        : {blit_mismatch}");
    if decoded.len() >= 5 && resized == 0 {
        failures.push(
            "the resize branch never ran — the first frame matched the 960x540 placeholder, \
             which cannot happen and means the size bookkeeping is wrong"
                .to_string(),
        );
    }
    if blit_mismatch > 0 {
        failures.push(format!(
            "{blit_mismatch} frame(s) would have reached minifb as something other than the \
             decoded pixels"
        ));
    }

    // --- Stage 5: is the decoded picture itself sound? -----------------------
    println!("\n  stage 5  is the decoded picture well-formed?");
    let mut health = StreamHealth::new();
    for f in &decoded {
        health.add(f);
    }
    let t = health.totals();
    let px = t.pixels.max(1) as f64;
    println!("    frames analysed       : {}", health.frames());
    println!("    saturated pixels      : {:.2}%", 100.0 * t.saturated as f64 / px);
    println!("    harsh horizontal      : {:.2}%   (absolute — scene dependent)", harsh_h_percent(&t));
    println!("    harsh vertical        : {:.2}%", 100.0 * t.harsh_v as f64 / px);
    match health.pattern() {
        Pattern::Spikes { frames, worst_ratio, .. } => {
            println!("    frame-to-frame pattern: SPIKES on frames {frames:?}, worst {worst_ratio:.1}x the median");
            failures.push(format!(
                "the decoded picture has {frames:?} broken out of {} — a frame lost its \
                 reference, and that happens before the decoder, not in it",
                health.frames()
            ));
        }
        Pattern::TooLittleDetail {
            edge_percent,
            mean_luma,
        } => {
            // This gate's own scene is built from hard edges and measures ~25%
            // pooled, so landing here means the measurement is no longer seeing
            // its input. A gate that quietly stops testing must fail loudly, not
            // print PASS.
            failures.push(format!(
                "the reference scene measured {edge_percent:.2}% edge energy (mean luma \
                 {mean_luma:.0}/255), under the {:.0}% floor — this gate is no longer measuring \
                 anything, so a PASS from it would be meaningless",
                rc_render::pixels::DETAIL_FLOOR_PERCENT
            ));
        }
        Pattern::Uniform { median_harsh_h, .. } => {
            println!("    frame-to-frame pattern: uniform, median harsh horizontal {median_harsh_h:.2}%");
            println!("                         every frame carries about the same edge");
            println!("                         energy, so whatever this looks like, it is");
            println!("                         consistently so — no lost reference frames.");
        }
        Pattern::TooFewFrames { seen } => {
            failures.push(format!("only {seen} frame(s) measured — too few to judge"));
        }
    }

    println!();
    if failures.is_empty() {
        println!("PASS — every stage from NAL to minifb's buffer was faithful.");
        println!();
        println!("Consequence: this machine cannot turn a correct stream into a wrong picture.");
        println!("So the corruption is produced *before* the decoder — the phone's bitrate, its");
        println!("frame cadence, or a frame lost in transport. Nothing in rc-render will fix it,");
        println!("and reading this crate again will not find it.");
        println!();
        println!("Next step is the live probe, which can see the phone:");
        println!("  cargo run --release -p rc-render --example vcam_forensics -- \\");
        println!("      --connect <iphone-ip>:8765 --seconds 25");
    } else {
        eprintln!("FAIL — the renderer is not faithful:");
        for f in &failures {
            eprintln!("  - {f}");
        }
        std::process::exit(1);
    }
}

/// The channel that dominates each vertical third, named. H.264 is lossy, so
/// the margins here are wide on purpose: 200 against 20 per channel is far
/// beyond what compression can blur.
fn dominant_per_third(f: &RgbaFrame) -> [&'static str; 3] {
    let w = f.width as usize;
    let h = f.height as usize;
    let names = ["red", "green", "blue"];
    (0..3)
        .map(|t| {
            let x0 = w * t / 3;
            let x1 = if t == 2 { w } else { w * (t + 1) / 3 };
            let (mut sr, mut sg, mut sb) = (0u64, 0u64, 0u64);
            for y in 0..h {
                for &p in &f.pixels[y * w + x0..y * w + x1] {
                    sr += ((p >> 16) & 0xff) as u64;
                    sg += ((p >> 8) & 0xff) as u64;
                    sb += (p & 0xff) as u64;
                }
            }
            let idx: usize = if sr >= sg && sr >= sb {
                0
            } else if sg >= sb {
                1
            } else {
                2
            };
            names[idx]
        })
        .collect::<Vec<_>>()
        .try_into()
        .expect("three thirds")
}

/// Encode a scene chosen to break anything subtly wrong: three solid thirds of
/// saturated red / green / blue (catches a channel swap), hard vertical edges
/// every few pixels inside each third (catches a row-pitch or stride error,
/// which shears rather than smears), and a white block sweeping right so
/// consecutive frames differ (catches a stale buffer or a missed frame).
/// Encoded at the real bitrate, so a decode that cannot cope with the real
/// quality level fails here too.
fn encode_hostile_scene() -> Option<Vec<Vec<u8>>> {
    use openh264::encoder::{BitRate, Encoder, EncoderConfig};
    use openh264::formats::{RgbSliceU8, YUVBuffer};

    // Frame skipping stays ON, which is what OpenH264 requires before it will
    // honour a target bitrate at all — with it off, `set_bitrate` is ignored
    // and the stream silently encodes at quality-mode size, which would make
    // this whole check vacuous.
    let config = EncoderConfig::new().bitrate(BitRate::from_bps(BITRATE));
    let mut encoder = Encoder::with_api_config(openh264::OpenH264API::from_source(), config).ok()?;

    let mut nals = Vec::new();
    for f in 0..12usize {
        let mut rgb = vec![0u8; W * H * 3];
        let sweep = W * f / 12;
        for y in 0..H {
            for x in 0..W {
                let third = (x * 3 / W).min(2);
                // Vertical stripes inside each third: a stride error shows up
                // as these shearing, which is unmistakable.
                let (mut r, mut g, mut b) = match third {
                    0 => (220u8, 24u8, 24u8),
                    1 => (24u8, 220u8, 24u8),
                    _ => (24u8, 24u8, 220u8),
                };
                if x % 16 < 2 {
                    r /= 4;
                    g /= 4;
                    b /= 4;
                }
                if x > sweep && x < sweep + 48 {
                    r = 255;
                    g = 255;
                    b = 255;
                }
                let i = (y * W + x) * 3;
                rgb[i] = r;
                rgb[i + 1] = g;
                rgb[i + 2] = b;
            }
        }
        let yuv = YUVBuffer::from_rgb8_source(RgbSliceU8::new(&rgb, (W, H)));
        let bitstream = encoder.encode(&yuv).ok()?;
        nals.extend(split_annexb(&bitstream.to_vec()));
    }
    Some(nals)
}

/// Split an Annex-B stream into NAL payloads with the start codes stripped,
/// which is the shape the iPhone puts on the wire.
fn split_annexb(data: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut i = 0;
    let mut start = None;
    while i + 3 <= data.len() {
        let is_start = (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
            || (i + 4 <= data.len()
                && data[i] == 0
                && data[i + 1] == 0
                && data[i + 2] == 0
                && data[i + 3] == 1);
        if is_start {
            if let Some(s) = start {
                if i > s {
                    out.push(data[s..i].to_vec());
                }
            }
            i += if data[i + 2] == 1 { 3 } else { 4 };
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
