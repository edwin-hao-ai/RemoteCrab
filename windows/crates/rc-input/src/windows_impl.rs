//! Windows `SendInput` execution of the neutral actions from [`injector`].
//!
//! Only compiled on Windows. All the decision logic lives in the pure
//! modules so this file stays a thin syscall layer.

use std::mem::size_of;

use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_HWHEEL,
    MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP,
    MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_VIRTUALDESK,
    MOUSEEVENTF_WHEEL, MOUSEINPUT, MOUSE_EVENT_FLAGS, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

use crate::injector::{InputTranslator, MouseAction, ScreenSize};
use crate::keymap::{self, Injected};
use rc_protocol::{KeyEvent, TouchEvent};

/// Query the virtual screen (all monitors) for cursor clamping.
pub fn virtual_screen_size() -> ScreenSize {
    unsafe {
        ScreenSize {
            width: GetSystemMetrics(SM_CXVIRTUALSCREEN) as f64,
            height: GetSystemMetrics(SM_CYVIRTUALSCREEN) as f64,
            origin_x: GetSystemMetrics(SM_XVIRTUALSCREEN) as f64,
            origin_y: GetSystemMetrics(SM_YVIRTUALSCREEN) as f64,
        }
    }
}

/// The real Windows input injector. Owns an [`InputTranslator`] for the
/// tracked cursor + drag/scroll state.
#[derive(Default)]
pub struct WindowsInjector {
    translator: InputTranslator,
    /// Left button held (drag in progress) — a `Move` then becomes a drag.
    left_down: bool,
}

impl WindowsInjector {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn inject_touch(&mut self, event: &TouchEvent) {
        let screen = virtual_screen_size();
        let actions = self.translator.touch(event, screen);
        for action in actions {
            self.perform_mouse(action);
        }
    }

    pub fn inject_key(&self, event: &KeyEvent) {
        match self.translator.key(event) {
            Injected::Key { vk, down, modifiers } => {
                // Hold the modifiers, tap the key, release the modifiers.
                let mods = keymap::modifier_vks(modifiers);
                let is_modifier_key = mods.contains(&vk);
                for m in &mods {
                    if *m != vk {
                        send_vk(*m, true);
                    }
                }
                send_vk(vk, down);
                if !is_modifier_key {
                    for m in mods.iter().rev() {
                        send_vk(*m, false);
                    }
                }
            }
            Injected::Text(units) => send_unicode(&units),
            Injected::Unknown => {}
        }
    }

    /// Called when a scroll burst goes quiet (the Mac uses a 0.18 s timer).
    pub fn finish_scroll(&mut self) {
        for action in self.translator.finish_scroll() {
            self.perform_mouse(action);
        }
    }

    fn perform_mouse(&mut self, action: MouseAction) {
        match action {
            MouseAction::Move { x, y } => {
                // A move while the button is held IS a drag on Windows —
                // `SendInput` reports it as such to the target window.
                send_mouse(MOUSEEVENTF_MOVE, x, y, 0);
            }
            MouseAction::LeftDown { x, y } => {
                self.left_down = true;
                send_mouse(MOUSEEVENTF_LEFTDOWN, x, y, 0);
            }
            MouseAction::LeftUp { x, y } => {
                self.left_down = false;
                send_mouse(MOUSEEVENTF_LEFTUP, x, y, 0);
            }
            MouseAction::RightDown { x, y } => send_mouse(MOUSEEVENTF_RIGHTDOWN, x, y, 0),
            MouseAction::RightUp { x, y } => send_mouse(MOUSEEVENTF_RIGHTUP, x, y, 0),
            MouseAction::MiddleDown { x, y } => send_mouse(MOUSEEVENTF_MIDDLEDOWN, x, y, 0),
            MouseAction::MiddleUp { x, y } => send_mouse(MOUSEEVENTF_MIDDLEUP, x, y, 0),
            MouseAction::Wheel { dx, dy } => {
                if dy.abs() >= 1.0 {
                    send_mouse(MOUSEEVENTF_WHEEL, 0, 0, dy.round() as i32);
                }
                if dx.abs() >= 1.0 {
                    send_mouse(MOUSEEVENTF_HWHEEL, 0, 0, dx.round() as i32);
                }
            }
            MouseAction::ScrollPhase(_) => {
                // Windows has no scroll-phase events; the wheel deltas alone
                // drive native smooth scrolling. Intentionally a no-op.
            }
        }
    }
}

/// Post a mouse event whose `x`/`y` are **absolute virtual-desktop pixels**.
///
/// Windows interprets `dx`/`dy` as absolute coordinates only when
/// `MOUSEEVENTF_ABSOLUTE` is set — and even then they must be normalized to
/// `0..65535` across the virtual desktop (`MOUSEEVENTF_VIRTUALDESK` covers
/// all monitors). Without this the values are treated as *relative* deltas
/// and the cursor races off-screen — which is exactly the "cursor
/// disappears" bug.
fn send_mouse(flags: MOUSE_EVENT_FLAGS, x: i32, y: i32, data: i32) {
    let has_move = flags.contains(MOUSEEVENTF_MOVE)
        || flags.contains(MOUSEEVENTF_LEFTDOWN)
        || flags.contains(MOUSEEVENTF_RIGHTDOWN)
        || flags.contains(MOUSEEVENTF_MIDDLEDOWN);

    let mut flags = flags;
    let (dx, dy) = if has_move {
        flags |= MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
        let screen = virtual_screen_size();
        (normalize_axis(x, screen.origin_x as i32, screen.width as i32),
         normalize_axis(y, screen.origin_y as i32, screen.height as i32))
    } else {
        (0, 0)
    };

    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy,
                mouseData: data as u32,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    unsafe {
        SendInput(&[input], size_of::<INPUT>() as i32);
    }
}

/// Map an absolute virtual-desktop pixel to the 0..65535 range Windows wants.
fn normalize_axis(coord: i32, origin: i32, extent: i32) -> i32 {
    if extent <= 1 {
        return 0;
    }
    let relative = (coord - origin).clamp(0, extent - 1);
    ((relative as i64 * 65535) / (extent as i64 - 1)) as i32
}

fn send_vk(vk: u16, down: bool) {
    let flags: KEYBD_EVENT_FLAGS = if down { KEYBD_EVENT_FLAGS(0) } else { KEYEVENTF_KEYUP };
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                wScan: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    unsafe {
        SendInput(&[input], size_of::<INPUT>() as i32);
    }
}

/// Type UTF-16 units directly (IME already applied on iOS) — layout-agnostic.
fn send_unicode(units: &[u16]) {
    let mut inputs = Vec::with_capacity(units.len() * 2);
    for &unit in units {
        for down in [true, false] {
            inputs.push(INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: VIRTUAL_KEY(0),
                        wScan: unit,
                        dwFlags: if down {
                            KEYEVENTF_UNICODE
                        } else {
                            KEYEVENTF_UNICODE | KEYEVENTF_KEYUP
                        },
                        time: 0,
                        dwExtraInfo: 0,
                    },
                },
            });
        }
    }
    if inputs.is_empty() {
        return;
    }
    unsafe {
        SendInput(&inputs, size_of::<INPUT>() as i32);
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_axis;

    #[test]
    fn axis_normalization_covers_the_full_range() {
        // Single 1920-wide monitor.
        assert_eq!(normalize_axis(0, 0, 1920), 0);
        assert_eq!(normalize_axis(1919, 0, 1920), 65535);
        // Middle maps to roughly half.
        let mid = normalize_axis(960, 0, 1920);
        assert!((32_000..=33_500).contains(&mid), "mid = {mid}");
    }

    #[test]
    fn axis_normalization_respects_a_negative_origin() {
        // A monitor to the left of the primary starts at a negative X.
        assert_eq!(normalize_axis(-1920, -1920, 1920), 0);
        // x = 0 is the start of the primary (a 1920-wide panel sitting to
        // the right of another 1920-wide one -> virtual extent 3840).
        let primary_start = normalize_axis(0, -1920, 3840);
        assert!(
            (32_700..=32_850).contains(&primary_start),
            "primary_start = {primary_start} (expected ~32776)"
        );
    }

    #[test]
    fn axis_normalization_clamps_out_of_range() {
        assert_eq!(normalize_axis(-500, 0, 1920), 0);
        assert_eq!(normalize_axis(999_999, 0, 1920), 65535);
    }
}
