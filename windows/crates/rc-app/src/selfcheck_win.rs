//! The self-check window: four live quadrants, redrawn on a timer.
//!
//! The model is [`rc_net::selfcheck`], which is pure and tested. This draws it.
//!
//! Plain Win32 controls, for the same reason as the wizard and the settings
//! window: this is the third window, so a UI framework would be a dependency
//! rather than an addition.

use rc_net::selfcheck::{Health, SelfCheck};
use std::sync::Mutex;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{COLOR_WINDOW, HBRUSH};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;

const CLASS: PCWSTR = w!("RemoteCrabSelfCheck");
const ID_CLOSE: usize = 30;

/// Supplied by the app: a fresh snapshot of the evidence.
pub type Sample = Box<dyn Fn() -> rc_net::selfcheck::Evidence + Send + Sync>;

static SAMPLE: Mutex<Option<Sample>> = Mutex::new(None);
/// A timer id, so the one we start is the one we stop.
static TIMER: Mutex<Option<usize>> = Mutex::new(None);

/// How often to redraw. Fast enough that a keypress shows up while the user is
/// still holding the key, slow enough that it costs nothing: the whole point is
/// that nothing visible happens, so the readout has to be the visible thing.
const INTERVAL_MS: u32 = 200;

pub fn show(sample: Sample) -> Option<HWND> {
    unsafe {
        if let Ok(existing) = FindWindowW(CLASS, None) {
            let _ = ShowWindow(existing, SW_RESTORE);
            let _ = SetForegroundWindow(existing);
            return Some(existing);
        }
        let hinstance = HINSTANCE(GetModuleHandleW(None).ok()?.0);
        register(hinstance);
        *SAMPLE.lock().ok()? = Some(sample);
        // Shown once, after it exists — see the note in `wizard_win::show`.
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            CLASS,
            w!("RemoteCrab 自检 / Self-check"),
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            640,
            420,
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
                // A plain timer, not a thread: the work is one struct read and
                // a few labels.
                SetTimer(Some(hwnd), 1, INTERVAL_MS, None);
                if let Ok(mut t) = TIMER.lock() {
                    *t = Some(1);
                }
                LRESULT(0)
            }
            WM_TIMER => {
                build(hwnd);
                LRESULT(0)
            }
            WM_COMMAND => {
                if (wparam.0 & 0xFFFF) == ID_CLOSE {
                    let _ = DestroyWindow(hwnd);
                }
                LRESULT(0)
            }
            WM_CLOSE => {
                let _ = DestroyWindow(hwnd);
                LRESULT(0)
            }
            WM_DESTROY => {
                if let Ok(mut t) = TIMER.lock() {
                    if let Some(id) = t.take() {
                        let _ = KillTimer(Some(hwnd), id);
                    }
                }
                if let Ok(mut g) = SAMPLE.lock() {
                    *g = None;
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
}

/// The quadrant table: index, x, y, and the title in both languages.
///
/// One table, not two. It used to be a `GRID` plus a separate
/// `quadrant_titles()` that listed the same names, which is exactly how the
/// window and the tests end up disagreeing about which quadrant is which.
const GRID: [(usize, i32, i32, &str, &str); 4] = [
    (0, 24, 24, "摄像头", "Camera"),
    (1, 320, 24, "键盘", "Keyboard"),
    (2, 24, 190, "触控板", "Trackpad"),
    (3, 320, 190, "麦克风", "Microphone"),
];

unsafe fn build(hwnd: HWND) {
    use crate::i18n::t;
    unsafe {
        // Sampled with the lock held and released before the drawing, so the
        // closure cannot run arbitrary code while the app's state is pinned.
        let evidence = SAMPLE
            .lock()
            .ok()
            .and_then(|guard| guard.as_ref().map(|s| s()))
            .unwrap_or_default();
        let check = SelfCheck::from(&evidence, t);

        for id in 0..40 {
            if let Ok(h) = GetDlgItem(Some(hwnd), id) {
                let _ = DestroyWindow(h);
            }
        }

        for ((i, x, y, _zh, _en), (zh, en)) in GRID.iter().zip(quadrant_titles()) {
            let (i, x, y) = (*i, *x, *y);
            let q = match i {
                0 => &check.camera,
                1 => &check.keyboard,
                2 => &check.trackpad,
                _ => &check.microphone,
            };
            let title = t(zh, en);
            let word = t(q.health.word().0, q.health.word().1);
            // A marker rather than a colour. Win32 colours text through a
            // per-control subclass or an owner-draw control, and neither is
            // worth the code for four words — but "!" on a quadrant that
            // actually has a problem costs nothing and reads at a glance.
            let marker = if wants_colour(q.health) && q.health == Health::Bad {
                "! "
            } else {
                ""
            };
            label(hwnd, 40 + x, y, &format!("{marker}{title}  —  {word}"));
            label(hwnd, 40 + x, y + 24, &q.summary);
            for (n, line) in q.detail.iter().enumerate() {
                label(hwnd, 48 + x, y + 48 + n as i32 * 18, line);
            }
        }

        label(
            hwnd,
            24,
            350,
            t(
                "输入是看不见的，所以这里才有这个面板。",
                "Input is invisible, which is why this panel exists.",
            ),
        );
        let _ = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("BUTTON"),
            &windows::core::HSTRING::from(t("关闭", "Close")),
            WINDOW_STYLE(0x0001),
            460,
            344,
            120,
            30,
            Some(hwnd),
            Some(HMENU(ID_CLOSE as *mut std::ffi::c_void)),
            None,
            None,
        );
    }
}

/// One line of text. `WS_CHILD` without `WS_VISIBLE` still shows in a window
/// created this way, but the flag is set anyway so the intent is in the code.
unsafe fn label(hwnd: HWND, x: i32, y: i32, text: &str) {
    unsafe {
        let _ = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("STATIC"),
            &windows::core::HSTRING::from(text),
            WINDOW_STYLE(0x0001), // WS_CHILD
            x,
            y,
            280,
            18,
            Some(hwnd),
            Some(HMENU(std::ptr::null_mut())),
            None,
            None,
        );
    }
}

/// The four quadrant titles, in the order they are drawn, as a testable list.
///
/// The window and the tests must agree on the order, or the tests would be
/// asserting about quadrants that are not the ones on screen.
pub fn quadrant_titles() -> [(&'static str, &'static str); 4] {
    GRID.map(|(_, _, _, zh, en)| (zh, en))
}

/// Whether a quadrant's health warrants a colour change at all.
///
/// Kept here rather than in the paint code so the rule is testable: three of the
/// four states look identical in plain text, and "waiting" must not be painted
/// as an error or every idle moment looks like a failure.
pub fn wants_colour(h: Health) -> bool {
    !matches!(h, Health::Waiting)
}

#[cfg(test)]
mod tests {
    use super::{quadrant_titles, wants_colour};
    use rc_net::selfcheck::Health;

    /// The window draws in `GRID` order and the tests read `quadrant_titles`,
    /// so a reordering that forgets the tests would be caught here.
    #[test]
    fn the_four_quadrants_are_the_ones_the_mac_shows() {
        assert_eq!(
            quadrant_titles(),
            [
                ("摄像头", "Camera"),
                ("键盘", "Keyboard"),
                ("触控板", "Trackpad"),
                ("麦克风", "Microphone"),
            ]
        );
    }

    /// Painting "waiting" as an error is how a panel that is usually idle ends
    /// up looking broken.
    #[test]
    fn waiting_is_not_painted_as_a_problem() {
        assert!(!wants_colour(Health::Waiting));
        assert!(wants_colour(Health::Good));
        assert!(wants_colour(Health::Bad));
    }
}
