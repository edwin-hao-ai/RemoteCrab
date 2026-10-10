//! The self-check window: four live quadrants, redrawn on a timer.
//!
//! The model is [`rc_net::selfcheck`], which is pure and tested. This draws it.
//!
//! Plain Win32 controls, for the same reason as the wizard and the settings
//! window: this is the third window, so a UI framework would be a dependency
//! rather than an addition.

use crate::theme;
use rc_net::selfcheck::{Health, SelfCheck};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Mutex;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    RedrawWindow, HDC, RDW_ALLCHILDREN, RDW_ERASE, RDW_INVALIDATE,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::DRAWITEMSTRUCT;
use windows::Win32::UI::WindowsAndMessaging::*;

/// Win32 child-window styles, as plain numbers. See `wizard_win` for the full
/// story: these were `0x0001`, which is not `WS_CHILD`, so every label and the
/// quadrant grid were top-level windows and the panel drew empty.
const WS_CHILD: u32 = 0x4000_0000;
const WS_VISIBLE: u32 = 0x1000_0000;

const CLASS: PCWSTR = w!("RemoteCrabSelfCheck");
const ID_CLOSE: usize = 30;
/// The footer note. Below `ID_LINE_BASE`, which is how `WM_CTLCOLORSTATIC` tells
/// it apart from a quadrant's lines.
const ID_FOOTER: usize = 40;

/// Control ids for the panel's lines: `quadrant * 100 + field`.
///
/// One id per line, so the rebuild can destroy exactly the lines it is about to
/// replace. That is not tidiness. The labels used to be created with no id at
/// all, which made every one of them id 0, and the rebuild's destroy loop looks
/// controls up *by id* — so it could match at most one of them per pass. About
/// twenty lines were created every 200 ms and one was destroyed, which means an
/// open panel leaked something like ninety window handles a second.
const ID_LINE_BASE: usize = 100;
/// Offsets within a quadrant's block of ids.
const FIELD_TITLE: usize = 0;
const FIELD_SUMMARY: usize = 1;
const FIELD_DETAIL: usize = 10;
/// How many detail lines a quadrant may have. The model produces two or three
/// today; the cap exists so the destroy list is a fixed one rather than a guess.
const MAX_DETAIL: usize = 8;

const fn line_id(quadrant: usize, field: usize) -> usize {
    ID_LINE_BASE + quadrant * 100 + field
}

/// Each quadrant's health, as a small code, for `WM_CTLCOLORSTATIC`.
///
/// Win32 asks the parent what colour to draw a child in, and it describes the
/// child only by its control id — fixed when the window was built. The health
/// changes every 200 ms under a fixed id, so it is carried *beside* the id rather
/// than inside it. Four bytes, read and written on one thread.
static HEALTH: [AtomicU8; 4] = [
    AtomicU8::new(HEALTH_NEUTRAL),
    AtomicU8::new(HEALTH_NEUTRAL),
    AtomicU8::new(HEALTH_NEUTRAL),
    AtomicU8::new(HEALTH_NEUTRAL),
];

/// Neutral: nothing to report, or nothing to report *yet*. Deliberately the same
/// as the default, so a quadrant whose code was never written reads as idle
/// rather than as broken.
const HEALTH_NEUTRAL: u8 = 0;
const HEALTH_GOOD: u8 = 1;
const HEALTH_BAD: u8 = 2;

/// The colour code for a health state.
///
/// `wants_colour` decides *whether* a state is worth a colour at all; this applies
/// it, which is the point of keeping that rule out of the paint code. Waiting is
/// the state this protects: three of the four states look alike in plain text, and
/// painting "waiting" as a problem is how a panel that is idle most of the time
/// comes to look broken.
fn health_code(health: Health) -> u8 {
    if !wants_colour(health) {
        return HEALTH_NEUTRAL;
    }
    if health == Health::Good {
        HEALTH_GOOD
    } else {
        HEALTH_BAD
    }
}

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
        // Built at runtime so the window honours the chosen language rather than
        // drawing both (see the note in `settings_win::show`).
        let title =
            windows::core::HSTRING::from(format!("RemoteCrab — {}", crate::i18n::t("自检", "Self-check")));
        // Shown once, after it exists — see the note in `wizard_win::show`.
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            CLASS,
            PCWSTR(title.as_ptr()),
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
        // See `wizard_win::register`: no class brush, so the DWM backdrop
        // (Mica) shows through the client.
        hbrBackground: windows::Win32::Graphics::Gdi::HBRUSH::default(),
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
                theme::apply_backdrop(hwnd);
                build(hwnd);
                // A plain timer, not a thread: the work is one struct read and
                // a few labels.
                SetTimer(Some(hwnd), 1, INTERVAL_MS, None);
                if let Ok(mut t) = TIMER.lock() {
                    *t = Some(1);
                }
                LRESULT(0)
            }
            // Transparent client for the Mica backdrop; see `wizard_win`.
            WM_ERASEBKGND => LRESULT(1),
            WM_TIMER => {
                // The panel rebuilds its labels rather than mutating them, which
                // is fine at this size — but it did so without suppressing
                // redraw, so every 200 ms the window blanked its children and
                // painted them again. On a panel whose whole job is to be read at
                // a glance, that reads as the panel flickering rather than as a
                // value changing. Freeze, swap, repaint once.
                let _ = SendMessageW(hwnd, WM_SETREDRAW, Some(WPARAM(0)), None);
                build(hwnd);
                let _ = SendMessageW(hwnd, WM_SETREDRAW, Some(WPARAM(1)), None);
                let _ = RedrawWindow(
                    Some(hwnd),
                    None,
                    None,
                    RDW_ERASE | RDW_INVALIDATE | RDW_ALLCHILDREN,
                );
                LRESULT(0)
            }
            // The parent answers what colour each child is drawn in, and the id
            // is what says which child this is — see `wizard_win` for the same
            // message on the same kind of control. A quadrant's title takes that
            // quadrant's health; its summary and detail lines are supporting text
            // and read the same whichever way the quadrant went, which is what
            // makes the one coloured line stand out.
            WM_CTLCOLORSTATIC => {
                let hdc = HDC(wparam.0 as *mut std::ffi::c_void);
                let control = HWND(lparam.0 as *mut std::ffi::c_void);
                let id = GetDlgCtrlID(control) as usize;
                let p = theme::palette();
                let (colour, back) = if id >= ID_LINE_BASE {
                    let within = id - ID_LINE_BASE;
                    let quadrant = (within / 100).min(HEALTH.len() - 1);
                    match within % 100 {
                        FIELD_TITLE => (
                            match HEALTH[quadrant].load(Ordering::Relaxed) {
                                HEALTH_GOOD => p.ok,
                                HEALTH_BAD => p.err,
                                _ => p.text,
                            },
                            None,
                        ),
                        FIELD_SUMMARY => (p.text_soft, None),
                        _ => (p.text_faint, None),
                    }
                } else {
                    // The footer note, which has no id and no colour of its own.
                    (p.text_faint, None)
                };
                LRESULT(theme::tint_child(hdc, colour, back).0 as isize)
            }
            WM_DRAWITEM => {
                if lparam.0 != 0 {
                    let di = &*(lparam.0 as *const DRAWITEMSTRUCT);
                    theme::paint_button(di, theme::ButtonStyle::Secondary);
                }
                LRESULT(1)
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

        // Exactly the ids this function creates, and nothing else. The rebuild
        // finds its old controls by id because that is the only handle it keeps
        // between passes — see the note on `ID_LINE_BASE` for what guessing cost.
        for quadrant in 0..GRID.len() {
            for field in [FIELD_TITLE, FIELD_SUMMARY] {
                destroy(hwnd, line_id(quadrant, field));
            }
            for n in 0..MAX_DETAIL {
                destroy(hwnd, line_id(quadrant, FIELD_DETAIL + n));
            }
        }
        destroy(hwnd, ID_FOOTER);

        let quadrants = [
            &check.camera,
            &check.keyboard,
            &check.trackpad,
            &check.microphone,
        ];
        // Written before the controls exist, because the first `WM_CTLCOLORSTATIC`
        // can arrive as soon as one of them is created.
        for (i, q) in quadrants.iter().enumerate() {
            HEALTH[i].store(health_code(q.health), Ordering::Relaxed);
        }

        let title_font = theme::font(theme::TEXT_SUBHEAD, theme::WEIGHT_SEMIBOLD);
        let body_font = theme::font(theme::TEXT_BODY, theme::WEIGHT_REGULAR);
        let detail_font = theme::font(theme::TEXT_CAPTION, theme::WEIGHT_REGULAR);

        for ((i, x, y, _zh, _en), (zh, en)) in GRID.iter().zip(quadrant_titles()) {
            let (i, x, y) = (*i, *x, *y);
            let q = quadrants[i];
            let title = t(zh, en);
            let word = t(q.health.word().0, q.health.word().1);
            // The "!" marker the plain-text version carried is gone. It was there
            // because a Win32 static has no colour of its own, and the parent hands
            // one out now — see `WM_CTLCOLORSTATIC`.
            let heading = label(
                hwnd,
                line_id(i, FIELD_TITLE),
                theme::boxed(x, y, 280, 22),
                &format!("{title}   ·   {word}"),
            );
            theme::set_font(heading, title_font);

            let summary = label(
                hwnd,
                line_id(i, FIELD_SUMMARY),
                theme::boxed(x, y + 28, 280, 20),
                &q.summary,
            );
            theme::set_font(summary, body_font);

            for (n, line) in q.detail.iter().take(MAX_DETAIL).enumerate() {
                let detail = label(
                    hwnd,
                    line_id(i, FIELD_DETAIL + n),
                    theme::boxed(x + 8, y + 52 + n as i32 * 18, 272, 18),
                    line,
                );
                theme::set_font(detail, detail_font);
            }
        }

        let footer = label(
            hwnd,
            ID_FOOTER,
            theme::boxed(24, 350, 400, 20),
            t(
                "输入是看不见的，所以这里才有这个面板。",
                "Input is invisible, which is why this panel exists.",
            ),
        );
        theme::set_font(footer, detail_font);

        let close = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("BUTTON"),
            &windows::core::HSTRING::from(t("关闭", "Close")),
            WINDOW_STYLE(WS_CHILD | WS_VISIBLE) | WINDOW_STYLE(BS_OWNERDRAW as u32),
            460,
            344,
            120,
            34,
            Some(hwnd),
            Some(HMENU(ID_CLOSE as *mut std::ffi::c_void)),
            None,
            None,
        );
        if let Ok(close) = close {
            theme::set_font(close, body_font);
        }
    }
}

/// Remove the control with this id, if it is still there.
unsafe fn destroy(hwnd: HWND, id: usize) {
    if let Ok(h) = GetDlgItem(Some(hwnd), id as i32) {
        let _ = DestroyWindow(h);
    }
}

/// One line of text, with the id `WM_CTLCOLORSTATIC` will be asked about.
unsafe fn label(hwnd: HWND, id: usize, area: RECT, text: &str) -> HWND {
    CreateWindowExW(
        WINDOW_EX_STYLE::default(),
        w!("STATIC"),
        &windows::core::HSTRING::from(text),
        WINDOW_STYLE(WS_CHILD | WS_VISIBLE),
        area.left,
        area.top,
        area.right - area.left,
        area.bottom - area.top,
        Some(hwnd),
        Some(HMENU(id as *mut std::ffi::c_void)),
        None,
        None,
    )
    .unwrap_or_default()
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
