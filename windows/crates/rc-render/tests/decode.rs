//! Proves the preview pipeline decodes a **real** H.264 stream.
//!
//! We encode a synthetic frame with OpenH264's encoder, feed the resulting
//! NAL units through `PreviewPipeline` exactly as the iOS app would, and
//! assert a correctly-sized frame comes out.

use openh264::encoder::Encoder;
use openh264::formats::{RgbSliceU8, YUVBuffer};
use rc_protocol::{NalFrame, NalKind};
use rc_render::PreviewPipeline;

/// Split an Annex-B byte stream into individual NAL payloads (no start code).
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

#[test]
fn decodes_a_real_h264_stream() {
    const W: usize = 64;
    const H: usize = 64;

    // A flat grey RGB frame → YUV → H.264.
    let rgb = vec![128u8; W * H * 3];
    let yuv = YUVBuffer::from_rgb8_source(RgbSliceU8::new(&rgb, (W, H)));

    let mut encoder = Encoder::new().expect("encoder");
    let bitstream = encoder.encode(&yuv).expect("encode");
    let annexb = bitstream.to_vec();

    let nals = split_annexb(&annexb);
    assert!(!nals.is_empty(), "encoder produced no NAL units");

    let mut pipeline = PreviewPipeline::new().expect("decoder");
    let mut decoded_any = false;
    for nal in nals {
        let frame = NalFrame {
            kind: NalKind::Video,
            data: nal,
            timestamp_micros: 0,
        };
        if pipeline.push(&frame) {
            decoded_any = true;
        }
    }

    assert!(decoded_any, "no frame decoded from a valid stream");
    let frame = pipeline.latest().expect("a decoded frame");
    assert_eq!(frame.width, W as u32);
    assert_eq!(frame.height, H as u32);
    assert_eq!(frame.pixels.len(), W * H);
    // Grey in → grey out (within encoder tolerance).
    let px = frame.pixels[W * H / 2];
    let (r, g, b) = ((px >> 16) & 0xFF, (px >> 8) & 0xFF, px & 0xFF);
    assert!((100..=160).contains(&r), "r = {r} (expected ~128)");
    assert!((100..=160).contains(&g), "g = {g}");
    assert!((100..=160).contains(&b), "b = {b}");
}
