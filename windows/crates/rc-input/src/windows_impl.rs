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

use crate::injector::{
    swipe_shortcut, InputTranslator, MouseAction, ScreenSize, SwipeShortcut, WheelAccumulator,
};

/// How long a scroll has to be quiet before it counts as finished. The Mac
/// uses the same 0.18 s (`ReceiverSession`/`CGEventInjector`).
const SCROLL_SETTLE: std::time::Duration = std::time::Duration::from_millis(180);
use crate::keymap::{self, Injected};
use rc_protocol::{KeyEvent, ScreenInput, TouchEvent, TouchPhase};

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
    /// Fractional wheel travel, carried between events. See
    /// [`crate::injector::WheelAccumulator`]: posting `delta.round()` per event
    /// behind a `|d| >= 1.0` guard dropped slow scrolls entirely and turned
    /// everything else into whole notches.
    wheel: WheelAccumulator,
    /// …and a separate one for pinch-zoom, which must not share a remainder
    /// with scrolling.
    ctrl_wheel: WheelAccumulator,
    /// Set once `end_gesture` has run, so a second call is harmless.
    released: bool,
    /// Keys the translator is holding, so they can be released on a drop.
    released_keys: Vec<u16>,
    /// When the last scroll event arrived, so an end-of-scroll marker can be
    /// emitted after a quiet gap. The Mac does this with a 0.18 s
    /// `DispatchQueue` timer; comparing timestamps on the next event achieves
    /// the same thing without a thread per injector, and it cannot be missed
    /// because it does not depend on anything being scheduled.
    last_scroll: Option<std::time::Instant>,
}

impl WindowsInjector {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn inject_touch(&mut self, event: &TouchEvent) {
        // A three/four-finger swipe is a Windows task/desktop shortcut, not
        // a mouse action (the Mac maps it to Mission Control). It used to
        // be a silent no-op on Windows.
        if event.phase == TouchPhase::ThreeFingerSwipe {
            if let Some(shortcut) = swipe_shortcut(event.dx, event.dy) {
                self.perform_swipe(shortcut);
            }
            return;
        }
        // A scroll that has been quiet for a moment has ended. Emitting the
        // marker here rather than on a timer means it cannot be lost, and
        // `finish_scroll` had in fact never been called from anywhere, so the
        // translator's `scroll_active` / `momentum_active` latched on for the
        // life of the session.
        if matches!(event.phase, TouchPhase::Scroll | TouchPhase::Pinch) {
            let quiet = self
                .last_scroll
                .map(|t| t.elapsed() > SCROLL_SETTLE)
                .unwrap_or(false);
            if quiet {
                for action in self.translator.finish_scroll() {
                    self.perform_mouse(action);
                }
            }
        }
        if matches!(event.phase, TouchPhase::Scroll) {
            self.last_scroll = Some(std::time::Instant::now());
        }

        let screen = virtual_screen_size();
        let actions = self.translator.touch(event, screen);
        for action in actions {
            self.perform_mouse(action);
        }
    }

    /// End of gesture: release the wheel accumulator's remainder and emit the
    /// end-of-scroll markers. Called when the link drops or the user lifts a
    /// finger after a pinch, where no further event would arrive to notice.
    pub fn end_gesture(&mut self) {
        self.wheel.flush();
        self.last_scroll = None;
        for action in self.translator.finish_scroll() {
            self.perform_mouse(action);
        }
        for vk in self.held_modifiers() {
            send_vk(vk, false);
        }
        self.released = true;
    }

    /// Every modifier the translator is currently holding, so a dropped link
    /// cannot leave Shift stuck down on the user's keyboard.
    fn held_modifiers(&mut self) -> Vec<u16> {
        std::mem::take(&mut self.released_keys)
    }

    pub fn inject_key(&self, event: &KeyEvent) {
        match self.translator.key(event) {
            Injected::Key {
                vk,
                down,
                modifiers,
            } => {
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

    /// Where the translator currently believes the pointer is, in
    /// virtual-desktop pixels. Read by the `REMOTECRAB_E2E_TRACKPAD_DIR`
    /// diagnostic to print the cursor's actual travel next to the delta that
    /// was received.
    pub fn cursor(&self) -> (f64, f64) {
        self.translator.last_cursor
    }

    /// Inject one mirror `ScreenInput` at the window frame `origin`/`size`
    /// (virtual-desktop pixels). Modifiers are held around the mouse actions
    /// so shift-click / ⌘-click etc. reach the target window.
    pub fn inject_screen_input(
        &mut self,
        input: &ScreenInput,
        origin: (f64, f64),
        size: (f64, f64),
    ) {
        let actions = crate::injector::screen_actions(input, origin, size);
        let mods = keymap::modifier_vks(input.modifiers);
        for m in &mods {
            send_vk(*m, true);
        }
        for action in actions {
            self.perform_mouse(action);
        }
        for m in mods.iter().rev() {
            send_vk(*m, false);
        }
    }

    /// Three/four-finger swipe → Task View / virtual-desktop switch.
    fn perform_swipe(&self, shortcut: SwipeShortcut) {
        match shortcut {
            SwipeShortcut::TaskView => send_chord(&[VK_LWIN, VK_TAB]),
            SwipeShortcut::DesktopLeft => send_chord(&[VK_CONTROL, VK_LWIN, VK_LEFT]),
            SwipeShortcut::DesktopRight => send_chord(&[VK_CONTROL, VK_LWIN, VK_RIGHT]),
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
                let (h, v) = self.wheel.take(dx, dy);
                if v != 0 {
                    send_mouse(MOUSEEVENTF_WHEEL, 0, 0, v);
                }
                if h != 0 {
                    send_mouse(MOUSEEVENTF_HWHEEL, 0, 0, h);
                }
            }
            MouseAction::CtrlWheel { dx, dy } => {
                // Ctrl+wheel is the zoom gesture most apps understand. It goes
                // through a separate accumulator: mixing zoom travel into the
                // scroll travel would make a pinch scroll the page, and vice
                // versa, for as long as the remainder survived.
                let (h, v) = self.ctrl_wheel.take(dx, dy);
                if v != 0 || h != 0 {
                    send_vk(VK_CONTROL, true);
                    if v != 0 {
                        send_mouse(MOUSEEVENTF_WHEEL, 0, 0, v);
                    }
                    if h != 0 {
                        send_mouse(MOUSEEVENTF_HWHEEL, 0, 0, h);
                    }
                    send_vk(VK_CONTROL, false);
                }
            }
            MouseAction::ModifierKeys { vks, pressed } => {
                // Remember what is down so a dropped link can release it. A
                // stuck Shift is the kind of bug that makes the whole machine
                // feel broken and is invisible in every log.
                // `SendInput` has no per-event flag byte, so a held modifier
                // is a real key-down that has to be released later. The
                // translator emits both transitions, diffed against the keys
                // it already holds, so the key state matches the trackpad's.
                for vk in vks {
                    send_vk(vk, pressed);
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
        (
            normalize_axis(x, screen.origin_x as i32, screen.width as i32),
            normalize_axis(y, screen.origin_y as i32, screen.height as i32),
        )
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

const VK_CONTROL: u16 = 0x11;
const VK_LWIN: u16 = 0x5B;
const VK_TAB: u16 = 0x09;
const VK_LEFT: u16 = 0x25;
const VK_RIGHT: u16 = 0x27;

/// Hold each key in order, release in reverse (a chord like Ctrl+Win+Left).
fn send_chord(vks: &[u16]) {
    for vk in vks {
        send_vk(*vk, true);
    }
    for vk in vks.iter().rev() {
        send_vk(*vk, false);
    }
}

fn send_vk(vk: u16, down: bool) {
    let flags: KEYBD_EVENT_FLAGS = if down {
        KEYBD_EVENT_FLAGS(0)
    } else {
        KEYEVENTF_KEYUP
    };
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
