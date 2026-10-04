//! Decode an H.264 file through the **shipping** pipeline and judge it.
//!
//! Why this exists: for three sessions the question "is the corruption in our
//! decoder or in the phone's bitstream?" could not be answered without the
//! phone, because the only tool that measured anything needed a live TCP
//! connection. This one needs a file, so the question becomes answerable at a
//! desk.
//!
//! It is the same path a live frame takes — `PreviewPipeline`, then
//! `H264PreviewDecoder::feed_nal`, then `write_rgba8`, then the same
//! `0x00RRGGBB` repack — so a file that decodes wrongly here would decode
//! wrongly in the preview window too.
//!
//! ```sh
//! # judge a recording and print the same health report the live probe prints
//! cargo run --release -p rc-render --example decode_file -- path/to/recording.h264
//!
//! # dump RGBA so it can be diffed against another decoder, byte for byte
//! cargo run --release -p rc-render --example decode_file -- in.h264 --dump out.rgba
//! ```
//!
//! For an `.mp4`, extract the elementary stream first — the reader here is
//! Annex-B, deliberately, so it has no demuxer to disagree with:
//!
//! ```sh
//! ffmpeg -i in.mp4 -c copy -bsf:v h264_mp4toannexb -f h264 out.h264
//! ```

use std::collections::HashMap;

use rc_protocol::{NalFrame, NalKind};
use rc_render::pixels::{harsh_h_percent, Pattern, StreamHealth};
use rc_render::PreviewPipeline;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut input: Option<String> = None;
    let mut dump: Option<String> = None;
    let mut debug = false;
    let mut argv = std::env::args().skip(1);
    while let Some(a) = argv.next() {
        match a.as_str() {
            "--dump" => dump = Some(argv.next().ok_or("--dump needs a path")?),
            "--debug" => debug = true,
            other if other.starts_with("--") => {
                return Err(format!("unexpected argument {other:?}").into())
            }
            path => input = Some(path.to_string()),
        }
    }
    let path = input.ok_or("usage: decode_file <file.h264> [--dump out.rgba]")?;

    let bytes = std::fs::read(&path)?;
    let nals = split_annexb(&bytes);
    if nals.is_empty() {
        return Err(format!("no NAL units found in {path} — is it Annex-B?").into());
    }

    // NAL census first. A stream with surprises in it is worth knowing about
    // before blaming the decoder: several per frame means slices, and an
    // unexpected type means the iOS side's "skip SEI" walk dropped something
    // this file relies on.
    let mut census: HashMap<u8, usize> = HashMap::new();
    for n in &nals {
        *census.entry(n.first().copied().unwrap_or(0) & 0x1F).or_default() += 1;
    }
    let mut kinds: Vec<_> = census.into_iter().collect();
    kinds.sort();
    println!("file            : {path}");
    println!("bytes           : {}", bytes.len());
    println!("NAL units       : {}", nals.len());
    print!("NAL types       :");
    for (t, c) in &kinds {
        print!(" {}={}", nal_name(*t), c);
    }
    println!();

    let mut pipeline = if debug {
        PreviewPipeline::with_debug_tracing()?
    } else {
        PreviewPipeline::new()?
    };
    let mut health = StreamHealth::new();
    let mut produced = 0u64;
    let mut no_output = 0u64;
    let mut sizes: Vec<u64> = Vec::new();
    let mut out: Option<std::fs::File> = match &dump {
        Some(p) => Some(std::fs::File::create(p)?),
        None => None,
    };

    for data in &nals {
        let t = data.first().copied().unwrap_or(0) & 0x1F;
        let kind = match t {
            7 => NalKind::Sps,
            8 => NalKind::Pps,
            _ => NalKind::Video,
        };
        sizes.push(data.len() as u64);
        let nal = NalFrame {
            kind,
            data: data.clone(),
            timestamp_micros: 0,
        };
        if pipeline.push(&nal) {
            produced += 1;
            if let Some(f) = pipeline.latest() {
                health.add(f);
                if let Some(file) = out.as_mut() {
                    use std::io::Write;
                    for p in &f.pixels {
                        file.write_all(&p.to_le_bytes())?;
                    }
                }
            }
        } else if produced > 0 && kind == NalKind::Video {
            no_output += 1;
        }
    }

    if let Some(p) = &dump {
        println!("\nwrote raw RGBA to {p} (0x00RRGGBB words, little-endian)");
    }

    let (w, h) = pipeline.dimensions();
    println!("\ndecoded         : {produced} frames, {w}x{h}");
    println!("no output       : {no_output} video NALs produced nothing");
    println!("refused         : {}", pipeline.refused());
    if let Some(e) = pipeline.last_error() {
        println!("last error      : {e}");
    }
    if !sizes.is_empty() {
        sizes.sort_unstable();
        let sum: u64 = sizes.iter().sum();
        println!(
            "NAL size        : avg {}  min {}  max {}",
            sum / sizes.len() as u64,
            sizes[0],
            sizes[sizes.len() - 1]
        );
    }

    if produced == 0 {
        println!("\nVERDICT: nothing decoded — the decoder refused the whole file.");
        return Ok(());
    }

    let t = health.totals();
    let px = t.pixels.max(1) as f64;
    println!("\npixels (absolute figures are scene dependent — read the pattern):");
    println!("  saturated      : {:.2}%", 100.0 * t.saturated as f64 / px);
    println!("  harsh horizontal: {:.2}%", harsh_h_percent(&t));
    println!("  harsh vertical : {:.2}%", 100.0 * t.harsh_v as f64 / px);
    println!("  detail         : {:.2}%  (floor {:.2}%)", health.detail(), rc_render::pixels::DETAIL_FLOOR_PERCENT);

    println!("\nVERDICT:");
    match health.pattern() {
        Pattern::TooLittleDetail { edge_percent, mean_luma } => {
            println!("  too little detail ({edge_percent:.2}%, luma {mean_luma:.0}) — this");
            println!("  recording cannot show or hide speckle, so it cannot judge anything.");
        }
        Pattern::Uniform { median_harsh_h, .. } => {
            println!("  uniform (median harsh horizontal {median_harsh_h:.2}%). No frame stands out.");
            if no_output == 0 {
                println!("  A file decoder cannot lose packets, so with no NAL left without");
                println!("  output either, this pipeline handled the stream cleanly.");
            } else {
                println!("  But {no_output} NAL(s) produced no frame, which on a file means the");
                println!("  bitstream itself is inconsistent, not that anything was lost in transit.");
            }
        }
        Pattern::Spikes { frames, worst_ratio, .. } => {
            println!("  {} frame(s) are outliers, worst {worst_ratio:.1}x the median.", frames.len());
            println!("  First few: {:?}", &frames[..frames.len().min(10)]);
            std::process::exit(1);
        }
        Pattern::TooFewFrames { seen } => {
            println!("  only {seen} frame(s) — too few to judge.");
        }
    }
    Ok(())
}

fn nal_name(t: u8) -> &'static str {
    match t {
        1 => "non-IDR",
        5 => "IDR",
        6 => "SEI",
        7 => "SPS",
        8 => "PPS",
        9 => "AUD",
        _ => "other",
    }
}

/// Split Annex-B into NAL payloads with the start codes stripped — the shape the
/// iOS app puts on the wire, so `feed_nal` sees exactly what it sees live.
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