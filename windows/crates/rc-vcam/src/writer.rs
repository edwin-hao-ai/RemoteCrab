//! App-side writer: owns the shared-memory section, publishes frames.
//!
//! Windows-only. The section is **file-backed** (see
//! [`crate::shm::ring_file_path`]) so it is visible across sessions — the app
//! runs in the user's session while the consuming COM source runs inside the
//! Windows Frame Server (session 0).

#![cfg(windows)]

use std::mem::size_of;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, GENERIC_READ, GENERIC_WRITE, HANDLE};
use windows::Win32::Security::{
    InitializeSecurityDescriptor, SetSecurityDescriptorDacl, PSECURITY_DESCRIPTOR,
    SECURITY_ATTRIBUTES, SECURITY_DESCRIPTOR,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, GetFileSizeEx, SetEndOfFile, SetFilePointerEx, FILE_ATTRIBUTE_NORMAL,
    FILE_BEGIN, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_ALWAYS,
};
use windows::Win32::System::Memory::{
    CreateFileMappingW, MapViewOfFile, UnmapViewOfFile, FILE_MAP_ALL_ACCESS,
    MEMORY_MAPPED_VIEW_ADDRESS, PAGE_READWRITE,
};

use crate::shm::{mapping_size, ring_file_path, HeaderView, HEADER_SIZE};

/// Owns the mapping and the mapped view. Drop unmaps + closes.
pub struct FrameWriter {
    mapping: HANDLE,
    file: HANDLE,
    view: MEMORY_MAPPED_VIEW_ADDRESS,
    width: u32,
    height: u32,
    fps: u32,
    seq: u64,
    idx: u32,
}

// SAFETY: `FrameWriter` exclusively owns its two handles and the mapped view.
// Moving it to another thread only transfers ownership (HANDLEs are
// process-scoped, not thread-scoped) and `publish` takes `&mut self`, so two
// threads can never touch the view at once. Not `Sync` — the raw view pointer
// is unsynchronised.
unsafe impl Send for FrameWriter {}

/// Windows' `SECURITY_DESCRIPTOR_REVISION` (windows-rs does not export it).
const SECURITY_DESCRIPTOR_REVISION: u32 = 1;

/// A zeroed security descriptor with a NULL DACL (full access to everyone) so
/// the Frame Server can open the section from another session.
///
/// Returned **by value**: the caller keeps it alive in its own frame and points
/// `SECURITY_ATTRIBUTES::lpSecurityDescriptor` at it. The pointer must outlive
/// both `CreateFileW` and `CreateFileMappingW` — a dangling descriptor is
/// validated as garbage by the kernel and comes back as
/// `ERROR_INVALID_REVISION`.
fn everyone_security_descriptor() -> windows::core::Result<SECURITY_DESCRIPTOR> {
    let mut sd: SECURITY_DESCRIPTOR = unsafe { std::mem::zeroed() };
    unsafe {
        let psd = PSECURITY_DESCRIPTOR(&mut sd as *mut _ as *mut core::ffi::c_void);
        InitializeSecurityDescriptor(psd, SECURITY_DESCRIPTOR_REVISION)?;
        SetSecurityDescriptorDacl(psd, true, None, false)?;
    }
    Ok(sd)
}

/// Ensure the ring file is at least `size` bytes.
///
/// Truncation is deliberately *not* attempted: `CREATE_ALWAYS` on a file that
/// a camera consumer still has mapped fails with `ERROR_USER_MAPPED_FILE` —
/// which is exactly what happens when the Frame Server keeps the section open
/// across an app restart. The tail of a stale, larger file is harmless because
/// both sides derive their view size from the header.
fn grow_to(file: HANDLE, size: i64) -> Result<(), String> {
    let mut current: i64 = 0;
    unsafe { GetFileSizeEx(file, &mut current) }
        .map_err(|e| format!("GetFileSizeEx failed: {e}"))?;
    if current >= size {
        return Ok(());
    }
    unsafe { SetFilePointerEx(file, size, None, FILE_BEGIN).and_then(|_| SetEndOfFile(file)) }
        .map_err(|e| format!("grow ring to {size} bytes failed: {e}"))
}

impl FrameWriter {
    /// Create (or reopen) the file-backed mapping for `width`×`height` BGRA
    /// frames.
    pub fn create(width: u32, height: u32, fps: u32) -> Result<Self, String> {
        if width == 0 || height == 0 {
            return Err("frame size must be non-zero".to_string());
        }
        let size = mapping_size(width, height);
        let path = ring_file_path();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)
                .map_err(|e| format!("create {}: {e}", dir.display()))?;
        }
        let path_w = crate::to_wide(&path.to_string_lossy());

        // `sd` must outlive `sa`: `sa` borrows it through a raw pointer.
        let mut sd =
            everyone_security_descriptor().map_err(|e| format!("security descriptor: {e}"))?;
        let sa = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: &mut sd as *mut _ as *mut core::ffi::c_void,
            bInheritHandle: false.into(),
        };

        let file: HANDLE = unsafe {
            CreateFileW(
                PCWSTR(path_w.as_ptr()),
                GENERIC_READ.0 | GENERIC_WRITE.0,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                Some(&sa),
                OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL,
                None,
            )
        }
        .map_err(|e| format!("CreateFileW failed: {e}"))?;
        grow_to(file, size as i64)?;

        let mapping: HANDLE = unsafe {
            CreateFileMappingW(
                file,
                Some(&sa),
                PAGE_READWRITE,
                0,
                size as u32,
                PCWSTR::null(),
            )
        }
        .map_err(|e| {
            unsafe {
                let _ = CloseHandle(file);
            }
            format!("CreateFileMappingW failed: {e}")
        })?;

        let view = unsafe { MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, size) };
        if view.Value.is_null() {
            unsafe {
                let _ = CloseHandle(mapping);
                let _ = CloseHandle(file);
            }
            return Err("MapViewOfFile returned null".to_string());
        }

        unsafe { HeaderView::write_spsc(view.Value as *mut u8, width, height, fps, 0, 0) };

        Ok(FrameWriter {
            mapping,
            file,
            view,
            width,
            height,
            fps,
            seq: 0,
            idx: 0,
        })
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn fps(&self) -> u32 {
        self.fps
    }

    /// The file backing the section (for diagnostics).
    pub fn ring_path(&self) -> std::path::PathBuf {
        ring_file_path()
    }

    /// Publish one BGRA frame. `bgra.len()` must be `width*height*4`.
    pub fn publish(&mut self, bgra: &[u8]) -> Result<(), String> {
        let expect = (self.width as usize) * (self.height as usize) * 4;
        if bgra.len() != expect {
            return Err(format!("frame is {} bytes, expected {expect}", bgra.len()));
        }
        let base = self.view.Value as *mut u8;
        let next = self.idx ^ 1;
        let stride = self.width * 4;
        unsafe {
            let dst =
                base.add(HEADER_SIZE + (stride as usize) * (self.height as usize) * (next as usize));
            std::ptr::copy_nonoverlapping(bgra.as_ptr(), dst, bgra.len());
        }
        self.seq += 1;
        self.idx = next;
        // Publish: the counter + index flip are the only things a reader
        // needs; write geometry again in case the reader attached late.
        unsafe { HeaderView::write_spsc(base, self.width, self.height, self.fps, self.seq, self.idx) };
        Ok(())
    }

    pub fn frames_written(&self) -> u64 {
        self.seq
    }
}

impl Drop for FrameWriter {
    fn drop(&mut self) {
        unsafe {
            let _ = UnmapViewOfFile(self.view);
            let _ = CloseHandle(self.mapping);
            let _ = CloseHandle(self.file);
        }
    }
}

#[cfg(test)]
mod tests {
    //! Round-trip tests against the real file-backed section. The section is
    //! process-global, so the tests take a lock to run one at a time.
    use super::*;
    use windows::Win32::System::Memory::{
        CreateFileMappingW as MapFile, MapViewOfFile as MapView, UnmapViewOfFile as Unmap,
        FILE_MAP_READ, PAGE_READONLY,
    };

    static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

    const W: u32 = 8;
    const H: u32 = 8;
    const FRAME: usize = (W as usize) * (H as usize) * 4;

    /// A minimal reader standing in for `rc-vcam-source`'s `RingReader`.
    struct TestReader {
        view: MEMORY_MAPPED_VIEW_ADDRESS,
        mapping: HANDLE,
        file: HANDLE,
    }

    impl TestReader {
        fn open() -> Self {
            let path_w = crate::to_wide(&ring_file_path().to_string_lossy());
            unsafe {
                let file = windows::Win32::Storage::FileSystem::CreateFileW(
                    PCWSTR(path_w.as_ptr()),
                    GENERIC_READ.0,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    None,
                    windows::Win32::Storage::FileSystem::OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL,
                    None,
                )
                .expect("open ring file");
                let mapping =
                    MapFile(file, None, PAGE_READONLY, 0, 0, PCWSTR::null()).expect("map");
                let view = MapView(mapping, FILE_MAP_READ, 0, 0, 0);
                assert!(!view.Value.is_null(), "map view");
                TestReader { view, mapping, file }
            }
        }

        fn header(&self) -> crate::shm::Header {
            unsafe { HeaderView::read(self.view.Value as *const u8) }.expect("valid header")
        }

        fn bytes_at(&self, off: usize, n: usize) -> Vec<u8> {
            let mut out = vec![0u8; n];
            unsafe {
                std::ptr::copy_nonoverlapping(
                    (self.view.Value as *const u8).add(off),
                    out.as_mut_ptr(),
                    n,
                );
            }
            out
        }
    }

    impl Drop for TestReader {
        fn drop(&mut self) {
            unsafe {
                let _ = Unmap(self.view);
                let _ = CloseHandle(self.mapping);
                let _ = CloseHandle(self.file);
            }
        }
    }

    #[test]
    fn publish_writes_pixels_and_advances_the_header() {
        let _guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let mut writer = FrameWriter::create(W, H, 30).unwrap();
        assert_eq!(writer.frames_written(), 0);

        let frame = vec![7u8; FRAME];
        writer.publish(&frame).unwrap();
        assert_eq!(writer.frames_written(), 1);

        let reader = TestReader::open();
        let hdr = reader.header();
        assert_eq!(hdr.width, W);
        assert_eq!(hdr.height, H);
        assert_eq!(hdr.stride, W * 4);
        assert_eq!(hdr.frame_seq, 1);
        assert_eq!(hdr.write_idx, 1, "the first frame lands in buffer 1");
        assert_eq!(
            reader.bytes_at(hdr.buf_offset(hdr.write_idx).expect("valid header"), FRAME),
            frame
        );
    }

    #[test]
    fn double_buffering_alternates_and_the_newest_wins() {
        let _guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let mut writer = FrameWriter::create(W, H, 30).unwrap();
        writer.publish(&vec![1u8; FRAME]).unwrap();
        writer.publish(&vec![2u8; FRAME]).unwrap();

        let reader = TestReader::open();
        let hdr = reader.header();
        assert_eq!(hdr.frame_seq, 2);
        assert_eq!(hdr.write_idx, 0, "second frame flips back to buffer 0");
        assert_eq!(
            reader.bytes_at(hdr.buf_offset(0).expect("valid header"), 4),
            vec![2u8; 4]
        );
    }

    #[test]
    fn publish_rejects_a_wrong_sized_frame() {
        let _guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let mut writer = FrameWriter::create(W, H, 30).unwrap();
        let err = writer.publish(&[0u8; 4]).unwrap_err();
        assert!(err.contains("expected"), "{err}");
        assert_eq!(writer.frames_written(), 0, "a rejected frame is not counted");
    }

    #[test]
    fn create_rejects_zero_geometry() {
        assert!(FrameWriter::create(0, H, 30).is_err());
        assert!(FrameWriter::create(W, 0, 30).is_err());
    }
}
