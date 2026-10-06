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
use crate::theme;
use crate::wizard::{current_page, Page, State};
use rc_net::firstrun::{Camera, FirstRun, Integrity};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::HDC;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::DRAWITEMSTRUCT;
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
///
/// The labelling controls have ids too, which is a change: they used to be
/// created with no id at all, so `WM_CTLCOLORSTATIC` — the message Win32 sends to
/// ask *what colour should this label be* — had nothing to answer with, and every
/// label got the system dialog grey. With ids, one handler colours the window.
const ID_NEXT: usize = 1;
const ID_BACK: usize = 2;
const ID_CLOSE: usize = 3;
/// The per-page action: install the camera, or re-check.
const ID_ACTION: usize = 4;
/// The page heading.
const ID_STATE: usize = 5;
/// "第 2 / 5 步".
const ID_STEP: usize = 6;
/// The page's paragraph.
const ID_BODY: usize = 7;
/// What the last click of the action button reported.
const ID_MESSAGE: usize = 8;
/// The one-pixel rule above the buttons.
const ID_HAIRLINE: usize = 9;

/// Layout. `IBSpace` on the Mac side runs 4/8/12/16/24/32; these are the same
/// numbers, so the two platforms keep the same rhythm.
const PAD: i32 = 24; // IBSpace.xl
const GAP: i32 = 8; // IBSpace.s
const BUTTON_H: i32 = 36;
const BUTTON_W: i32 = 116;
const ACTION_W: i32 = 224;

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
            // Sized so the client area is a comfortable 584×421: enough for a
            // two-line paragraph at 14px with room to breathe, and narrow enough
            // to read as a dialog rather than a document window.
            600,
            460,
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
        // The window's own background, so every pixel the controls do not cover
        // is the product's canvas colour rather than `COLOR_WINDOW`, the grey
        // that made these windows look like a 1995 utility.
        hbrBackground: theme::brush_for(theme::palette().canvas),
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
            // Win32 asks the parent what colour each child should draw itself in.
            // The default answer is the system dialog pair — black on grey —
            // which is why every label looked like a form from 1995. The ids are
            // what tell the labels apart; before they existed there was nothing
            // to answer with.
            WM_CTLCOLORSTATIC => {
                let hdc = HDC(wparam.0 as *mut std::ffi::c_void);
                let control = HWND(_lparam.0 as *mut std::ffi::c_void);
                let id = GetDlgCtrlID(control) as usize;
                let p = theme::palette();
                let (colour, back) = match id {
                    ID_STATE => (p.text, p.canvas),
                    ID_STEP => (p.text_faint, p.canvas),
                    ID_BODY => (p.text_soft, p.canvas),
                    ID_MESSAGE => (p.err, p.canvas),
                    // The hairline is a one-pixel child that fills itself with the
                    // brush returned here, which is steadier than painting a rule
                    // in `WM_PAINT` and having a control invalidate over it.
                    ID_HAIRLINE => (p.line, p.line),
                    _ => (p.text, p.canvas),
                };
                LRESULT(theme::tint_child(hdc, colour, Some(back)).0 as isize)
            }
            // The buttons are owner-drawn, so this is where they get their look.
            // `wparam` is the control id and `lparam` the `DRAWITEMSTRUCT`; the id
            // is not read because the struct carries `CtlID`.
            WM_DRAWITEM => {
                if _lparam.0 != 0 {
                    let di = &*(_lparam.0 as *const DRAWITEMSTRUCT);
                    let style = if di.CtlID as usize == ID_NEXT {
                        theme::ButtonStyle::Primary
                    } else {
                        theme::ButtonStyle::Secondary
                    };
                    theme::paint_button(di, style);
                }
                LRESULT(1)
            }
            WM_CLOSE => {
                finish(hwnd);
                LRESULT(0)
            }
            WM_DESTROY => {
                // No `PostQuitMessage`. This window shares the tray's thread and the
                // tray's message loop, so quitting on destroy ends the *app*: the
                // wizard's X, or finishing its last page, shut the receiver down.
                // Because the tray icon went with it, the program simply vanished
                // with nothing in the log — which reads as a crash, not as a close.
                //
                // The settings window and the self-check panel also live on that
                // thread and have never done this; the wizard was the odd one out.
                // The loop ends when the tray window is destroyed, and that is the
                // only thing that should end it.
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
        // Rebuilt per page rather than repositioned: a handful of controls do not
        // justify a layout engine, and deleting them is the only way to be sure no
        // control from the previous page is still on screen.
        for id in [
            ID_NEXT, ID_BACK, ID_CLOSE, ID_ACTION, ID_STATE, ID_STEP, ID_BODY, ID_MESSAGE,
            ID_HAIRLINE,
        ] {
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

        // Every position is computed from the client area rather than written
        // down. The previous layout was absolute coordinates in a window of a
        // fixed size, so a larger font or a different DPI slid the button row off
        // the bottom edge.
        let mut client = RECT::default();
        let _ = GetClientRect(hwnd, &mut client);
        let width = client.right - client.left;
        let height = client.bottom - client.top;
        let content_w = width - PAD * 2;
        let row_y = height - PAD - BUTTON_H;
        let button_font = theme::font(theme::TEXT_BODY, theme::WEIGHT_REGULAR);

        // The heading: 20px semibold, the same relationship the Mac side draws
        // between a page title and its body.
        let heading = label(hwnd, ID_STATE, &title, theme::boxed(PAD, PAD, content_w, 30));
        theme::set_font(
            heading,
            theme::font(theme::TEXT_HEADING, theme::WEIGHT_SEMIBOLD),
        );

        // "第 2 / 5 步". A wizard that will not say how long it is makes people
        // guess whether they are nearly done, which is the question a wizard
        // exists to answer.
        let step_label = if crate::i18n::is_chinese() {
            format!("第 {} / {} 步", page.index() + 1, Page::all().len())
        } else {
            format!("Step {} of {}", page.index() + 1, Page::all().len())
        };
        let step = label(
            hwnd,
            ID_STEP,
            &step_label,
            theme::boxed(PAD, PAD + 34, content_w, 18),
        );
        theme::set_font(step, theme::font(theme::TEXT_CAPTION, theme::WEIGHT_REGULAR));

        // The page's paragraph. A static rather than the read-only edit box this
        // used to be: it is text to read, and an edit box brings a sunken border
        // and a caret that both say "you can type here" about something you
        // cannot.
        let body_top = PAD + 64;
        let body_bottom = row_y - 28;
        let body_ctrl = label(
            hwnd,
            ID_BODY,
            &body,
            theme::boxed(PAD, body_top, content_w, (body_bottom - body_top).max(80)),
        );
        theme::set_font(body_ctrl, button_font);

        // The rule above the button row: a one-pixel static that fills itself with
        // the border colour.
        let _ = label(hwnd, ID_HAIRLINE, "", theme::boxed(PAD, row_y - 16, content_w, 1));

        // Back sits on the left with the page's own action beside it; the button
        // this wizard is driving toward is always the one on the far right, which
        // is where Windows users look for it.
        let back = button(
            hwnd,
            ID_BACK,
            t("上一步", "Back"),
            theme::boxed(PAD, row_y, BUTTON_W, BUTTON_H),
            page.prev().is_some(),
        );
        theme::set_font(back, button_font);

        if has_action {
            let action = button(
                hwnd,
                ID_ACTION,
                &action_label,
                theme::boxed(PAD + BUTTON_W + GAP, row_y, ACTION_W, BUTTON_H),
                true,
            );
            theme::set_font(action, button_font);

            // What the last click of that button actually did. Without it, a user
            // who declines the UAC prompt sees the button come straight back with
            // no explanation, and the wizard's own text tells them to click again —
            // which is the advice that cannot work, because the prompt was refused.
            if let Some((zh, en)) = crate::wizard::action_message() {
                let message = label(
                    hwnd,
                    ID_MESSAGE,
                    t(zh, en),
                    theme::boxed(PAD, row_y - 44, content_w, 20),
                );
                theme::set_font(
                    message,
                    theme::font(theme::TEXT_CAPTION, theme::WEIGHT_REGULAR),
                );
            }
        }

        // Next becomes "完成" on the last page, which is the only place the
        // two meanings would otherwise be confused.
        let next_label: &str = if page == Page::Done {
            t("完成", "Finish")
        } else {
            t("下一步", "Next")
        };
        let enabled = page.is_complete(&fr) || page == Page::Done;
        let next = button(
            hwnd,
            ID_NEXT,
            next_label,
            theme::boxed(width - PAD - BUTTON_W, row_y, BUTTON_W, BUTTON_H),
            enabled,
        );
        theme::set_font(next, theme::font(theme::TEXT_BODY, theme::WEIGHT_MEDIUM));
    }
}

/// A text control.
///
/// `STATIC` with `SS_LEFT`, which word-wraps to the control's width: what a
/// paragraph in a fixed-width dialog wants, and something an edit box would not do
/// without being told twice.
unsafe fn label(parent: HWND, id: usize, text: &str, area: RECT) -> HWND {
    CreateWindowExW(
        WINDOW_EX_STYLE::default(),
        w!("STATIC"),
        &windows::core::HSTRING::from(text),
        WINDOW_STYLE(WS_CHILD | WS_VISIBLE),
        area.left,
        area.top,
        area.right - area.left,
        area.bottom - area.top,
        Some(parent),
        Some(HMENU(id as *mut std::ffi::c_void)),
        None,
        None,
    )
    .unwrap_or_default()
}

/// A button, owner-drawn so that [`theme::paint_button`] decides what it looks
/// like rather than the system.
unsafe fn button(parent: HWND, id: usize, text: &str, area: RECT, enabled: bool) -> HWND {
    CreateWindowExW(
        WINDOW_EX_STYLE::default(),
        w!("BUTTON"),
        &windows::core::HSTRING::from(text),
        WINDOW_STYLE(WS_CHILD | WS_VISIBLE) | WINDOW_STYLE(BS_OWNERDRAW as u32)
            | if enabled {
                WINDOW_STYLE(0)
            } else {
                WS_DISABLED
            },
        area.left,
        area.top,
        area.right - area.left,
        area.bottom - area.top,
        Some(parent),
        Some(HMENU(id as *mut std::ffi::c_void)),
        None,
        None,
    )
    .unwrap_or_default()
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
                        "可以。普通窗口都能控制；已经是管理员权限的窗口不能。\n\
                         在设置里打开「开机自动启动」，下次登录后就能控制所有窗口。",
                        "Ready. Ordinary windows can be driven; windows already running as administrator \
                         cannot.\n\
                         Turn on \"Start at login\" in Settings and every window can be driven from \
                         the next login.",
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

