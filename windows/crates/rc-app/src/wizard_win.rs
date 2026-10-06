//! A Win32 window: the wizard's drawing and its controls.
//!
//! Split from [`crate::wizard`], which owns the *flow* and is tested. This file
//! is the part that only compiles into a Windows binary and can only be checked
//! by looking at it.
//!
//! Plain Win32 controls, deliberately. The tray menu is already plain Win32, the
//! product has no other UI framework, and a wizard is five static labels and
//! two buttons — bringing in a toolkit for that would be a dependency the
//! project would carry forever to draw checkmarks.

use crate::i18n::t;
use crate::wizard::{current_page, Page, State};
use rc_net::firstrun::{Camera, FirstRun, Integrity};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{COLOR_WINDOW, HBRUSH};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;

/// Win32 child-window styles, as plain numbers.
///
/// Spelled out because this is exactly what was wrong: the controls were created
/// with `0x0001` where `WS_CHILD` was meant and `0x0020` where `WS_VISIBLE` was
/// meant, and neither of those is either. `WS_CHILD` is `0x40000000` and
/// `WS_VISIBLE` is `0x10000000`.
///
/// So every control in every one of this program's windows was created as a
/// **top-level** window. The parents rendered empty — a white dialog with a
/// title bar — while their contents sat elsewhere on the desktop, invisible
/// because that flag was wrong too. Nothing failed: the API accepted both
/// numbers and did something reasonable with them, which is why this survived
/// until someone looked at the window.
const WS_CHILD: u32 = 0x4000_0000;
const WS_VISIBLE: u32 = 0x1000_0000;

const CLASS: PCWSTR = w!("RemoteCrabWizard");

/// Control ids. Fixed values, so the `WM_COMMAND` handler is a `match` on
/// constants rather than on captured state.
const ID_NEXT: usize = 1;
const ID_BACK: usize = 2;
const ID_CLOSE: usize = 3;
/// The per-page action: install the camera, or re-check.
const ID_ACTION: usize = 4;
const ID_STATE: usize = 5;

/// Show the wizard, or raise the copy already open.
///
/// Returning the existing window on a second request is the point: a user who
/// clicks the tray row twice gets the window they already have, brought
/// forward, rather than a second window nobody asked for.
pub fn show(first_run: FirstRun, on_action: Box<dyn Fn() + Send + Sync>) -> Option<HWND> {
    unsafe {
        // Raise an existing window before doing any setup, so the state is not
        // reset under a window that is already on screen.
        if let Ok(existing) = FindWindowW(CLASS, None) {
            let _ = ShowWindow(existing, SW_RESTORE);
            let _ = SetForegroundWindow(existing);
            return Some(existing);
        }

        let hinstance = HINSTANCE(GetModuleHandleW(None).ok()?.0);
        register(hinstance);
        *crate::wizard::STATE.lock().ok()? = Some(State {
            first_run,
            page: Page::Welcome,
            action: Some(on_action),
            action_message: None,
        });
        if std::env::var("RC_WIZARD_TRACE").is_ok() {
            eprintln!("[wizard] show: STATE set, creating the window");
        }
        // `WS_VISIBLE` is deliberately absent from the style and the window is
        // shown once, below, after it exists. All three of this program's
        // windows were created without `WS_VISIBLE` and nothing ever showed them,
        // so every one of them was built, laid out, and left invisible — the
        // wizard told first-run users what to do from a window they could not
        // see. `WS_OVERLAPPED` is 0x0, so the style here was really just
        // caption + system menu.
        // And built at runtime, so the title draws one language rather than both
        // — see the note in `settings_win::show`.
        let title =
            windows::core::HSTRING::from(format!("RemoteCrab — {}", t("首次设置", "Setup")));
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            CLASS,
            PCWSTR(title.as_ptr()),
            // "首次设置", not "设置": this window and the Settings window used to
            // share the Chinese title "设置", so two different windows looked
            // identical in the taskbar and in any screenshot. The English halves
            // were already distinct.
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            520,
            380,
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
        // A second registration returns an error, which is fine: the class is
        // process-global and the wizard may be reopened.
        let _ = RegisterClassW(&wc);
    }
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    _lparam: LPARAM,
) -> LRESULT {
    unsafe {
        match msg {
            WM_CREATE => {
                build_controls(hwnd);
                LRESULT(0)
            }
            WM_COMMAND => {
                let id = wparam.0 & 0xFFFF;
                let page = current_page();
                match id {
                    ID_NEXT => match page.next() {
                        Some(p) => {
                            crate::wizard::set_page(p);
                            build_controls(hwnd);
                            LRESULT(0)
                        }
                        None => {
                            finish(hwnd);
                            LRESULT(0)
                        }
                    },
                    ID_BACK => {
                        if let Some(p) = page.prev() {
                            crate::wizard::set_page(p);
                            build_controls(hwnd);
                        }
                        LRESULT(0)
                    }
                    ID_ACTION => {
                        // The action is the only thing here that changes the
                        // machine, so it is the only one behind a button. It
                        // runs with the lock released, because installing the
                        // camera raises a UAC dialog.
                        crate::wizard::run_action();
                        // Whatever it did, the page's own text is now stale.
                        build_controls(hwnd);
                        LRESULT(0)
                    }
                    ID_CLOSE => {
                        finish(hwnd);
                        LRESULT(0)
                    }
                    _ => DefWindowProcW(hwnd, msg, wparam, _lparam),
                }
            }
            // No custom painting: the window is a stack of standard controls
            // on the default dialog background, which is what every settings
            // window on Windows looks like, and a hand-painted one would be a
            // GDI dependency for no visible gain.
            WM_PAINT => {
                let _ = DefWindowProcW(hwnd, msg, wparam, _lparam);
                LRESULT(0)
            }
            WM_CLOSE => {
                finish(hwnd);
                LRESULT(0)
            }
            WM_DESTROY => {
                PostQuitMessage(0);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, _lparam),
        }
    }
}

fn finish(hwnd: HWND) {
    unsafe {
        let _ = DestroyWindow(hwnd);
    }
}

unsafe fn build_controls(hwnd: HWND) {
    unsafe {
        // Rebuilt per page rather than repositioned: five controls do not
        // justify a layout engine, and deleting them is the only way to be sure
        // no control from the previous page is still on screen.
        for id in [ID_NEXT, ID_BACK, ID_CLOSE, ID_ACTION, ID_STATE] {
            // The parent is an `Option<HWND>` in this projection, and a
            // missing child comes back as an Err rather than a null handle.
            if let Ok(h) = GetDlgItem(Some(hwnd), id as i32) {
                let _ = DestroyWindow(h);
            }
        }
        let Some((page, fr)) = crate::wizard::with_state(|s| (s.page, s.first_run)) else {
            if std::env::var("RC_WIZARD_TRACE").is_ok() {
                eprintln!("[wizard] build_controls: STATE is None — nothing to draw");
            }
            return;
        };

        let (title, body, action_label, has_action) = copy_for(page, &fr);

        // The state line. `SS_LEFT` with an explicit font would need a font;
        // the default dialog font is what every other Win32 app uses and is
        // legible at the sizes here.
        let state = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("STATIC"),
            &windows::core::HSTRING::from(&title),
            WINDOW_STYLE(WS_CHILD | WS_VISIBLE), // WS_CHILD | WS_VISIBLE
            20,
            20,
            460,
            40,
            Some(hwnd),
            Some(HMENU(ID_STATE as *mut std::ffi::c_void)),
            None,
            None,
        );
        if let Ok(state) = state {
            let _ = SetWindowTextW(state, &windows::core::HSTRING::from(&title));
        }

        let _ = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("EDIT"),
            &windows::core::HSTRING::from(&body),
            WINDOW_STYLE(WS_CHILD | WS_VISIBLE | 0x000C00 | 0x0080_0000), // WS_CHILD|WS_VISIBLE|ES_MULTILINE|ES_READONLY
            20,
            70,
            460,
            160,
            Some(hwnd),
            Some(HMENU(std::ptr::null_mut())),
            None,
            None,
        );

        if has_action {
            let _ = CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                w!("BUTTON"),
                &windows::core::HSTRING::from(&action_label),
                WINDOW_STYLE(WS_CHILD | WS_VISIBLE), // WS_CHILD | WS_VISIBLE
                20,
                245,
                220,
                30,
                Some(hwnd),
                Some(HMENU(ID_ACTION as *mut std::ffi::c_void)),
                None,
                None,
            );

            // What the last click of that button actually did. Without it, a user
            // who declines the UAC prompt sees the button come straight back with
            // no explanation, and the wizard's own text tells them to click again —
            // which is the advice that cannot work, because the prompt was refused.
            if let Some((zh, en)) = crate::wizard::action_message() {
                let _ = CreateWindowExW(
                    WINDOW_EX_STYLE::default(),
                    w!("STATIC"),
                    &windows::core::HSTRING::from(t(zh, en)),
                    WINDOW_STYLE(WS_CHILD | WS_VISIBLE), // WS_CHILD | WS_VISIBLE
                    20,
                    280,
                    460,
                    34,
                    Some(hwnd),
                    Some(HMENU(std::ptr::null_mut())),
                    None,
                    None,
                );
            }
        }

        let back = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("BUTTON"),
            &windows::core::HSTRING::from(t("上一步", "Back")),
            WINDOW_STYLE(WS_CHILD | WS_VISIBLE)
                | if page.prev().is_some() {
                    WINDOW_STYLE(0)
                } else {
                    WS_DISABLED
                },
            240,
            290,
            110,
            32,
            Some(hwnd),
            Some(HMENU(ID_BACK as *mut std::ffi::c_void)),
            None,
            None,
        );
        let _ = back;

        // Next becomes "完成" on the last page, which is the only place the
        // two meanings would otherwise be confused.
        let next_label: &str = if page == Page::Done {
            t("完成", "Finish")
        } else {
            t("下一步", "Next")
        };
        let enabled = page.is_complete(&fr) || page == Page::Done;
        let _ = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("BUTTON"),
            &windows::core::HSTRING::from(next_label),
            WINDOW_STYLE(WS_CHILD | WS_VISIBLE)
                | if enabled {
                    WINDOW_STYLE(0)
                } else {
                    WS_DISABLED
                },
            360,
            290,
            120,
            32,
            Some(hwnd),
            Some(HMENU(ID_NEXT as *mut std::ffi::c_void)),
            None,
            None,
        );
    }
}

fn copy_for(page: Page, fr: &FirstRun) -> (String, String, String, bool) {
    match page {
        Page::Welcome => (
            t("欢迎", "Welcome").to_string(),
            t(
                "RemoteCrab 把你的 iPhone 变成这台电脑的摄像头、麦克风、触控板和键盘。\n\
                 下面几步检查一下这台电脑准备好了没有，大约需要一分钟。",
                "RemoteCrab turns your iPhone into this PC's camera, microphone, trackpad and keyboard.\n\
                 The next few steps check that this PC is ready. It takes about a minute.",
            )
            .to_string(),
            String::new(),
            false,
        ),
        Page::Input => {
            let ok = fr.integrity.can_inject();
            (
                t("触控板和键盘", "Trackpad and keyboard").to_string(),
                match fr.integrity {
                    Integrity::High => t(
                        "可以。以管理员身份运行，能控制包括管理员程序在内的所有窗口。",
                        "Ready. Running elevated, so it can drive every window including other admin apps.",
                    )
                    .to_string(),
                    Integrity::Medium => t(
                        "可以。普通窗口都能控制；已经是管理员权限的窗口不能（这是 Windows 的安全限制，不是故障）。",
                        "Ready. Ordinary windows can be driven; windows already running as administrator \
                         cannot, which is a Windows security boundary rather than a fault.",
                    )
                    .to_string(),
                    Integrity::Low => t(
                        "不行：系统以低权限模式启动了本程序，无法向大多数窗口发送输入。\n\
                         请用管理员身份运行一次。",
                        "Not yet: this program started at low integrity, so it cannot send input to most \
                         windows. Run it once as administrator.",
                    )
                    .to_string(),
                },
                t("以管理员身份重试", "Retry as administrator").to_string(),
                !ok,
            )
        }
        Page::Camera => {
            let ok = fr.camera == Camera::Ready;
            (
                t("虚拟摄像头", "Virtual camera").to_string(),
                if ok {
                    t(
                        "已注册。相机应用、Zoom、OBS 里都能选到「RemoteCrab Camera」。",
                        "Registered — Camera, Zoom and OBS can all choose \"RemoteCrab Camera\".",
                    )
                    .to_string()
                } else {
                    t(
                        "还没注册。注册会写系统级的 COM 配置，需要一次管理员确认。\n\
                         装好之后，这台电脑的任何程序都能把它当成摄像头。",
                        "Not registered yet. Registering writes a machine-wide COM entry and needs one \
                         administrator confirmation. Once installed, any app on this PC can treat it as \
                         a camera.",
                    )
                    .to_string()
                },
                t("安装虚拟摄像头", "Install the virtual camera").to_string(),
                !ok,
            )
        }
        Page::StartAtLogin => (
            t("开机自动启动", "Start at login").to_string(),
            if fr.autostart {
                t("已开启，登录后会自动运行。", "On — RemoteCrab starts when you log in.")
                    .to_string()
            } else {
                t(
                    "未开启。想让它每次登录后自动运行，可以在托盘菜单里勾选。",
                    "Off. To have it start every time you log in, tick it in the tray menu.",
                )
                .to_string()
            },
            String::new(),
            false,
        ),
        Page::Done => (
            t("可以开始了", "You are ready").to_string(),
            t(
                "现在可以在 iPhone 上打开 RemoteCrab 并开始推流。\n\
                 状态、预览和设置都在右下角的通知区域图标里。",
                "Open RemoteCrab on your iPhone and start streaming.\n\
                 Status, preview and settings are all in the notification-area icon.",
            )
            .to_string(),
            String::new(),
            false,
        ),
    }
}

