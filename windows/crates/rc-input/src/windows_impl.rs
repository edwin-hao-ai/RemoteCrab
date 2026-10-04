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

/// Keys the trackpad is holding down on the user's behalf.
///
/// Split out of [`WindowsInjector`] so it can be tested without `SendInput`.
/// The bookkeeping it replaces was previously only reachable by actually
/// pressing a key on the machine running the tests, which is why it shipped
/// unwritten: there was no way to write a test for it, and no test failed.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct HeldKeys(Vec<u16>);

impl HeldKeys {
    /// Fold one `MouseAction::ModifierKeys` transition into the held set.
    ///
    /// This is the seam that makes the safety net testable: it takes the
    /// translator's own output, so a test can drive real actions through it.
    /// Testing `press`/`release` in isolation was not enough — the original bug
    /// was that nothing *called* them, and a test that never crosses that line
    /// passes with the calls deleted (verified by removing them).
    pub fn apply(&mut self, vks: &[u16], pressed: bool) {
        for &vk in vks {
            if pressed {
                self.press(vk);
            } else {
                self.release(vk);
            }
        }
    }

    /// Note a key-down. Repeats are collapsed, because the translator already
    /// diffs and a repeated press is not a second physical key-down.
    pub fn press(&mut self, vk: u16) {
        if !self.0.contains(&vk) {
            self.0.push(vk);
        }
    }

    /// Note a key-up.
    pub fn release(&mut self, vk: u16) {
        self.0.retain(|&k| k != vk);
    }

    /// Give up everything held and return it, so a caller can release the lot.
    /// Draining is what makes `end_gesture` idempotent without a flag.
    pub fn take_all(&mut self) -> Vec<u16> {
        std::mem::take(&mut self.0)
    }

    pub fn is_held(&self, vk: u16) -> bool {
        self.0.contains(&vk)
    }

    #[cfg(test)]
    pub fn as_slice(&self) -> &[u16] {
        &self.0
    }
}

/// How a key event reaches Windows. A field so tests can watch what would be
/// sent instead of pressing keys on the machine running them.
///
/// The bookkeeping that decides whether a stuck modifier can be released lives
/// in `perform_mouse`, behind this call. With the calls hard-wired, that
/// bookkeeping was unreachable from a test — which is how a three-part safety
/// net shipped with its only moving part unwired and 45 tests green. A test
/// that duplicates the wiring instead of exercising it is worse than no test,
/// because it certifies a line nothing runs.
type SendKey = fn(u16, bool);
/// As above, for mouse events.
type SendMouse = fn(MOUSE_EVENT_FLAGS, i32, i32, i32);

/// The real Windows input injector. Owns an [`InputTranslator`] for the
/// tracked cursor + drag/scroll state.
pub struct WindowsInjector {
    translator: InputTranslator,
    /// Fractional wheel travel, carried between events. See
    /// [`crate::injector::WheelAccumulator`]: posting `delta.round()` per event
    /// behind a `|d| >= 1.0` guard dropped slow scrolls entirely and turned
    /// everything else into whole notches.
    wheel: WheelAccumulator,
    /// …and a separate one for pinch-zoom, which must not share a remainder
    /// with scrolling.
    ctrl_wheel: WheelAccumulator,
    /// Keys the translator is currently holding down on the user's behalf, so
    /// a dropped link can release them.
    ///
    /// This used to be declared and drained but never written: the
    /// `ModifierKeys` arm said it "remembered what is down so a dropped link can
    /// release it" and then only called `send_vk`. So `held_modifiers()`
    /// always came back empty and the safety net it fed could not release
    /// anything — a held Shift survived a disconnect as a genuinely stuck key,
    /// invisible in every log. 45 tests passed over the top of that.
    held_keys: HeldKeys,
    /// When the last scroll event arrived, so an end-of-scroll marker can be
    /// emitted after a quiet gap. The Mac does this with a 0.18 s
    /// `DispatchQueue` timer; comparing timestamps on the next event achieves
    /// the same thing without a thread per injector, and it cannot be missed
    /// because it does not depend on anything being scheduled.
    last_scroll: Option<std::time::Instant>,
    send_key: SendKey,
    send_mouse: SendMouse,
}

impl Default for WindowsInjector {
    fn default() -> Self {
        Self {
            translator: InputTranslator::new(),
            wheel: WheelAccumulator::default(),
            ctrl_wheel: WheelAccumulator::default(),
            held_keys: HeldKeys::default(),
            last_scroll: None,
            send_key: send_vk,
            send_mouse,
        }
    }
}

impl WindowsInjector {
    pub fn new() -> Self {
        Self::default()
    }

    /// An injector that records what it *would* send instead of sending it, so
    /// the bookkeeping behind the `SendInput` calls can be tested.
    #[cfg(test)]
    pub fn recording() -> Self {
        Self {
            send_key: record_key,
            send_mouse: record_mouse,
            ..Self::default()
        }
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

    /// End of gesture: release the wheel accumulator's remainder, the
    /// end-of-scroll markers, and any modifier the trackpad is still holding.
    ///
    /// Must be called when the link drops. Without it a `Shift` held for a
    /// range-select stays physically down on the user's keyboard, because
    /// `SendInput` posted a real key-down and nothing ever posts the key-up —
    /// every later keystroke is shifted until they press and release it
    /// themselves.
    ///
    /// Idempotent: `held_keys` is drained, so a second call has nothing to do.
    pub fn end_gesture(&mut self) {
        self.wheel.flush();
        self.ctrl_wheel.flush();
        self.last_scroll = None;
        for action in self.translator.finish_scroll() {
            self.perform_mouse(action);
        }
        for vk in self.held_modifiers() {
            (self.send_key)(vk, false);
        }
    }

    /// Every modifier still held on the user's behalf, so a dropped link
    /// cannot leave Shift stuck down on the user's keyboard.
    fn held_modifiers(&mut self) -> Vec<u16> {
        self.held_keys.take_all()
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
                (self.send_mouse)(MOUSEEVENTF_MOVE, x, y, 0);
            }
            MouseAction::LeftDown { x, y } => {
                (self.send_mouse)(MOUSEEVENTF_LEFTDOWN, x, y, 0);
            }
            MouseAction::LeftUp { x, y } => {
                (self.send_mouse)(MOUSEEVENTF_LEFTUP, x, y, 0);
            }
            MouseAction::RightDown { x, y } => (self.send_mouse)(MOUSEEVENTF_RIGHTDOWN, x, y, 0),
            MouseAction::RightUp { x, y } => (self.send_mouse)(MOUSEEVENTF_RIGHTUP, x, y, 0),
            MouseAction::MiddleDown { x, y } => (self.send_mouse)(MOUSEEVENTF_MIDDLEDOWN, x, y, 0),
            MouseAction::MiddleUp { x, y } => (self.send_mouse)(MOUSEEVENTF_MIDDLEUP, x, y, 0),
            MouseAction::Wheel { dx, dy } => {
                let (h, v) = self.wheel.take(dx, dy);
                if v != 0 {
                    (self.send_mouse)(MOUSEEVENTF_WHEEL, 0, 0, v);
                }
                if h != 0 {
                    (self.send_mouse)(MOUSEEVENTF_HWHEEL, 0, 0, h);
                }
            }
            MouseAction::CtrlWheel { dx, dy } => {
                // Ctrl+wheel is the zoom gesture most apps understand. It goes
                // through a separate accumulator: mixing zoom travel into the
                // scroll travel would make a pinch scroll the page, and vice
                // versa, for as long as the remainder survived.
                let (h, v) = self.ctrl_wheel.take(dx, dy);
                if v != 0 || h != 0 {
                    (self.send_key)(VK_CONTROL, true);
                    if v != 0 {
                        (self.send_mouse)(MOUSEEVENTF_WHEEL, 0, 0, v);
                    }
                    if h != 0 {
                        (self.send_mouse)(MOUSEEVENTF_HWHEEL, 0, 0, h);
                    }
                    (self.send_key)(VK_CONTROL, false);
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
                self.held_keys.apply(&vks, pressed);
                for vk in vks {
                    (self.send_key)(vk, pressed);
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

/// Key events a recording injector swallowed, so a test can assert what would
/// have reached the keyboard.
#[cfg(test)]
static SENT_KEYS: std::sync::Mutex<Vec<(u16, bool)>> = std::sync::Mutex::new(Vec::new());

#[cfg(test)]
fn record_key(vk: u16, pressed: bool) {
    SENT_KEYS.lock().expect("keys").push((vk, pressed));
}

#[cfg(test)]
fn record_mouse(_flags: MOUSE_EVENT_FLAGS, _x: i32, _y: i32, _data: i32) {}

#[cfg(test)]
fn sent_keys() -> Vec<(u16, bool)> {
    std::mem::take(&mut *SENT_KEYS.lock().expect("keys"))
}

#[cfg(test)]
mod tests {
    use super::{normalize_axis, sent_keys, HeldKeys};
    use crate::keymap::vk;
    use rc_protocol::{Modifier, TouchEvent, TouchPhase};

    fn touch(phase: TouchPhase, modifiers: u8) -> TouchEvent {
        TouchEvent {
            phase,
            x: 0.0,
            y: 0.0,
            dx: 0.01,
            dy: 0.0,
            modifiers,
            momentum: None,
            timestamp_micros: 0,
        }
    }

    /// The defect this whole change exists for, and the one 45 tests did not
    /// catch: a Shift held for a range-select must be recoverable when the
    /// link drops, or it stays physically down on the user's keyboard and every
    /// later keystroke is shifted.
    ///
    /// `HeldKeys` is tested directly rather than through `WindowsInjector`
    /// because the injector's only way to reach this state is a real
    /// `SendInput`, which would press a key on the machine running the tests.
    #[test]
    fn a_held_modifier_is_handed_back_for_release() {
        let mut held = HeldKeys::default();
        held.press(vk::SHIFT);
        held.press(vk::CONTROL);
        assert!(held.is_held(vk::SHIFT));
        assert!(held.is_held(vk::CONTROL));

        // What `end_gesture` does: take everything and key-up each one.
        let recovered = held.take_all();
        assert_eq!(
            recovered.len(),
            2,
            "both held modifiers must come back: {recovered:?}"
        );
        assert!(recovered.contains(&vk::SHIFT));
        assert!(recovered.contains(&vk::CONTROL));
    }

    /// Why draining is load-bearing rather than a convenience: it is what makes
    /// `end_gesture` idempotent, so the caller does not need a latch — and the
    /// latch it used to carry was written and never read.
    #[test]
    fn releasing_twice_releases_once() {
        let mut held = HeldKeys::default();
        held.press(vk::SHIFT);
        assert_eq!(held.take_all().len(), 1);
        assert!(
            held.take_all().is_empty(),
            "a second end_gesture must have nothing left to do"
        );
    }

    /// A modifier the user let go of must not be released twice — the second
    /// key-up lands on whatever the user is actually typing next.
    #[test]
    fn a_released_modifier_is_not_offered_again() {
        let mut held = HeldKeys::default();
        held.press(vk::SHIFT);
        held.release(vk::SHIFT);
        assert!(!held.is_held(vk::SHIFT));
        assert!(held.take_all().is_empty());
    }

    /// The translator already diffs, so a repeat press is not a second physical
    /// key-down. Counting it twice would make one release look insufficient.
    #[test]
    fn a_repeated_press_is_one_key_down() {
        let mut held = HeldKeys::default();
        held.press(vk::CONTROL);
        held.press(vk::CONTROL);
        assert_eq!(held.take_all(), vec![vk::CONTROL]);
    }

    /// Sliding from one modifier to another mid-drag must not lose the pair:
    /// ⌘ and ⌃ both map to Ctrl, so the *bits* change while the *key* does not.
    #[test]
    fn a_modifier_change_that_keeps_the_same_key_keeps_it_held() {
        let mut held = HeldKeys::default();
        held.press(vk::CONTROL);
        // The translator emits no transition here, because Ctrl is still held.
        assert!(held.is_held(vk::CONTROL));
        assert_eq!(held.take_all(), vec![vk::CONTROL]);
    }

    /// The contract that was actually broken, tested where it was broken.
    ///
    /// The old bug was not `HeldKeys` behaving wrongly — it was that nothing
    /// fed it. So this drives the **real** `WindowsInjector`, through the real
    /// `inject_touch` → translator → `perform_mouse` path, which is the line the
    /// previous version of this file left unwired.
    ///
    /// A test that rebuilt the wiring in its own body passed with the wiring
    /// deleted; that was verified, not assumed.
    #[test]
    fn a_modifier_held_by_a_real_gesture_is_released_at_the_end() {
        let _ = sent_keys(); // start from a clean slate
        let mut inj = super::WindowsInjector::recording();

        // Shift-drag: down, two moves, up. The translator emits the key-up.
        inj.inject_touch(&touch(TouchPhase::DragStart, Modifier::SHIFT));
        inj.inject_touch(&touch(TouchPhase::Move, Modifier::SHIFT));
        inj.inject_touch(&touch(TouchPhase::Move, Modifier::SHIFT));
        inj.inject_touch(&touch(TouchPhase::Up, Modifier::NONE));

        let sent = sent_keys();
        assert!(
            sent.contains(&(vk::SHIFT, true)),
            "Shift must actually go down: {sent:?}"
        );
        assert!(
            sent.contains(&(vk::SHIFT, false)),
            "and must come back up: {sent:?}"
        );
        // Nothing stranded, so end_gesture has nothing left to do.
        inj.end_gesture();
        assert!(
            !sent_keys().contains(&(vk::SHIFT, false)),
            "a normally-ended gesture must not leave a duplicate key-up"
        );
    }

    /// The actual user-visible failure: the phone vanishes mid-gesture, so the
    /// translator never emits its key-up, and only `end_gesture` can rescue the
    /// key. Without it Shift stays physically down and every later keystroke is
    /// shifted, with nothing in any log.
    #[test]
    fn a_link_drop_mid_gesture_releases_the_held_modifier() {
        let _ = sent_keys();
        let mut inj = super::WindowsInjector::recording();

        inj.inject_touch(&touch(TouchPhase::DragStart, Modifier::SHIFT));
        inj.inject_touch(&touch(TouchPhase::Move, Modifier::SHIFT));
        inj.inject_touch(&touch(TouchPhase::Move, Modifier::SHIFT));
        assert!(
            sent_keys().contains(&(vk::SHIFT, true)),
            "precondition: Shift is down"
        );

        // The link dies. No `Up` ever arrives.
        inj.end_gesture();

        assert!(
            sent_keys().contains(&(vk::SHIFT, false)),
            "end_gesture must key the stranded Shift up — this is the whole bug"
        );
    }

    /// A modifier the user let go of must not be released a second time: the
    /// duplicate key-up lands on whatever the user is typing next.
    #[test]
    fn a_released_modifier_is_not_released_again() {
        let _ = sent_keys();
        let mut inj = super::WindowsInjector::recording();
        inj.inject_touch(&touch(TouchPhase::DragStart, Modifier::SHIFT));
        inj.inject_touch(&touch(TouchPhase::Up, Modifier::NONE));
        assert_eq!(
            sent_keys()
                .iter()
                .filter(|&&(_, pressed)| !pressed)
                .count(),
            1,
            "exactly one key-up from the gesture"
        );

        inj.end_gesture();
        assert!(
            sent_keys().is_empty(),
            "end_gesture must have nothing to release, or it double-taps the key"
        );
    }

    /// Two held modifiers at once, dropped together.
    #[test]
    fn a_drop_releases_everything_that_was_held() {
        let _ = sent_keys();
        let mut inj = super::WindowsInjector::recording();
        inj.inject_touch(&touch(TouchPhase::DragStart, Modifier::SHIFT | Modifier::CONTROL));
        inj.inject_touch(&touch(TouchPhase::Move, Modifier::SHIFT | Modifier::CONTROL));
        inj.end_gesture();

        let sent = sent_keys();
        for key in [vk::SHIFT, vk::CONTROL] {
            assert!(
                sent.contains(&(key, false)),
                "{key:#x} must be released on a drop: {sent:?}"
            );
        }
    }

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
