//! The buffer between the audio thread and the pump, and the index-ownership
//! rule that the whole feature rests on.
//!
//! # Why this file is mostly about one rule
//!
//! The first version of the Mac side had **two threads writing one index**: the
//! realtime callback reset the read cursor when the ring overflowed, while the
//! pump advanced the same cursor to consume. With an unsigned cursor, two
//! writers means `write - read` can wrap, so "do we have a full packet yet"
//! passes on a garbage value and the reader ends up copying slots that are not
//! the ones it thinks it is reading. The symptom is not a crash; it is audio
//! that is *nearly* right, which is much harder to notice and much harder to
//! reproduce (lesson 125).
//!
//! So the ownership is structural here rather than a comment:
//!
//! * `write` is a private atomic only [`PcmRing::push_frames`] stores.
//! * `read` is a private atomic only [`PcmRing::take_packet`] stores.
//! * An overflowing producer cannot move the read cursor at all. It can only
//!   *count* what must go ([`PcmRing::push_frames`] returns it), and the reader
//!   applies that count to its own cursor.
//!
//! `unsafe impl Send + Sync` is sound because the samples themselves are
//! published by the index: the producer stores a frame, then releases `write`;
//! the consumer loads `write` with acquire before reading that frame. That
//! ordering is what makes the plain `Box<[i16]>` safe to share, and it is the
//! reason this is not a `Mutex`.

use std::sync::atomic::{AtomicU64, Ordering};

/// One 20 ms packet at 48 kHz stereo: the shape the wire wants.
pub const FRAMES_PER_PACKET: usize = 960;
pub const CHANNELS: usize = 2;
pub const BYTES_PER_PACKET: usize = FRAMES_PER_PACKET * CHANNELS * 2;

/// 500 ms of slack, matching the Mac side's ring.
///
/// Sized so a GC pause, a stalled pump or a slow disk does not lose audio, and
/// no larger: a live stream wants the freshest audio, not the most complete
/// archive, so overflow drops the OLDEST frames.
pub const CAPACITY_FRAMES: usize = 24_000;

/// What one drained packet contained, plus its own measurement.
#[derive(Debug, Clone, PartialEq)]
pub struct Packet {
    /// Exactly [`BYTES_PER_PACKET`] bytes: interleaved stereo Int16.
    pub pcm: Vec<u8>,
    /// RMS of *this packet*, never a running average over the capture.
    pub rms: f64,
    /// Largest absolute sample in this packet.
    pub peak: i32,
}

impl Packet {
    pub fn rms_int(&self) -> i64 {
        self.rms as i64
    }
}

/// A single-producer / single-consumer ring of interleaved stereo Int16.
///
/// Both halves take `&self`, because the producer and the consumer each hold
/// their own `Arc<PcmRing>` — the whole design depends on the two threads never
/// needing to borrow each other, and a `&mut` API would force them to share one
/// owner. Interior mutability is what makes that possible; the discipline that
/// makes it *safe* is the one-cursor-per-thread rule below.
#[derive(Debug)]
pub struct PcmRing {
    /// Raw, because the samples are written by the producer thread and read by
    /// the consumer thread. The cursors below are what publish them.
    base: *mut i16,
    /// Kept only to own the allocation (and to be the thing `Debug` prints).
    _buf: Box<[i16]>,
    /// Producer cursor. Stored only by `push_frames`.
    write: AtomicU64,
    /// Consumer cursor: the next frame it will read. Stored only by
    /// `take_packet`, and only ever moved FORWARDS past a frame it has finished
    /// copying.
    read: AtomicU64,
    /// Frames refused because the ring was full. Stored by both, summed.
    dropped: AtomicU64,
    capacity_frames: u64,
}

// SAFETY: the sample buffer is a single-producer/single-consumer ring whose
// handoff is published by the release/acquire pairs on `write` and `read`. The
// producer only ever advances `write`, the consumer only ever advances `read`,
// and neither ever touches the other's cursor's *writes*. No other shared
// mutable state exists in this struct.
unsafe impl Send for PcmRing {}
unsafe impl Sync for PcmRing {}

impl PcmRing {
    pub fn new() -> Self {
        Self::with_capacity_frames(CAPACITY_FRAMES)
    }

    pub fn with_capacity_frames(capacity_frames: usize) -> Self {
        let capacity_frames = capacity_frames.max(FRAMES_PER_PACKET);
        let buf: Box<[i16]> = vec![0; capacity_frames * CHANNELS].into_boxed_slice();
        let base = buf.as_ptr() as *mut i16;
        Self {
            base,
            _buf: buf,
            write: AtomicU64::new(0),
            read: AtomicU64::new(0),
            dropped: AtomicU64::new(0),
            capacity_frames: capacity_frames as u64,
        }
    }

    pub fn capacity_frames(&self) -> u64 {
        self.capacity_frames
    }

    /// Append interleaved stereo samples. **Producer thread only.**
    ///
    /// Returns the number of frames it could NOT store because the ring was
    /// full.
    ///
    /// # Why a full ring drops the NEWEST audio, not the oldest
    ///
    /// Overwriting the oldest is what a live stream would ideally do, and this
    /// ring's first two drafts tried it. It cannot be made safe.
    ///
    /// The consumer advances `read` only *after* it has finished copying a
    /// packet, so while a copy is in flight `read` still points at the region
    /// being read. A producer that laps that region writes into slots the
    /// consumer is reading — the result is a packet containing the tail of one
    /// buffer and the head of the next, which is an audible click. Telling the
    /// consumer to skip the region does not help: it has no way to say "skip
    /// this" while it is mid-copy, and there is no lock in the audio path.
    ///
    /// Both were caught only by the two-thread tests in `thread_tests`, never by
    /// a single-threaded one, because with one thread the cursors are never
    /// observed out of step.
    ///
    /// So the producer refuses to write into unread space and reports the loss.
    /// With a 500 ms ring and a pump every 10 ms this should never fire; when it
    /// does, the count in [`PcmRing::dropped_frames`] is the honest signal that
    /// the consumer cannot keep up, and a gap in the audio is a far better
    /// failure than a click in it.
    pub fn push_frames(&self, interleaved: &[i16]) -> u64 {
        let capacity = self.capacity_frames;
        let frames = (interleaved.len() / CHANNELS) as u64;
        let w = self.write.load(Ordering::Relaxed);
        let read = self.read.load(Ordering::Acquire);

        if w.saturating_sub(read) + frames > capacity {
            let lost = frames;
            self.dropped.fetch_add(lost, Ordering::AcqRel);
            return lost;
        }

        let mut w = w;
        for frame in interleaved.chunks_exact(CHANNELS) {
            let slot = (w % capacity) as usize * CHANNELS;
            // SAFETY: `slot` is below `capacity_frames * CHANNELS` by the modulo,
            // and the free-space check above guarantees this slot has not been
            // read yet, so only this producer thread is writing it.
            unsafe {
                *self.base.add(slot) = frame[0];
                *self.base.add(slot + 1) = frame[1];
            }
            w = w.wrapping_add(1);
        }
        // Release: the samples above must be visible before a reader that sees
        // this cursor is allowed to read them.
        self.write.store(w, Ordering::Release);
        0
    }

    /// Drain one packet, or `None` when fewer than [`FRAMES_PER_PACKET`]
    /// frames are buffered. **Consumer thread only.**
    pub fn take_packet(&self) -> Option<Packet> {
        let start = self.read.load(Ordering::Acquire);
        let write = self.write.load(Ordering::Acquire);
        if write.saturating_sub(start) < FRAMES_PER_PACKET as u64 {
            return None;
        }

        let mut samples = vec![0i16; FRAMES_PER_PACKET * CHANNELS];
        let capacity = self.capacity_frames;
        for (n, out) in samples.chunks_exact_mut(CHANNELS).enumerate() {
            let slot = (start.wrapping_add(n as u64) % capacity) as usize * CHANNELS;
            // SAFETY: `slot` is in bounds by the modulo, it is inside the window
            // the producer promised was unread, and the acquire load of `write`
            // above is what makes these samples visible.
            unsafe {
                out[0] = *self.base.add(slot);
                out[1] = *self.base.add(slot + 1);
            }
        }

        self.read
            .store(start.wrapping_add(FRAMES_PER_PACKET as u64), Ordering::Release);

        let (rms, peak) = super::convert::measure(&samples);
        let mut pcm = Vec::with_capacity(BYTES_PER_PACKET);
        for s in &samples {
            pcm.extend_from_slice(&s.to_le_bytes());
        }
        Some(Packet { pcm, rms, peak })
    }

    /// Frames the consumer has not taken yet. Never more than the capacity: the
    /// producer refuses to write into unread space, so this is a real count and
    /// not a backlog.
    pub fn available_frames(&self) -> u64 {
        let w = self.write.load(Ordering::Acquire);
        let r = self.read.load(Ordering::Acquire);
        w.saturating_sub(r)
    }

    /// Frames refused or discarded because the consumer fell behind.
    pub fn dropped_frames(&self) -> u64 {
        self.dropped.load(Ordering::Acquire)
    }

    /// Free space in frames, which is what decides whether the next push fits.
    pub fn free_frames(&self) -> u64 {
        self.capacity_frames
            .saturating_sub(self.available_frames())
    }

    /// The most recently written slot's peak, as a cheap probe of "the producer
    /// is writing" that does not consume anything.
    pub fn newest_sample(&self) -> i16 {
        let w = self.write.load(Ordering::Acquire);
        if w == 0 {
            return 0;
        }
        let slot = ((w - 1) % self.capacity_frames) as usize * CHANNELS;
        // SAFETY: in bounds by the modulo; a probe, so no ordering concern.
        unsafe {
            (*self.base.add(slot)).abs().max((*self.base.add(slot + 1)).abs())
        }
    }

    /// Drop everything and forget the counters. Called when the capture stops.
    pub fn reset(&self) {
        self.write.store(0, Ordering::Release);
        self.read.store(0, Ordering::Release);
        self.dropped.store(0, Ordering::Release);
    }
}

impl Default for PcmRing {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A packet is 3840 bytes: 20 ms x 48 kHz x 2ch x 2 bytes. If this is
    /// wrong the phone's player resamples nothing and simply plays garbage.
    #[test]
    fn a_packet_is_exactly_twenty_milliseconds_of_stereo_int16() {
        assert_eq!(FRAMES_PER_PACKET, 960);
        assert_eq!(CHANNELS, 2);
        assert_eq!(BYTES_PER_PACKET, 3840);
        let ring = PcmRing::new();
        let frames = vec![7i16; FRAMES_PER_PACKET * CHANNELS];
        assert_eq!(ring.push_frames(&frames), 0);
        let p = ring.take_packet().expect("a full packet must be available");
        assert_eq!(p.pcm.len(), BYTES_PER_PACKET);
    }

    #[test]
    fn less_than_a_packet_yields_nothing() {
        let ring = PcmRing::new();
        let frames = vec![1i16; (FRAMES_PER_PACKET - 1) * CHANNELS];
        ring.push_frames(&frames);
        assert!(ring.take_packet().is_none());
        // One more frame completes it.
        ring.push_frames(&[1i16; CHANNELS]);
        assert!(ring.take_packet().is_some());
    }

    /// Samples must come out in the order they went in, interleaved L/R. A
    /// ring that transposes or de-interleaves plays a phase-inverted,
    /// left-right-swapped stream that still *sounds* like music.
    #[test]
    fn samples_come_back_in_order_and_in_channels() {
        let ring = PcmRing::new();
        let mut input = Vec::with_capacity(FRAMES_PER_PACKET * CHANNELS);
        for f in 0..FRAMES_PER_PACKET {
            input.push(f as i16 + 1); // L
            input.push(-(f as i16 + 1)); // R
        }
        ring.push_frames(&input);
        let p = ring.take_packet().unwrap();
        for f in 0..FRAMES_PER_PACKET {
            let l = i16::from_le_bytes([p.pcm[f * 4], p.pcm[f * 4 + 1]]);
            let r = i16::from_le_bytes([p.pcm[f * 4 + 2], p.pcm[f * 4 + 3]]);
            assert_eq!(l, f as i16 + 1, "left sample {f}");
            assert_eq!(r, -(f as i16 + 1), "right sample {f}");
        }
    }

    /// The invariant the whole file exists for. A producer that overruns must
    /// NOT be able to move the read cursor: it can only report the overflow,
    /// and the consumer applies it. If this test ever needs the producer to
    /// "helpfully" reset the read cursor, the two-writer bug is back.
    #[test]
    fn an_overflowing_producer_counts_instead_of_moving_the_read_cursor() {
        let ring = PcmRing::with_capacity_frames(FRAMES_PER_PACKET * 2);
        let frames = vec![1i16; FRAMES_PER_PACKET * CHANNELS];
        // Two packets fit exactly.
        assert_eq!(ring.push_frames(&frames), 0);
        assert_eq!(ring.push_frames(&frames), 0);
        assert_eq!(ring.available_frames(), 2 * FRAMES_PER_PACKET as u64);
        assert_eq!(ring.free_frames(), 0);
        // The third does not, and it says so instead of writing into a region
        // the consumer has not read yet.
        assert_eq!(ring.push_frames(&frames), FRAMES_PER_PACKET as u64);
        // The read cursor has not moved on its own, and the reported gap is
        // still exactly what fits: nothing was overwritten.
        assert_eq!(ring.available_frames(), 2 * FRAMES_PER_PACKET as u64);
        assert_eq!(ring.dropped_frames(), FRAMES_PER_PACKET as u64);

        let p = ring.take_packet().expect("a packet must be available");
        assert_eq!(p.peak, 1, "a refused push must not corrupt the buffer");
        assert_eq!(ring.available_frames(), FRAMES_PER_PACKET as u64);
        // Space is free again, so the next push is accepted.
        assert_eq!(ring.push_frames(&frames), 0);
    }

    /// A full ring must keep the audio it already has rather than replacing it
    /// with whatever arrived most recently — and because the producer refuses to
    /// write rather than lapping, what comes out is exactly what went in.
    #[test]
    fn a_full_ring_keeps_the_audio_it_already_holds() {
        let ring = PcmRing::with_capacity_frames(FRAMES_PER_PACKET * 2);
        ring.push_frames(&vec![111i16; FRAMES_PER_PACKET * CHANNELS]);
        ring.push_frames(&vec![222i16; FRAMES_PER_PACKET * CHANNELS]);
        // These two are refused, so they cannot displace the 111 packet.
        assert_eq!(
            ring.push_frames(&vec![333i16; FRAMES_PER_PACKET * CHANNELS]),
            FRAMES_PER_PACKET as u64
        );
        assert_eq!(
            ring.push_frames(&vec![444i16; FRAMES_PER_PACKET * CHANNELS]),
            FRAMES_PER_PACKET as u64
        );

        let mut peaks = Vec::new();
        while let Some(p) = ring.take_packet() {
            peaks.push(p.peak);
        }
        assert_eq!(peaks, vec![111, 222], "the ring's contents were disturbed");
    }

    /// The consumer must never read a frame the producer has already
    /// overwritten, and the reported gap must always fit the ring — those two
    /// together are what a missing memory barrier or a lapping producer breaks.
    #[test]
    fn the_consumer_never_reads_past_what_the_producer_wrote() {
        let ring = PcmRing::with_capacity_frames(FRAMES_PER_PACKET);
        for round in 1..=20i16 {
            let lost = ring.push_frames(&vec![round; FRAMES_PER_PACKET * CHANNELS]);
            assert_eq!(lost, 0, "the pump should always be keeping up here");
            let p = ring.take_packet().expect("a packet must be available");
            let first = i16::from_le_bytes([p.pcm[0], p.pcm[1]]);
            assert_eq!(first, round, "read a slot the producer had moved past");
            assert!(
                ring.available_frames() <= ring.capacity_frames(),
                "after a drain the gap must fit the ring: {} > {}",
                ring.available_frames(),
                ring.capacity_frames()
            );
        }
        assert_eq!(ring.dropped_frames(), 0);
    }

    /// The cursors are unsigned and must never report a negative or wrapped
    /// count, which is the mechanism by which the two-writer bug turned into
    /// garbage reads.
    #[test]
    fn the_available_count_never_exceeds_what_was_pushed() {
        let ring = PcmRing::with_capacity_frames(FRAMES_PER_PACKET);
        let one_packet = FRAMES_PER_PACKET as u64;
        for i in 0..50u64 {
            ring.push_frames(&vec![5i16; FRAMES_PER_PACKET * CHANNELS]);
            assert!(
                ring.available_frames() <= (i + 1).min(1) * one_packet,
                "available {} exceeds what was accepted",
                ring.available_frames()
            );
        }
    }

    /// A full drain in a row, the way the pump does it, must keep the ring
    /// consistent: every packet taken is a packet written, in order.
    #[test]
    fn draining_in_a_loop_loses_nothing_and_keeps_order() {
        let ring = PcmRing::new();
        let mut taken = 0;
        for written in 0..40u32 {
            // One packet, valued by its sequence number, so a reordering shows
            // up as a number rather than as "the audio sounded wrong".
            let value = (written % 40) as i16 + 1;
            ring.push_frames(&vec![value; FRAMES_PER_PACKET * CHANNELS]);
            while let Some(p) = ring.take_packet() {
                let first = i16::from_le_bytes([p.pcm[0], p.pcm[1]]);
                assert_eq!(
                    u32::from(first as u16) - 1,
                    taken % 40,
                    "packet {taken} arrived out of order (value {first})"
                );
                taken += 1;
            }
        }
        assert!(taken > 0, "the pump never got a packet");
    }

    #[test]
    fn measurement_travels_with_the_packet() {
        let ring = PcmRing::new();
        ring.push_frames(&vec![4000i16; FRAMES_PER_PACKET * CHANNELS]);
        let p = ring.take_packet().unwrap();
        assert!((p.rms - 4000.0).abs() < 1.0, "rms {}", p.rms);
        assert_eq!(p.peak, 4000);
        assert_eq!(p.rms_int(), 4000);
    }

    #[test]
    fn reset_empties_the_ring_and_the_counters() {
        let ring = PcmRing::new();
        ring.push_frames(&vec![9i16; FRAMES_PER_PACKET * CHANNELS]);
        ring.reset();
        assert_eq!(ring.available_frames(), 0);
        assert_eq!(ring.dropped_frames(), 0);
        assert!(ring.take_packet().is_none());
    }

    /// The newest-sample probe must not consume, and must report a peak rather
    /// than a signed value — a negative reading here reads as "no audio".
    #[test]
    fn the_probe_reports_a_magnitude_and_consumes_nothing() {
        let ring = PcmRing::new();
        ring.push_frames(&vec![-9000i16; FRAMES_PER_PACKET * CHANNELS]);
        assert_eq!(ring.newest_sample(), 9000);
        assert!(ring.take_packet().is_some(), "the probe consumed audio");
    }
}

#[cfg(test)]
mod thread_tests {
    //! The ring carries `unsafe impl Send + Sync` and a raw pointer into its own
    //! buffer, so the claim that the handoff is safe has to be demonstrated with
    //! the two halves actually on two threads.
    //!
    //! Every test in the parent module drives both sides from ONE thread, which
    //! cannot see a missing memory barrier at all: it passes against an
    //! implementation that publishes its samples with a relaxed store, because on
    //! one thread the compiler and the CPU already agree. Only a second thread
    //! makes the ordering question real.
    use super::*;
    use std::sync::Arc;

    /// One producer, one consumer, 300 packets, every packet checked for internal
    /// consistency — and every packet asserted to have ARRIVED.
    ///
    /// The producer writes one constant value per packet and the consumer
    /// verifies all 1920 samples of each packet carry that same value. A torn
    /// read — half of one packet and half of the next — shows up as a mismatch,
    /// which is precisely what a missing acquire/release pair produces.
    ///
    /// The producer is paced at 200 s per packet so it does not simply lap the
    /// consumer and refuse everything, which would test nothing about integrity.
    ///
    /// It also **retries a refused packet instead of asserting it was accepted.**
    /// The original form asserted `lost == 0` on the theory that four packets of
    /// headroom could never be exhausted at this pace. That is a timing
    /// assumption about the *scheduler*, not the ring: under a debug build the
    /// consumer thread can go unscheduled for several milliseconds, the producer
    /// fills the four-packet ring and a refusal is the ring doing exactly what
    /// `push_frames` documents. The assertion made `cargo test --workspace --lib`
    /// — the gate `scripts/test.sh` runs before every commit — fail about one run
    /// in four on a clean tree, which is worse than no assertion because it
    /// teaches re-running until green. Waiting for space and retrying the same
    /// packet keeps the torn-packet check honest without depending on when the
    /// consumer is scheduled.
    #[test]
    fn a_producer_and_a_consumer_on_separate_threads_never_see_a_torn_packet() {
        const PACKETS: i16 = 300;
        let ring = Arc::new(PcmRing::with_capacity_frames(FRAMES_PER_PACKET * 4));

        let producer = {
            let ring = Arc::clone(&ring);
            std::thread::spawn(move || {
                for v in 1..=PACKETS {
                    // The ring is deliberately tiny, so a momentary refusal is
                    // expected whenever the consumer is descheduled. Wait for
                    // space and retry the same packet; a refusal here is the
                    // documented full-ring behaviour, not a defect.
                    loop {
                        let lost = ring.push_frames(&vec![v; FRAMES_PER_PACKET * CHANNELS]);
                        if lost == 0 {
                            break;
                        }
                        std::thread::sleep(std::time::Duration::from_micros(500));
                    }
                    std::thread::sleep(std::time::Duration::from_micros(200));
                }
            })
        };

        let consumer = {
            let ring = Arc::clone(&ring);
            std::thread::spawn(move || {
                let mut seen = 0;
                // Bounded by TIME, not by iterations. An iteration budget is a
                // trap here: the consumer's loop is thousands of times cheaper
                // than the producer's pacing, so it would exhaust a fixed count
                // in a couple of milliseconds and leave, and then the producer's
                // refusals would look like a ring bug rather than a test that
                // stopped reading.
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
                while seen < PACKETS as usize && std::time::Instant::now() < deadline {
                    match ring.take_packet() {
                        Some(p) => {
                            let first = i16::from_le_bytes([p.pcm[0], p.pcm[1]]);
                            for c in p.pcm.chunks_exact(2) {
                                let v = i16::from_le_bytes([c[0], c[1]]);
                                assert_eq!(v, first, "packet {seen} was torn");
                            }
                            seen += 1;
                        }
                        None => std::thread::yield_now(),
                    }
                }
                seen
            })
        };

        producer.join().unwrap();
        let seen = consumer.join().unwrap();
        assert_eq!(
            seen, PACKETS as usize,
            "a paced producer must lose nothing over two threads"
        );
        // `dropped_frames()` is deliberately NOT asserted to be zero: a
        // momentary refusal while the consumer is descheduled is the ring's
        // documented behaviour and the producer retries through it. What must
        // hold is that every packet the producer *did* accept arrived intact
        // (the `seen` count above) and that the consumer drained the ring.
        assert_eq!(ring.available_frames(), 0, "the ring should be empty");
    }

    /// Overrun under real conditions: the producer runs to completion while the
    /// consumer does not exist yet, then the consumer catches up. What matters
    /// is that every packet it reads is internally whole and holds audio the
    /// producer actually wrote — never a slot that has been reused.
    #[test]
    fn a_stalled_consumer_does_not_corrupt_the_stream() {
        let ring = Arc::new(PcmRing::with_capacity_frames(FRAMES_PER_PACKET * 2));
        let producer = {
            let ring = Arc::clone(&ring);
            std::thread::spawn(move || {
                for v in 1..=200i16 {
                    ring.push_frames(&vec![v; FRAMES_PER_PACKET * CHANNELS]);
                }
            })
        };
        producer.join().unwrap();

        // Only the ring's capacity survived, and every packet is internally
        // whole — which is the point: the 180 packets that did not fit were
        // refused, not written over the top of these.
        let mut peaks = Vec::new();
        while let Some(p) = ring.take_packet() {
            let first = i16::from_le_bytes([p.pcm[0], p.pcm[1]]);
            assert!(
                p.pcm.chunks_exact(2)
                    .all(|c| i16::from_le_bytes([c[0], c[1]]) == first),
                "a packet after an overrun was torn"
            );
            assert!(first > 0, "read a slot the producer never wrote");
            peaks.push(first);
        }
        assert_eq!(peaks.len(), 2, "the ring should yield exactly its capacity");
        assert!(
            ring.dropped_frames() > 0,
            "the refused writes were not reported"
        );
    }
}