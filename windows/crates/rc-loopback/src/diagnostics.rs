//! What the capture is doing, in a shape the app layer can read once per pump
//! tick and print a line from.
//!
//! One mutex, not a field per counter, because none of this is on the realtime
//! path: the producer updates it once per ~10 ms buffer and the consumer reads
//! it a few times a second. A mutex is cheaper to reason about than a handful
//! of atomics with a `f64` in the middle, and the thing that must NOT lock is
//! the ring — which is why the ring is separate and lock-free.
//!
//! The counters exist because "packets are moving" and "sound is arriving" look
//! identical from the wire. Three states have to be tellable apart and none of
//! them can be told from a packet count:
//!
//! * the capture is not running (a failure — `failure`)
//! * the capture is running and the system is silent (`captured_rms == 0`)
//! * the capture is running and carrying audio (`captured_rms > 0`)

use crate::convert::MixFormat;
use crate::LoopbackError;

/// The snapshot half, guarded by one `Mutex` owned by the capture.
#[derive(Debug, Default)]
pub struct Diagnostics {
    pub running: bool,
    pub captured_frames: u64,
    pub silent_buffers: u64,
    pub dropped_frames: u64,
    /// Sum of squares over everything captured, and how many samples went into
    /// it. Kept as the raw pair rather than a finished RMS so a caller can ask
    /// "what is it right now" without inheriting a running average.
    pub energy_sum: f64,
    pub energy_count: u64,
    pub peak: i32,
    pub mix: Option<MixFormat>,
    /// The endpoint we are actually capturing, e.g.
    /// `{0.0.0.00000000}.{7f4b2e50-…}`. Shown in the status so "the default
    /// output" is a nameable thing when it is the wrong one.
    pub endpoint_id: Option<String>,
    pub failure: Option<LoopbackError>,
    pub muted: bool,
    pub volume_before_mute: Option<f32>,
}

impl Diagnostics {
    /// RMS over everything captured so far. A diagnostic, not a per-packet
    /// reading — `Packet::rms` is the one that says whether *this* packet had
    /// sound in it.
    pub fn captured_rms(&self) -> f64 {
        if self.energy_count == 0 {
            return 0.0;
        }
        (self.energy_sum / self.energy_count as f64).sqrt()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_untouched_snapshot_reports_no_audio_rather_than_a_division_by_zero() {
        let d = Diagnostics::default();
        assert_eq!(d.captured_rms(), 0.0);
        assert_eq!(d.captured_frames, 0);
    }

    #[test]
    fn rms_follows_the_energy_it_was_given() {
        // 100 samples of amplitude 4: the sum of SQUARES is 16 each.
        let d = Diagnostics {
            energy_sum: 16.0 * 100.0,
            energy_count: 100,
            ..Default::default()
        };
        assert!((d.captured_rms() - 4.0).abs() < 1e-9);
    }
}