//! Per-stage decode cost, so "is this format affordable" gets a number instead
//! of an opinion. Splits the frame budget across H.264 decode and the BGRA
//! swizzle, because those two have different owners and different fixes.
//!
//!   ffmpeg -f lavfi -i testsrc2=size=3840x2160:rate=30:duration=6 \
//!          -c:v libx264 -profile:v high -bf 0 -g 60 -b:v 16M \
//!          -pix_fmt yuv420p -f h264 4k.h264
//!   cargo run -p rc-render --release --example bench_decode -- 4k.h264
//!
//! Numbers behind `docs/WINDOWS-4K-FEASIBILITY-2026-10-05.md`.

use std::time::Instant;

/// Split Annex-B into NAL payloads with start codes stripped.
fn split_annexb(data: &[u8]) -> Vec<Vec<u8>> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1 {
            starts.push((i, 4));
            i += 4;
        } else if i + 4 <= data.len()
            && data[i] == 0
            && data[i + 1] == 0
            && data[i + 2] == 1
        {
            starts.push((i, 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut out = Vec::with_capacity(starts.len());
    for (n, (pos, len)) in starts.iter().enumerate() {
        let begin = pos + len;
        let end = starts.get(n + 1).map_or(data.len(), |(p, _)| *p);
        // Trim the zero run that belongs to the next start code.
        let mut e = end;
        while e > begin && data[e - 1] == 0 {
            e -= 1;
        }
        out.push(data[begin..e].to_vec());
    }
    out
}

fn main() {
    let path = std::env::args().nth(1).expect("need a .h264");
    let bytes = std::fs::read(&path).expect("read");

    let mut dec = rc_render::decoder::H264PreviewDecoder::new().expect("decoder");
    let (mut t_feed, mut t_rgba) = (std::time::Duration::ZERO, std::time::Duration::ZERO);
    let (mut frames, mut nals) = (0usize, 0usize);

    let t0 = Instant::now();
    for nal in split_annexb(&bytes) {
        if nal.is_empty() || nal[0] & 0x1f == 9 {
            continue;
        }
        nals += 1;
        let a = Instant::now();
        if let Some(frame) = dec.feed_nal(&nal) {
            t_feed += a.elapsed();
            let b = Instant::now();
            let _ = frame.to_bgra();
            t_rgba += b.elapsed();
            frames += 1;
        }
    }
    let total = t0.elapsed();

    let f = frames as f64;
    println!("frames        : {frames}");
    println!("video NALs    : {nals}");
    println!("refused       : {}", dec.refused());
    println!("dimensions    : {:?}", dec.dimensions());
    println!("TOTAL         : {:.2} s  ({:.1} fps)", total.as_secs_f64(), f / total.as_secs_f64());
    println!(
        "  feed_nal    : {:.2} s  ({:.2} ms/frame, {:.1} fps ceiling)",
        t_feed.as_secs_f64(),
        t_feed.as_secs_f64() * 1000.0 / f,
        f / t_feed.as_secs_f64()
    );
    println!(
        "  to_bgra     : {:.2} s  ({:.2} ms/frame, {:.1} fps ceiling)",
        t_rgba.as_secs_f64(),
        t_rgba.as_secs_f64() * 1000.0 / f,
        f / t_rgba.as_secs_f64()
    );
    println!(
        "  30fps budget: 33.33 ms/frame -> feed {} / bgra {}",
        if t_feed.as_secs_f64() * 1000.0 / f < 33.33 { "OK" } else { "OVER" },
        if t_rgba.as_secs_f64() * 1000.0 / f < 33.33 { "OK" } else { "OVER" }
    );
}