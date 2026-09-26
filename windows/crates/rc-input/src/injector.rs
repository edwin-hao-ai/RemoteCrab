//! Pure translation of `TouchEvent` / `KeyEvent` into platform-neutral
//! actions. The Windows layer executes them; tests assert the sequence.

use rc_protocol::{KeyEvent, Modifier, ScreenInput, ScreenInputAction, TouchEvent, TouchPhase};

use crate::keymap::{self, Injected};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollPhase {
    Begin,
    Change,
    End,
    MomentumBegin,
    MomentumContinue,
    MomentumEnd,
}

/// A single mouse action to perform.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MouseAction {
    Move { x: i32, y: i32 },
    LeftDown { x: i32, y: i32 },
    LeftUp { x: i32, y: i32 },
    RightDown { x: i32, y: i32 },
    RightUp { x: i32, y: i32 },
    MiddleDown { x: i32, y: i32 },
    MiddleUp { x: i32, y: i32 },
    /// Vertical + horizontal wheel deltas in Windows units (120 = one notch).
    Wheel { dx: f64, dy: f64 },
    ScrollPhase(ScrollPhase),
}

/// Screen dimensions the cursor is clamped to. On Windows these come from
/// `GetSystemMetrics(SM_CXVIRTUALSCREEN/SM_CYVIRTUALSCREEN)`; tests pass a
/// fixed size.
#[derive(Debug, Clone, Copy)]
pub struct ScreenSize {
    pub width: f64,
    pub height: f64,
    /// Top-left of the virtual screen (multi-monitor can start negative).
    pub origin_x: f64,
    pub origin_y: f64,
}

impl ScreenSize {
    pub fn new(width: f64, height: f64) -> Self {
        ScreenSize {
            width,
            height,
            origin_x: 0.0,
            origin_y: 0.0,
        }
    }
}

/// Stateful translator: keeps the tracked cursor position, drag state and
/// scroll phase, exactly like the Mac injector.
#[derive(Debug)]
pub struct InputTranslator {
    pub last_cursor: (f64, f64),
    is_dragging: bool,
    scroll_active: bool,
    momentum_active: bool,
}

impl Default for InputTranslator {
    fn default() -> Self {
        Self::new()
    }
}

impl InputTranslator {
    pub fn new() -> Self {
        InputTranslator {
            last_cursor: (0.0, 0.0),
            is_dragging: false,
            scroll_active: false,
            momentum_active: false,
        }
    }

    /// Translate one touch event into zero or more mouse actions.
    ///
    /// `gain`: a full-phone-height swipe maps to roughly one screen of
    /// travel. The Mac uses `screenHeight * 1.2` for scrolling and
    /// `screenHeight` for cursor movement.
    pub fn touch(&mut self, event: &TouchEvent, screen: ScreenSize) -> Vec<MouseAction> {
        let mut actions = Vec::new();
        let cursor = (self.last_cursor.0.round() as i32, self.last_cursor.1.round() as i32);

        match event.phase {
            TouchPhase::Down => actions.push(MouseAction::LeftDown { x: cursor.0, y: cursor.1 }),
            TouchPhase::Up => actions.push(MouseAction::LeftUp { x: cursor.0, y: cursor.1 }),
            TouchPhase::Move => {
                // Both axes scale by the screen HEIGHT (the iOS side
                // normalizes both by the same reference — see CGEventInjector).
                let dx = event.dx as f64 * screen.height;
                let dy = event.dy as f64 * screen.height;
                let (nx, ny) = self.clamp(self.last_cursor.0 + dx, self.last_cursor.1 + dy, screen);
                self.last_cursor = (nx, ny);
                let pos = (nx.round() as i32, ny.round() as i32);
                if self.is_dragging {
                    actions.push(MouseAction::Move { x: pos.0, y: pos.1 });
                    // A drag posts a move with the left button held; the
                    // Windows layer turns this into a left-drag.
                } else {
                    actions.push(MouseAction::Move { x: pos.0, y: pos.1 });
                }
            }
            TouchPhase::DragStart => {
                actions.push(MouseAction::LeftDown { x: cursor.0, y: cursor.1 });
                self.is_dragging = true;
            }
            TouchPhase::RightDown => {
                actions.push(MouseAction::RightDown { x: cursor.0, y: cursor.1 })
            }
            TouchPhase::RightUp => actions.push(MouseAction::RightUp { x: cursor.0, y: cursor.1 }),
            TouchPhase::Click => {
                actions.push(MouseAction::LeftDown { x: cursor.0, y: cursor.1 });
                actions.push(MouseAction::LeftUp { x: cursor.0, y: cursor.1 });
            }
            TouchPhase::ThreeFingerTap => {
                // Middle click.
                actions.push(MouseAction::MiddleDown { x: cursor.0, y: cursor.1 });
                actions.push(MouseAction::MiddleUp { x: cursor.0, y: cursor.1 });
            }
            TouchPhase::ForceClick => {
                actions.push(MouseAction::RightDown { x: cursor.0, y: cursor.1 });
                actions.push(MouseAction::RightUp { x: cursor.0, y: cursor.1 });
            }
            TouchPhase::Scroll => {
                let gain = screen.height * 1.2;
                let dy = -(event.dy as f64) * gain;
                let dx = -(event.dx as f64) * gain;
                actions.push(MouseAction::Wheel { dx, dy });
                let momentum = event.momentum.unwrap_or(false);
                if momentum {
                    actions.push(MouseAction::ScrollPhase(if self.momentum_active {
                        ScrollPhase::MomentumContinue
                    } else {
                        ScrollPhase::MomentumBegin
                    }));
                    self.momentum_active = true;
                } else {
                    actions.push(MouseAction::ScrollPhase(if self.scroll_active {
                        ScrollPhase::Change
                    } else {
                        ScrollPhase::Begin
                    }));
                    self.scroll_active = true;
                }
            }
            TouchPhase::Pinch => {
                // No public API posts magnification; Ctrl+scroll is the
                // standard zoom gesture (Mac uses ⌘+scroll).
                let gain = screen.height * 1.2;
                let dy = -(event.dx as f64) * gain;
                actions.push(MouseAction::Wheel { dx: 0.0, dy });
            }
            TouchPhase::ThreeFingerSwipe => {
                // Handled by the caller as a keyboard shortcut (Task View /
                // virtual desktops) — no mouse action.
            }
        }

        if event.phase == TouchPhase::Up {
            self.is_dragging = false;
        }
        actions
    }

    /// End-of-scroll marker (the Mac posts this after a 0.18 s quiet gap).
    pub fn finish_scroll(&mut self) -> Vec<MouseAction> {
        let mut actions = Vec::new();
        if self.momentum_active {
            actions.push(MouseAction::ScrollPhase(ScrollPhase::MomentumEnd));
            self.momentum_active = false;
        }
        if self.scroll_active {
            actions.push(MouseAction::ScrollPhase(ScrollPhase::End));
            self.scroll_active = false;
        }
        actions
    }

    pub fn key(&self, event: &KeyEvent) -> Injected {
        keymap::resolve(event)
    }

    fn clamp(&self, x: f64, y: f64, screen: ScreenSize) -> (f64, f64) {
        let min_x = screen.origin_x;
        let min_y = screen.origin_y;
        let max_x = screen.origin_x + screen.width - 1.0;
        let max_y = screen.origin_y + screen.height - 1.0;
        (x.clamp(min_x, max_x), y.clamp(min_y, max_y))
    }
}

/// Modifier symbols for the connection-test UI, in Apple menu order.
pub fn modifier_symbols(modifiers: u8) -> String {
    let mut result = String::new();
    if modifiers & Modifier::CONTROL != 0 {
        result.push('⌃');
    }
    if modifiers & Modifier::OPTION != 0 {
        result.push('⌥');
    }
    if modifiers & Modifier::SHIFT != 0 {
        result.push('⇧');
    }
    if modifiers & Modifier::COMMAND != 0 {
        result.push('⌘');
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen() -> ScreenSize {
        ScreenSize::new(1000.0, 1000.0)
    }

    fn touch(phase: TouchPhase, dx: f32, dy: f32) -> TouchEvent {
        TouchEvent {
            phase,
            x: 0.5,
            y: 0.5,
            dx,
            dy,
            modifiers: 0,
            momentum: None,
            timestamp_micros: 0,
        }
    }

    #[test]
    fn move_scales_by_screen_height() {
        let mut t = InputTranslator::new();
        // A 0.1 move with a 1000px screen = 100px.
        let actions = t.touch(&touch(TouchPhase::Move, 0.1, 0.0), screen());
        assert_eq!(actions, vec![MouseAction::Move { x: 100, y: 0 }]);
        assert!((t.last_cursor.0 - 100.0).abs() < 0.01);
        assert_eq!(t.last_cursor.1, 0.0);
    }

    #[test]
    fn move_clamps_to_screen() {
        let mut t = InputTranslator::new();
        // Huge negative delta clamps to (0,0) — deterministic, like the Mac.
        let actions = t.touch(&touch(TouchPhase::Move, -5.0, -5.0), screen());
        assert_eq!(actions, vec![MouseAction::Move { x: 0, y: 0 }]);
    }

    #[test]
    fn click_is_down_then_up_at_cursor() {
        let mut t = InputTranslator::new();
        t.touch(&touch(TouchPhase::Move, 0.2, 0.2), screen());
        let actions = t.touch(&touch(TouchPhase::Click, 0.0, 0.0), screen());
        assert_eq!(
            actions,
            vec![
                MouseAction::LeftDown { x: 200, y: 200 },
                MouseAction::LeftUp { x: 200, y: 200 },
            ]
        );
    }

    #[test]
    fn drag_start_sets_left_button_down() {
        let mut t = InputTranslator::new();
        let actions = t.touch(&touch(TouchPhase::DragStart, 0.0, 0.0), screen());
        assert_eq!(actions, vec![MouseAction::LeftDown { x: 0, y: 0 }]);
        assert!(t.is_dragging);
        t.touch(&touch(TouchPhase::Up, 0.0, 0.0), screen());
        assert!(!t.is_dragging);
    }

    #[test]
    fn scroll_is_inverted_and_gained() {
        let mut t = InputTranslator::new();
        // dy = 0.1 → -(0.1) * 1000 * 1.2 = -120 (one notch).
        let actions = t.touch(&touch(TouchPhase::Scroll, 0.0, 0.1), screen());
        assert_eq!(actions.len(), 2);
        match actions[0] {
            MouseAction::Wheel { dx, dy } => {
                assert!(dx.abs() < 0.01);
                assert!((dy + 120.0).abs() < 0.01, "dy = {dy}");
            }
            other => panic!("expected Wheel, got {other:?}"),
        }
        assert_eq!(actions[1], MouseAction::ScrollPhase(ScrollPhase::Begin));
    }

    #[test]
    fn scroll_phases_begin_then_change_then_finish() {
        let mut t = InputTranslator::new();
        let first = t.touch(&touch(TouchPhase::Scroll, 0.0, 0.05), screen());
        assert!(first.contains(&MouseAction::ScrollPhase(ScrollPhase::Begin)));
        let second = t.touch(&touch(TouchPhase::Scroll, 0.0, 0.05), screen());
        assert!(second.contains(&MouseAction::ScrollPhase(ScrollPhase::Change)));
        let end = t.finish_scroll();
        assert_eq!(end, vec![MouseAction::ScrollPhase(ScrollPhase::End)]);
    }

    #[test]
    fn momentum_scroll_uses_momentum_phases() {
        let mut t = InputTranslator::new();
        let mut ev = touch(TouchPhase::Scroll, 0.0, 0.05);
        ev.momentum = Some(true);
        let first = t.touch(&ev, screen());
        assert!(first.contains(&MouseAction::ScrollPhase(ScrollPhase::MomentumBegin)));
        let second = t.touch(&ev, screen());
        assert!(second.contains(&MouseAction::ScrollPhase(ScrollPhase::MomentumContinue)));
        let end = t.finish_scroll();
        assert_eq!(end, vec![MouseAction::ScrollPhase(ScrollPhase::MomentumEnd)]);
    }

    #[test]
    fn pinch_becomes_ctrl_scroll() {
        let mut t = InputTranslator::new();
        let actions = t.touch(&touch(TouchPhase::Pinch, 0.1, 0.0), screen());
        // dy = -(0.1) * 1200 = -120 (allow f32 rounding).
        assert_eq!(actions.len(), 1);
        match actions[0] {
            MouseAction::Wheel { dx, dy } => {
                assert_eq!(dx, 0.0);
                assert!((dy + 120.0).abs() < 0.01, "dy = {dy}");
            }
            other => panic!("expected Wheel, got {other:?}"),
        }
    }

    #[test]
    fn three_finger_tap_is_middle_click() {
        let mut t = InputTranslator::new();
        let actions = t.touch(&touch(TouchPhase::ThreeFingerTap, 0.0, 0.0), screen());
        assert_eq!(
            actions,
            vec![
                MouseAction::MiddleDown { x: 0, y: 0 },
                MouseAction::MiddleUp { x: 0, y: 0 },
            ]
        );
    }

    #[test]
    fn modifier_symbols_order() {
        let all = Modifier::CONTROL | Modifier::OPTION | Modifier::SHIFT | Modifier::COMMAND;
        assert_eq!(modifier_symbols(all), "⌃⌥⇧⌘");
        assert_eq!(modifier_symbols(Modifier::COMMAND), "⌘");
    }
}

/// Vertical wheel units per 1.0 of normalized scroll delta. Windows wants
/// `120` per notch; ~10 notches for a full-window drag feels close to the Mac.
const SCROLL_UNITS: f64 = 1200.0;

/// Translate one mirror `ScreenInput` into absolute mouse actions.
///
/// The window frame is `origin` (top-left in virtual-desktop pixels) and
/// `size`; `(u, v)` is normalized inside the window. Modifiers are applied by
/// the caller (the Windows layer holds the VKs around these actions).
pub fn screen_actions(
    input: &ScreenInput,
    origin: (f64, f64),
    size: (f64, f64),
) -> Vec<MouseAction> {
    let point = |u: f32, v: f32| {
        let u = u.clamp(0.0, 1.0) as f64;
        let v = v.clamp(0.0, 1.0) as f64;
        (
            (origin.0 + u * size.0).round() as i32,
            (origin.1 + v * size.1).round() as i32,
        )
    };
    let (x, y) = point(input.u, input.v);
    match input.action {
        ScreenInputAction::Click => vec![
            MouseAction::Move { x, y },
            MouseAction::LeftDown { x, y },
            MouseAction::LeftUp { x, y },
        ],
        ScreenInputAction::DragStart => {
            vec![MouseAction::Move { x, y }, MouseAction::LeftDown { x, y }]
        }
        ScreenInputAction::DragMove => vec![MouseAction::Move { x, y }],
        ScreenInputAction::DragEnd => {
            vec![MouseAction::Move { x, y }, MouseAction::LeftUp { x, y }]
        }
        ScreenInputAction::RightClick => vec![
            MouseAction::Move { x, y },
            MouseAction::RightDown { x, y },
            MouseAction::RightUp { x, y },
        ],
        ScreenInputAction::Scroll => vec![MouseAction::Wheel {
            dx: input.dx as f64 * SCROLL_UNITS,
            dy: input.dy as f64 * SCROLL_UNITS,
        }],
    }
}

#[cfg(test)]
mod screen_tests {
    use super::*;
    use rc_protocol::ScreenInputAction;

    fn input(action: ScreenInputAction, u: f32, v: f32) -> ScreenInput {
        ScreenInput {
            action,
            u,
            v,
            dx: 0.0,
            dy: 0.0,
            modifiers: 0,
            click_count: 1,
            timestamp_micros: 0,
        }
    }

    #[test]
    fn click_maps_to_absolute_move_down_up() {
        let actions = screen_actions(&input(ScreenInputAction::Click, 0.5, 0.5), (100.0, 50.0), (200.0, 100.0));
        assert_eq!(
            actions,
            vec![
                MouseAction::Move { x: 200, y: 100 },
                MouseAction::LeftDown { x: 200, y: 100 },
                MouseAction::LeftUp { x: 200, y: 100 },
            ]
        );
    }

    #[test]
    fn drag_sequence_holds_and_releases() {
        let start = screen_actions(&input(ScreenInputAction::DragStart, 0.0, 0.0), (10.0, 20.0), (100.0, 50.0));
        assert_eq!(start, vec![MouseAction::Move { x: 10, y: 20 }, MouseAction::LeftDown { x: 10, y: 20 }]);
        let end = screen_actions(&input(ScreenInputAction::DragEnd, 1.0, 1.0), (10.0, 20.0), (100.0, 50.0));
        assert_eq!(end, vec![MouseAction::Move { x: 110, y: 70 }, MouseAction::LeftUp { x: 110, y: 70 }]);
    }

    #[test]
    fn clamp_keeps_clicks_inside_the_window() {
        let actions = screen_actions(&input(ScreenInputAction::Click, 2.0, -1.0), (0.0, 0.0), (100.0, 100.0));
        assert_eq!(actions[0], MouseAction::Move { x: 100, y: 0 });
    }

    #[test]
    fn scroll_becomes_wheel_deltas() {
        let mut sc = input(ScreenInputAction::Scroll, 0.0, 0.0);
        // 1/16 is exact in f32, so 0.0625 * 1200 == 75.0 exactly.
        sc.dy = 0.0625;
        let actions = screen_actions(&sc, (0.0, 0.0), (100.0, 100.0));
        assert_eq!(actions, vec![MouseAction::Wheel { dx: 0.0, dy: 75.0 }]);
    }
}
