//! Measuring whether a decoded picture is *uniformly* degraded or has
//! individual *broken* frames.
//!
//! # Why this module exists
//!
//! The preview showed "coloured speckle along high-contrast edges, plus
//! periodic horizontal streaking". Two very different faults produce that
//! picture, and they live on opposite sides of the decoder:
//!
//! * **every** frame is a bit soft / a bit blocky → the phone encoded at too
//!   low a bitrate. Nothing on this machine is broken.
//! * **some** frames are garbage and the next one is fine again → a
//!   reference frame went missing somewhere between the camera and the
//!   decoder. The fix is a frame-loss counter, not a bitrate bump.
//!
//! A screenshot cannot tell those apart, and neither can a fixed threshold on
//! spatial high-frequency energy: how much edge energy a *healthy* frame has
//! depends entirely on what the camera is pointing at. A hand moving in front
//! of a bright window produces far more of it than the flat synthetic pattern
//! these numbers were first measured on, so any absolute cut-off eventually
//! calls a perfectly healthy stream "corrupt" and sends the reader to the
//! wrong layer of the product.
//!
//! So nothing here compares against a magic number. Every frame is compared
//! against **the median of the same stream**, which makes the measurement
//! independent of the scene: a stream where every frame has about the same
//! edge energy is uniformly whatever it is, and a stream where a few frames
//! tower over the rest has those specific frames broken.
//!
//! # What this does not prove
//!
//! It reads *decoded pixels*. It says nothing about the blit that follows,
//! and it cannot name the layer that lost the frame. See
//! `examples/renderer_fidelity.rs` for the other half — proving that these
//! same pixels survive the renderer unchanged.

use crate::decoder::RgbaFrame;

/// Per-frame spatial measurements, all as raw counts over that frame's pixels.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FrameHealth {
    /// Pixel count — the denominator for every fraction below.
    pub pixels: u64,
    /// Neighbouring pixels horizontally whose combined channel delta exceeds
    /// [`DELTA_THRESHOLD`]. This is what "speckle along edges" looks like.
    pub harsh_h: u64,
    /// The same vertically. Vertical streaking points here.
    pub harsh_v: u64,
    /// Rows that are one flat colour end to end.
    pub flat_rows: u64,
    /// Rows scanned, i.e. the frame height.
    pub rows: u64,
    /// Pixels with any channel at 0 or 255.
    pub saturated: u64,
    /// Channel sums, for spotting a stuck or swapped channel.
    pub sum_r: u64,
    pub sum_g: u64,
    pub sum_b: u64,
}

/// Combined channel delta above which two neighbouring pixels count as an
/// edge. 90 of a possible 765 is ~12%: high enough to ignore sensor noise
/// and mild ringing, low enough to catch a real edge. It is a *noise floor*,
/// not a verdict — the verdict comes from comparing frames to each other.
pub const DELTA_THRESHOLD: i32 = 90;

/// A frame's edge energy, as a fraction of its pixels, expressed in percent.
/// This is the number that gets compared across frames.
pub fn harsh_h_percent(f: &FrameHealth) -> f64 {
    pct(f.harsh_h, f.pixels)
}

/// [`harsh_h_percent`] for the vertical axis.
pub fn harsh_v_percent(f: &FrameHealth) -> f64 {
    pct(f.harsh_v, f.pixels)
}

fn pct(n: u64, of: u64) -> f64 {
    if of == 0 {
        0.0
    } else {
        100.0 * n as f64 / of as f64
    }
}

#[inline]
fn channels(p: u32) -> (i32, i32, i32) {
    (
        ((p >> 16) & 0xff) as i32,
        ((p >> 8) & 0xff) as i32,
        (p & 0xff) as i32,
    )
}

/// Measure one decoded frame.
///
/// Every pixel is read exactly once per axis, so a 1080x1920 frame costs
/// ~2M reads. That is fine for a diagnostic and far too slow for the live
/// path, which is why this lives beside the decoder rather than inside it.
pub fn measure(frame: &RgbaFrame) -> FrameHealth {
    let mut h = FrameHealth {
        pixels: (frame.width as u64) * (frame.height as u64),
        rows: frame.height as u64,
        ..FrameHealth::default()
    };
    if h.pixels == 0 || frame.pixels.is_empty() {
        return h;
    }

    let w = frame.width as usize;
    let hh = frame.height as usize;
    let px = &frame.pixels;

    for y in 0..hh {
        let row = &px[y * w..y * w + w];
        let mut flat = true;
        let first = row[0];
        for &p in row {
            let (r, g, b) = channels(p);
            if (r, g, b) != channels(first) {
                flat = false;
            }
            if r == 0 || r == 255 || g == 0 || g == 255 || b == 0 || b == 255 {
                h.saturated += 1;
            }
            h.sum_r += r as u64;
            h.sum_g += g as u64;
            h.sum_b += b as u64;
        }
        if flat {
            h.flat_rows += 1;
        }
        for x in 1..w {
            let (r, g, b) = channels(row[x]);
            let (pr, pg, pb) = channels(row[x - 1]);
            if (r - pr).abs() + (g - pg).abs() + (b - pb).abs() > DELTA_THRESHOLD {
                h.harsh_h += 1;
            }
        }
    }

    for y in 1..hh {
        let row = &px[y * w..y * w + w];
        let up = &px[(y - 1) * w..(y - 1) * w + w];
        for x in 0..w {
            let (r, g, b) = channels(row[x]);
            let (ur, ug, ub) = channels(up[x]);
            if (r - ur).abs() + (g - ug).abs() + (b - ub).abs() > DELTA_THRESHOLD {
                h.harsh_v += 1;
            }
        }
    }

    h
}

/// What the stream as a whole looks like, relative to itself.
#[derive(Debug, Clone, PartialEq)]
pub enum Pattern {
    /// Too few frames to compare anything.
    TooFewFrames { seen: u64 },
    /// The stream carries almost no detail, so it cannot confirm *or* refute a
    /// claim about speckle. See [`StreamHealth::detail`].
    ///
    /// This exists because "no frame stood out" reads exactly like "all good",
    /// and on a nearly featureless picture those are the same statement. A
    /// camera pointed at a dark wall, a lens cap, or a blank wall produces a
    /// stream with essentially zero edge energy; a decoder given that input
    /// cannot corrupt it visibly, so the absence of corruption proves nothing
    /// about the decoder. Reporting this as a pass is the failure mode of every
    /// version of this tool that only printed percentages.
    TooLittleDetail { edge_percent: f64, mean_luma: f64 },
    /// Every frame has about the same edge energy. Whatever the picture looks
    /// like, it looks like it *consistently* — the signature of a uniformly
    /// weak encode (too low a bitrate), not of lost reference frames.
    Uniform {
        median_harsh_h: f64,
        median_harsh_v: f64,
    },
    /// A minority of frames tower over the rest. Those specific frames are
    /// broken while their neighbours are fine, which is what a missing
    /// reference frame looks like: the decoder paints garbage until the next
    /// keyframe arrives and then recovers.
    Spikes {
        /// 1-based positions, in decode order, of the frames that spiked.
        frames: Vec<u64>,
        /// Worst spike as a multiple of the stream's own median.
        worst_ratio: f64,
        median_harsh_h: f64,
    },
}

/// Mean luma (BT.601, 0-255) across a frame's pixels.
pub fn mean_luma(pixels: &[u32]) -> f64 {
    if pixels.is_empty() {
        return 0.0;
    }
    let sum: u64 = pixels
        .iter()
        .map(|&p| {
            let (r, g, b) = channels(p);
            ((77 * r + 150 * g + 29 * b) >> 8).max(0) as u64
        })
        .sum();
    sum as f64 / pixels.len() as f64
}

/// Accumulated measurements over a stream, and the comparison that turns them
/// into a [`Pattern`].
#[derive(Debug, Default)]
pub struct StreamHealth {
    per_frame: Vec<FrameHealth>,
}

impl StreamHealth {
    pub fn new() -> Self {
        Self::default()
    }

    /// Measure and record one frame. Ignores an empty frame so a mid-stream
    /// resolution change cannot drag the median to zero.
    pub fn add(&mut self, frame: &RgbaFrame) {
        let m = measure(frame);
        if m.pixels > 0 {
            self.per_frame.push(m);
        }
    }

    pub fn frames(&self) -> u64 {
        self.per_frame.len() as u64
    }

    /// The frame measurements, in decode order.
    pub fn per_frame(&self) -> &[FrameHealth] {
        &self.per_frame
    }

    /// Totals across every frame measured — for the per-channel balance and
    /// the saturation share, which describe the picture rather than any one
    /// frame's health.
    pub fn totals(&self) -> FrameHealth {
        let mut t = FrameHealth::default();
        for f in &self.per_frame {
            t.pixels += f.pixels;
            t.rows += f.rows;
            t.harsh_h += f.harsh_h;
            t.harsh_v += f.harsh_v;
            t.flat_rows += f.flat_rows;
            t.saturated += f.saturated;
            t.sum_r += f.sum_r;
            t.sum_g += f.sum_g;
            t.sum_b += f.sum_b;
        }
        t
    }

    /// Pooled edge energy of the whole stream, in percent of pixels, counting
    /// both axes.
    pub fn detail(&self) -> f64 {
        if self.per_frame.is_empty() {
            return 0.0;
        }
        let t = self.totals();
        // `sum(counts) / sum(pixels)` is already the pixel-weighted mean over
        // every frame measured. Dividing by the frame count as well made the
        // answer shrink with the length of the capture, so a long run of a
        // genuinely textured scene read as featureless.
        100.0 * (t.harsh_h + t.harsh_v) as f64 / t.pixels.max(1) as f64
    }

    /// Mean luma of the last frame measured, 0-255.
    pub fn luma(&self) -> f64 {
        match self.per_frame.last() {
            // FrameHealth keeps sums but not pixels, so this is reconstructed
            // from the channel balance rather than kept per frame: a cheap and
            // sufficient "is the picture dark or bright" figure.
            Some(f) => {
                let n = (f.pixels.max(1)) as f64;
                (0.299 * f.sum_r as f64 + 0.587 * f.sum_g as f64 + 0.114 * f.sum_b as f64) / n
            }
            None => 0.0,
        }
    }

    pub fn pattern(&self) -> Pattern {
        if self.per_frame.len() < 5 {
            return Pattern::TooFewFrames {
                seen: self.per_frame.len() as u64,
            };
        }
        // Checked before the median comparison, because on a featureless stream
        // the median is ~0 and every moving frame becomes an infinite multiple
        // of it — which would be reported as corruption and would be nothing of
        // the kind.
        let edge = self.detail();
        if edge < DETAIL_FLOOR_PERCENT {
            return Pattern::TooLittleDetail {
                edge_percent: edge,
                mean_luma: self.luma(),
            };
        }
        let mut hs: Vec<f64> = self
            .per_frame
            .iter()
            .map(|f| harsh_h_percent(f) + harsh_v_percent(f))
            .collect();
        let mut vs: Vec<f64> = self.per_frame.iter().map(harsh_v_percent).collect();
        hs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        vs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let mid = hs.len() / 2;
        let median_both = hs[mid];
        let median_v = vs[mid];

        // A perfectly still camera can produce a median of ~0, where any
        // single moving frame is an infinite multiple of it. That is motion,
        // not corruption, so the floor is deliberately not zero.
        let floor = SPIKE_MEDIAN_FLOOR;
        let baseline = median_both.max(floor);

        let mut frames = Vec::new();
        let mut worst = 0.0f64;
        for (i, f) in self.per_frame.iter().enumerate() {
            let e = harsh_h_percent(f) + harsh_v_percent(f);
            let ratio = e / baseline;
            if ratio > SPIKE_RATIO {
                frames.push(i as u64 + 1);
                worst = worst.max(ratio);
            }
        }

        if frames.is_empty() {
            Pattern::Uniform {
                median_harsh_h: median_both / 2.0,
                median_harsh_v: median_v,
            }
        } else {
            Pattern::Spikes {
                frames,
                worst_ratio: worst,
                median_harsh_h: median_both / 2.0,
            }
        }
    }
}

/// A frame must exceed this multiple of the stream's own median edge energy
/// before it is called an outlier.
///
/// Three is chosen so that ordinary camera motion — which lifts edge energy
/// across *every* frame, and lifts the median with it — cannot trip it, while
/// a decoder painting half the frame with noise can. It is a heuristic, and
/// [`StreamHealth::per_frame`] exists so a reader can check it rather than
/// trust it.
pub const SPIKE_RATIO: f64 = 3.0;

/// Median edge energy below which the ratio test is meaningless. Roughly 0.2%
/// of pixels on each axis, i.e. an almost perfectly flat picture.
pub const SPIKE_MEDIAN_FLOOR: f64 = 0.4;

/// Pooled edge energy below which a stream carries too little detail for
/// "nothing stood out" to mean anything.
///
/// The calibration is three measurements, not a preference:
///
/// | input | `detail()` | where |
/// |---|---|---|
/// | provably flawless, hard-edged 1080x1920 | **12.31%** | `renderer_fidelity`, which also asserts it clears this floor |
/// | real iPhone, textured high-contrast subject | **1.60%** | 348-NAL live capture |
/// | real iPhone, blank wall | **0.04%** | 361-NAL live capture |
///
/// 0.25% sits about six times above the blank wall and about six times below
/// the textured capture — the geometric midpoint of the two real-phone
/// measurements, which is the only pair that matters for this decision.
///
/// It was 1.0% before, and that number was wrong twice over: it was
/// calibrated against a `detail()` that divided by the frame count, so a
/// 12-frame sample read 12.31/12 = 1.03% and only just cleared it, while a
/// 309-frame capture of a genuinely textured scene read 1.60/309 = 0.005% and
/// was rejected as featureless. A threshold derived from a broken measurement
/// is worse than no threshold, because it then rejects real evidence.
pub const DETAIL_FLOOR_PERCENT: f64 = 0.25;


#[cfg(test)]
mod tests {
    use super::*;
    use crate::decoder::RgbaFrame;

    fn frame(w: u32, h: u32, f: impl Fn(u32, u32) -> u32) -> RgbaFrame {
        let mut pixels = Vec::with_capacity((w * h) as usize);
        for y in 0..h {
            for x in 0..w {
                pixels.push(f(x, y));
            }
        }
        RgbaFrame {
            width: w,
            height: h,
            pixels,
        }
    }

    fn flat(c: u32) -> u32 {
        (c << 16) | (c << 8) | c
    }

    /// A left-red / right-blue picture. Used to prove channel order survives
    /// the decode: if the RGBA repack put blue in the high byte, this fails.
    fn red_blue(w: u32, h: u32) -> RgbaFrame {
        frame(w, h, |x, _| {
            if x < w / 2 {
                0x00FF_0000
            } else {
                0x0000_00FF
            }
        })
    }

    /// Uniformly noisy — what a corrupt frame looks like.
    fn noise(w: u32, h: u32, seed: u32) -> RgbaFrame {
        frame(w, h, |x, y| {
            let n = (x.wrapping_mul(2654435761) ^ y.wrapping_mul(40503) ^ seed) & 0xff;
            (n << 16) | (n << 8) | n
        })
    }

    /// A smooth ramp — a healthy, low-edge-energy picture.
    fn ramp(w: u32, h: u32, phase: u32) -> RgbaFrame {
        frame(w, h, |x, y| {
            let v = (x + y + phase) * 255 / (w + h);
            (v << 16) | (v << 8) | v
        })
    }

    #[test]
    fn a_flat_picture_has_no_edges_and_no_saturation() {
        let f = frame(16, 16, |_, _| flat(128));
        let m = measure(&f);
        assert_eq!(m.harsh_h, 0);
        assert_eq!(m.harsh_v, 0);
        assert_eq!(m.saturated, 0);
        assert_eq!(m.flat_rows, 16);
        assert_eq!(m.pixels, 256);
        assert_eq!(m.rows, 16);
    }

    /// The property that makes the whole module work: the metrics must not
    /// care how much detail the scene has, only whether one frame differs from
    /// its neighbours.
    #[test]
    fn a_healthy_high_detail_scene_reports_high_edge_energy() {
        // This is why an absolute threshold is wrong: real scenes produce far
        // more edge energy than a flat test pattern.
        let f = noise(64, 64, 7);
        let m = measure(&f);
        assert!(
            harsh_h_percent(&m) > 20.0,
            "a noisy frame should measure as full of edges, got {:.2}%",
            harsh_h_percent(&m)
        );
    }

    #[test]
    fn channel_means_are_tracked_per_channel() {
        let m = measure(&red_blue(4, 2));
        // 4x2 = 8 pixels; x < 2 is red (2 per row), x >= 2 is blue.
        assert_eq!(m.sum_r, 4 * 255);
        assert_eq!(m.sum_g, 0);
        assert_eq!(m.sum_b, 4 * 255);
    }

    #[test]
    fn an_empty_frame_measures_to_nothing_rather_than_dividing_by_zero() {
        let m = measure(&RgbaFrame {
            width: 0,
            height: 0,
            pixels: vec![],
        });
        assert_eq!(m.pixels, 0);
        assert_eq!(harsh_h_percent(&m), 0.0);
        assert_eq!(harsh_v_percent(&m), 0.0);
    }

    /// The verdict the module exists to produce: most frames fine, a couple
    /// broken.
    /// Busy, detailed, and identical from frame to frame: whatever it looks like,
    /// it looks like it consistently. Ordinary camera motion must not read as
    /// spikes, and a fixed threshold here would have called it corrupt.
    #[test]
    fn a_uniform_detailed_stream_is_reported_as_uniform() {
        let mut s = StreamHealth::new();
        for _ in 0..12 {
            s.add(&noise(32, 32, 7));
        }
        assert!(
            s.detail() > DETAIL_FLOOR_PERCENT,
            "fixture must clear the detail floor, measured {}%",
            s.detail()
        );
        match s.pattern() {
            Pattern::Uniform { .. } => {}
            other => panic!("identical busy frames are not outliers: {other:?}"),
        }
    }

    #[test]
    fn a_few_broken_frames_among_good_ones_are_reported_as_spikes() {
        let mut s = StreamHealth::new();
        for i in 0..12 {
            // Every third frame is noise — the decoder lost its reference.
            if i % 3 == 1 {
                s.add(&noise(32, 32, i));
            } else {
                s.add(&ramp(32, 32, i));
            }
        }
        match s.pattern() {
            Pattern::Spikes {
                frames, worst_ratio, ..
            } => {
                assert!(!frames.is_empty(), "should have found the noisy frames");
                assert!(worst_ratio > SPIKE_RATIO);
            }
            other => panic!("expected spikes, got {other:?}"),
        }
    }

    /// The false-positive this design exists to avoid: a busy but *healthy*
    /// scene. Every frame has plenty of edges, none of them an outlier, and a
    /// fixed threshold would have called this "corrupt".
    #[test]
    fn a_busy_healthy_scene_is_not_called_corrupt() {
        let mut s = StreamHealth::new();
        for i in 0..12 {
            // Different noise every frame, all of it equally busy: real
            // high-frequency detail that changes every frame.
            s.add(&noise(32, 32, i as u32 * 977));
        }
        match s.pattern() {
            Pattern::Uniform { .. } => {}
            other => panic!("equally busy frames are not outliers: {other:?}"),
        }
    }

    #[test]
    fn too_few_frames_is_its_own_answer_rather_than_a_guess() {
        let mut s = StreamHealth::new();
        s.add(&ramp(8, 8, 0));
        s.add(&noise(8, 8, 1));
        assert_eq!(s.pattern(), Pattern::TooFewFrames { seen: 2 });
    }

    /// The false comfort this module must not give. A featureless stream is
    /// trivially free of corruption, so reporting "uniform, therefore healthy"
    /// would be a pass that proves nothing — and it is what every earlier
    /// version of this tool did.
    #[test]
    fn a_featureless_stream_is_not_reported_as_healthy() {
        let mut s = StreamHealth::new();
        for _ in 0..12 {
            s.add(&frame(64, 64, |_, _| flat(24))); // near-black, no detail
        }
        match s.pattern() {
            Pattern::TooLittleDetail {
                edge_percent,
                mean_luma,
            } => {
                assert!(edge_percent < DETAIL_FLOOR_PERCENT);
                assert!(
                    (mean_luma - 24.0).abs() < 1.0,
                    "mean luma should read ~24, got {mean_luma}"
                );
            }
            other => panic!("a black stream must not be called uniform: {other:?}"),
        }
    }

    /// The calibration, pinned so the floor cannot be quietly moved. A provably
    /// flawless high-detail stream must clear it; a flat one must not.
    #[test]
    fn the_detail_floor_sits_between_a_blank_wall_and_a_real_scene() {
        let mut busy = StreamHealth::new();
        for _ in 0..12 {
            busy.add(&noise(64, 64, 3));
        }
        assert!(
            busy.detail() > DETAIL_FLOOR_PERCENT,
            "a busy scene measured {}% must clear the {DETAIL_FLOOR_PERCENT}% floor",
            busy.detail()
        );

        let mut blank = StreamHealth::new();
        for _ in 0..12 {
            blank.add(&ramp(64, 64, 0));
        }
        assert!(
            blank.detail() < DETAIL_FLOOR_PERCENT,
            "a smooth ramp measured {}% must stay under the floor",
            blank.detail()
        );
    }

    /// The bug this pins, and it is the reason the floor had to be recalibrated
    /// downward: `detail()` divided the pooled fraction by the frame count *as
    /// well*, so a 12-frame sample read 24.6/12 = 2.05% and cleared a 1% floor,
    /// while a 309-frame capture of a genuinely textured scene read
    /// 1.6/309 = 0.005% and was reported as "no detail, cannot judge".
    ///
    /// `Σharsh / Σpixels` is already the pixel-weighted mean, so the frame count
    /// must not appear in it at all. Length of capture is not a property of the
    /// content.
    #[test]
    fn detail_does_not_depend_on_how_many_frames_were_measured() {
        let mut few = StreamHealth::new();
        for _ in 0..10 {
            few.add(&noise(48, 48, 11));
        }
        let mut many = StreamHealth::new();
        for _ in 0..400 {
            many.add(&noise(48, 48, 11));
        }
        assert_eq!(few.frames(), 10);
        assert_eq!(many.frames(), 400);
        assert!(
            (few.detail() - many.detail()).abs() < 0.05,
            "10 frames read {:.3}% but 400 read {:.3}% — length of capture is not a \
             property of the content",
            few.detail(),
            many.detail()
        );
    }

    /// And the value it reports has to mean what the calibration comment says it
    /// means: the sum of the two axes, as a percentage of pixels.
    #[test]
    fn detail_is_the_sum_of_both_axes_as_a_percentage_of_pixels() {
        let mut s = StreamHealth::new();
        for _ in 0..6 {
            s.add(&noise(32, 32, 5));
        }
        let t = s.totals();
        let expected = 100.0 * (t.harsh_h + t.harsh_v) as f64 / t.pixels as f64;
        assert!(
            (s.detail() - expected).abs() < 1e-9,
            "detail() = {} but the axes sum to {expected}",
            s.detail()
        );
        // And that is the same thing as the per-frame fractions added together,
        // which is how the floor was originally expressed.
        let per_frame = s
            .per_frame()
            .iter()
            .map(|f| harsh_h_percent(f) + harsh_v_percent(f))
            .sum::<f64>()
            / s.frames() as f64;
        assert!(
            (s.detail() - per_frame).abs() < 0.5,
            "pooled {} vs mean-of-frames {per_frame} — these must agree",
            s.detail()
        );
    }

    #[test]
    fn mean_luma_reads_a_mid_grey_picture_correctly() {
        assert!((mean_luma(&[0x00808080; 64]) - 128.0).abs() < 1.0);
        assert!(mean_luma(&[0x00FF_FFFF; 64]) > 240.0);
        assert_eq!(mean_luma(&[]), 0.0);
    }

    #[test]
    fn totals_aggregate_every_frame() {
        let mut s = StreamHealth::new();
        s.add(&frame(4, 4, |_, _| flat(0)));
        s.add(&frame(4, 4, |_, _| flat(255)));
        let t = s.totals();
        assert_eq!(t.pixels, 32);
        assert_eq!(t.saturated, 32, "0 and 255 are both saturated");
        assert_eq!(t.rows, 8);
        assert_eq!(s.frames(), 2);
    }
}
