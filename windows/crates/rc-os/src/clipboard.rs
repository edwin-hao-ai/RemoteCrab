//! Win32 clipboard read/write (UTF-16, CF_UNICODETEXT).

use std::os::windows::ffi::OsStrExt;
use std::ffi::OsStr;

use windows::Win32::Foundation::{HANDLE, HGLOBAL};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;

/// Read the clipboard's text, or `None` when empty / non-text.
pub fn get_text() -> Option<String> {
    unsafe {
        if OpenClipboard(None).is_err() {
            return None;
        }
        let handle = GetClipboardData(CF_UNICODETEXT.0 as u32).ok()?;
        if handle.is_invalid() {
            let _ = CloseClipboard();
            return None;
        }
        let ptr = GlobalLock(HGLOBAL(handle.0)) as *const u16;
        if ptr.is_null() {
            let _ = CloseClipboard();
            return None;
        }
        let mut len = 0isize;
        while *ptr.offset(len) != 0 {
            len += 1;
        }
        let slice = std::slice::from_raw_parts(ptr, len as usize);
        let text = String::from_utf16_lossy(slice);
        let _ = GlobalUnlock(HGLOBAL(handle.0));
        let _ = CloseClipboard();
        Some(text)
    }
}

/// Replace the clipboard with `text`. Returns false on any Win32 failure.
pub fn set_text(text: &str) -> bool {
    let wide: Vec<u16> = OsStr::new(text)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let bytes = wide.len() * std::mem::size_of::<u16>();

    unsafe {
        if OpenClipboard(None).is_err() {
            return false;
        }
        let _ = EmptyClipboard();
        let Ok(handle) = GlobalAlloc(GMEM_MOVEABLE, bytes) else {
            let _ = CloseClipboard();
            return false;
        };
        let ptr = GlobalLock(handle) as *mut u16;
        if ptr.is_null() {
            let _ = CloseClipboard();
            return false;
        }
        std::ptr::copy_nonoverlapping(wide.as_ptr(), ptr, wide.len());
        let _ = GlobalUnlock(handle);
        // The system owns the handle after a successful SetClipboardData.
        if SetClipboardData(CF_UNICODETEXT.0 as u32, Some(HANDLE(handle.0))).is_err() {
            let _ = CloseClipboard();
            return false;
        }
        let _ = CloseClipboard();
        true
    }
}
