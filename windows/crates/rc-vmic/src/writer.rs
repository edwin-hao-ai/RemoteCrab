//! App-side writer: owns the file-backed audio ring and appends PCM.
//!
//! Windows-only, for the same reason as the camera ring: the section is
//! file-backed under `%ProgramData%` so it is visible across sessions.

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

use crate::shm::{mapping_size, ring_file_path, HeaderView, HEADER_SIZE, MAX_CAPACITY_BYTES, MIN_CAPACITY_BYTES};

const SECURITY_DESCRIPTOR_REVISION: u32 = 1;

/// Owns the mapping and the mapped view. Drop unmaps + closes.
pub struct AudioWriter {
    mapping: HANDLE,
    file: HANDLE,
    view: MEMORY_MAPPED_VIEW_ADDRESS,
    sample_rate: u32,
    channels: u32,
    capacity: u32,
    write_pos: u64,
    dropped: u32,
    underruns: u32,
}

// SAFETY: as `rc_vcam::writer::FrameWriter` — `AudioWriter` exclusively owns the
// handles and the view, and `write` takes `&mut self`, so no two threads touch
// the view at once. Not `Sync`.
unsafe impl Send for AudioWriter {}

/// Reduce the ring file to the principals that genuinely need it.
///
/// Identical reasoning to the camera ring (`rc_vcam::writer`): the file is
/// created with a NULL DACL so a reader in another session can open it, then
/// narrowed to SYSTEM / Administrators / LOCAL SERVICE / INTERACTIVE. Without
/// this, any process on the machine could inject audio into every app that
/// selects "RemoteCrab Microphone", or read whatever is being recorded.
fn lock_down_ring_permissions(path: &std::path::Path) -> Result<(), String> {
    let out = std::process::Command::new("icacls")
        .arg(path)
        .arg("/inheritance:r")
        .arg("/grant:r")
        .arg("SYSTEM:(F)")
        .arg("Administrators:(F)")
        .arg("LOCAL SERVICE:(F)")
        .arg("INTERACTIVE:(F)")
        .output()
        .map_err(|e| format!("icacls could not be started: {e}"))?;

    if !out.status.success() {
        let msg = String::from_utf8_lossy(&out.stderr);
        let msg = msg.trim();
        let msg = if msg.is_empty() {
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        } else {
            msg.to_string()
        };
        return Err(format!("icacls failed on {}: {msg}", path.display()));
    }
    Ok(())
}

fn everyone_security_descriptor() -> windows::core::Result<SECURITY_DESCRIPTOR> {
    let mut sd: SECURITY_DESCRIPTOR = unsafe { std::mem::zeroed() };
    unsafe {
        let psd = PSECURITY_DESCRIPTOR(&mut sd as *mut _ as *mut core::ffi::c_void);
        InitializeSecurityDescriptor(psd, SECURITY_DESCRIPTOR_REVISION)?;
        SetSecurityDescriptorDacl(psd, true, None, false)?;
    }
    Ok(sd)
}

/// Ensure the ring file is at least `size` bytes (never truncate — a reader may
/// still have it mapped, and both sides size their view from the header).
fn grow_to(file: HANDLE, size: i64) -> Result<(), String> {
    let mut current: i64 = 0;
    unsafe { GetFileSizeEx(file, &mut current) }.map_err(|e| format!("GetFileSizeEx: {e}"))?;
    if current >= size {
        return Ok(());
    }
    unsafe { SetFilePointerEx(file, size, None, FILE_BEGIN).and_then(|_| SetEndOfFile(file)) }
        .map_err(|e| format!("grow ring to {size} bytes: {e}"))
}

impl AudioWriter {
    /// Default ring capacity: two seconds of 48 kHz 16-bit stereo, so a driver
    /// that is briefly scheduled late never underruns.
    pub const DEFAULT_CAPACITY: u32 = 48_000 * 2 * 2 * 2;

    pub fn create(sample_rate: u32, channels: u32) -> Result<Self, String> {
        Self::create_with_capacity(sample_rate, channels, Self::DEFAULT_CAPACITY)
    }

    pub fn create_with_capacity(
        sample_rate: u32,
        channels: u32,
        capacity_bytes: u32,
    ) -> Result<Self, String> {
        if !speed_ok(sample_rate) {
            return Err(format!("unsupported sample rate {sample_rate}"));
        }
        if channels == 0 || channels > 2 {
            return Err(format!("unsupported channel count {channels}"));
        }
        if !(MIN_CAPACITY_BYTES..=MAX_CAPACITY_BYTES).contains(&capacity_bytes)
            || !capacity_bytes.is_multiple_of(channels * 2)
        {
            return Err(format!("unsupported ring capacity {capacity_bytes}"));
        }
        let size = mapping_size(capacity_bytes);
        let path = ring_file_path();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
        }
        let path_w = crate::to_wide(&path.to_string_lossy());

        let mut sd = everyone_security_descriptor().map_err(|e| format!("security descriptor: {e}"))?;
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
        .map_err(|e| format!("CreateFileW: {e}"))?;

        if let Err(e) = grow_to(file, size as i64).and_then(|_| lock_down_ring_permissions(&path)) {
            unsafe {
                let _ = CloseHandle(file);
            }
            return Err(e);
        }

        let mapping: HANDLE = unsafe {
            CreateFileMappingW(file, Some(&sa), PAGE_READWRITE, 0, size as u32, PCWSTR::null())
        }
        .map_err(|e| {
            unsafe {
                let _ = CloseHandle(file);
            }
            format!("CreateFileMappingW: {e}")
        })?;

        let view = unsafe { MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, size) };
        if view.Value.is_null() {
            unsafe {
                let _ = CloseHandle(mapping);
                let _ = CloseHandle(file);
            }
            return Err("MapViewOfFile returned null".to_string());
        }

        unsafe {
            HeaderView::write(view.Value as *mut u8, sample_rate, channels, 16, capacity_bytes, 0, 0, 0, 0);
        }

        Ok(AudioWriter {
            mapping,
            file,
            view,
            sample_rate,
            channels,
            capacity: capacity_bytes,
            write_pos: 0,
            dropped: 0,
            underruns: 0,
        })
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }
    pub fn channels(&self) -> u32 {
        self.channels
    }
    pub fn bytes_written(&self) -> u64 {
        self.write_pos
    }
    pub fn dropped_packets(&self) -> u32 {
        self.dropped
    }

    /// Append interleaved 16-bit PCM. Extra bytes are dropped (with a count)
    /// rather than blocking the audio callback or blocking the network thread.
    pub fn write(&mut self, pcm: &[u8]) -> Result<(), String> {
        if pcm.is_empty() {
            return Ok(());
        }
        let base = self.view.Value as *mut u8;
        let hdr = unsafe { HeaderView::read(base as *const u8) };
        // The driver owns `read_pos`. A missing/uninitialised header means the
        // driver has not attached yet; treat it as "nothing consumed".
        let read_pos = hdr.map(|h| h.read_pos).unwrap_or(0);

        let cap = self.capacity as usize;
        if (self.write_pos - read_pos) as usize + pcm.len() > cap {
            self.dropped += 1;
            self.publish(base, read_pos);
            return Ok(());
        }

        let mut pos = (self.write_pos % cap as u64) as usize;
        let mut src = pcm;
        unsafe {
            while !src.is_empty() {
                let n = (cap - pos).min(src.len());
                std::ptr::copy_nonoverlapping(src.as_ptr(), base.add(HEADER_SIZE + pos), n);
                pos = (pos + n) % cap;
                src = &src[n..];
            }
        }
        self.write_pos += pcm.len() as u64;
        self.publish(base, read_pos);
        Ok(())
    }

    fn publish(&self, base: *mut u8, read_pos: u64) {
        unsafe {
            HeaderView::write(
                base,
                self.sample_rate,
                self.channels,
                16,
                self.capacity,
                self.write_pos,
                read_pos,
                self.dropped,
                self.underruns,
            );
        }
    }
}

fn speed_ok(sample_rate: u32) -> bool {
    (8_000..=192_000).contains(&sample_rate)
}

impl Drop for AudioWriter {
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
    use super::*;
    use windows::Win32::System::Memory::{
        CreateFileMappingW as MapFile, MapViewOfFile as MapView, UnmapViewOfFile as Unmap,
        FILE_MAP_READ, PAGE_READONLY,
    };

    static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// A minimal reader standing in for the driver's ring consumer.
    struct TestReader {
        view: MEMORY_MAPPED_VIEW_ADDRESS,
        mapping: HANDLE,
        file: HANDLE,
    }

    impl TestReader {
        fn open() -> Self {
            let path_w = crate::to_wide(&ring_file_path().to_string_lossy());
            unsafe {
                let file = CreateFileW(
                    PCWSTR(path_w.as_ptr()),
                    GENERIC_READ.0,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    None,
                    windows::Win32::Storage::FileSystem::OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL,
                    None,
                )
                .expect("open ring file");
                let mapping = MapFile(file, None, PAGE_READONLY, 0, 0, PCWSTR::null()).expect("map");
                let view = MapView(mapping, FILE_MAP_READ, 0, 0, 0);
                assert!(!view.Value.is_null(), "map view");
                TestReader { view, mapping, file }
            }
        }

        fn header(&self) -> crate::shm::Header {
            unsafe { HeaderView::read(self.view.Value as *const u8) }.expect("valid header")
        }

        /// Read `n` bytes starting at monotonic ring position `pos`.
        fn bytes_from(&self, pos: u64, n: usize) -> Vec<u8> {
            let cap = self.header().capacity_bytes as usize;
            let mut out = Vec::with_capacity(n);
            let mut p = pos;
            unsafe {
                let base = (self.view.Value as *const u8).add(HEADER_SIZE);
                for _ in 0..n {
                    out.push(*base.add((p % cap as u64) as usize));
                    p += 1;
                }
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
    fn writing_pcm_publishes_the_format_and_the_cursor() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let mut w = AudioWriter::create_with_capacity(48_000, 1, 4096).unwrap();
        let pcm: Vec<u8> = (0..256u32).flat_map(|i| (i as i16).to_le_bytes()).collect();
        w.write(&pcm).unwrap();
        assert_eq!(w.bytes_written(), 512);

        let r = TestReader::open();
        let h = r.header();
        assert_eq!(h.sample_rate, 48_000);
        assert_eq!(h.channels, 1);
        assert_eq!(h.bits_per_sample, 16);
        assert_eq!(h.write_pos, 512);
        assert_eq!(h.available(), 512);
        assert_eq!(r.bytes_from(0, pcm.len()), pcm);
    }

    /// The second write lands right after the first, and a reader can still
    /// fetch the whole stream by position.
    #[test]
    fn appends_are_contiguous() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let mut w = AudioWriter::create_with_capacity(48_000, 1, 4096).unwrap();
        w.write(&[1u8; 100]).unwrap();
        w.write(&[2u8; 100]).unwrap();
        let r = TestReader::open();
        assert_eq!(r.header().write_pos, 200);
        assert_eq!(r.bytes_from(0, 100), vec![1u8; 100]);
        assert_eq!(r.bytes_from(100, 100), vec![2u8; 100]);
    }

    #[test]
    fn create_rejects_a_bad_format() {
        assert!(AudioWriter::create_with_capacity(100, 1, 4096).is_err());
        assert!(AudioWriter::create_with_capacity(48_000, 3, 4096).is_err());
        assert!(AudioWriter::create_with_capacity(48_000, 1, 16).is_err());
    }

    /// A writer that outruns the reader drops a packet instead of wrapping onto
    /// unread data, and counts it.
    #[test]
    fn a_full_ring_drops_rather_than_overwrites() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let mut w = AudioWriter::create_with_capacity(48_000, 1, 4096).unwrap();
        // Fill it exactly: the reader never advances, so the next packet must drop.
        for _ in 0..16 {
            w.write(&[9u8; 256]).unwrap();
        }
        assert_eq!(w.bytes_written(), 4096);
        assert_eq!(w.dropped_packets(), 0);
        w.write(&[1u8; 256]).unwrap();
        assert_eq!(w.bytes_written(), 4096, "no advance when there is no room");
        assert_eq!(w.dropped_packets(), 1);
    }
}
