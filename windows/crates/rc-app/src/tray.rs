//! System-tray icon + context menu.
//!
//! Follows the Mac menu-bar popover (`MenuBarMenu.swift`) rather than the
//! Win32 default: a status header, a **labelled section per group**, an icon
//! on every row, and a version footer — because "Real macOS menus are heavily
//! sectioned" is the standard the two products should meet, and a flat grey
//! list of twelve rows is what made this look cheap next to the Mac.
//!
//! The same rows the Mac exposes (Camera / Microphone / Trackpad / Keyboard,
//! record, clipboard, last file, preview, reconnect, disconnect, start at
//! login, quit) with the same bilingual wording.
//!
//! Known limit: the row chrome is still the native `TrackPopupMenu`, which
//! Windows will not let an app style — rounded corners, hover fills and
//! typography have to wait for a self-drawn panel. Everything that *is*
//! expressible in a native menu (information architecture, grouping, icons,
//! wording, ordering) is matched here.
//!
//! The menu rebuilds fresh on every open from a `Shared` snapshot the app
//! loop keeps updated, and every selection is forwarded over a channel to
//! the app's `tokio::select!` loop, which owns the session/audio/recording
//! state — the tray thread itself owns nothing. On non-Windows dev builds
//! the handle is a no-op stub so the wiring compiles unchanged everywhere.

use rc_protocol::Feature;

pub use crate::tray_menu::{decorate, flags_for, menu_rows, MenuRow, MenuState, Row};

/// One user action from the tray menu, routed to the app loop.
#[cfg_attr(not(windows), allow(dead_code))]
#[derive(Debug, Clone)]
pub enum TrayCommand {
    SetFeature(Feature, bool),
    ToggleRecord,
    SendClipboard,
    ShowLastFile,
    TogglePreview,
    Reconnect,
    Disconnect,
    ToggleAutostart,
    Quit,
}

// ---------------------------------------------------------------------------
// Windows implementation
// ---------------------------------------------------------------------------
#[cfg(windows)]
mod win32 {
    use std::sync::atomic::{AtomicIsize, Ordering};
    use std::sync::{Arc, Mutex};

    use rc_protocol::FeatureStateSnapshot;
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
    use windows::Win32::Graphics::Gdi::{
        CreateBitmap, CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDC,
        ReleaseDC, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP, HGDIOBJ,
    };
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Shell::{
        Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
        DispatchMessageW, GetCursorPos, GetMessageW, GetWindowLongPtrW, HICON, HMENU, IDI_APPLICATION,
        IMAGE_ICON, LR_DEFAULTSIZE, LR_SHARED,
        MSG, MENU_ITEM_FLAGS, PostMessageW, PostQuitMessage, RegisterClassW, SetForegroundWindow,
        SetWindowLongPtrW, TrackPopupMenu, TranslateMessage, WNDCLASSW,
        CreateIconIndirect, ICONINFO,
        WS_OVERLAPPED, GWLP_USERDATA, WM_APP, WM_DESTROY,
        TPM_BOTTOMALIGN, TPM_RETURNCMD, TPM_RIGHTBUTTON, LoadImageW,
    };

    use rc_protocol::Feature;
    use super::TrayCommand;

    /// The tray callback message (app-private, above `WM_APP`).
    const TRAY_CB: u32 = WM_APP + 1;
    /// Close request marshalled to the tray thread.
    const WM_TRAY_CLOSE: u32 = WM_APP + 2;

    /// Menu ids handed to the app loop.
    struct Ids;
    impl Ids {
        const CAMERA: usize = 1;
        const MICROPHONE: usize = 2;
        const TRACKPAD: usize = 3;
        const KEYBOARD: usize = 4;
        const RECORD: usize = 7;
        const CLIPBOARD: usize = 8;
        const SHOW_FILE: usize = 9;
        const PREVIEW: usize = 14;
        const RECONNECT: usize = 10;
        const DISCONNECT: usize = 11;
        const AUTOSTART: usize = 13;
        const QUIT: usize = 12;
    }

    /// Everything the menu renders; owned by the app loop, read fresh on open.
    #[derive(Default)]
    struct Shared {
        status: String,
        features: Option<FeatureStateSnapshot>,
        recording: bool,
        /// Mirrors the HKCU Run key so the menu shows a truthful checkmark.
        autostart: bool,
        /// A file was received this session — enables "Show last received".
        has_last_file: bool,
        /// The preview window is open.
        preview_on: bool,
    }

    struct Ctx {
        shared: Arc<Mutex<Shared>>,
        cmd_tx: tokio::sync::mpsc::UnboundedSender<TrayCommand>,
    }

    /// Handle to the live tray thread. `Drop` closes it.
    pub struct TrayHandle {
        shared: Arc<Mutex<Shared>>,
        hwnd_slot: Arc<AtomicIsize>,
    }

    impl TrayHandle {
        /// Push the status line (the sync-able pill-language line).
        pub fn set_status(&self, status: &str) {
            if let Ok(mut s) = self.shared.lock() {
                s.status = status.to_string();
            }
        }

        /// Refresh the feature-toggle checkmarks.
        pub fn set_features(&self, features: Option<FeatureStateSnapshot>) {
            if let Ok(mut s) = self.shared.lock() {
                s.features = features;
            }
        }

        pub fn set_recording(&self, on: bool) {
            if let Ok(mut s) = self.shared.lock() {
                s.recording = on;
            }
        }

        pub fn set_autostart(&self, on: bool) {
            if let Ok(mut s) = self.shared.lock() {
                s.autostart = on;
            }
        }

        pub fn set_has_last_file(&self, on: bool) {
            if let Ok(mut s) = self.shared.lock() {
                s.has_last_file = on;
            }
        }

        pub fn set_preview(&self, on: bool) {
            if let Ok(mut s) = self.shared.lock() {
                s.preview_on = on;
            }
        }

        /// Ask the tray thread to tear its window + icon down and exit.
        pub fn stop(&self) {
            let hwnd = self.hwnd_slot.swap(0, Ordering::SeqCst);
            if hwnd != 0 {
                unsafe {
                    let _ = PostMessageW(
                        Some(HWND(hwnd as *mut _)),
                        WM_TRAY_CLOSE,
                        WPARAM(0),
                        LPARAM(0),
                    );
                }
            }
        }
    }

    impl Drop for TrayHandle {
        fn drop(&mut self) {
            self.stop();
        }
    }

    /// Spawn the tray thread. Returns the update handle plus the command
    /// channel the app loop selects on.
    pub fn start(tip: &str) -> (TrayHandle, tokio::sync::mpsc::UnboundedReceiver<TrayCommand>) {
        let (cmd_tx, cmd_rx) = tokio::sync::mpsc::unbounded_channel();
        let shared = Arc::new(Mutex::new(Shared::default()));
        let hwnd_slot = Arc::new(AtomicIsize::new(0));

        let tip = tip.to_string();
        let shared_for_thread = shared.clone();
        let hwnd_for_thread = hwnd_slot.clone();
        std::thread::Builder::new()
            .name("rc-tray".to_string())
            .spawn(move || unsafe { run(&tip, shared_for_thread, cmd_tx, hwnd_for_thread) })
            .ok();

        (TrayHandle { shared, hwnd_slot }, cmd_rx)
    }

    /// A tray-less handle (`--no-tray`): receiver already at EOF, so the app
    /// loop's tray arm disables itself on its first tick.
    pub fn disabled() -> (TrayHandle, tokio::sync::mpsc::UnboundedReceiver<TrayCommand>) {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        drop(tx);
        (
            TrayHandle {
                shared: Arc::new(Mutex::new(Shared::default())),
                hwnd_slot: Arc::new(AtomicIsize::new(0)),
            },
            rx,
        )
    }

    unsafe fn run(
        tip: &str,
        shared: Arc<Mutex<Shared>>,
        cmd_tx: tokio::sync::mpsc::UnboundedSender<TrayCommand>,
        hwnd_slot: Arc<AtomicIsize>,
    ) {
        let Ok(module) = GetModuleHandleW(None) else {
            return;
        };
        // `GetModuleHandleW` yields HMODULE; window/LoadImage APIs want
        // HINSTANCE — the two are the same handle value.
        let hinstance = HINSTANCE(module.0);
        let class_name = windows::core::w!("RemoteCrabTray");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(wnd_proc),
            hInstance: hinstance,
            lpszClassName: PCWSTR(class_name.as_ptr()),
            ..Default::default()
        };
        if RegisterClassW(&wc) == 0 {
            return;
        }

        let Ok(hwnd) = CreateWindowExW(
            Default::default(),
            PCWSTR(class_name.as_ptr()),
            windows::core::w!("RemoteCrab tray"),
            WS_OVERLAPPED, // never shown; a message sink for tray callbacks
            0,
            0,
            0,
            0,
            None,
            None,
            Some(hinstance),
            None,
        ) else {
            return;
        };

        // Prefer the product icon (embedded PNG → HICON); fall back to the
        // generic system icon if anything about that fails.
        let icon = tray_icon(hinstance).or_else(|| {
            LoadImageW(
                Some(hinstance),
                IDI_APPLICATION,
                IMAGE_ICON,
                0,
                0,
                LR_DEFAULTSIZE | LR_SHARED,
            )
            .ok()
            .map(|h| HICON(h.0))
        });
        let Some(icon) = icon else {
            return;
        };

        // Attach the context before the icon appears (callbacks read it).
        SetWindowLongPtrW(
            hwnd,
            GWLP_USERDATA,
            Box::into_raw(Box::new(Ctx {
                shared: shared.clone(),
                cmd_tx: cmd_tx.clone(),
            })) as isize,
        );

        let mut tip_buf = [0u16; 128];
        set_utf16(&mut tip_buf, tip);
        let nid = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: 1,
            uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage: TRAY_CB,
            hIcon: HICON(icon.0),
            szTip: tip_buf,
            ..Default::default()
        };
        if !Shell_NotifyIconW(NIM_ADD, &nid).as_bool() {
            return;
        }
        hwnd_slot.store(hwnd.0 as isize, Ordering::SeqCst);

        // Message pump until WM_QUIT (fired from WM_DESTROY).
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, Some(hwnd), 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    unsafe extern "system" fn wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        match msg {
            WM_TRAY_CLOSE => {
                let _ = DestroyWindow(hwnd);
                LRESULT(0)
            }
            WM_DESTROY => {
                let nid = NOTIFYICONDATAW {
                    cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
                    hWnd: hwnd,
                    uID: 1,
                    ..Default::default()
                };
                let _ = Shell_NotifyIconW(NIM_DELETE, &nid);
                PostQuitMessage(0);
                LRESULT(0)
            }
            TRAY_CB => {
                // Any click on the icon opens the menu.
                show_menu(hwnd);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    /// Snapshot → menu → popup → send the picked command.
    unsafe fn show_menu(hwnd: HWND) {
        let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Ctx;
        if ptr.is_null() {
            return;
        }
        let ctx = &*ptr;

        // Snapshot the state up front; the popup blocks this thread, so
        // don't hold the mutex across it.
        let (status, features, recording, autostart, has_last_file, preview_on) = {
            let Ok(s) = ctx.shared.lock() else {
                return;
            };
            (
                s.status.clone(),
                s.features.clone(),
                s.recording,
                s.autostart,
                s.has_last_file,
                s.preview_on,
            )
        };

        let Some(menu) = CreatePopupMenu().ok() else {
            return;
        };

        // Draw the shared menu model. One description of the menu (see
        // `menu_rows`) means the Windows popup and the Mac popover are
        // reviewed against the same list, and the layout is unit-tested.
        let state = super::MenuState {
            camera: features.as_ref().is_some_and(|f| f.camera_on),
            microphone: features.as_ref().is_some_and(|f| f.mic_on),
            trackpad: features.as_ref().is_some_and(|f| f.trackpad_on),
            keyboard: features.as_ref().is_some_and(|f| f.keyboard_on),
            recording,
            has_last_file,
            preview_on,
            autostart,
        };
        let mut model = super::menu_rows(&state);
        model.insert(0, super::MenuRow {
            kind: super::Row::Info,
            id: 0,
            text: status.clone(),
        });
        for row in &model {
            let flags = super::flags_for(row, &state);
            append_item(menu, flags, row.id as usize, &super::decorate(row));
        }
        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        let _ = SetForegroundWindow(hwnd);
        let chosen = TrackPopupMenu(
            menu,
            TPM_RETURNCMD | TPM_BOTTOMALIGN | TPM_RIGHTBUTTON,
            pt.x,
            pt.y,
            None, // nreserved: Option<i32>
            hwnd,
            None,
        );
        let _ = DestroyMenu(menu);
        // The documented tray-menu quirk: without a follow-up posted message
        // the popup can stay open after an outside click.
        let _ = PostMessageW(Some(hwnd), 0, WPARAM(0), LPARAM(0));

        let id = (chosen.0 & 0xFFFF) as usize;
        if let Some(cmd) = match id {
            Ids::CAMERA => Some(TrayCommand::SetFeature(
                Feature::Camera,
                !state_on(&features, |f| f.camera_on),
            )),
            Ids::MICROPHONE => Some(TrayCommand::SetFeature(
                Feature::Microphone,
                !state_on(&features, |f| f.mic_on),
            )),
            Ids::TRACKPAD => Some(TrayCommand::SetFeature(
                Feature::Trackpad,
                !state_on(&features, |f| f.trackpad_on),
            )),
            Ids::KEYBOARD => Some(TrayCommand::SetFeature(
                Feature::Keyboard,
                !state_on(&features, |f| f.keyboard_on),
            )),
            Ids::RECORD => Some(TrayCommand::ToggleRecord),
            Ids::CLIPBOARD => Some(TrayCommand::SendClipboard),
            Ids::SHOW_FILE => Some(TrayCommand::ShowLastFile),
            Ids::PREVIEW => Some(TrayCommand::TogglePreview),
            Ids::RECONNECT => Some(TrayCommand::Reconnect),
            Ids::DISCONNECT => Some(TrayCommand::Disconnect),
            Ids::AUTOSTART => Some(TrayCommand::ToggleAutostart),
            Ids::QUIT => Some(TrayCommand::Quit),
            _ => None,
        } {
            let _ = ctx.cmd_tx.send(cmd);
        }
    }

    /// Current state of one feature row, from the snapshot (default off).
    fn state_on(
        features: &Option<FeatureStateSnapshot>,
        pick: fn(&FeatureStateSnapshot) -> bool,
    ) -> bool {
        features.as_ref().map(pick).unwrap_or(false)
    }

    fn append_item(
        menu: HMENU,
        flags: MENU_ITEM_FLAGS,
        id: usize,
        name: &str,
    ) {
        let text: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
        unsafe {
            let _ = AppendMenuW(menu, flags, id, PCWSTR(text.as_ptr()));
        }
    }

    /// The embedded product icon as an `HICON`, or None (caller falls back).
    fn tray_icon(_hinstance: HINSTANCE) -> Option<HICON> {
        const PNG: &[u8] = include_bytes!("../../../assets/tray-icon.png");
        let (rgba, w, h) = decode_png(PNG)?;
        unsafe { hicon_from_rgba(&rgba, w, h) }
    }

    /// Minimal PNG → straight RGBA (the embedded asset is 32-bit RGBA).
    fn decode_png(bytes: &[u8]) -> Option<(Vec<u8>, i32, i32)> {
        let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
        decoder.set_transformations(png::Transformations::normalize_to_color8());
        let mut reader = decoder.read_info().ok()?;
        let mut buf = vec![0u8; reader.output_buffer_size()];
        let info = reader.next_frame(&mut buf).ok()?;
        let (w, h) = (info.width as i32, info.height as i32);
        let pixels = match info.color_type {
            png::ColorType::Rgba => buf[..info.buffer_size()].to_vec(),
            png::ColorType::Rgb => buf[..info.buffer_size()]
                .chunks_exact(3)
                .flat_map(|p| [p[0], p[1], p[2], 0xFF])
                .collect(),
            _ => return None,
        };
        Some((pixels, w, h))
    }

    /// Build an `HICON` from top-down RGBA via a 32-bit DIB + a 1-bpp mask.
    unsafe fn hicon_from_rgba(rgba: &[u8], w: i32, h: i32) -> Option<HICON> {
        if w <= 0 || h <= 0 || rgba.len() < (w * h * 4) as usize {
            return None;
        }
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let mut bmi = BITMAPINFO::default();
        bmi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -h; // top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB.0;
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let color: HBITMAP =
            match CreateDIBSection(Some(mem), &bmi, DIB_RGB_COLORS, &mut bits, None, 0) {
                Ok(b) if !bits.is_null() => b,
                _ => {
                    let _ = DeleteDC(mem);
                    let _ = ReleaseDC(None, screen);
                    return None;
                }
            };
        {
            let dst = std::slice::from_raw_parts_mut(bits as *mut u8, (w * h * 4) as usize);
            for (o, px) in rgba.chunks_exact(4).enumerate() {
                dst[o * 4] = px[2]; // B
                dst[o * 4 + 1] = px[1]; // G
                dst[o * 4 + 2] = px[0]; // R
                dst[o * 4 + 3] = px[3]; // A
            }
        }
        // An all-zero 1-bpp mask: the 32-bit alpha channel governs.
        let mask = CreateBitmap(w, h, 1, 1, None);
        let info = ICONINFO {
            fIcon: windows::core::BOOL(1),
            xHotspot: 0,
            yHotspot: 0,
            hbmMask: mask,
            hbmColor: color,
        };
        let icon = CreateIconIndirect(&info).ok();
        let _ = DeleteObject(HGDIOBJ(color.0));
        let _ = DeleteObject(HGDIOBJ(mask.0));
        let _ = DeleteDC(mem);
        let _ = ReleaseDC(None, screen);
        icon
    }

    /// Copy `text` into a fixed-size UTF-16 buffer, NUL-terminated.
    fn set_utf16(buf: &mut [u16], text: &str) {
        let len = buf.len().saturating_sub(1);
        for (dst, src) in buf.iter_mut().zip(text.encode_utf16().take(len)) {
            *dst = src;
        }
    }
}

#[cfg(windows)]
pub use win32::{start, disabled};

// ---------------------------------------------------------------------------
// No-op stub for non-Windows dev builds (select-arm wiring compiles the same)
// ---------------------------------------------------------------------------

#[cfg(not(windows))]
pub struct TrayHandle;

#[cfg(not(windows))]
#[allow(dead_code)] // host builds only no-op; the real calls are windows-gated
impl TrayHandle {
    pub fn set_status(&self, _status: &str) {}
    pub fn set_features(&self, _features: Option<rc_protocol::FeatureStateSnapshot>) {}
    pub fn set_recording(&self, _on: bool) {}
    pub fn set_autostart(&self, _on: bool) {}
    pub fn set_has_last_file(&self, _on: bool) {}
    pub fn set_preview(&self, _on: bool) {}
}

#[cfg(not(windows))]
pub fn start(_tip: &str) -> (TrayHandle, tokio::sync::mpsc::UnboundedReceiver<TrayCommand>) {
    // A sender-dropped channel: `recv()` yields `None` immediately, so the
    // app loop disables the tray arm on the first tick.
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    drop(tx);
    (TrayHandle, rx)
}

