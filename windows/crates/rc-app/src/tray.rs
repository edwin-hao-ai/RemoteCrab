//! System-tray icon + context menu.
//!
//! Mirrors the Mac menu-bar popover's structure and wording (`MenuBarMenu`):
//! a status line, the same four feature-toggle rows the Mac exposes
//! (Camera / Microphone / Trackpad / Keyboard), then Start/Stop Recording,
//! Send Clipboard to iPhone, Reconnect, Disconnect and `Quit RemoteCrab`.
//!
//! The menu rebuilds fresh on every open from a `Shared` snapshot the app
//! loop keeps updated, and every selection is forwarded over a channel to
//! the app's `tokio::select!` loop, which owns the session/audio/recording
//! state — the tray thread itself owns nothing. On non-Windows dev builds
//! the handle is a no-op stub so the wiring compiles unchanged everywhere.

use rc_protocol::Feature;

/// One user action from the tray menu, routed to the app loop.
#[cfg_attr(not(windows), allow(dead_code))]
#[derive(Debug, Clone)]
pub enum TrayCommand {
    SetFeature(Feature, bool),
    ToggleRecord,
    SendClipboard,
    Reconnect,
    Disconnect,
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
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Shell::{
        Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
        DispatchMessageW, GetCursorPos, GetMessageW, GetWindowLongPtrW, HICON, HMENU, IDI_APPLICATION,
        IMAGE_ICON, LR_DEFAULTSIZE, LR_SHARED, MF_CHECKED, MF_GRAYED, MF_SEPARATOR, MF_STRING,
        MSG, MENU_ITEM_FLAGS, PostMessageW, PostQuitMessage, RegisterClassW, SetForegroundWindow,
        SetWindowLongPtrW, TrackPopupMenu, TranslateMessage, WNDCLASSW,
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
        const RECONNECT: usize = 10;
        const DISCONNECT: usize = 11;
        const QUIT: usize = 12;
    }

    /// Everything the menu renders; owned by the app loop, read fresh on open.
    #[derive(Default)]
    struct Shared {
        status: String,
        features: Option<FeatureStateSnapshot>,
        recording: bool,
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

        let Ok(icon) = LoadImageW(
            Some(hinstance),
            IDI_APPLICATION,
            IMAGE_ICON,
            0,
            0,
            LR_DEFAULTSIZE | LR_SHARED,
        ) else {
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
        let (status, features, recording) = {
            let Ok(s) = ctx.shared.lock() else {
                return;
            };
            (s.status.clone(), s.features.clone(), s.recording)
        };

        let Some(menu) = CreatePopupMenu().ok() else {
            return;
        };

        append_item(menu, MF_STRING | MF_GRAYED, 0, &status);
        append_separator(menu);

        for (id, name, on) in [
            (Ids::CAMERA, crate::i18n::t("摄像头", "Camera"), features.as_ref().map(|f| f.camera_on)),
            (Ids::MICROPHONE, crate::i18n::t("麦克风", "Microphone"), features.as_ref().map(|f| f.mic_on)),
            (Ids::TRACKPAD, crate::i18n::t("触控板", "Trackpad"), features.as_ref().map(|f| f.trackpad_on)),
            (Ids::KEYBOARD, crate::i18n::t("键盘", "Keyboard"), features.as_ref().map(|f| f.keyboard_on)),
        ] {
            let mut flags = MF_STRING;
            if on == Some(true) {
                flags |= MF_CHECKED;
            }
            append_item(menu, flags, id, name);
        }
        append_separator(menu);

        append_item(
            menu,
            MF_STRING,
            Ids::RECORD,
            if recording {
                crate::i18n::t("停止录制", "Stop Recording")
            } else {
                crate::i18n::t("开始录制", "Start Recording")
            },
        );
        append_item(menu, MF_STRING, Ids::CLIPBOARD,
                    crate::i18n::t("发送剪贴板到 iPhone", "Send Clipboard to iPhone"));
        append_separator(menu);
        append_item(menu, MF_STRING, Ids::RECONNECT, crate::i18n::t("重新连接", "Reconnect"));
        append_item(menu, MF_STRING, Ids::DISCONNECT, crate::i18n::t("断开连接", "Disconnect"));
        append_separator(menu);
        append_item(menu, MF_STRING, Ids::QUIT, crate::i18n::t("退出 RemoteCrab", "Quit RemoteCrab"));

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
            Ids::RECONNECT => Some(TrayCommand::Reconnect),
            Ids::DISCONNECT => Some(TrayCommand::Disconnect),
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

    fn append_separator(menu: HMENU) {
        unsafe {
            let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
        }
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
impl TrayHandle {
    pub fn set_status(&self, _status: &str) {}
    pub fn set_features(&self, _features: Option<rc_protocol::FeatureStateSnapshot>) {}
    pub fn set_recording(&self, _on: bool) {}
}

#[cfg(not(windows))]
pub fn start(_tip: &str) -> (TrayHandle, tokio::sync::mpsc::UnboundedReceiver<TrayCommand>) {
    // A sender-dropped channel: `recv()` yields `None` immediately, so the
    // app loop disables the tray arm on the first tick.
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    drop(tx);
    (TrayHandle, rx)
}
