//! The settings window.
//!
//! Plain Win32 again, and deliberately so: the tray menu and the wizard are
//! already plain Win32, and this is the third window, not the first — the point
//! at which a UI framework stops being an addition and starts being a
//! dependency the project maintains forever.
//!
//! Four sections, matching the Mac's `PreferencesView` order:
//! notifications (with an editable denylist), connection (the paired phones),
//! camera, and video quality. Each control writes straight through to the thing
//! it changes, and the window re-reads on every paint, so there is no "apply"
////! step and no way to have unsaved settings.
//!
//! The model — what is a valid entry, what a refusal says — is in
//! [`rc_net::settings`], tested on any host.

use rc_net::settings::Quality;
use std::sync::Mutex;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::InvalidateRect;
use windows::Win32::Graphics::Gdi::{COLOR_WINDOW, HBRUSH};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;

const CLASS: PCWSTR = w!("RemoteCrabSettings");

// Control ids. Fixed, so the handler is a `match` on constants.
const ID_ADD: usize = 10;
const ID_REMOVE: usize = 11;
const ID_LIST: usize = 12;
const ID_ENTRY: usize = 13;
const ID_FORGET: usize = 14;
const ID_PHONES: usize = 15;
const ID_RELAY: usize = 16;
const ID_CAMERA: usize = 17;
const ID_QUALITY: usize = 18;
const ID_AUTOSTART: usize = 19;
const ID_CLOSE: usize = 20;
const ID_UPDATE: usize = 21;
const ID_OPEN_LOG: usize = 22;

/// One editor action: change a name list, or refuse with a reason.
type NameEdit = Box<dyn Fn(&str) -> Result<(), Refusal> + Send + Sync>;

/// Why an edit was refused, as a message in both languages.
pub type Refusal = (&'static str, &'static str);

/// The window's data source.
///
/// Each field is a boxed closure rather than a trait object on a concrete type
/// because the settings window reads and writes four *different* pieces of app
/// state, and a trait with nine methods would be a trait implemented once for
/// the app and once for the tests — with the tests then not testing the real
/// wiring.
pub struct Actions {
    /// Add a name to the relay denylist. `Err` carries the reason to show.
    pub deny: NameEdit,
    /// Remove one.
    pub undeny: Box<dyn Fn(&str) + Send + Sync>,
    /// The current denylist, re-read on every paint.
    pub denylist: Box<dyn Fn() -> Vec<String> + Send + Sync>,
    /// Forget a paired phone. Takes the phone's name.
    pub forget: Box<dyn Fn(&str) + Send + Sync>,
    /// The paired phones, re-read on every paint.
    pub phones: Box<dyn Fn() -> Vec<String> + Send + Sync>,
    /// The relay switch.
    pub relay: Box<dyn Fn() -> bool + Send + Sync>,
    pub set_relay: Box<dyn Fn(bool) + Send + Sync>,
    /// Whether the virtual camera is registered.
    pub camera: Box<dyn Fn() -> bool + Send + Sync>,
    /// The chosen video quality.
    pub quality: Box<dyn Fn() -> Quality + Send + Sync>,
    pub set_quality: Box<dyn Fn(Quality) + Send + Sync>,
    /// Start at login.
    pub autostart: Box<dyn Fn() -> bool + Send + Sync>,
    pub set_autostart: Box<dyn Fn(bool) + Send + Sync>,
    /// Install the virtual camera — the same UAC-raising path the wizard and
    /// the tray row use, so the three cannot drift. Returns what the attempt did
    /// so a refusal is reported rather than swallowed; [`crate::wizard::install_outcome`]
    /// decides what each outcome deserves to say.
    pub install_camera: Box<dyn Fn() -> Option<(&'static str, &'static str)> + Send + Sync>,
    /// Start a background update check. The window cannot wait for the network,
    /// so this returns immediately and the result arrives through
    /// [`set_update_message`].
    pub check_update: Box<dyn Fn() + Send + Sync>,
}

static STATE: Mutex<Option<Actions>> = Mutex::new(None);
/// The name a user has typed, and the last refusal, so a message survives until
/// the next edit rather than vanishing on the next paint.
static DRAFT: Mutex<(String, Option<(&'static str, &'static str)>)> =
    Mutex::new((String::new(), None));

fn with<R>(f: impl FnOnce(&Actions) -> R) -> Option<R> {
    STATE.lock().ok().and_then(|g| g.as_ref().map(f))
}

pub fn show(actions: Actions) -> Option<HWND> {
    unsafe {
        if let Ok(existing) = FindWindowW(CLASS, None) {
            let _ = ShowWindow(existing, SW_RESTORE);
            let _ = SetForegroundWindow(existing);
            return Some(existing);
        }
        let hinstance = HINSTANCE(GetModuleHandleW(None).ok()?.0);
        register(hinstance);
        *STATE.lock().ok()? = Some(actions);
        // Shown once, after it exists — see the note in `wizard_win::show`.
        // Created without `WS_VISIBLE` (and `WS_OVERLAPPED` is 0x0), so without
        // this the window is built, laid out, and never seen.
        // The title is built at runtime rather than a compile-time bilingual
        // literal. "RemoteCrab 设置 / Settings" drew both languages at once,
        // which is a translation key leaking into the chrome — the user picked a
        // language in Settings, and the window should honour it.
        let title = windows::core::HSTRING::from(format!(
            "RemoteCrab — {}",
            crate::i18n::t("设置", "Settings")
        ));
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            CLASS,
            PCWSTR(title.as_ptr()),
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            560,
            620,
            None,
            None,
            Some(hinstance),
            None,
        )
        .ok()?;
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);
        Some(hwnd)
    }
}

fn register(hinstance: HINSTANCE) {
    let cursor = unsafe { LoadCursorW(None, IDC_ARROW) }.unwrap_or_default();
    let wc = WNDCLASSW {
        lpfnWndProc: Some(wnd_proc),
        hInstance: hinstance,
        lpszClassName: CLASS,
        hCursor: cursor,
        hbrBackground: HBRUSH((COLOR_WINDOW.0 + 1) as *mut std::ffi::c_void),
        ..Default::default()
    };
    unsafe {
        let _ = RegisterClassW(&wc);
    }
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    unsafe {
        match msg {
            WM_CREATE => {
                build(hwnd);
                LRESULT(0)
            }
            WM_COMMAND => match wparam.0 & 0xFFFF {
                ID_ADD => {
                    add_denylist(hwnd);
                    LRESULT(0)
                }
                ID_REMOVE => {
                    remove_denylist(hwnd);
                    LRESULT(0)
                }
                ID_FORGET => {
                    forget_phone(hwnd);
                    LRESULT(0)
                }
                ID_RELAY => {
                    let now = with(|a| (a.relay)()).unwrap_or(false);
                    let on = !now;
                    with(|a| (a.set_relay)(on));
                    build(hwnd);
                    LRESULT(0)
                }
                // Installs the camera. Present **only** when it is missing —
                // a button that appears after the camera works is a button that
                // lies about its own effect.
                ID_CAMERA => {
                    // Run outside the lock: installing raises a UAC dialog, and
                    // holding a mutex across a modal dialog is how a process
                    // deadlocks.
                    let outcome = match STATE.lock() {
                        Ok(g) => match g.as_ref() {
                            Some(a) => (a.install_camera)(),
                            None => None,
                        },
                        Err(_) => None,
                    };
                    set_draft_error(outcome);
                    build(hwnd);
                    LRESULT(0)
                }
                ID_AUTOSTART => {
                    let now = with(|a| (a.autostart)()).unwrap_or(false);
                    let on = !now;
                    with(|a| (a.set_autostart)(on));
                    build(hwnd);
                    LRESULT(0)
                }
                ID_QUALITY => {
                    let next = with(|a| (a.quality)()).unwrap_or_default().index() + 1;
                    let q = Quality::from_index(next % Quality::CHOICES.len());
                    with(|a| (a.set_quality)(q));
                    build(hwnd);
                    LRESULT(0)
                }
                ID_CLOSE => {
                    let _ = DestroyWindow(hwnd);
                    LRESULT(0)
                }
                ID_UPDATE => {
                    // Fire-and-forget: the check talks to the network and the
                    // message loop cannot wait. The answer arrives by way of
                    // `set_update_message` plus `WM_SETTINGS_REFRESH`.
                    with(|a| (a.check_update)());
                    build(hwnd);
                    LRESULT(0)
                }
                ID_OPEN_LOG => {
                    // Reveal rather than open: a log is a file to hand to
                    // someone, and Explorer puts it under the cursor so it can
                    // be attached without hunting for the path.
                    rc_os::files::reveal(&rc_os::uninstall::local_appdata_dir());
                    LRESULT(0)
                }
                _ => DefWindowProcW(hwnd, msg, wparam, lparam),
            },
            WM_SETTINGS_REFRESH => {
                // Posted by a worker thread. Windows are thread-affine, so the
                // worker cannot redraw this one; it asks instead.
                build(hwnd);
                LRESULT(0)
            }
            WM_CLOSE => {
                let _ = DestroyWindow(hwnd);
                LRESULT(0)
            }
            WM_DESTROY => {
                // The state is per-window, so a second opening re-reads
                // everything rather than showing a stale snapshot.
                if let Ok(mut g) = STATE.lock() {
                    *g = None;
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
}

fn draft() -> String {
    DRAFT.lock().map(|d| d.0.clone()).unwrap_or_default()
}

fn set_draft_error(e: Option<(&'static str, &'static str)>) {
    if let Ok(mut d) = DRAFT.lock() {
        d.1 = e;
    }
}

/// What the last update check said, as one line under its button.
///
/// A module-level `Mutex` for the same reason `DRAFT` is: the check runs on a
/// worker thread, and the window has no channel into it — Win32 owns the message
/// loop, so the result is parked here and the worker pokes the window to repaint.
static UPDATE_MESSAGE: Mutex<Option<String>> = Mutex::new(None);

/// Called from the update worker with a finished sentence.
pub fn set_update_message(text: String) {
    if let Ok(mut m) = UPDATE_MESSAGE.lock() {
        *m = Some(text);
    }
}

fn with_update<R>(f: impl FnOnce(&Option<String>) -> R) -> R {
    match UPDATE_MESSAGE.lock() {
        Ok(g) => f(&g),
        Err(_) => f(&None),
    }
}

/// Ask an open settings window to redraw, from any thread.
///
/// `WM_APP + 1` because the range above `WM_APP` is reserved for applications —
/// the same reason the tray uses one. Posting rather than calling `build`
/// directly: a Win32 window belongs to the thread that created it, and a
/// cross-thread redraw is a class of bug that only shows up under load.
const WM_SETTINGS_REFRESH: u32 = WM_APP + 1;

pub fn refresh_if_open() {
    unsafe {
        if let Ok(hwnd) = FindWindowW(CLASS, None) {
            let _ = PostMessageW(Some(hwnd), WM_SETTINGS_REFRESH, WPARAM(0), LPARAM(0));
        }
    }
}

fn add_denylist(hwnd: HWND) {
    let typed = draft();
    let result = with(|a| (a.deny)(&typed));
    match result {
        Some(Ok(())) => {
            if let Ok(mut d) = DRAFT.lock() {
                // Cleared on success: leaving the text in the box after it has
                // been added invites the user to add it twice.
                d.0.clear();
                d.1 = None;
            }
        }
        Some(Err(msg)) => set_draft_error(Some(msg)),
        None => {}
    }
    unsafe {
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
}

fn remove_denylist(hwnd: HWND) {
    // The list is a single-selection listbox, so there is at most one selection
    // and it is the row the user is pointing at. No model needed: the row label
    // *is* the entry, and removal matches on it.
    let chosen = unsafe { selected(hwnd, ID_LIST) };
    if let Some(name) = chosen {
        with(|a| (a.undeny)(&name));
    }
    unsafe {
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
}

fn forget_phone(hwnd: HWND) {
    if let Some(name) = unsafe { selected(hwnd, ID_PHONES) } {
        with(|a| (a.forget)(&name));
    }
    unsafe {
        let _ = InvalidateRect(Some(hwnd), None, false);
    }
}

unsafe fn selected(hwnd: HWND, id: usize) -> Option<String> {
    unsafe {
        let h = GetDlgItem(Some(hwnd), id as i32).ok()?;
        let i = SendMessageW(h, LB_GETCURSEL, None, None).0;
        if i < 0 {
            return None;
        }
        let len = SendMessageW(h, LB_GETTEXTLEN, None, None).0 as usize;
        let mut buf = vec![0u16; len + 1];
        let n = SendMessageW(
            h,
            LB_GETTEXT,
            Some(WPARAM(i as usize)),
            Some(LPARAM(buf.as_mut_ptr() as isize)),
        )
        .0 as usize;
        buf.truncate(n);
        Some(String::from_utf16_lossy(&buf))
    }
}

unsafe fn build(hwnd: HWND) {
    use crate::i18n::t;
    unsafe {
        for id in [
            ID_ADD,
            ID_REMOVE,
            ID_LIST,
            ID_ENTRY,
            ID_FORGET,
            ID_PHONES,
            ID_RELAY,
            ID_CAMERA,
            ID_QUALITY,
            ID_AUTOSTART,
            ID_CLOSE,
        ] {
            if let Ok(h) = GetDlgItem(Some(hwnd), id as i32) {
                let _ = DestroyWindow(h);
            }
        }

        let mut y = 16;
        // --- Notifications
        label(hwnd, t("通知", "Notifications"), 20, y);
        y += 22;
        checkbox(
            hwnd,
            ID_RELAY,
            t("把通知转发到手机", "Forward notifications to the phone"),
            20,
            y,
            with(|a| (a.relay)()).unwrap_or(false),
        );
        y += 28;
        label(
            hwnd,
            t(
                "以下应用不会被转发（名字包含即可）",
                "Never forwarded (name contains)",
            ),
            20,
            y,
        );
        y += 20;

        let denied = with(|a| (a.denylist)()).unwrap_or_default();
        let lb = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("LISTBOX"),
            PCWSTR::null(),
            WINDOW_STYLE(0x0001 | 0x0081_0000 | 0x0004_0000), // CHILD|VISIBLE|LBS_NOTIFY|WS_VSCROLL
            20,
            y,
            340,
            120,
            Some(hwnd),
            Some(HMENU(ID_LIST as *mut std::ffi::c_void)),
            None,
            None,
        );
        if let Ok(lb) = lb {
            for name in &denied {
                let _ = SendMessageW(
                    lb,
                    LB_ADDSTRING,
                    None,
                    Some(LPARAM(windows::core::HSTRING::from(name).as_ptr() as isize)),
                );
            }
        }
        y += 128;

        let (footer_zh, footer_en) = rc_net::settings::denylist_footer(denied.len());
        label(hwnd, t(footer_zh, footer_en), 20, y);
        y += 20;

        let entry = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("EDIT"),
            &windows::core::HSTRING::from(draft()),
            WINDOW_STYLE(0x0001 | 0x0080_0000), // CHILD|VISIBLE|WS_BORDER
            20,
            y,
            250,
            26,
            Some(hwnd),
            Some(HMENU(ID_ENTRY as *mut std::ffi::c_void)),
            None,
            None,
        );
        if let Ok(entry) = entry {
            // 2000 is EM_SETLIMITTEXT; without it the box takes 32767 characters,
            // which lets a user paste a novel into a list of app names.
            SendMessageW(entry, 2000, Some(WPARAM(120)), None);
        }
        button(hwnd, ID_ADD, t("添加", "Add"), 280, y, 80, 26);
        button(hwnd, ID_REMOVE, t("移除", "Remove"), 368, y, 90, 26);
        y += 34;

        // A refusal, or the confirmation that the entry was added. Shown here
        // rather than in a dialog because it is information about a field, not a
        // question.
        let message = DRAFT
            .lock()
            .ok()
            .and_then(|d| d.1.map(|(zh, en)| t(zh, en).to_string()))
            .unwrap_or_default();
        if !message.is_empty() {
            label(hwnd, &message, 20, y);
            y += 20;
        }

        // --- Connection
        y += 8;
        label(hwnd, t("已配对的手机", "Paired phones"), 20, y);
        y += 20;
        let phones = with(|a| (a.phones)()).unwrap_or_default();
        let lb2 = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("LISTBOX"),
            PCWSTR::null(),
            WINDOW_STYLE(0x0001 | 0x0081_0000 | 0x0004_0000),
            20,
            y,
            340,
            100,
            Some(hwnd),
            Some(HMENU(ID_PHONES as *mut std::ffi::c_void)),
            None,
            None,
        );
        if let Ok(lb2) = lb2 {
            for name in &phones {
                let _ = SendMessageW(
                    lb2,
                    LB_ADDSTRING,
                    None,
                    Some(LPARAM(windows::core::HSTRING::from(name).as_ptr() as isize)),
                );
            }
        }
        y += 108;
        if phones.is_empty() {
            label(
                hwnd,
                t("还没有配对过手机。", "No phones paired yet."),
                20,
                y,
            );
            y += 20;
        }
        button(
            hwnd,
            ID_FORGET,
            // "this computer" was wrong: the button forgets the phone selected in
            // the list above it, and forgetting "this computer" is not a thing
            // this window can do. A user reading the old label and clicking with
            // nothing selected got silence, which reads as the button being
            // broken rather than as there being nothing to forget.
            t("忘记选中的手机", "Forget the selected phone"),
            20,
            y,
            180,
            26,
        );
        y += 40;

        // --- Camera
        //
        // One line or the other, never both. This drew the "registered" line
        // unconditionally and then drew "not registered" on the same `y` when it
        // was not, so the two `STATIC`s overlapped and an unregistered user read
        // both claims stacked on top of each other.
        let cam = with(|a| (a.camera)()).unwrap_or(false);
        if cam {
            label(
                hwnd,
                t(
                    "虚拟摄像头：已注册（在相机、Zoom、OBS 里可选）",
                    "Virtual camera: registered (available in Camera, Zoom, OBS)",
                ),
                20,
                y,
            );
            y += 22;
        } else if !crate::vcam::is_supported() {
            // Registration cannot be the problem, so do not offer to register:
            // this Windows build has no way to present a software camera, and an
            // "install" button here would fail with no explanation.
            label(
                hwnd,
                t(
                    "虚拟摄像头需要 Windows 11 22H2 或更新版本；这个系统版本不支持，装也用不了。",
                    "The virtual camera needs Windows 11 22H2 or newer. This build cannot present one, so installing would not help.",
                ),
                20,
                y,
            );
            y += 22;
        } else {
            label(
                hwnd,
                t(
                    "虚拟摄像头：未注册。注册一次，这台电脑的任何程序都能把它当摄像头。",
                    "Virtual camera: not registered. Install it once and any app on this PC can treat it as a camera.",
                ),
                20,
                y,
            );
            button(
                hwnd,
                ID_CAMERA,
                t(
                    "安装虚拟摄像头（需要允许管理员提示）",
                    "Install the virtual camera (allow the admin prompt)",
                ),
                20,
                y + 22,
                300,
                26,
            );
            y += 54;
        }

        // --- Video
        let q = with(|a| (a.quality)()).unwrap_or_default();
        label(
            hwnd,
            t(
                &format!("画质：{}（点此切换）", q.label(true)),
                &format!("Quality: {} (click to change)", q.label(false)),
            ),
            20,
            y,
        );
        button(hwnd, ID_QUALITY, t("切换", "Change"), 200, y - 4, 90, 26);
        y += 30;

        // --- Updates
        //
        // The line comes before the button so it reads as what happened, not as
        // a label for it, and it is only drawn when there is something to say —
        // an empty "no update yet" line is the kind of permanent furniture
        // people stop seeing.
        let update_line = with_update(|m| m.clone()).unwrap_or_default();
        if !update_line.is_empty() {
            label(hwnd, &update_line, 20, y);
            y += 20;
        }
        button(
            hwnd,
            ID_UPDATE,
            t("检查更新", "Check for updates"),
            20,
            y,
            160,
            26,
        );
        // The log, one click away. A receiver whose whole UI is a tray icon has
        // no console to read and no window to find, so "the app misbehaved" left
        // the user with nothing to send us; the file existed and the path was in
        // nobody's head.
        button(
            hwnd,
            ID_OPEN_LOG,
            t("打开日志文件夹", "Open the log folder"),
            190,
            y,
            160,
            26,
        );
        y += 34;

        // --- Startup
        checkbox(
            hwnd,
            ID_AUTOSTART,
            t("开机自动启动", "Start at login"),
            20,
            y,
            with(|a| (a.autostart)()).unwrap_or(false),
        );
        y += 34;

        button(hwnd, ID_CLOSE, t("关闭", "Close"), 400, y, 120, 30);
    }
}

unsafe fn label(hwnd: HWND, text: &str, x: i32, y: i32) {
    unsafe {
        let _ = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("STATIC"),
            &windows::core::HSTRING::from(text),
            WINDOW_STYLE(0x0001), // WS_CHILD
            x,
            y,
            500,
            20,
            Some(hwnd),
            Some(HMENU(std::ptr::null_mut())),
            None,
            None,
        );
    }
}

unsafe fn button(hwnd: HWND, id: usize, text: &str, x: i32, y: i32, w_: i32, h: i32) {
    unsafe {
        let _ = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("BUTTON"),
            &windows::core::HSTRING::from(text),
            WINDOW_STYLE(0x0001), // WS_CHILD
            x,
            y,
            w_,
            h,
            Some(hwnd),
            Some(HMENU(id as *mut std::ffi::c_void)),
            None,
            None,
        );
    }
}

/// A checkbox whose tick is the state, because a settings window that shows an
/// "on" toggle and does not tick it is a settings window nobody believes.
unsafe fn checkbox(hwnd: HWND, id: usize, text: &str, x: i32, y: i32, on: bool) {
    unsafe {
        // BS_CHECKBOX is 0x0002; BS_PUSHBUTTON is 0x0000.
        let style = WINDOW_STYLE(0x0001 | 0x0002); // WS_CHILD | WS_VISIBLE | BS_CHECKBOX
        let _ = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("BUTTON"),
            &windows::core::HSTRING::from(text),
            // `BS_CHECKED` is not a `WINDOW_STYLE` constant in this projection;
            // the value is the documented one (0x0001) and is written as a
            // literal with a comment rather than through a name that does not
            // exist.
            style
                | if on {
                    WINDOW_STYLE(0x0001)
                } else {
                    WINDOW_STYLE(0)
                },
            x,
            y,
            420,
            24,
            Some(hwnd),
            Some(HMENU(id as *mut std::ffi::c_void)),
            None,
            None,
        );
    }
}
