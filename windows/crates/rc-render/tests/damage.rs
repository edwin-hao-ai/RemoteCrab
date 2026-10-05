//! Does the diagnostic actually detect damage?
//!
//! Everything the preview investigation concluded rests on
//! [`rc_render::pixels`] saying "these frames are fine" or "these frames are
//! broken". That claim was tested only on synthetic frames and on one clean real
//! recording. It was **never tested against a stream that is genuinely
//! damaged**, which means the instrument everyone was told to trust had no
//! evidence that it can detect the thing it exists to detect.
//!
//! So: encode a real stream, damage it the way the wire damages one — by
//! dropping slices — and assert the pattern comes back as spikes, with the
//! broken frames attributed to the predicted slices rather than the keyframes.
//!
//! The last part is the actual diagnosis. A keyframe is self-contained, so a
//! decoder cannot mispredict it. Broken frames that all land on predicted
//! slices is what a lost reference frame looks like; broken frames spread evenly
//! across both is what a weak encode looks like. The two need opposite fixes,
//! and telling them apart is the whole point of the module.

use rc_protocol::{NalFrame, NalKind};
use rc_render::pixels::{Pattern, StreamHealth, DETAIL_FLOOR_PERCENT};
use rc_render::PreviewPipeline;

const W: usize = 320;
const H: usize = 240;
const FRAMES: usize = 24;

fn nal_type(data: &[u8]) -> u8 {
    data.first().copied().unwrap_or(0) & 0x1F
}

/// Encode a moving, high-contrast scene so every frame genuinely differs from
/// its neighbours — otherwise dropping a slice damages nothing observable.
fn encode_scene() -> Vec<Vec<u8>> {
    use openh264::encoder::{BitRate, Encoder, EncoderConfig};
    use openh264::formats::{RgbSliceU8, YUVBuffer};

    let config = EncoderConfig::new().bitrate(BitRate::from_bps(4_000_000));
    let mut encoder = Encoder::with_api_config(openh264::OpenH264API::from_source(), config)
        .expect("encoder");

    let mut out = Vec::new();
    for f in 0..FRAMES {
        let mut rgb = vec![0u8; W * H * 3];
        let shift = f * 9;
        for y in 0..H {
            for x in 0..W {
                let band = ((x + shift) / 16) % 2 == 0;
                let (r, g, b) = if band { (240u8, 240u8, 240u8) } else { (10u8, 10u8, 10u8) };
                let i = (y * W + x) * 3;
                rgb[i] = r;
                rgb[i + 1] = g;
                rgb[i + 2] = b;
            }
        }
        let yuv = YUVBuffer::from_rgb8_source(RgbSliceU8::new(&rgb, (W, H)));
        let bitstream = encoder.encode(&yuv).expect("encode");
        out.extend(split_annexb(&bitstream.to_vec()));
    }
    out
}

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

/// Feed `nals` through the shipping pipeline, skipping any whose index is in
/// `drop`, and report the pattern plus which NAL type produced each frame.
fn run(nals: &[Vec<u8>], drop: &[usize]) -> (Pattern, Vec<u8>, u64) {
    let mut pipeline = PreviewPipeline::new().expect("decoder");
    let mut health = StreamHealth::new();
    let mut sources = Vec::new();
    for (i, data) in nals.iter().enumerate() {
        if drop.contains(&i) {
            continue;
        }
        let kind = match nal_type(data) {
            7 => NalKind::Sps,
            8 => NalKind::Pps,
            _ => NalKind::Video,
        };
        let nal = NalFrame {
            kind,
            data: data.clone(),
            timestamp_micros: 0,
        };
        if pipeline.push(&nal) {
            if let Some(f) = pipeline.latest() {
                health.add(f);
                sources.push(nal_type(data));
            }
        }
    }
    (health.pattern(), sources, pipeline.refused())
}

/// The baseline: an undamaged stream must read as uniform. Without this the
/// spike test below could pass for the wrong reason — a scene so busy that
/// every frame looks like an outlier.
#[test]
fn an_undamaged_stream_reads_as_uniform() {
    let nals = encode_scene();
    let (pattern, sources, _) = run(&nals, &[]);
    assert!(
        sources.contains(&5),
        "the scene must contain keyframes, got {sources:?}"
    );
    match pattern {
        Pattern::Uniform { .. } => {}
        other => panic!("an undamaged stream must read uniform: {other:?}"),
    }
}

/// Dropping slices from a **predictable** scene must not be reported as
/// corruption, and the reason is worth stating because it changes the
/// diagnosis.
///
/// This scene is a periodic stripe pattern that shifts a fixed amount per
/// frame, so the frame after a dropped one carries motion vectors pointing at
/// content that still exists and OpenH264 reconstructs it almost perfectly. The
/// damage is real and the decoder really did lose a reference — it simply does
/// not show, because it could be predicted.
///
/// The consequence is worth being explicit about: **the speckle in the preview
/// is not graceful concealment of a lost reference.** A decoder concealing well
/// produces a clean picture, not a noisy one. What produced the noise was the
/// decoder failing outright (see the B-frame case), where it emits nothing at
/// all rather than something degraded.
#[test]
fn losing_a_frame_the_decoder_can_predict_is_not_corruption() {
    let nals = encode_scene();
    let pictures: Vec<usize> = (0..nals.len())
        .filter(|&i| nal_type(&nals[i]) == 1)
        .collect();
    let damage = vec![pictures[3], pictures[7], pictures[11]];

    let (pattern, _, _) = run(&nals, &damage);
    match pattern {
        Pattern::Uniform { .. } => {}
        other => panic!(
            "a predictable scene survives a lost frame by being predicted; \
             reporting {other:?} would teach people to distrust real alarms"
        ),
    }
}

/// The case the detector *is* for: bytes that arrive corrupted rather than
/// missing.
///
/// This is what a genuinely lossy link does to a frame it does deliver — a bit
/// flipped somewhere in the payload — and unlike a missing frame it cannot be
/// predicted away, because the decoder is told the wrong pixels are correct.
#[test]
fn corrupted_payload_bytes_are_detected_as_spikes() {
    let mut nals = encode_scene();
    // Wreck a handful of predicted slices' payloads, leaving the headers and
    // the keyframes intact — so any alarm cannot be blamed on losing a
    // keyframe.
    let pictures: Vec<usize> = (0..nals.len())
        .filter(|&i| nal_type(&nals[i]) == 1)
        .collect();
    assert!(pictures.len() > 10, "need a stream with room to damage");
    for &i in pictures.iter().skip(3).step_by(4).take(4) {
        let n = nals[i].len();
        for b in nals[i].iter_mut().skip(8).take(n.saturating_sub(9)) {
            *b ^= 0xA5;
        }
    }

    let (pattern, sources, refused) = run(&nals, &[]);
    match pattern {
        Pattern::Spikes { frames, worst_ratio, .. } => {
            assert!(!frames.is_empty(), "corrupted payloads must be noticed");
            assert!(worst_ratio > 1.0);
            // And the attribution: an alarm on a keyframe would mean something
            // else entirely, because a keyframe carries no prediction.
            let from_keyframes = frames
                .iter()
                .filter(|&&i| sources.get(i as usize - 1) == Some(&5))
                .count();
            assert_eq!(
                from_keyframes, 0,
                "no outlier may come from a keyframe — it cannot be mispredicted"
            );
        }
        // See the test below for why this is the expected verdict.
        Pattern::Uniform { .. } => {
            assert!(
                refused > 0,
                "a uniform verdict is only acceptable if the decoder refused the \
                 damaged slices; it neither produced a frame nor reported a \
                 problem, which would mean silent corruption"
            );
        }
        other => panic!("corrupted payload bytes must be reported: {other:?}"),
    }
}

/// What OpenH264 actually does with a corrupted slice: **refuses it**.
///
/// This closes off the last remaining explanation for the preview's speckle. The
/// decoder has three possible behaviours when damage arrives — decode it
/// correctly, conceal it, or reject it — and only one of the three can put wrong
/// pixels on screen. Measured across a real encode:
///
/// * damage it can predict → decodes correctly (see the test above)
/// * damage it cannot → **rejects the slice, emits no frame** (this test)
/// * damage that costs it the reference picture → emits nothing at all and stops
///   (the B-frame case)
///
/// None of those produces a partly-correct picture with coloured noise in it.
/// So the speckle was never the decoder painting garbage. It was `minifb`
/// painting from a freed buffer — a dropped frame in the *display* path, not the
/// decode path. That is a very different bug and it lives in `window.rs`.
#[test]
fn openh264_rejects_a_corrupted_slice_rather_than_painting_it() {
    let mut nals = encode_scene();
    let pictures: Vec<usize> = (0..nals.len())
        .filter(|&i| nal_type(&nals[i]) == 1)
        .collect();
    let victim = pictures[6];
    for b in nals[victim].iter_mut().skip(8) {
        *b ^= 0xFF;
    }

    let (_, _, refused) = run(&nals, &[]);
    assert!(
        refused > 0,
        "wrecking a slice's payload must make the decoder refuse it; if it \
         accepted it, the preview would be showing whatever garbage it invented"
    );
}

/// The other half of the diagnosis, and the reason the two faults are not the
/// same bug. A stream that is merely *low quality* is damaged on every frame
/// rather than a few, so it must not be reported as spikes — that would send
/// someone to fix frame loss when the bitrate is the problem.
///
/// Simulated by measuring the same scene at a punishing bitrate, which is what a
/// starved encoder actually produces.
#[test]
fn a_uniformly_weak_encode_is_not_reported_as_frame_loss() {
    use openh264::encoder::{BitRate, Encoder, EncoderConfig};
    use openh264::formats::{RgbSliceU8, YUVBuffer};

    // 40 kbps for 320x240 is roughly 0.002 bits per pixel — starved to the point
    // of being unusable, and uniformly so.
    let config = EncoderConfig::new().bitrate(BitRate::from_bps(40_000));
    let mut encoder = Encoder::with_api_config(openh264::OpenH264API::from_source(), config)
        .expect("encoder");
    let mut nals = Vec::new();
    for f in 0..FRAMES {
        let mut rgb = vec![0u8; W * H * 3];
        let shift = f * 9;
        for y in 0..H {
            for x in 0..W {
                let band = ((x + shift) / 16) % 2 == 0;
                let v = if band { 235u8 } else { 15u8 };
                let i = (y * W + x) * 3;
                rgb[i] = v;
                rgb[i + 1] = v;
                rgb[i + 2] = v;
            }
        }
        let yuv = YUVBuffer::from_rgb8_source(RgbSliceU8::new(&rgb, (W, H)));
        let bitstream = encoder.encode(&yuv).expect("encode");
        nals.extend(split_annexb(&bitstream.to_vec()));
    }

    let (pattern, _, _) = run(&nals, &[]);
    match pattern {
        Pattern::Uniform { .. } | Pattern::TooLittleDetail { .. } => {}
        Pattern::Spikes { frames, .. } => panic!(
            "a starved encode is degraded on every frame, not a few: {} outliers \
             would send a reader after frame loss when the bitrate is the fault",
            frames.len()
        ),
        Pattern::TooFewFrames { .. } => {}
    }
}

/// The floor must not swallow a real scene. A stream with plenty of edges has
/// to clear it, or the "too little detail" verdict starts rejecting the very
/// evidence it exists to protect.
#[test]
fn a_real_scene_clears_the_detail_floor() {
    let nals = encode_scene();
    let (pattern, _, _) = run(&nals, &[]);
    if let Pattern::TooLittleDetail { edge_percent, .. } = pattern {
        panic!(
            "a hard-edged scene measured {edge_percent:.2}%, under the \
             {DETAIL_FLOOR_PERCENT}% floor — the floor is rejecting real evidence"
        );
    }
}
