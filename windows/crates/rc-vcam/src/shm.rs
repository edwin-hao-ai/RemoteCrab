//! Shared-memory frame ring between the RemoteCrab app (writer) and the
//! virtual-camera COM source DLL (reader, loaded in the consuming app's
//! process).
//!
//! Why shared memory rather than a pipe: the COM source runs inside *another*
//! process (Camera.exe, Zoom, OBS) and must pull the newest frame at its own
//! cadence; a latest-frame-wins slot is exactly right and needs no
//! synchronisation beyond an atomic frame counter.
//!
//! Layout (little-endian, fixed):
//!
//! ```text
//! offset 0   u32  magic      ('RCMV')
//! offset 4   u32  version
//! offset 8   u32  width
//! offset 12  u32  height
//! offset 16  u32  fps
//! offset 20  u32  stride     (bytes per row, = width*4)
//! offset 24  u64  frame_seq  (incremented by the writer after each frame)
//! offset 32  u64  write_idx  (0 or 1 — which buffer is newest)
//! offset 40  ..   reserved to 64
//! offset 64  buf0  (stride*height bytes, BGRA)
//! offset 64+size  buf1
//! ```
//!
//! Double-buffered so the reader never sees a torn frame: the writer fills the
//! non-current buffer, then publishes it by flipping `write_idx` and bumping
//! `frame_seq`. BGRA is what both Media Foundation (RGB32) and our OpenH264
//! decoder already produce, so no conversion is needed at either end.

pub const MAGIC: u32 = 0x5243_4D56; // 'RCMV'
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 64;

/// Path of the shared-memory section backing the ring.
///
/// A **file-backed** mapping under `%ProgramData%` rather than a named
/// (`Local\` / `Global\`) mapping: the writer lives in the user's session
/// while the consuming COM source runs inside the Windows Frame Server
/// (`LocalService`, session 0). `Local\` is session-scoped (invisible to the
/// frame server → black frames) and creating a `Global\` section from a
/// non-elevated process needs `SeCreateGlobalPrivilege` (access denied). A
/// file with a permissive DACL is visible to both sessions.
pub fn ring_file_path() -> std::path::PathBuf {
    let base = std::env::var_os("ProgramData")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("C:\\ProgramData"));
    base.join("RemoteCrab").join("vcam-ring.bin")
}

/// Size of the mapping for a given frame size.
pub fn mapping_size(width: u32, height: u32) -> usize {
    let stride = width as usize * 4;
    HEADER_SIZE + stride * height as usize * 2
}

/// A simple header view over a mapped region (unsafe: caller guarantees the
/// region is at least `HEADER_SIZE + 2*stride*height` bytes).
pub struct HeaderView;

impl HeaderView {
    /// # Safety
    /// `base` must point to a writable region of at least `HEADER_SIZE` bytes.
    pub unsafe fn write_spsc(
        base: *mut u8,
        width: u32,
        height: u32,
        fps: u32,
        seq: u64,
        write_idx: u32,
    ) {
        std::ptr::write_unaligned(base as *mut u32, MAGIC);
        std::ptr::write_unaligned(base.add(4) as *mut u32, VERSION);
        std::ptr::write_unaligned(base.add(8) as *mut u32, width);
        std::ptr::write_unaligned(base.add(12) as *mut u32, height);
        std::ptr::write_unaligned(base.add(16) as *mut u32, fps);
        std::ptr::write_unaligned(base.add(20) as *mut u32, width * 4);
        std::ptr::write_unaligned(base.add(24) as *mut u64, seq);
        std::ptr::write_unaligned(base.add(32) as *mut u64, write_idx as u64);
    }

    /// Read the header as a plain tuple. Returns `None` when the writer has
    /// not initialised the mapping yet (or the magic is wrong).
    ///
    /// # Safety
    /// `base` must point to a readable region of at least `HEADER_SIZE` bytes.
    pub unsafe fn read(base: *const u8) -> Option<Header> {
        let magic = std::ptr::read_unaligned(base as *const u32);
        if magic != MAGIC {
            return None;
        }
        Some(Header {
            version: std::ptr::read_unaligned(base.add(4) as *const u32),
            width: std::ptr::read_unaligned(base.add(8) as *const u32),
            height: std::ptr::read_unaligned(base.add(12) as *const u32),
            fps: std::ptr::read_unaligned(base.add(16) as *const u32),
            stride: std::ptr::read_unaligned(base.add(20) as *const u32),
            frame_seq: std::ptr::read_unaligned(base.add(24) as *const u64),
            write_idx: std::ptr::read_unaligned(base.add(32) as *const u64) as u32,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub version: u32,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub stride: u32,
    pub frame_seq: u64,
    pub write_idx: u32,
}

impl Header {
    pub fn frame_bytes(&self) -> usize {
        self.stride as usize * self.height as usize
    }

    /// Offset of the given buffer's pixels within the mapping.
    pub fn buf_offset(&self, idx: u32) -> usize {
        HEADER_SIZE + self.frame_bytes() * (idx as usize & 1)
    }
}

/// Compute a deterministic BGRA test pattern (used by the self-test so the
/// whole virtual-camera path can be verified without a phone).
pub fn test_pattern_bgra(width: u32, height: u32, frame: u64) -> Vec<u8> {
    let mut out = vec![0u8; (width * height * 4) as usize];
    // A horizontal bar sweeping left→right, on a colour ramp: obviously
    // "alive" in a camera preview and trivially assertable by pixel probe.
    let bar_w = (width / 8).max(1);
    let bar_x = ((frame as u32 * 8) % width.max(1)) as i64;
    for y in 0..height {
        for x in 0..width {
            let i = ((y * width + x) * 4) as usize;
            let dx = (x as i64 - bar_x).rem_euclid(width as i64);
            let in_bar = dx < bar_w as i64;
            let (b, g, r) = if in_bar {
                (40, 80, 250) // orange-red bar (BGRA)
            } else {
                let v = (x * 255 / width.max(1)) as u8;
                (200u8.saturating_sub(v / 2), (v / 2).saturating_add(60), v)
            };
            out[i] = b;
            out[i + 1] = g;
            out[i + 2] = r;
            out[i + 3] = 255;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mapping_size_accounts_for_header_and_both_buffers() {
        let size = mapping_size(640, 480);
        assert_eq!(size, HEADER_SIZE + 640 * 4 * 480 * 2);
    }

    #[test]
    fn header_round_trip_in_a_heap_buffer() {
        let w = 320u32;
        let h = 240u32;
        let mut buf = vec![0u8; mapping_size(w, h)];
        let base = buf.as_mut_ptr();
        unsafe { HeaderView::write_spsc(base, w, h, 30, 7, 1) };

        let hdr = unsafe { HeaderView::read(base as *const u8) }.expect("magic");
        assert_eq!(hdr.width, w);
        assert_eq!(hdr.height, h);
        assert_eq!(hdr.fps, 30);
        assert_eq!(hdr.stride, w * 4);
        assert_eq!(hdr.frame_seq, 7);
        assert_eq!(hdr.write_idx, 1);
        assert_eq!(hdr.frame_bytes(), w as usize * 4 * h as usize);
    }

    #[test]
    fn read_without_magic_returns_none() {
        let buf = [0u8; HEADER_SIZE];
        assert!(unsafe { HeaderView::read(buf.as_ptr()) }.is_none());
    }

    #[test]
    fn buf_offset_flips_between_the_two_buffers() {
        let hdr = Header {
            version: 1,
            width: 4,
            height: 4,
            fps: 30,
            stride: 16,
            frame_seq: 0,
            write_idx: 0,
        };
        assert_eq!(hdr.buf_offset(0), HEADER_SIZE);
        assert_eq!(hdr.buf_offset(1), HEADER_SIZE + 64);
        // Out-of-range indices wrap to the two buffers.
        assert_eq!(hdr.buf_offset(2), HEADER_SIZE);
        assert_eq!(hdr.buf_offset(3), HEADER_SIZE + 64);
    }

    #[test]
    fn test_pattern_is_opaque_and_changes_over_time() {
        let a = test_pattern_bgra(64, 48, 0);
        let b = test_pattern_bgra(64, 48, 5);
        assert_eq!(a.len(), 64 * 48 * 4);
        assert!(a.chunks_exact(4).all(|p| p[3] == 255), "all pixels opaque");
        assert_ne!(a, b, "the pattern must move between frames");
    }
}
