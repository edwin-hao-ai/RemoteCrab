//! Shared-memory **audio** ring between the RemoteCrab app (writer) and the
//! virtual-microphone driver (reader, loaded in `audiodg`/the kernel audio
//! stack).
//!
//! The sibling of [`rc_vcam::shm`], but audio cannot use a "latest frame wins"
//! slot: dropping video frames is invisible, while dropping PCM is a click.
//! So this is a **single-producer / single-consumer byte ring**: the app appends
//! PCM, the driver drains it at the rate the audio engine asks for. Positions
//! are monotonic byte counters, so the two sides agree on ordering without ever
//! sharing a pointer.
//!
//! Layout (little-endian, fixed):
//!
//! ```text
//! offset 0   u32  magic          ('RCMA')
//! offset 4   u32  version
//! offset 8   u32  sample_rate
//! offset 12  u32  channels
//! offset 16  u32  bits_per_sample (16)
//! offset 20  u32  capacity_bytes  (PCM area size)
//! offset 24  u64  write_pos       (bytes appended, monotonic)
//! offset 32  u64  read_pos        (bytes consumed by the driver, monotonic)
//! offset 40  u32  dropped_packets (writer: ring full)
//! offset 44  u32  underruns       (driver: asked for more than was in the ring)
//! offset 48  ..   reserved to 64
//! offset 64  PCM area (capacity_bytes, circular)
//! ```
//!
//! The live byte at ring position `p` sits at `HEADER_SIZE + (p % capacity)`.

pub const MAGIC: u32 = 0x5243_4D41; // 'RCMA'
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 64;

/// Bounds the reader uses before it trusts a `capacity_bytes` from the ring.
/// 64 MiB is ~5½ minutes of 48 kHz stereo; anything larger is a corrupt header,
/// not an ambitious buffer.
pub const MAX_CAPACITY_BYTES: u32 = 64 * 1024 * 1024;
pub const MIN_CAPACITY_BYTES: u32 = 4096;

/// Path of the file backing the ring.
///
/// File-backed under `%ProgramData%` for the same reason as the camera ring:
/// the writer runs in the user's session while the reader may be in a service
/// session, and a permissive-DACL file is visible to both whereas a session-
/// scoped `Local\` mapping is not.
pub fn ring_file_path() -> std::path::PathBuf {
    let base = std::env::var_os("ProgramData")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("C:\\ProgramData"));
    base.join("RemoteCrab").join("vmic-ring.bin")
}

/// Total mapping size for a given PCM ring capacity.
pub fn mapping_size(capacity_bytes: u32) -> usize {
    HEADER_SIZE + capacity_bytes as usize
}

/// A header view over a mapped region (unsafe: caller guarantees the region is
/// at least `HEADER_SIZE + capacity_bytes` bytes).
pub struct HeaderView;

impl HeaderView {
    /// # Safety
    /// `base` must point to a writable region of at least `HEADER_SIZE` bytes.
    #[allow(clippy::too_many_arguments)]
    pub unsafe fn write(
        base: *mut u8,
        sample_rate: u32,
        channels: u32,
        bits_per_sample: u32,
        capacity_bytes: u32,
        write_pos: u64,
        read_pos: u64,
        dropped_packets: u32,
        underruns: u32,
    ) {
        std::ptr::write_unaligned(base as *mut u32, MAGIC);
        std::ptr::write_unaligned(base.add(4) as *mut u32, VERSION);
        std::ptr::write_unaligned(base.add(8) as *mut u32, sample_rate);
        std::ptr::write_unaligned(base.add(12) as *mut u32, channels);
        std::ptr::write_unaligned(base.add(16) as *mut u32, bits_per_sample);
        std::ptr::write_unaligned(base.add(20) as *mut u32, capacity_bytes);
        std::ptr::write_unaligned(base.add(24) as *mut u64, write_pos);
        std::ptr::write_unaligned(base.add(32) as *mut u64, read_pos);
        std::ptr::write_unaligned(base.add(40) as *mut u32, dropped_packets);
        std::ptr::write_unaligned(base.add(44) as *mut u32, underruns);
    }

    /// Read the header, or `None` when the magic is wrong, the writer has not
    /// initialised it, or the format is not self-consistent.
    ///
    /// # Safety
    /// `base` must point to a readable region of at least `HEADER_SIZE` bytes.
    pub unsafe fn read(base: *const u8) -> Option<Header> {
        if std::ptr::read_unaligned(base as *const u32) != MAGIC {
            return None;
        }
        let header = Header {
            version: std::ptr::read_unaligned(base.add(4) as *const u32),
            sample_rate: std::ptr::read_unaligned(base.add(8) as *const u32),
            channels: std::ptr::read_unaligned(base.add(12) as *const u32),
            bits_per_sample: std::ptr::read_unaligned(base.add(16) as *const u32),
            capacity_bytes: std::ptr::read_unaligned(base.add(20) as *const u32),
            write_pos: std::ptr::read_unaligned(base.add(24) as *const u64),
            read_pos: std::ptr::read_unaligned(base.add(32) as *const u64),
            dropped_packets: std::ptr::read_unaligned(base.add(40) as *const u32),
            underruns: std::ptr::read_unaligned(base.add(44) as *const u32),
        };
        header.is_consistent().then_some(header)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub version: u32,
    pub sample_rate: u32,
    pub channels: u32,
    pub bits_per_sample: u32,
    pub capacity_bytes: u32,
    pub write_pos: u64,
    pub read_pos: u64,
    pub dropped_packets: u32,
    pub underruns: u32,
}

impl Header {
    pub const MIN_SAMPLE_RATE: u32 = 8_000;
    pub const MAX_SAMPLE_RATE: u32 = 192_000;

    /// Whether the format is internally consistent.
    ///
    /// The driver sizes its copy from `capacity_bytes` and interprets the PCM
    /// from the format fields, so a header left by a crashed or older writer
    /// must be refused rather than believed — in the audio engine's process,
    /// where a bad read is not something the user can see.
    pub fn is_consistent(&self) -> bool {
        if self.version == 0 || self.version > VERSION {
            return false;
        }
        if !(Self::MIN_SAMPLE_RATE..=Self::MAX_SAMPLE_RATE).contains(&self.sample_rate) {
            return false;
        }
        if self.channels == 0 || self.channels > 2 {
            return false;
        }
        if self.bits_per_sample != 16 {
            return false;
        }
        if self.capacity_bytes < MIN_CAPACITY_BYTES || self.capacity_bytes > MAX_CAPACITY_BYTES {
            return false;
        }
        // A full ring of frames must fit a whole sample frame.
        if !self.capacity_bytes.is_multiple_of(self.channels * 2) {
            return false;
        }
        self.read_pos <= self.write_pos
    }

    /// Bytes currently readable (not yet consumed by the driver).
    pub fn available(&self) -> u64 {
        self.write_pos.saturating_sub(self.read_pos)
    }

    /// Total bytes the mapping must have for this header.
    pub fn required_size(&self) -> Option<usize> {
        self.is_consistent()
            .then(|| HEADER_SIZE + self.capacity_bytes as usize)
    }
}

/// A deterministic sine tone, used by the self-test so the whole virtual-mic
/// path can be verified without a phone (the audio sibling of
/// `rc_vcam::shm::test_pattern_bgra`).
///
/// Returns `frames` interleaved 16-bit little-endian samples, `channels` wide.
pub fn test_tone(
    sample_rate: u32,
    channels: u32,
    freq_hz: f32,
    amplitude: f32,
    start_frame: u64,
    frames: usize,
) -> Vec<u8> {
    let ch = channels.max(1) as usize;
    let amp = amplitude.clamp(0.0, 1.0) * i16::MAX as f32;
    let mut out = Vec::with_capacity(frames * ch * 2);
    for f in 0..frames {
        let t = (start_frame + f as u64) as f32 / sample_rate.max(1) as f32;
        let s = (amp * (2.0 * std::f32::consts::PI * freq_hz * t).sin()) as i16;
        let bytes = s.to_le_bytes();
        for _ in 0..ch {
            out.extend_from_slice(&bytes);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header(capacity: u32, write_pos: u64, read_pos: u64) -> Header {
        Header {
            version: VERSION,
            sample_rate: 48_000,
            channels: 1,
            bits_per_sample: 16,
            capacity_bytes: capacity,
            write_pos,
            read_pos,
            dropped_packets: 0,
            underruns: 0,
        }
    }

    #[test]
    fn mapping_size_accounts_for_the_header() {
        assert_eq!(mapping_size(48_000), HEADER_SIZE + 48_000);
    }

    #[test]
    fn header_round_trips_in_a_heap_buffer() {
        let cap = 48_000u32;
        let mut buf = vec![0u8; mapping_size(cap)];
        unsafe {
            HeaderView::write(buf.as_mut_ptr(), 48_000, 2, 16, cap, 400, 320, 3, 1);
        }
        let h = unsafe { HeaderView::read(buf.as_ptr()) }.expect("magic");
        assert_eq!(h.sample_rate, 48_000);
        assert_eq!(h.channels, 2);
        assert_eq!(h.bits_per_sample, 16);
        assert_eq!(h.capacity_bytes, cap);
        assert_eq!(h.write_pos, 400);
        assert_eq!(h.read_pos, 320);
        assert_eq!(h.dropped_packets, 3);
        assert_eq!(h.underruns, 1);
        assert_eq!(h.available(), 80);
        assert_eq!(h.required_size(), Some(HEADER_SIZE + cap as usize));
    }

    #[test]
    fn a_bad_magic_is_rejected() {
        let buf = [0u8; HEADER_SIZE];
        assert!(unsafe { HeaderView::read(buf.as_ptr()) }.is_none());
    }

    #[test]
    fn a_well_formed_header_is_accepted() {
        assert!(header(48_000, 100, 0).is_consistent());
    }

    #[test]
    fn an_out_of_range_sample_rate_is_rejected() {
        let mut h = header(48_000, 0, 0);
        h.sample_rate = 100;
        assert!(!h.is_consistent());
        h.sample_rate = 1_000_000;
        assert!(!h.is_consistent());
    }

    #[test]
    fn a_third_channel_is_rejected() {
        let mut h = header(48_000, 0, 0);
        h.channels = 3;
        assert!(!h.is_consistent());
        h.channels = 0;
        assert!(!h.is_consistent());
    }

    #[test]
    fn non_16_bit_is_rejected() {
        let mut h = header(48_000, 0, 0);
        h.bits_per_sample = 24;
        assert!(!h.is_consistent());
    }

    /// A capacity too small or absurdly large must not be believed — the driver
    /// sizes its copy from it.
    #[test]
    fn an_out_of_range_capacity_is_rejected() {
        assert!(!header(16, 0, 0).is_consistent());
        assert!(!header(MAX_CAPACITY_BYTES + 2, 0, 0).is_consistent());
    }

    /// The read cursor must never run ahead of the write cursor; that would
    /// make `available()` wrap and the driver read stale bytes.
    #[test]
    fn a_reader_ahead_of_the_writer_is_rejected() {
        assert!(!header(48_000, 100, 200).is_consistent());
        assert!(header(48_000, 200, 100).is_consistent());
    }

    #[test]
    fn an_unknown_version_is_rejected() {
        let mut h = header(48_000, 0, 0);
        h.version = 0;
        assert!(!h.is_consistent());
        h.version = VERSION + 1;
        assert!(!h.is_consistent());
    }

    #[test]
    fn the_test_tone_has_the_right_shape_and_is_not_silent() {
        let tone = test_tone(48_000, 1, 1_000.0, 0.5, 0, 4_800);
        assert_eq!(tone.len(), 4_800 * 2);
        // Not silent.
        assert!(tone.chunks_exact(2).any(|s| i16::from_le_bytes([s[0], s[1]]) != 0));
        // Stereo interleaves the same sample into both channels.
        let stereo = test_tone(48_000, 2, 1_000.0, 0.5, 0, 100);
        assert_eq!(stereo.len(), 100 * 2 * 2);
        for frame in stereo.chunks_exact(4) {
            assert_eq!(&frame[0..2], &frame[2..4], "L and R match");
        }
    }
}
