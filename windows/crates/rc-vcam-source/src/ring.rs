//! Shared-memory reader for the COM source.
//!
//! The RemoteCrab app owns the file-backed section
//! (`rc-vcam::writer::FrameWriter`); this side only opens a read view and
//! copies the newest frame. A file-backed mapping (rather than a named
//! `Local\` section) is required because the app runs in the user's session
//! and the source runs inside the Frame Server (session 0).

use windows::core::{GUID, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, GENERIC_READ, HANDLE};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows::Win32::System::Memory::{
    CreateFileMappingW, MapViewOfFile, UnmapViewOfFile, FILE_MAP_READ,
    MEMORY_MAPPED_VIEW_ADDRESS, PAGE_READONLY,
};

use rc_vcam::shm::{ring_file_path, Header, HeaderView};

/// Must match `rc_vcam::win::SOURCE_CLSID`.
pub const SOURCE_CLSID: GUID = GUID::from_u128(0x9d4b0d4d_1d2a_4b3e_9c0a_7f6e5d4c3b2a);

pub struct RingReader {
    view: MEMORY_MAPPED_VIEW_ADDRESS,
    mapping: HANDLE,
    file: HANDLE,
}

// Only ever read; safe to share.
unsafe impl Send for RingReader {}
unsafe impl Sync for RingReader {}

/// Exposed for diagnostics.
pub fn ring_path() -> std::path::PathBuf {
    ring_file_path()
}

impl RingReader {
    pub fn open() -> Option<Self> {
        let path = ring_file_path();
        let path_w = rc_vcam::to_wide(&path.to_string_lossy());
        unsafe {
            let file = CreateFileW(
                PCWSTR(path_w.as_ptr()),
                GENERIC_READ.0,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                None,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                None,
            )
            .ok()?;
            let mapping = match CreateFileMappingW(file, None, PAGE_READONLY, 0, 0, PCWSTR::null()) {
                Ok(m) => m,
                Err(_) => {
                    let _ = CloseHandle(file);
                    return None;
                }
            };
            let view = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
            if view.Value.is_null() {
                let _ = CloseHandle(mapping);
                let _ = CloseHandle(file);
                return None;
            }
            Some(RingReader {
                view,
                mapping,
                file,
            })
        }
    }

    pub fn header(&self) -> Option<Header> {
        unsafe { HeaderView::read(self.view.Value as *const u8) }
    }

    /// Copy the newest frame's BGRA bytes (plus its header).
    pub fn latest_frame(&self) -> Option<(Header, Vec<u8>)> {
        let hdr = self.header()?;
        if hdr.width == 0 || hdr.height == 0 || hdr.frame_seq == 0 {
            return None;
        }
        let bytes = hdr.frame_bytes();
        let off = hdr.buf_offset(hdr.write_idx);
        let mut out = vec![0u8; bytes];
        unsafe {
            let src = (self.view.Value as *const u8).add(off);
            std::ptr::copy_nonoverlapping(src, out.as_mut_ptr(), bytes);
        }
        Some((hdr, out))
    }
}

impl Drop for RingReader {
    fn drop(&mut self) {
        unsafe {
            let _ = UnmapViewOfFile(self.view);
            let _ = CloseHandle(self.mapping);
            let _ = CloseHandle(self.file);
        }
    }
}
