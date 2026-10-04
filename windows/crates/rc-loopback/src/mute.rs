//! Deciding whether muting the PC's own volume has broken the feature.
//!
//! # The uncertainty this exists to handle
//!
//! On macOS the tap has `muteBehavior = .mutedWhenTapped`, so "the Mac goes
//! quiet while the phone plays" is one property of the capture and needs no
//! design. Windows has no equivalent: the only lever is the endpoint's master
//! volume.
//!
//! What is **not known without measuring** is whether lowering the master
//! volume also zeroes the loopback signal. If it does, muting would silence
//! the very audio we are trying to send, and the headline feature would fail
//! in the exact configuration a user is most likely to choose. Project
//! discipline is explicit that this is not a thing to reason about and ship —
//! so it is measured, at runtime, on the user's own machine.
//!
//! # What can and cannot be concluded
//!
//! The test is an A/B, and an A/B needs a "before":
//!
//! * Audio heard **before** the mute, then digital silence **after** it, means
//!   the mute silenced the capture. [`MuteVerdict::MuteSilencedCapture`].
//! * No audio before the mute means the system was quiet anyway, and silence
//!   afterwards proves nothing. [`MuteVerdict::Inconclusive`] — and crucially
//!   NOT a reason to unmute, because doing that on a guess would start playing
//!   the user's audio out of their speakers for no stated reason.
//!
//! Either way the caller un-mutes on `MuteSilencedCapture`, so the failure mode
//! is "the PC keeps playing" rather than "the feature is dead".

/// What the watcher concluded from what it has seen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MuteVerdict {
    /// Nothing to report. Either not muted, or the evidence is not there.
    Healthy,
    /// The capture was carrying audio and then went perfectly silent after the
    /// master volume was lowered. The volume has to go back up.
    MuteSilencedCapture,
    /// Muted, but the system was quiet before the mute, so nothing can be
    /// concluded. Keep waiting; do not touch the volume.
    Inconclusive,
}

/// Packets of continuous digital silence that make `MuteSilencedCapture`
/// credible.
///
/// A packet is 20 ms, so 75 packets is 1.5 s. Long enough that a gap between
/// two tracks does not trigger it, short enough that the user has not given up.
pub const SILENCE_PACKETS_BEFORE_VERDICT: u64 = 75;

/// Below this, a packet is digital silence rather than a sound too quiet to
/// hear. Int16 full scale is 32767, so this is about -60 dBFS: quieter than
/// that and the user hears nothing either, which makes the A/B meaningless.
const AUDIBLE_FLOOR: f64 = 32.0;

/// The per-capture state behind [`MuteVerdict`]. Fed one packet at a time.
#[derive(Debug, Clone, Default)]
pub struct MuteWatch {
    muted: bool,
    /// Has any packet so far been audible? The live answer.
    saw_audible: bool,
    /// Did the capture carry real audio before the volume was lowered? The
    /// snapshot `on_muted` freezes, so a loud packet *after* the mute cannot
    /// retroactively supply the baseline.
    heard_audio_before_mute: bool,
    silent_packets_in_a_row: u64,
    /// Set once a verdict has been delivered, so the caller is told once and
    /// not on every subsequent packet.
    reported: bool,
}

impl MuteWatch {
    pub fn new(muted: bool) -> Self {
        Self {
            muted,
            ..Default::default()
        }
    }

    /// Whether the volume is currently lowered by us.
    pub fn is_muted(&self) -> bool {
        self.muted
    }

    /// Called when the volume is lowered. Everything already seen becomes the
    /// "before" half of the A/B, and the silence counter restarts.
    pub fn on_muted(&mut self) {
        if !self.muted {
            self.heard_audio_before_mute = self.saw_audible;
            self.silent_packets_in_a_row = 0;
        }
        self.muted = true;
        self.reported = false;
    }

    /// Called when the volume is restored.
    pub fn on_unmuted(&mut self) {
        self.muted = false;
        self.saw_audible = false;
        self.silent_packets_in_a_row = 0;
        self.reported = false;
    }

    /// Feed one packet's RMS.
    pub fn feed(&mut self, packet_rms: f64) -> MuteVerdict {
        let audible = packet_rms.is_finite() && packet_rms >= AUDIBLE_FLOOR;
        if audible {
            self.saw_audible = true;
        }
        if !self.muted {
            return MuteVerdict::Healthy;
        }
        // Before the mute, audio is the baseline rather than a contradiction.
        if !self.heard_audio_before_mute {
            return if audible {
                MuteVerdict::Healthy
            } else {
                MuteVerdict::Inconclusive
            };
        }
        if audible {
            self.silent_packets_in_a_row = 0;
            return MuteVerdict::Healthy;
        }
        self.silent_packets_in_a_row += 1;
        if !self.reported && self.silent_packets_in_a_row >= SILENCE_PACKETS_BEFORE_VERDICT {
            self.reported = true;
            return MuteVerdict::MuteSilencedCapture;
        }
        MuteVerdict::Healthy
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LOUD: f64 = 4_000.0;
    const SILENT: f64 = 0.0;
    /// Just under the floor: too quiet to hear, so it must count as silence.
    const INAUDIBLE: f64 = 10.0;

    fn muted_with_baseline() -> MuteWatch {
        let mut w = MuteWatch::new(false);
        w.feed(LOUD);
        w.on_muted();
        w
    }

    #[test]
    fn not_muted_never_reports_a_problem() {
        let mut w = MuteWatch::new(false);
        for _ in 0..500 {
            assert_eq!(w.feed(SILENT), MuteVerdict::Healthy);
        }
    }

    /// The headline case: audio was flowing, we lowered the volume, and the
    /// capture went perfectly silent. That is the mute breaking the feature.
    #[test]
    fn silence_after_audio_while_muted_is_reported() {
        let mut w = muted_with_baseline();
        // Not immediately — one silent packet is a gap between tracks.
        for _ in 0..(SILENCE_PACKETS_BEFORE_VERDICT - 1) {
            assert_eq!(w.feed(SILENT), MuteVerdict::Healthy);
        }
        assert_eq!(w.feed(SILENT), MuteVerdict::MuteSilencedCapture);
    }

    /// Reported once, not on every packet afterwards, so the caller does not
    /// restore the volume over and over.
    #[test]
    fn the_verdict_is_delivered_once() {
        let mut w = muted_with_baseline();
        let mut hits = 0;
        for _ in 0..(SILENCE_PACKETS_BEFORE_VERDICT * 3) {
            if w.feed(SILENT) == MuteVerdict::MuteSilencedCapture {
                hits += 1;
            }
        }
        assert_eq!(hits, 1, "the caller must be told once, not on every packet");
    }

    /// The honest limit: a quiet system proves nothing, and must not cause the
    /// volume to be restored on a guess.
    #[test]
    fn silence_without_a_baseline_is_inconclusive_not_a_failure() {
        let mut w = MuteWatch::new(false);
        w.feed(SILENT);
        w.on_muted();
        for _ in 0..(SILENCE_PACKETS_BEFORE_VERDICT * 4) {
            assert_eq!(w.feed(SILENT), MuteVerdict::Inconclusive);
        }
    }

    /// The case where muting works: audio before, audio after. This is the
    /// whole feature working, so the watcher must stay quiet.
    #[test]
    fn audio_continuing_after_the_mute_is_healthy() {
        let mut w = muted_with_baseline();
        for _ in 0..(SILENCE_PACKETS_BEFORE_VERDICT * 4) {
            assert_eq!(w.feed(LOUD), MuteVerdict::Healthy);
        }
    }

    /// The baseline is frozen at the moment of muting: audio arriving after
    /// cannot supply the "before", or the feature could never be judged.
    #[test]
    fn the_baseline_is_frozen_when_the_volume_goes_down() {
        let mut w = MuteWatch::new(false);
        assert_eq!(w.feed(SILENT), MuteVerdict::Healthy);
        w.on_muted();
        // Audio now, silence later: the "before" had nothing in it.
        w.feed(LOUD);
        for _ in 0..(SILENCE_PACKETS_BEFORE_VERDICT * 2) {
            assert_eq!(w.feed(SILENT), MuteVerdict::Inconclusive);
        }
    }

    /// A short silence that then recovers is a gap in the music, not a mute
    /// that broke the capture — so the counter has to reset.
    #[test]
    fn a_gap_that_reopens_resets_the_silence_run() {
        let mut w = muted_with_baseline();
        for _ in 0..(SILENCE_PACKETS_BEFORE_VERDICT - 1) {
            w.feed(SILENT);
        }
        assert_eq!(w.feed(LOUD), MuteVerdict::Healthy);
        for _ in 0..(SILENCE_PACKETS_BEFORE_VERDICT - 1) {
            assert_eq!(w.feed(SILENT), MuteVerdict::Healthy);
        }
    }

    /// Too quiet to hear must count as silence, or the feature "works" for a
    /// volume the user cannot hear.
    #[test]
    fn audio_below_the_floor_counts_as_silence() {
        let mut w = muted_with_baseline();
        for _ in 0..(SILENCE_PACKETS_BEFORE_VERDICT - 1) {
            w.feed(INAUDIBLE);
        }
        assert_eq!(w.feed(INAUDIBLE), MuteVerdict::MuteSilencedCapture);
    }

    /// A NaN RMS compares false against everything, so it could read as either
    /// "audible" or "silence" depending on which side of the test it lands.
    /// It must never be audible.
    #[test]
    fn a_nan_level_never_looks_audible() {
        let mut w = MuteWatch::new(false);
        assert_eq!(w.feed(f64::NAN), MuteVerdict::Healthy);
        w.feed(LOUD);
        w.on_muted();
        assert_eq!(w.feed(f64::NAN), MuteVerdict::Healthy);
    }

    #[test]
    fn unmuting_clears_the_baseline_so_the_next_mute_remeasures() {
        let mut w = muted_with_baseline();
        for _ in 0..SILENCE_PACKETS_BEFORE_VERDICT {
            w.feed(SILENT);
        }
        w.on_unmuted();
        assert!(!w.is_muted());
        // No audio since the unmute, so silence proves nothing now.
        for _ in 0..(SILENCE_PACKETS_BEFORE_VERDICT * 2) {
            w.feed(SILENT);
        }
        w.on_muted();
        assert_eq!(w.feed(SILENT), MuteVerdict::Inconclusive);
    }
}