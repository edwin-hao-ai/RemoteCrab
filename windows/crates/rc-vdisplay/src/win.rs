//! Windows half: the control pipe (liveness + commands) and the frame-ring
//! reader (pixels). Everything Win32 lives here so the grammar above stays
//! testable everywhere.

use std::io::{BufRead, BufReader, Write};

use windows::core::{BOOL, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, GENERIC_READ, HANDLE, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, GetFileSizeEx, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE,
    OPEN_EXISTING,
};
use windows::Win32::System::Memory::{
    CreateFileMappingW, MapViewOfFile, UnmapViewOfFile, FILE_MAP_READ,
    MEMORY_MAPPED_VIEW_ADDRESS, PAGE_READONLY,
};
use windows::Win32::System::Pipes::WaitNamedPipeW;

use rc_vcam::shm::{Header, HeaderView};

use crate::{parse_ack, parse_pong, DisplayFrame, PIPE_NAME};

/// NUL-terminated wide string.
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// How long to wait for a driver instance before concluding "not installed".
///
/// `WaitNamedPipeW` returns immediately when the name does not exist at all,
/// and waits only when the pipe exists but every instance is busy. So a small
/// bound both detects absence fast and tolerates a momentary busy.
const PIPE_TIMEOUT_MS: u32 = 250;

/// One request/response exchange with the driver's control pipe.
///
/// `None` when the pipe is absent (no driver, or it is not running yet) or the
/// exchange fails. This is the single liveness probe: a stale ring file cannot
/// answer, which is why presence is keyed on the pipe and not the ring.
fn roundtrip(request: &str) -> Option<String> {
    let name = wide(PIPE_NAME);
    // `WaitNamedPipeW` returns a `BOOL`: false means the pipe is not there (or
    // stayed busy) — the driver is not installed or not running.
    if !unsafe { WaitNamedPipeW(PCWSTR(name.as_ptr()), PIPE_TIMEOUT_MS) }.as_bool() {
        return None;
    }
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(PIPE_NAME)
        .ok()?;
    file.write_all(request.as_bytes()).ok()?;
    file.write_all(b"\n").ok()?;
    file.flush().ok()?;
    let mut line = String::new();
    // The driver speaks line-delimited text; one read of one line is the whole
    // reply for every command in the grammar.
    BufReader::new(file).read_line(&mut line).ok()?;
    let line = line.trim().to_string();
    if line.is_empty() {
        None
    } else {
        Some(line)
    }
}

/// The driver's protocol version, or `None` when it is not installed/running.
pub fn probe() -> Option<u32> {
    parse_pong(&roundtrip("PING")?)
}

/// Whether a virtual-display driver is installed and answering.
pub fn available() -> bool {
    probe().is_some()
}

/// Create the virtual monitor at `size` (pixels), or remove it with `None`.
///
/// Returns the driver's error verbatim when it refuses, so the console/report
/// can say *why* rather than a generic failure.
pub fn set_monitor(size: Option<(u32, u32)>) -> Result<(), String> {
    let request = match size {
        Some((w, h)) => format!("MONITOR {w} {h}"),
        None => "MONITOR OFF".to_string(),
    };
    match roundtrip(&request) {
        Some(reply) => parse_ack(&reply),
        None => Err("virtual display driver is not running".to_string()),
    }
}

/// The virtual monitor's frame in **virtual-desktop pixels** — the coordinate
/// space `SendInput`'s absolute moves use, so it feeds `screenInput` directly.
///
/// Found by matching a monitor whose `rcMonitor` size equals the driver's
/// frame size. The IddCx driver has no API to report the desktop position the
/// OS assigned its monitor (topology layout is the OS's to decide), so the
/// reader derives it here instead. Matching on the exact requested resolution
/// is unambiguous in practice: the virtual monitor is the only one the user
/// did not physically plug in, and it is created at a size we chose.
///
/// Returns `None` when no monitor matches (driver gone, or the OS has not
/// finished laying it out) — the caller then falls back to `(0, 0, w, h)`.
pub fn find_monitor_rect(width: u32, height: u32) -> Option<(f64, f64, f64, f64)> {
    struct Ctx {
        want_w: u32,
        want_h: u32,
        found: Option<(f64, f64, f64, f64)>,
    }
    unsafe extern "system" fn proc(
        monitor: HMONITOR,
        _hdc: HDC,
        _rect: *mut RECT,
        data: LPARAM,
    ) -> BOOL {
        // SAFETY: `data` is the `&mut Ctx` passed to `EnumDisplayMonitors`
        // below, which outlives the enumeration.
        let ctx = unsafe { &mut *(data.0 as *mut Ctx) };
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if unsafe { GetMonitorInfoW(monitor, &mut info) }.as_bool() {
            let r = info.rcMonitor;
            let w = (r.right - r.left).max(0) as u32;
            let h = (r.bottom - r.top).max(0) as u32;
            if w == ctx.want_w && h == ctx.want_h {
                ctx.found = Some((r.left as f64, r.top as f64, w as f64, h as f64));
                return BOOL(0); // found it — stop enumerating
            }
        }
        BOOL(1)
    }

    let mut ctx = Ctx {
        want_w: width,
        want_h: height,
        found: None,
    };
    unsafe {
        let _ = EnumDisplayMonitors(
            None,
            None,
            Some(proc),
            LPARAM(&mut ctx as *mut Ctx as isize),
        );
    }
    ctx.found
}

/// Read-only view of the driver's frame ring.
///
/// Mirrors the virtual camera's reader: a file-backed mapping opened
/// `FILE_MAP_READ`, validated through the shared `Header`, newest frame copied
/// out by value so nothing aliases the driver's live buffer.
pub struct DisplayReader {
    view: MEMORY_MAPPED_VIEW_ADDRESS,
    mapping: HANDLE,
    file: HANDLE,
    ring_size: usize,
}

// Only ever read; safe to share and move.
unsafe impl Send for DisplayReader {}
unsafe impl Sync for DisplayReader {}

fn file_size(file: HANDLE) -> Option<usize> {
    let mut size: i64 = 0;
    unsafe { GetFileSizeEx(file, &mut size).ok()? };
    usize::try_from(size).ok()
}

impl DisplayReader {
    /// Map the ring, or `None` when the driver has not created it.
    pub fn open() -> Option<Self> {
        let path = crate::ring_file_path();
        let path_w = wide(&path.to_string_lossy());
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
            let mapping = match CreateFileMappingW(file, None, PAGE_READONLY, 0, 0, PCWSTR::null())
            {
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
            // Every early return past this point must undo the three handles;
            // this runs each frame, so a leak compounds rather than being
            // reclaimed when the process exits.
            let ring_size = match file_size(file) {
                Some(n) => n,
                None => {
                    let _ = UnmapViewOfFile(view);
                    let _ = CloseHandle(mapping);
                    let _ = CloseHandle(file);
                    return None;
                }
            };
            Some(DisplayReader {
                view,
                mapping,
                file,
                ring_size,
            })
        }
    }

    fn header(&self) -> Option<Header> {
        let hdr = unsafe { HeaderView::read(self.view.Value as *const u8) }?;
        // A header that claims more than the mapping actually holds must be
        // refused, not trusted: the reader sizes its copy from these fields.
        if self.ring_size < hdr.required_size()? {
            return None;
        }
        Some(hdr)
    }

    /// Copy the newest frame, or `None` before the driver publishes one.
    pub fn latest(&self) -> Option<DisplayFrame> {
        let hdr = self.header()?;
        if hdr.frame_seq == 0 {
            return None;
        }
        let bytes = hdr.frame_bytes()?;
        let off = hdr.buf_offset(hdr.write_idx)?;
        if off.checked_add(bytes)? > self.ring_size {
            return None;
        }
        let mut bgra = vec![0u8; bytes];
        unsafe {
            let src = (self.view.Value as *const u8).add(off);
            std::ptr::copy_nonoverlapping(src, bgra.as_mut_ptr(), bytes);
        }
        Some(DisplayFrame {
            width: hdr.width,
            height: hdr.height,
            seq: hdr.frame_seq,
            bgra,
        })
    }
}

impl Drop for DisplayReader {
    fn drop(&mut self) {
        unsafe {
            let _ = UnmapViewOfFile(self.view);
            let _ = CloseHandle(self.mapping);
            let _ = CloseHandle(self.file);
        }
    }
}
