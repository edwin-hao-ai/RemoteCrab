//! The palette, font and control painting that the native windows share.
//!
//! These windows were Win32 defaults: a grey dialog in the system font. That is
//! what Windows 95 looked like, and it is not what the rest of this product
//! looks like. The values below are lifted from the Mac side's design tokens
//! (`RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBColors.swift`) so the
//! two platforms describe one product:
//!
//! | token  | light     | dark      | source                   |
//! |--------|-----------|-----------|--------------------------|
//! | card   | `#FFFFFF` | `#15151B` | glass tint over the glass |
//! | text   | `#000000` | `#FFFFFF` | `IBColors.textPrimary`   |
//! | accent | `#0A85FF` | `#40A8FF` | `IBColors.accentGlass`   |
//! | line   | 10% fg    | 10% fg    | `IBColors.borderRegular` |
//!
//! The window *background* is not a token at all any more: it is the Windows 11
//! Fluent backdrop (Mica), applied by [`apply_backdrop`], which is this
//! platform's counterpart to the Mac's Liquid Glass. The client is left
//! transparent so the material shows through, and the cards and controls paint
//! on top. Mac corner radii are likewise not copied, because 16pt on a 32px
//! button is a capsule rather than a corner.
//!
//! The spacing rhythm *is* copied. `IBSpace` runs 4/8/12/16/24/32 and the layouts
//! here use those numbers rather than whatever looked right at the time, so the
//! two platforms breathe at the same rate.
//!
//! Callers need three things: [`palette`] for colours, [`font`] for text, and
//! [`paint_button`] from `WM_DRAWITEM`. Nothing else in the program needs to know
//! any of this, which is the point of it being one file.

use std::sync::OnceLock;

use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWINDOWATTRIBUTE};
use windows::Win32::Graphics::Gdi::{
    CreateFontW, CreatePen, CreateSolidBrush, DeleteObject, DrawTextW, GetStockObject, LineTo,
    MoveToEx, RoundRect, SelectObject, SetBkColor, SetBkMode, SetTextColor, CLIP_DEFAULT_PRECIS,
    DEFAULT_CHARSET, DEFAULT_PITCH, FF_DONTCARE, FONT_QUALITY, HBRUSH, HDC, HFONT, HOLLOW_BRUSH,
    OUT_DEFAULT_PRECIS, PS_SOLID, TRANSPARENT, DT_CENTER, DT_LEFT, DT_SINGLELINE, DT_VCENTER,
};
use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
use windows::Win32::UI::Controls::{DRAWITEMSTRUCT, ODS_DISABLED, ODS_SELECTED};
use windows::Win32::UI::WindowsAndMessaging::{GetWindowTextW, SendMessageW, WM_SETFONT};

/// Windows' answer to the Mac's Liquid Glass: the Fluent backdrop.
///
/// Mica (`DWMSBT_MAINWINDOW`) samples the desktop wallpaper, tints it with the
/// theme and blurs it — the material Windows 11 uses for Settings, Explorer and
/// every first-party window. Rounding the corners and matching the immersive
/// title bar to the light/dark setting is the rest of it, so a RemoteCrab
/// window sits in the desktop the way the Mac's do.
///
/// Best-effort, like every other native call in this file: each attribute is
/// ignored on failure. On Windows 10 (no Mica) the window simply keeps whatever
/// its controls paint, which is the previous look — it degrades, it does not
/// break.
pub fn apply_backdrop(hwnd: HWND) {
    let write = |attr: i32, value: i32| unsafe {
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWINDOWATTRIBUTE(attr),
            (&value as *const i32).cast(),
            std::mem::size_of::<i32>() as u32,
        );
    };
    // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE; 33 = DWMWA_WINDOW_CORNER_PREFERENCE
    // (2 = DWMWCP_ROUND); 38 = DWMWA_SYSTEMBACKDROP_TYPE (2 = DWMSBT_MAINWINDOW,
    // Mica). The values are documented Win11 attributes; the crate's enum does
    // not name 38 in 0.62, so the raw integers are used.
    write(20, if apps_use_dark() { 1 } else { 0 });
    write(33, 2);
    write(38, 2);
}

/// A control's position and size.
///
/// The four numbers always travel together, so they travel as one argument; the
/// alternative is every helper taking four integers and every call site reading as
/// a row of unexplained figures.
pub const fn boxed(x: i32, y: i32, w: i32, h: i32) -> RECT {
    RECT {
        left: x,
        top: y,
        right: x + w,
        bottom: y + h,
    }
}

/// Give a control the font it should draw in.
///
/// `WM_SETFONT` rather than selecting it into a DC: the control keeps it, and the
/// DC handed to `WM_DRAWITEM` arrives with it already selected.
pub fn set_font(control: HWND, font: HFONT) {
    unsafe {
        SendMessageW(control, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
    }
}

/// `COLORREF` is `0x00BBGGRR`: blue in the high byte, red in the low one. Every
/// colour in this file is written the other way round (as a web `#RRGGBB`, which
/// is how the tokens above are quoted), so they all go through here.
const fn rgb(r: u32, g: u32, b: u32) -> COLORREF {
    COLORREF(r | (g << 8) | (b << 16))
}

/// The colours one drawing operation needs.
///
/// Brushes are not exposed. A caller that wants to fill a rectangle asks
/// [`brush_for`] with the colour it already got from here.
#[derive(Debug, Clone, Copy)]
pub struct Palette {
    /// Panels and cards sitting on the canvas.
    pub card: COLORREF,
    /// Body text and headings.
    pub text: COLORREF,
    /// Supporting text: captions, the state line, a second paragraph.
    pub text_soft: COLORREF,
    /// Text that is present but not meant to be read first.
    pub text_faint: COLORREF,
    /// Primary action.
    pub accent: COLORREF,
    /// Text drawn on top of [`Palette::accent`].
    pub on_accent: COLORREF,
    /// Hairlines and control outlines.
    pub line: COLORREF,
    /// Status: this works.
    pub ok: COLORREF,
    /// Status dot: broken, and the user can do something about it.
    pub err: COLORREF,
}

/// The system light/dark setting, and the tokens for it.
///
/// `AppsUseLightTheme` under `Themes\Personalize` is the documented place, and it
/// is what Explorer and Settings read, so a window that follows it matches the
/// rest of the desktop. The value is a DWORD where 0 means dark; the absence of
/// the key means the user has never chosen, in which case light is right because
/// that is the default the rest of the desktop will be using.
pub fn palette() -> &'static Palette {
    static PALETTE: OnceLock<Palette> = OnceLock::new();
    PALETTE.get_or_init(|| {
        if apps_use_dark() {
            Palette {
                card: rgb(0x15, 0x15, 0x1B),
                text: rgb(0xFF, 0xFF, 0xFF),
                text_soft: rgb(0xB0, 0xB0, 0xB8),
                text_faint: rgb(0x6E, 0x6E, 0x78),
                accent: rgb(0x40, 0xA8, 0xFF),
                on_accent: rgb(0x08, 0x08, 0x0C),
                line: rgb(0x2A, 0x2A, 0x32),
                ok: rgb(0x33, 0xCC, 0x80),
                err: rgb(0xFF, 0x45, 0x45),
            }
        } else {
            Palette {
                card: rgb(0xFF, 0xFF, 0xFF),
                text: rgb(0x1A, 0x1A, 0x1F),
                text_soft: rgb(0x55, 0x55, 0x5E),
                text_faint: rgb(0x9A, 0x9A, 0xA2),
                accent: rgb(0x0A, 0x85, 0xFF),
                on_accent: rgb(0xFF, 0xFF, 0xFF),
                line: rgb(0xDE, 0xDE, 0xE6),
                ok: rgb(0x00, 0x87, 0x59),
                err: rgb(0xDB, 0x26, 0x26),
            }
        }
    })
}

fn apps_use_dark() -> bool {
    let mut value: u32 = 1;
    let mut size = std::mem::size_of::<u32>() as u32;
    let result = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("AppsUseLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some((&mut value as *mut u32).cast()),
            Some(&mut size),
        )
    };
    // A missing key or value means "never chosen", which is light.
    result.is_ok() && value == 0
}

/// A font in the sizes this program uses.
///
/// `Segoe UI Variable Text` is the Windows 11 interface font. GDI falls back to
/// the default interface font when a family is missing, so naming it is safe on
/// Windows 10, where the fallback is Segoe UI, which is what this would have
/// asked for anyway.
///
/// Sizes are pixel heights, negative so they mean character height rather than
/// cell height. `FONT_QUALITY(5)` is `CLEARTYPE_QUALITY`; without it GDI returns
/// to the aliased look that made these windows read as old.
///
/// Cached by (size, weight) so that rebuilding a window's controls, which the
/// wizard does on every page change, does not leak a handle per page.
pub fn font(px: i32, weight: i32) -> HFONT {
    struct Fonts {
        entries: Vec<((i32, i32), HFONT)>,
    }
    // Font handles are process-global and this cache is only touched from the
    // thread that owns the windows.
    unsafe impl Send for Fonts {}
    unsafe impl Sync for Fonts {}

    static CACHE: OnceLock<std::sync::Mutex<Fonts>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| {
        std::sync::Mutex::new(Fonts {
            entries: Vec::new(),
        })
    });
    let Ok(mut cache) = cache.lock() else {
        return unsafe { create_font(px, weight) };
    };
    if let Some((_, font)) = cache.entries.iter().find(|(k, _)| *k == (px, weight)) {
        return *font;
    }
    let font = unsafe { create_font(px, weight) };
    cache.entries.push(((px, weight), font));
    font
}

unsafe fn create_font(px: i32, weight: i32) -> HFONT {
    CreateFontW(
        -px,
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS,
        FONT_QUALITY(5),
        DEFAULT_PITCH.0 as u32 | FF_DONTCARE.0 as u32,
        w!("Segoe UI Variable Text"),
    )
}

/// `FW_NORMAL` and friends, so callers do not pass bare numbers to [`font`].
pub const WEIGHT_REGULAR: i32 = 400;
pub const WEIGHT_MEDIUM: i32 = 500;
pub const WEIGHT_SEMIBOLD: i32 = 600;

/// The sizes, from the same 4pt rhythm as `IBSpace`.
pub const TEXT_HEADING: i32 = 20;
pub const TEXT_SUBHEAD: i32 = 15;
pub const TEXT_BODY: i32 = 14;
pub const TEXT_CAPTION: i32 = 12;

/// A solid brush for `colour`.
///
/// Cached, because the alternative is creating and destroying one per
/// `WM_CTLCOLOR` message, which arrives on every mouse move over the window, or
/// leaking one per call. The palette is fixed for the life of the process, so a
/// fixed set of brushes matches it exactly. The handles are never freed: they are
/// a few hundred bytes held until exit, which is cheaper than teaching every
/// window to tear them down in `WM_DESTROY` and getting that wrong.
pub fn brush_for(colour: COLORREF) -> HBRUSH {
    struct Cache {
        entries: Vec<(u32, HBRUSH)>,
    }
    // GDI handles are process-global and this cache is only ever touched from
    // the thread that owns the windows.
    unsafe impl Send for Cache {}
    unsafe impl Sync for Cache {}

    static CACHE: OnceLock<std::sync::Mutex<Cache>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| {
        std::sync::Mutex::new(Cache {
            entries: Vec::new(),
        })
    });
    let Ok(mut cache) = cache.lock() else {
        // A poisoned cache still holds valid handles; creating a fresh brush is
        // better than failing to paint.
        return unsafe { CreateSolidBrush(colour) };
    };
    if let Some((_, brush)) = cache.entries.iter().find(|(c, _)| *c == colour.0) {
        return *brush;
    }
    let brush = unsafe { CreateSolidBrush(colour) };
    cache.entries.push((colour.0, brush));
    brush
}

/// Paint a control's background and text with the palette applied, and return the
/// brush Win32 should use for that control.
///
/// This is what `WM_CTLCOLORSTATIC` and friends are for: Win32 asks the parent
/// what colour to draw a child in, and the default answer is the system dialog
/// pair, black on grey, which is the look this program is getting rid of. The
/// brush returned is owned by the cache in [`brush_for`], not by the caller.
///
/// `back` may be `None` for controls that should show the canvas through, which
/// is what text labels sitting directly on the window want.
pub fn tint_child(hdc: HDC, colour: COLORREF, back: Option<COLORREF>) -> HBRUSH {
    unsafe {
        SetTextColor(hdc, colour);
        // Labels on the canvas need a transparent background or they paint a
        // rectangle of their own colour over the window. A hollow brush leaves
        // the backdrop (Mica) showing through, so the text floats on the glass
        // the way the Mac's does.
        SetBkMode(hdc, TRANSPARENT);
        match back {
            None => HBRUSH(GetStockObject(HOLLOW_BRUSH).0),
            Some(back) => {
                SetBkColor(hdc, back);
                brush_for(back)
            }
        }
    }
}

/// Draw an owner-drawn checkbox.
///
/// A checkbox has to be owner-drawn to sit on this canvas at all. Windows
/// ignores the parent's brush for a themed button (`WM_CTLCOLORBTN` is answered
/// for owner-drawn buttons only), so a `BS_AUTOCHECKBOX` on a dark window keeps a
/// light box of its own and reads as a mistake.
///
/// The state is not read from the control — a `BS_OWNERDRAW` button has no state
/// to read — so the caller passes it, having taken it from the same model the
/// click handler writes to.
pub fn paint_check(di: &DRAWITEMSTRUCT, checked: bool) {
    let p = palette();
    let hdc = di.hDC;
    let rect = di.rcItem;

    // No `fill_canvas`: the backdrop (Mica) must show in the pixels the rounded
    // box does not cover, so the control is drawn straight onto the glass.

    let enabled = di.itemState.0 & ODS_DISABLED.0 == 0;
    let box_size = 16;
    let left = rect.left;
    let top = rect.top + (rect.bottom - rect.top - box_size) / 2;
    let (fill, border) = match (checked, enabled) {
        (true, true) => (p.accent, p.accent),
        (true, false) => (p.line, p.line),
        (false, _) => (p.card, p.line),
    };

    unsafe {
        let pen = CreatePen(PS_SOLID, 1, border);
        let brush = brush_for(fill);
        let old_pen = SelectObject(hdc, pen.into());
        let old_brush = SelectObject(hdc, brush.into());
        let _ = RoundRect(hdc, left, top, left + box_size, top + box_size, 5, 5);
        SelectObject(hdc, old_pen);
        SelectObject(hdc, old_brush);
        let _ = DeleteObject(pen.into());
    }

    if checked {
        // The tick, as two strokes. Four pixels either side of the centre is as
        // much shape as a 16-pixel box can carry.
        unsafe {
            let pen = CreatePen(PS_SOLID, 2, p.on_accent);
            let old = SelectObject(hdc, pen.into());
            let (cx, cy) = (left + box_size / 2, top + box_size / 2);
            let _ = MoveToEx(hdc, cx - 4, cy, None);
            let _ = LineTo(hdc, cx - 1, cy + 3);
            let _ = LineTo(hdc, cx + 4, cy - 4);
            SelectObject(hdc, old);
            let _ = DeleteObject(pen.into());
        }
    }

    let mut buf = [0u16; 256];
    let len = unsafe { GetWindowTextW(di.hwndItem, &mut buf) } as usize;
    let label_text = String::from_utf16_lossy(&buf[..len.min(buf.len())]);
    let mut wide: Vec<u16> = label_text.encode_utf16().collect();
    let mut text_rect = RECT {
        left: left + box_size + 10,
        ..rect
    };
    unsafe {
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, if enabled { p.text } else { p.text_faint });
        DrawTextW(
            hdc,
            &mut wide,
            &mut text_rect,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE,
        );
    }
}
/// Which of the two button looks to draw.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ButtonStyle {
    /// Filled with the accent: the one thing the window wants you to do.
    Primary,
    /// Outlined: everything else.
    Secondary,
}

/// Draw an owner-drawn button.
///
/// The buttons are owner-drawn because Win32's default push button is a 3D
/// bevelled rectangle that has looked dated since Windows Vista, and there is no
/// style flag that produces a flat one. `BS_OWNERDRAW` plus this is less code than
/// any of the alternatives, which are a control library or compositing the window
/// ourselves.
pub fn paint_button(di: &DRAWITEMSTRUCT, style: ButtonStyle) {
    let p = palette();
    let hdc = di.hDC;
    let rect = di.rcItem;

    // No `fill_canvas` — see `paint_check`. The button is a card floating on the
    // Mica backdrop, so its corners are transparent rather than canvas-coloured.
    let enabled = di.itemState.0 & ODS_DISABLED.0 == 0;
    let pressed = di.itemState.0 & ODS_SELECTED.0 != 0;

    let (fill, border, label) = match style {
        ButtonStyle::Primary if !enabled => (p.line, p.line, p.text_faint),
        ButtonStyle::Primary => (
            if pressed { p.line } else { p.accent },
            if pressed { p.line } else { p.accent },
            if pressed { p.text_soft } else { p.on_accent },
        ),
        ButtonStyle::Secondary if !enabled => (p.card, p.line, p.text_faint),
        ButtonStyle::Secondary => (
            if pressed { p.line } else { p.card },
            if pressed { p.accent } else { p.line },
            p.text,
        ),
    };

    unsafe {
        // A rounded rectangle wants a pen for the outline and a brush for the
        // inside, and both have to be selected while it draws.
        let pen = CreatePen(PS_SOLID, 1, border);
        let brush = brush_for(fill);
        let old_pen = SelectObject(hdc, pen.into());
        let old_brush = SelectObject(hdc, brush.into());
        let _ = RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, 8, 8);
        SelectObject(hdc, old_pen);
        SelectObject(hdc, old_brush);
        // The pen is per-call rather than cached: it is selected for a few
        // microseconds and there are three of these on screen.
        let _ = DeleteObject(pen.into());
    }

    let mut buf = [0u16; 128];
    let len = unsafe { GetWindowTextW(di.hwndItem, &mut buf) } as usize;
    let label_text = String::from_utf16_lossy(&buf[..len.min(buf.len())]);

    let mut text_rect = RECT {
        // A pressed button shifts its label down by the same pixel its fill
        // loses, which is the whole of the press animation.
        top: rect.top + if pressed { 1 } else { 0 },
        ..rect
    };
    let mut wide: Vec<u16> = label_text.encode_utf16().collect();
    unsafe {
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, label);
        DrawTextW(
            hdc,
            &mut wide,
            &mut text_rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        );
    }
}
