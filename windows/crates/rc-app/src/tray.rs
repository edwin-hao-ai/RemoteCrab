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

//! On non-Windows builds the menu model has no renderer, so the
//! compiler cannot see its consumers. It is still exercised — the
//! layout and wording tests run everywhere, and the Win32 renderer on
//! Windows uses every type.
#![cfg_attr(not(windows), allow(dead_code, unused_imports))]
use rc_protocol::Feature;

#[cfg(windows)]
pub use crate::tray_menu::flags_for;
// Used by the Win32 menu builder, and by the menu model's own tests. They are
// a deliberate part of the crate's testable surface, not leftovers.
#[allow(unused_imports)]
pub use crate::tray_menu::{decorate, detail_rows, menu_rows, MenuRow, MenuState, Row};

/// One user action from the tray menu, routed to the app loop.
#[cfg_attr(not(windows), allow(dead_code))]
#[derive(Debug, Clone)]
pub enum TrayCommand {
    /// Flip the phone's camera. The Mac has had this row since the switcher
    /// shipped; on Windows it was console-only, so facing the wrong way was a
    /// two-terminal operation.
    SwitchCamera,
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
        ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP,
        HGDIOBJ,
    };
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Shell::{
        Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NIM_MODIFY,
    NOTIFYICONDATAW,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        AppendMenuW, CreateIconIndirect, CreatePopupMenu, CreateWindowExW, DefWindowProcW,
        DestroyMenu, DestroyWindow, DispatchMessageW, GetCursorPos, GetMessageW, GetWindowLongPtrW,
        LoadImageW, MessageBoxW, PostMessageW, PostQuitMessage, RegisterClassW,
        RegisterWindowMessageW, SetForegroundWindow, SetMenuItemBitmaps, SetWindowLongPtrW,
        TrackPopupMenu, TranslateMessage, GWLP_USERDATA, HICON, HMENU, ICONINFO, IDI_APPLICATION,
        IMAGE_ICON,
        LR_DEFAULTSIZE, LR_SHARED, MB_ICONINFORMATION, MB_OK, MENU_ITEM_FLAGS, MF_BYCOMMAND,
        MF_GRAYED, MF_POPUP, MF_STRING, MSG, TPM_BOTTOMALIGN, TPM_RETURNCMD, TPM_RIGHTBUTTON,
        WM_APP, WM_DESTROY, WM_LBUTTONDBLCLK, WM_LBUTTONUP, WM_RBUTTONDBLCLK, WM_RBUTTONUP,
        WNDCLASSW, WS_OVERLAPPED,
    };

    use super::TrayCommand;
    use rc_protocol::Feature;

    /// The tray callback message (app-private, above `WM_APP`).
    const TRAY_CB: u32 = WM_APP + 1;
    /// Close request marshalled to the tray thread.
    const WM_TRAY_CLOSE: u32 = WM_APP + 2;
    /// "The status changed; put it in the tooltip."
    ///
    /// Posted rather than done in place: the setters run on whichever thread
    /// noticed the change, and a window — and the shell icon that belongs to it —
    /// is owned by the thread that created it. Without this hop the tooltip is
    /// whatever was passed at startup and never changes, which for a program whose
    /// entire surface is a tray icon is the fastest state check quietly returning a
    /// stale answer.
    const WM_TRAY_REFRESH: u32 = WM_APP + 6;
    /// "Open a window", marshalled to the tray thread.
    ///
    /// Every window is created here rather than by whoever wants it, for one
    /// reason: this is the only thread that dispatches messages, and a Win32
    /// window belongs to the thread that made it. Opening them from the runtime
    /// thread produced windows that were drawn once and then answered nothing —
    /// the first-run wizard shipped that way and Windows drew it as
    /// "(Not Responding)".
    const WM_OPEN_WIZARD: u32 = WM_APP + 3;
    const WM_OPEN_SETTINGS: u32 = WM_APP + 4;
    const WM_OPEN_SELF_CHECK: u32 = WM_APP + 5;

    /// Menu ids, handed to the app loop. One scheme only: the ids the shared
    /// menu model (`tray_menu::ids`) puts on the rows.
    ///
    /// There used to be a second, private table here. When the hand-written
    /// `append_item` calls were replaced by the shared model, the rows started
    /// carrying `tray_menu::ids` values (100+) while the click dispatch kept
    /// matching the old 1..14 table — so **every menu click fell through to
    /// `_ => None` and the whole tray went inert** while still rendering
    /// perfectly. Two id schemes is now a compile error by construction.
    use crate::tray_menu::ids;

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
        /// Short reason, already localized — rendered into the menu row.
        diagnosis_summary: String,
        /// The full explanation, shown in a dialog when the row is clicked.
        diagnosis_detail: String,
        /// Live readouts for the "connection details" submenu: `(label, value)`.
        details: Vec<(String, String)>,
    }

    struct Ctx {
        shared: Arc<Mutex<Shared>>,
        cmd_tx: tokio::sync::mpsc::UnboundedSender<TrayCommand>,
        /// The icon to put back when Explorer restarts.
        ///
        /// Kept rather than looked up again, because the message that says the
        /// taskbar is gone can arrive before anything else on this thread and the
        /// lookup is what may have failed in the first place.
        icon: HICON,
        /// The caller's line, which the status is appended to.
        tip: String,
    }

    /// The shell's view of this icon.
    ///
    /// Built in one place because there are now two that hand it over: the first
    /// `NIM_ADD`, and the one after Explorer restarts. Two copies would drift, and
    /// the copy that drifts is the one nobody looks at.
    fn notify_data(hwnd: HWND, icon: HICON, tip: &str) -> NOTIFYICONDATAW {
        let mut tip_buf = [0u16; 128];
        set_utf16(&mut tip_buf, tip);
        NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: 1,
            uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage: TRAY_CB,
            hIcon: icon,
            szTip: tip_buf,
            ..Default::default()
        }
    }

    /// The tooltip: the caller's line, plus the live status when there is one.
    ///
    /// Truncated by *characters*, not UTF-16 units, so a cut can never land between
    /// the halves of a surrogate pair.
    fn tip_text(base: &str, status: &str) -> String {
        let combined = if status.trim().is_empty() {
            base.to_string()
        } else {
            format!("{base} — {status}")
        };
        combined.chars().take(120).collect()
    }

    /// The tooltip for a context's current state.
    fn ctx_tip(ctx: &Ctx) -> String {
        let status = ctx.shared.lock().map(|s| s.status.clone()).unwrap_or_default();
        tip_text(&ctx.tip, &status)
    }

    /// The message Explorer broadcasts after it (re)starts.
    ///
    /// Registered rather than assumed: it is a *string* message, and the value
    /// Windows gives it differs per session. Compared against the wndproc's
    /// `msg` and handled before the `match`, because it is not a constant.
    static TASKBAR_CREATED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

    /// Handle to the live tray thread. `Drop` closes it.
    pub struct TrayHandle {
        shared: Arc<Mutex<Shared>>,
        hwnd_slot: Arc<AtomicIsize>,
    }

    impl TrayHandle {
        /// Push the status line (the sync-able pill-language line).
        ///
        /// Also the tooltip, because that is what the user sees when they hover —
        /// and for a program whose whole surface is one icon, a tooltip that never
        /// changes is the quickest way to check the state quietly lying.
        pub fn set_status(&self, status: &str) {
            if let Ok(mut s) = self.shared.lock() {
                s.status = status.to_string();
            }
            self.refresh_tooltip();
        }

        /// Ask the tray thread to put the current status in the tooltip.
        ///
        /// A post rather than a call: the setters run on whichever thread noticed
        /// the change, and a window — and the icon that belongs to it — is owned by
        /// the thread that created it.
        pub fn refresh_tooltip(&self) {
            let hwnd = self.hwnd_slot.load(Ordering::SeqCst);
            if hwnd != 0 {
                unsafe {
                    let _ = PostMessageW(
                        Some(HWND(hwnd as *mut std::ffi::c_void)),
                        WM_TRAY_REFRESH,
                        WPARAM(0),
                        LPARAM(0),
                    );
                }
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

        /// Publish the live readouts behind the "connection details" submenu.
        pub fn set_details(&self, details: Vec<(String, String)>) {
            if let Ok(mut s) = self.shared.lock() {
                s.details = details;
            }
        }

        /// Publish the connection diagnosis: a one-line reason for the menu
        /// row and the full text for the dialog.
        pub fn set_diagnosis(&self, summary: &str, detail: &str) {
            if let Ok(mut s) = self.shared.lock() {
                s.diagnosis_summary = summary.to_string();
                s.diagnosis_detail = detail.to_string();
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

        /// Ask the tray thread to open the setup wizard.
        ///
        /// A Win32 window belongs to the thread that created it, and only that
        /// thread can dispatch its messages. The tray thread is the only one in
        /// this program with a message pump, so a caller on any other thread has
        /// to ask rather than create — which is exactly what went wrong: the
        /// first-run wizard was built on the runtime thread, which never pumps,
        /// so it appeared and then answered nothing. Windows drew it as
        /// "(Not Responding)" in the title bar.
        pub fn open_wizard(&self) {
            // The tray thread publishes its window handle only once the icon
            // exists, and the first-run caller runs from the moment `start`
            // returns — so it can lose that race by a few milliseconds. Without
            // the wait the post goes to handle 0 and is silently dropped, which
            // is how the first-run wizard stopped appearing at all.
            //
            // Bounded: if the tray never comes up there is nothing to open a
            // window on, and blocking forever would be worse than not showing it.
            for _ in 0..100 {
                if self.hwnd_slot.load(Ordering::SeqCst) != 0 {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            self.post(WM_OPEN_WIZARD);
        }

        fn post(&self, msg: u32) {
            let hwnd = self.hwnd_slot.load(Ordering::SeqCst);
            if hwnd != 0 {
                unsafe {
                    let _ = PostMessageW(Some(HWND(hwnd as *mut _)), msg, WPARAM(0), LPARAM(0));
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
    pub fn start(
        tip: &str,
    ) -> (
        TrayHandle,
        tokio::sync::mpsc::UnboundedReceiver<TrayCommand>,
    ) {
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
    pub fn disabled() -> (
        TrayHandle,
        tokio::sync::mpsc::UnboundedReceiver<TrayCommand>,
    ) {
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
                icon: HICON(icon.0),
                tip: tip.to_string(),
            })) as isize,
        );

        // Asked for, not assumed: `TaskbarCreated` is one of the string messages,
        // so its value differs per session.
        let taskbar_created = unsafe { RegisterWindowMessageW(windows::core::w!("TaskbarCreated")) };
        TASKBAR_CREATED.store(taskbar_created, Ordering::Relaxed);
        if std::env::var("RC_TRAY_TRACE").is_ok() {
            eprintln!("[tray] TaskbarCreated = 0x{taskbar_created:04X}");
        }

        let nid = notify_data(hwnd, HICON(icon.0), &tip_text(tip, ""));
        if !Shell_NotifyIconW(NIM_ADD, &nid).as_bool() {
            return;
        }
        hwnd_slot.store(hwnd.0 as isize, Ordering::SeqCst);

        // Message pump until WM_QUIT (fired from WM_DESTROY).
        //
        // `None`, not `Some(hwnd)`: a filtered pump retrieves only the named
        // window's messages, and every other window this thread creates — the
        // settings window, the self-check panel, the setup wizard — then gets
        // drawn once, by the `CreateWindowExW` call itself, and never dispatched
        // again. They were painted and immediately (Not Responding), with no
        // visible clue about why. One thread, one pump, everything on it.
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
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
        // Every message this window receives, on request. This is how the
        // Explorer-restart path was proved to work: the broadcast is a
        // *registered* message, so there is no constant to grep for and no way to
        // see it arrive except by printing what does.
        if std::env::var("RC_TRAY_TRACE").is_ok() {
            eprintln!("[tray-msg] 0x{msg:04X}");
        }
        match msg {
            // Explorer restarted, so every notification-area icon is gone —
            // including this one. It restarts on every shell update and any time a
            // user restarts it by hand. Without this the receiver becomes
            // unreachable: no window, no console, no icon, and the only way to stop
            // it is Task Manager. It is a *string* message, so it is compared
            // rather than matched against a constant.
            _ if msg == TASKBAR_CREATED.load(Ordering::Relaxed) => {
                let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Ctx;
                if !ptr.is_null() {
                    let ctx = &*ptr;
                    let nid = notify_data(hwnd, ctx.icon, &ctx_tip(ctx));
                    let _ = Shell_NotifyIconW(NIM_ADD, &nid);
                    // Logged because this is the one moment the program is briefly
                    // invisible, and a user who saw the icon blink deserves to find
                    // out why rather than report it as a crash.
                    eprintln!(
                        "[tray] Explorer restarted — the icon was re-added to the notification area"
                    );
                }
                LRESULT(0)
            }
            // The status changed somewhere else in the process; the shell has to be
            // told from the thread that owns the icon.
            WM_TRAY_REFRESH => {
                let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Ctx;
                if !ptr.is_null() {
                    let ctx = &*ptr;
                    let nid = notify_data(hwnd, ctx.icon, &ctx_tip(ctx));
                    let _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
                }
                LRESULT(0)
            }
            WM_TRAY_CLOSE => {
                let _ = DestroyWindow(hwnd);
                LRESULT(0)
            }
            WM_OPEN_WIZARD => {
                // On this thread, because this is the thread with the pump.
                crate::open_wizard();
                LRESULT(0)
            }
            WM_OPEN_SETTINGS => {
                crate::open_settings();
                LRESULT(0)
            }
            WM_OPEN_SELF_CHECK => {
                crate::open_self_check();
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
                // The icon's callback carries the mouse message in the low word of
                // `lParam`, and Shell_NotifyIcon sends one for **every** event over
                // the icon — `WM_MOUSEMOVE` included, because this program never
                // called `NIM_SETVERSION` to opt into the newer protocol. Answering
                // them all opened the menu the moment the cursor crossed the icon,
                // which is not what a notification-area icon does anywhere else in
                // Windows: the menu arrived before the user had decided to click.
                //
                // Only a completed click opens it. Mouse movement and the
                // button-down half of a click arrive here too and mean nothing yet.
                let event = (lparam.0 as u32) & 0xFFFF;
                if matches!(
                    event,
                    WM_LBUTTONUP | WM_RBUTTONUP | WM_LBUTTONDBLCLK | WM_RBUTTONDBLCLK
                ) {
                    show_menu(hwnd);
                }
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
        let (status, features, recording, autostart, has_last_file, preview_on, diagnosis, details) = {
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
                s.diagnosis_summary.clone(),
                s.details.clone(),
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
            diagnosis,
            details,
            // Read from the machine, not cached: the whole point of the row is
            // that it disappears the moment a UAC prompt has been accepted, and
            // a cached "no" would keep offering an action that no longer does
            // anything.
            notify_relay: crate::notify_relay::is_enabled(),
            // Read from the phone's own snapshot rather than from the capture, so
            // the row reports what the user ASKED for and not what this machine
            // managed to start — a capture that failed still says "off, turn it
            // on from your phone", and the failure itself is spoken by
            // `speaker::status_line` instead.
            connected: features.is_some(),
            speaker_on: features.as_ref().is_some_and(|f| f.speaker_on),
            vcam_installed: {
                #[cfg(windows)]
                let installed = crate::vcam::is_registered();
                #[cfg(not(windows))]
                let installed = true;
                installed
            },
        };
        let mut model = super::menu_rows(&state);
        // The status line goes first, above the readouts submenu.
        model.insert(
            0,
            super::MenuRow {
                kind: super::Row::Info,
                id: 0,
                text: status.clone(),
            },
        );
        // A `Row::Sub` is a real Win32 submenu: build the child menu, then hand
        // its `HMENU` to `AppendMenuW` as the item id alongside `MF_POPUP`. The
        // flat model cannot express a handle, so this is the one place that
        // knows about one — and the submenu rows are then dropped from the flat
        // pass so they are not *also* drawn at the top level.
        for row in model.iter().filter(|r| r.kind == super::Row::Sub) {
            let Ok(inner) = CreatePopupMenu() else {
                continue;
            };
            for detail in super::detail_rows(&state) {
                append_item(inner, MF_STRING | MF_GRAYED, 0, &detail.text);
            }
            let title: Vec<u16> = super::decorate(row)
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            unsafe {
                let _ = AppendMenuW(menu, MF_POPUP, inner.0 as usize, PCWSTR(title.as_ptr()));
            }
        }
        let model: Vec<_> = model
            .into_iter()
            .filter(|r| r.kind != super::Row::Sub)
            .collect();

        // The icon sheet, cut into one bitmap per row. Loaded per popup
        // because a Win32 menu is rebuilt every time it opens; the alternative
        // (a cached set on `TrayHandle`) buys nothing at a 16x16x15 sheet.
        let icons = IconSheet::load();
        for row in &model {
            let flags = super::flags_for(row, &state);
            append_item(menu, flags, row.id, &super::decorate(row));
            if let Some(icons) = icons.as_ref() {
                let cell = crate::tray_menu::row_icon_cell(row.id, recording);
                if let Some(bmp) = cell.and_then(|c| unsafe { icons.bitmap(c) }) {
                    unsafe {
                        // MF_BYCOMMAND: the id is the command id, not a
                        // position, so this survives the model growing rows.
                        // Both slots, not just one: Win32 picks the
                        // "checked" bitmap for a ticked row and the
                        // "unchecked" one otherwise, so a single argument
                        // would make the icon appear only on half the rows.
                        let _ = SetMenuItemBitmaps(
                            menu,
                            row.id as u32,
                            MF_BYCOMMAND,
                            Some(bmp),
                            Some(bmp),
                        );
                    }
                }
            }
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
        // A row id the handler does not know is a silent no-op, and that is
        // exactly how this whole tray went dead once already (two id schemes,
        // both compiling, the model tests still green). In a debug build, make
        // it a loud failure instead.
        debug_assert!(
            id == 0 || crate::tray_menu::known_ids().contains(&id),
            "tray row id {id} has no click handler — add it to \
             tray_menu::known_ids() and to the match below"
        );
        if let Some(cmd) = match id {
            ids::CAMERA => Some(TrayCommand::SetFeature(
                Feature::Camera,
                !state_on(&features, |f| f.camera_on),
            )),
            ids::MICROPHONE => Some(TrayCommand::SetFeature(
                Feature::Microphone,
                !state_on(&features, |f| f.mic_on),
            )),
            ids::TRACKPAD => Some(TrayCommand::SetFeature(
                Feature::Trackpad,
                !state_on(&features, |f| f.trackpad_on),
            )),
            ids::KEYBOARD => Some(TrayCommand::SetFeature(
                Feature::Keyboard,
                !state_on(&features, |f| f.keyboard_on),
            )),
            ids::SWITCH_CAMERA => Some(TrayCommand::SwitchCamera),
            ids::RECORD => Some(TrayCommand::ToggleRecord),
            ids::CLIPBOARD => Some(TrayCommand::SendClipboard),
            ids::SHOW_FILE => Some(TrayCommand::ShowLastFile),
            ids::PREVIEW => Some(TrayCommand::TogglePreview),
            // Registering the camera needs administrator rights, so the whole
            // action is one Windows UAC prompt. Declining is a normal outcome,
            // so it gets a sentence that says the row is still there — not an
            // error.
            #[cfg(windows)]
            ids::INSTALL_VCAM => {
                let outcome = crate::vcam::install_with_elevation();
                // The wording lives in one place, shared with the wizard and the
                // settings window. Three private copies is three chances to say
                // something slightly different about the same refusal, and the
                // copy nobody edits is the one a user reads.
                if let Some((zh, en)) = crate::wizard::install_outcome(outcome) {
                    println!("  {}", crate::i18n::t(zh, en));
                } else {
                    println!("  administrator prompt accepted - confirming the registration");
                }
                // No toast, no status overwrite: the row vanishing from the
                // next popup *is* the confirmation, because `is_registered` is
                // re-read every time the menu is built. Overwriting the
                // connection status with a camera message would be a lie about
                // the thing the user is actually looking at.
                None
            }
            #[cfg(not(windows))]
            ids::INSTALL_VCAM => None,
            // Reopen the setup wizard. Not first-run-only: a user who declined
            // the camera install has no other way back into it.
            ids::SETUP => {
                crate::open_wizard();
                None
            }
            // The settings window. The one place the notification denylist can
            // be edited, which is what makes the relay a control rather than a
            // claim.
            // The four-quadrant self-check.
            ids::SELF_CHECK => {
                crate::open_self_check();
                None
            }
            ids::SETTINGS => {
                crate::open_settings();
                None
            }
            ids::NOTIFY => {
                let now_on = !crate::notify_relay::is_enabled();
                crate::notify_relay::set_enabled(now_on);
                println!(
                    "  {}",
                    crate::i18n::t(
                        if now_on {
                            "通知中继已开启 — 之后会弹一次 Windows 的通知权限确认。"
                        } else {
                            "通知中继已关闭。"
                        },
                        if now_on {
                            "Notification relay is on — Windows will ask once for notification access."
                        } else {
                            "Notification relay is off."
                        }
                    )
                );
                None
            }
            ids::DIAGNOSIS => {
                // A modal dialog on the tray thread: the app loop must not
                // block, and the tray thread owns the only HWND we can parent
                // it to. The text is already assembled and tested elsewhere.
                let detail = ctx
                    .shared
                    .lock()
                    .map(|s| s.diagnosis_detail.clone())
                    .unwrap_or_default();
                let body: Vec<u16> = detail.encode_utf16().chain(std::iter::once(0)).collect();
                let title: Vec<u16> = "RemoteCrab"
                    .encode_utf16()
                    .chain(std::iter::once(0))
                    .collect();
                unsafe {
                    let _ = MessageBoxW(
                        Some(hwnd),
                        PCWSTR(body.as_ptr()),
                        PCWSTR(title.as_ptr()),
                        MB_OK | MB_ICONINFORMATION,
                    );
                }
                None
            }
            ids::RECONNECT => Some(TrayCommand::Reconnect),
            ids::DISCONNECT => Some(TrayCommand::Disconnect),
            ids::AUTOSTART => Some(TrayCommand::ToggleAutostart),
            ids::QUIT => Some(TrayCommand::Quit),
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

    fn append_item(menu: HMENU, flags: MENU_ITEM_FLAGS, id: usize, name: &str) {
        let text: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
        unsafe {
            let _ = AppendMenuW(menu, flags, id, PCWSTR(text.as_ptr()));
        }
    }

    /// The menu icon sheet, decoded once per popup and cut into per-row
    /// monochrome bitmaps.
    ///
    /// `windows/assets/menu-icons.png` is a single horizontal strip of 16x16
    /// cells generated by `scripts/generate-windows-menu-icons.py`. Win32 menu
    /// icons have to be bitmaps (`SetMenuItemBitmaps`), not glyphs, which is
    /// why the sheet exists instead of a font — see the script's doc comment.
    struct IconSheet {
        /// One ARGB slice per cell, `CELL * CELL` pixels each.
        cells: Vec<Vec<u8>>,
    }

    impl IconSheet {
        const CELL: usize = 16;

        /// `None` if the asset is missing or malformed. The menu then renders
        /// with no icon column at all, which is a legible degradation; a wrong
        /// glyph would not be.
        fn load() -> Option<IconSheet> {
            const ASSET: &[u8] = include_bytes!("../../../assets/menu-icons.png");
            let (rgba, w, h) = decode_png(ASSET)?;
            if h as usize != Self::CELL || !(w as usize).is_multiple_of(Self::CELL) {
                return None;
            }
            if w as usize / Self::CELL != crate::tray_menu::ICON_CELLS_FOR_THE_SHEET {
                // The asset and the cell map have drifted apart — almost always
                // because the sheet was regenerated without updating
                // `icon_cell`. Refuse rather than draw the wrong glyphs.
                return None;
            }
            let cells = (0..(w as usize / Self::CELL))
                .map(|i| {
                    let start = i * Self::CELL * 4;
                    rgba[start..start + Self::CELL * Self::CELL * 4].to_vec()
                })
                .collect();
            Some(IconSheet { cells })
        }

        /// One cell as a 1-bit `HBITMAP`, which is what a menu icon wants:
        /// Windows uses the mask for the glyph and colours the text itself, so
        /// an icon that ignores the system theme (or hardcodes a colour that
        /// disappears on a dark menu) is the thing to avoid.
        unsafe fn bitmap(&self, cell: usize) -> Option<HBITMAP> {
            let src = self.cells.get(cell)?;
            let n = Self::CELL as i32;
            let screen = GetDC(None);
            let mem = CreateCompatibleDC(Some(screen));
            let mut bmi = BITMAPINFO::default();
            bmi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
            bmi.bmiHeader.biWidth = n;
            bmi.bmiHeader.biHeight = -n; // top-down
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 1;
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
                // 1bpp: one bit per pixel, 4 bytes per row, padded to 4 bytes.
                // Set means "ink", which is the bit the mask is read from.
                let stride = Self::CELL.div_ceil(32) * 4;
                let dst = std::slice::from_raw_parts_mut(bits as *mut u8, stride * Self::CELL);
                for y in 0..Self::CELL {
                    for x in 0..Self::CELL {
                        let px = (y * Self::CELL + x) * 4;
                        let (r, g, b, a) = (src[px], src[px + 1], src[px + 2], src[px + 3]);
                        // The sheet is a white glyph on transparent, so
                        // "visible" is alpha; tolerate an opaque black glyph
                        // too so the asset can be re-exported either way.
                        let on = a > 127 && (r + g + b) > 96;
                        if on {
                            let idx = y * stride + (x / 8);
                            dst[idx] |= 0x80 >> (x % 8);
                        }
                    }
                }
            }
            let _ = SelectObject(mem, HGDIOBJ(color.0));
            let _ = DeleteDC(mem);
            let _ = ReleaseDC(None, screen);
            Some(color)
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
    ///
    /// Truncates on a character boundary, and clears the tail. Two things the
    /// previous version got wrong, both invisible until the string is long enough:
    /// cutting between the halves of a surrogate pair leaves a lone surrogate,
    /// which the shell draws as a replacement character; and a shorter string
    /// written over a longer one leaves the old tail in place, because nothing
    /// cleared it.
    fn set_utf16(buf: &mut [u16], text: &str) {
        let mut written = 0;
        for ch in text.chars() {
            let mut units = [0u16; 2];
            let encoded = ch.encode_utf16(&mut units);
            if written + encoded.len() >= buf.len() {
                break;
            }
            buf[written..written + encoded.len()].copy_from_slice(encoded);
            written += encoded.len();
        }
        for slot in buf[written..].iter_mut() {
            *slot = 0;
        }
    }
}

#[cfg(windows)]
pub use win32::{disabled, start, TrayHandle};

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

    /// No-op off Windows: there is no tray to explain anything on.
    pub fn set_diagnosis(&self, _summary: &str, _detail: &str) {}

    /// No-op off Windows: there is no tray to show readouts in.
    pub fn set_details(&self, _details: Vec<(String, String)>) {}
}

#[cfg(not(windows))]
pub fn start(
    _tip: &str,
) -> (
    TrayHandle,
    tokio::sync::mpsc::UnboundedReceiver<TrayCommand>,
) {
    // A sender-dropped channel: `recv()` yields `None` immediately, so the
    // app loop disables the tray arm on the first tick.
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    drop(tx);
    (TrayHandle, rx)
}
