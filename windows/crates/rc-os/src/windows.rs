//! Enumerate the desktop's top-level windows for the iPhone window picker /
//! app switcher (`IBWindowList`, kind `0x18`), with a best-effort JPEG
//! thumbnail of each window (same shape as the Mac receiver's list).
//!
//! `id` is `"<pid>:<hwnd>"` so the iPhone keeps it as a real window entry
//! (`screenWindows` filters on the `:`), and `app_id` is `"pid:<pid>"` to
//! match `build_app_list`, so the iPhone can look up the app icon it has.

use windows::core::BOOL;
use windows::Win32::Foundation::{HWND, LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits,
    ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP,
    HGDIOBJ,
};
use windows::Win32::Storage::Xps::{PrintWindow, PRINT_WINDOW_FLAGS};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetForegroundWindow, GetWindowRect, GetWindowTextLengthW, GetWindowTextW,
    GetWindowThreadProcessId, IsWindowVisible,
};

use rc_protocol::{WindowInfo, WindowList};

use crate::apps::{foreground_pid, process_name};
use crate::thumbnail::encode_bgra_jpeg;

/// Longest edge of the JPEG thumbnail sent to the iPhone. The Mac caps its
/// snapshots similarly; the phone downsamples for the card anyway.
const THUMB_MAX_EDGE: u32 = 480;

/// `PW_RENDERFULLCONTENT` — capture DirectComposition / GPU-composited
/// windows instead of a black frame.
const PW_RENDER_FULL_CONTENT: PRINT_WINDOW_FLAGS = PRINT_WINDOW_FLAGS(2);

/// Build the window list. `can_capture` is true because Win32 `PrintWindow`
/// is always available; individual windows (protected surfaces, minimised
/// UWP) simply arrive thumbnail-less and the iPhone shows the app icon.
pub fn build_window_list() -> WindowList {
    let own_pid = std::process::id();
    let foreground = foreground_pid();
    let mut ctx = Ctx {
        own_pid,
        foreground,
        windows: Vec::new(),
    };
    unsafe {
        let _ = EnumWindows(Some(enum_proc), LPARAM(&mut ctx as *mut _ as isize));
    }
    WindowList {
        windows: ctx.windows,
        can_capture: true,
    }
}

struct Ctx {
    own_pid: u32,
    foreground: u32,
    windows: Vec<WindowInfo>,
}

unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let ctx = &mut *(lparam.0 as *mut Ctx);
    if !IsWindowVisible(hwnd).as_bool() {
        return BOOL(1);
    }
    let len = GetWindowTextLengthW(hwnd);
    if len <= 0 {
        return BOOL(1);
    }
    let mut buf = vec![0u16; (len + 1) as usize];
    let copied = GetWindowTextW(hwnd, &mut buf);
    let title = String::from_utf16_lossy(&buf[..copied as usize]);
    if title.trim().is_empty() {
        return BOOL(1);
    }
    let mut pid = 0u32;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    if pid == 0 || pid == ctx.own_pid {
        return BOOL(1);
    }
    let mut rect = RECT::default();
    if GetWindowRect(hwnd, &mut rect).is_err() {
        return BOOL(1);
    }
    let width = (rect.right - rect.left).max(0) as f64;
    let height = (rect.bottom - rect.top).max(0) as f64;
    let app_name = process_name(pid).unwrap_or_else(|| title.clone());
    ctx.windows.push(WindowInfo {
        id: format!("{pid}:{}", hwnd.0 as usize),
        app_id: format!("pid:{pid}"),
        app_name,
        title,
        is_active: pid == ctx.foreground,
        width,
        height,
        snapshot_jpeg: snapshot(hwnd),
    });
    BOOL(1)
}

/// Grab a window's pixels with `PrintWindow` and return a downscaled JPEG.
fn snapshot(hwnd: HWND) -> Option<Vec<u8>> {
    let (bgra, width, height) = grab_bgra(hwnd)?;
    encode_bgra_jpeg(&bgra, width as u32, height as u32, THUMB_MAX_EDGE)
}

/// Render a window into a top-down 32-bit BGRA buffer via `PrintWindow`.
fn grab_bgra(hwnd: HWND) -> Option<(Vec<u8>, i32, i32)> {
    unsafe {
        let mut rect = RECT::default();
        if GetWindowRect(hwnd, &mut rect).is_err() {
            return None;
        }
        let width = rect.right - rect.left;
        let height = rect.bottom - rect.top;
        if width <= 0 || height <= 0 {
            return None;
        }

        let screen_dc = GetDC(None);
        if screen_dc.is_invalid() {
            return None;
        }
        let mem_dc = CreateCompatibleDC(Some(screen_dc));
        let bitmap: HBITMAP = CreateCompatibleBitmap(screen_dc, width, height);

        let mut pixels: Option<Vec<u8>> = None;
        if !bitmap.is_invalid() {
            let old = SelectObject(mem_dc, HGDIOBJ(bitmap.0));
            let _ = PrintWindow(hwnd, mem_dc, PW_RENDER_FULL_CONTENT);

            let mut bmi = BITMAPINFO::default();
            bmi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
            bmi.bmiHeader.biWidth = width;
            bmi.bmiHeader.biHeight = -height; // top-down
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = BI_RGB.0;

            let mut raw = vec![0u8; (width as usize) * (height as usize) * 4];
            let lines = GetDIBits(
                mem_dc,
                bitmap,
                0,
                height as u32,
                Some(raw.as_mut_ptr() as *mut _),
                &mut bmi,
                DIB_RGB_COLORS,
            );
            if lines != 0 {
                pixels = Some(raw);
            }
            let _ = SelectObject(mem_dc, old);
            let _ = DeleteObject(HGDIOBJ(bitmap.0));
        }

        let _ = DeleteDC(mem_dc);
        let _ = ReleaseDC(None, screen_dc);

        pixels.map(|p| (p, width, height))
    }
}

/// A capturable window's identity + frame, for the app-window mirror.
#[derive(Debug, Clone)]
pub struct TargetInfo {
    /// `"<pid>:<hwnd>"` — the same id shape as `WindowInfo.id`.
    pub id: String,
    pub app_id: String,
    pub app_name: String,
    pub title: String,
    pub origin_x: f64,
    pub origin_y: f64,
    pub width: f64,
    pub height: f64,
}

/// Resolve a mirror target: the window with `id` (`"<pid>:<hwnd>"`), or the
/// current foreground window when `id` is `None`.
pub fn window_target(id: Option<&str>) -> Option<TargetInfo> {
    let hwnd = match id {
        Some(id) => hwnd_from_id(id)?,
        None => unsafe { GetForegroundWindow() },
    };
    if hwnd.is_invalid() {
        return None;
    }
    let mut pid = 0u32;
    unsafe {
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
    }
    if pid == 0 || pid == std::process::id() {
        return None;
    }
    target_info(hwnd, pid)
}

/// Grab a window (by `"<pid>:<hwnd>"` id) as full-resolution top-down BGRA.
pub fn capture_window_bgra(id: &str) -> Option<(Vec<u8>, u32, u32)> {
    let hwnd = hwnd_from_id(id)?;
    let (bgra, w, h) = grab_bgra(hwnd)?;
    Some((bgra, w as u32, h as u32))
}

fn hwnd_from_id(id: &str) -> Option<HWND> {
    let raw: usize = id.rsplit_once(':')?.1.parse().ok()?;
    Some(HWND(raw as *mut _))
}

fn target_info(hwnd: HWND, pid: u32) -> Option<TargetInfo> {
    let mut rect = RECT::default();
    if unsafe { GetWindowRect(hwnd, &mut rect) }.is_err() {
        return None;
    }
    let title = window_title(hwnd).unwrap_or_default();
    let app_name = process_name(pid).unwrap_or_else(|| title.clone());
    Some(TargetInfo {
        id: format!("{pid}:{}", hwnd.0 as usize),
        app_id: format!("pid:{pid}"),
        app_name,
        title,
        origin_x: rect.left as f64,
        origin_y: rect.top as f64,
        width: (rect.right - rect.left).max(0) as f64,
        height: (rect.bottom - rect.top).max(0) as f64,
    })
}

fn window_title(hwnd: HWND) -> Option<String> {
    let len = unsafe { GetWindowTextLengthW(hwnd) };
    if len <= 0 {
        return None;
    }
    let mut buf = vec![0u16; (len + 1) as usize];
    let copied = unsafe { GetWindowTextW(hwnd, &mut buf) };
    Some(String::from_utf16_lossy(&buf[..copied as usize]))
}
