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
///
/// `Clone` but not `Copy`: [`MouseAction::ModifierKeys`] owns the virtual-key
/// list, and the alternative — a fixed-size array plus a length — would buy
/// nothing for three keys.
#[derive(Debug, Clone, PartialEq)]
pub enum MouseAction {
    Move {
        x: i32,
        y: i32,
    },
    LeftDown {
        x: i32,
        y: i32,
    },
    LeftUp {
        x: i32,
        y: i32,
    },
    RightDown {
        x: i32,
        y: i32,
    },
    RightUp {
        x: i32,
        y: i32,
    },
    MiddleDown {
        x: i32,
        y: i32,
    },
    MiddleUp {
        x: i32,
        y: i32,
    },
    /// Vertical + horizontal wheel deltas in Windows units (120 = one notch).
    Wheel {
        dx: f64,
        dy: f64,
    },
    /// A wheel event with Ctrl held — the Windows equivalent of a pinch-zoom
    /// (`Ctrl+wheel` zooms in most apps; a bare wheel would just scroll).
    CtrlWheel {
        dx: f64,
        dy: f64,
    },
    ScrollPhase(ScrollPhase),
    /// Press or release the virtual keys for a modifier bitmask.
    ///
    /// The Mac attaches the modifier mask to each event as `CGEvent.flags`,
    /// so nothing needs holding. `SendInput` has no equivalent, so the
    /// translator emits the transitions and the platform layer holds the keys
    /// down — which is what makes ⇧-click extend a selection and ⌥-drag
    /// move a window, instead of both silently doing the plain thing.
    ModifierKeys {
        vks: Vec<u16>,
        pressed: bool,
    },
}

/// A three/four-finger swipe maps to a Windows task/desktop shortcut (the
/// Mac maps the same gesture to Mission Control).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwipeShortcut {
    /// Vertical swipe → Task View (`Win+Tab`).
    TaskView,
    /// Horizontal swipe left → previous virtual desktop (`Ctrl+Win+Left`).
    DesktopLeft,
    /// Horizontal swipe right → next virtual desktop (`Ctrl+Win+Right`).
    DesktopRight,
}

/// Which shortcut a swipe `(dx, dy)` should trigger, or `None` when the
/// travel is too small to be a swipe.
pub fn swipe_shortcut(dx: f32, dy: f32) -> Option<SwipeShortcut> {
    const MIN_TRAVEL: f32 = 0.05;
    if dx.abs() < MIN_TRAVEL && dy.abs() < MIN_TRAVEL {
        return None;
    }
    if dx.abs() > dy.abs() {
        Some(if dx < 0.0 {
            SwipeShortcut::DesktopLeft
        } else {
            SwipeShortcut::DesktopRight
        })
    } else {
        Some(SwipeShortcut::TaskView)
    }
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
    /// The virtual keys currently held down on behalf of the trackpad.
    held_vks: Vec<u16>,
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
            held_vks: Vec::new(),
        }
    }

    /// Translate one touch event into zero or more mouse actions.
    ///
    /// `gain`: a full-phone-height swipe maps to roughly one screen of
    /// travel. The Mac uses `screenHeight * 1.2` for scrolling and
    /// `screenHeight` for cursor movement.
    pub fn touch(&mut self, event: &TouchEvent, screen: ScreenSize) -> Vec<MouseAction> {
        let mut actions = Vec::new();
        let cursor = (
            self.last_cursor.0.round() as i32,
            self.last_cursor.1.round() as i32,
        );

        // Hold the trackpad's modifiers for the whole gesture, releasing them
        // when the user lets go.
        //
        // The diff is taken on the *mapped* virtual keys, not on the raw bits,
        // because ⌘ and ⌃ both collapse to Ctrl: a user who slides from ⌘ to ⌃
        // mid-drag changes the bits without changing the key, and diffing the
        // bits would emit "press Ctrl, release Ctrl" and drop the modifier.
        let want = keymap::modifier_vks(event.modifiers);
        for vk in want.iter().filter(|v| !self.held_vks.contains(v)) {
            actions.push(MouseAction::ModifierKeys {
                vks: vec![*vk],
                pressed: true,
            });
        }
        for vk in self.held_vks.iter().filter(|v| !want.contains(v)) {
            actions.push(MouseAction::ModifierKeys {
                vks: vec![*vk],
                pressed: false,
            });
        }
        self.held_vks = want;

        match event.phase {
            TouchPhase::Down => actions.push(MouseAction::LeftDown {
                x: cursor.0,
                y: cursor.1,
            }),
            TouchPhase::Up => actions.push(MouseAction::LeftUp {
                x: cursor.0,
                y: cursor.1,
            }),
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
                actions.push(MouseAction::LeftDown {
                    x: cursor.0,
                    y: cursor.1,
                });
                self.is_dragging = true;
            }
            TouchPhase::RightDown => actions.push(MouseAction::RightDown {
                x: cursor.0,
                y: cursor.1,
            }),
            TouchPhase::RightUp => actions.push(MouseAction::RightUp {
                x: cursor.0,
                y: cursor.1,
            }),
            TouchPhase::Click => {
                actions.push(MouseAction::LeftDown {
                    x: cursor.0,
                    y: cursor.1,
                });
                actions.push(MouseAction::LeftUp {
                    x: cursor.0,
                    y: cursor.1,
                });
            }
            TouchPhase::ThreeFingerTap => {
                // Middle click.
                actions.push(MouseAction::MiddleDown {
                    x: cursor.0,
                    y: cursor.1,
                });
                actions.push(MouseAction::MiddleUp {
                    x: cursor.0,
                    y: cursor.1,
                });
            }
            TouchPhase::ForceClick => {
                actions.push(MouseAction::RightDown {
                    x: cursor.0,
                    y: cursor.1,
                });
                actions.push(MouseAction::RightUp {
                    x: cursor.0,
                    y: cursor.1,
                });
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
                // No public API posts magnification; Ctrl+wheel is the
                // standard zoom gesture (the Mac uses ⌘+scroll). Without the
                // Ctrl hold this was a plain scroll — pinch never zoomed.
                let gain = screen.height * 1.2;
                let dy = -(event.dx as f64) * gain;
                actions.push(MouseAction::CtrlWheel { dx: 0.0, dy });
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

    /// Direction, as an invariant rather than a description.
    ///
    /// `move_clamps_to_screen` cannot catch an inverted axis: +5.0 and -5.0
    /// both clamp to (0,0), so it passes just as happily against a negated
    /// delta as against a correct one. A user reporting "the pointer goes
    /// right when my finger goes left" needs a test that starts from the
    /// middle of the screen — where nothing clamps — and moves a little.
    ///
    /// The pairing is the point: equal and opposite deltas must land
    /// symmetrically about the start, so no single gain or scale factor can
    /// make this pass while the axis is flipped.
    #[test]
    fn a_move_preserves_the_sign_of_its_delta() {
        // Start from the middle of the screen, where nothing clamps.
        let centre = |mut t: InputTranslator| {
            t.touch(&touch(TouchPhase::Move, 0.5, 0.0), screen());
            assert_eq!(t.last_cursor.0, 500.0, "the cursor must start centred");
            t
        };

        let mut right = centre(InputTranslator::new());
        right.touch(&touch(TouchPhase::Move, 0.01, 0.0), screen());
        assert!(
            right.last_cursor.0 > 500.0,
            "a positive dx must move the cursor toward larger x, got {:?}",
            right.last_cursor
        );

        let mut left = centre(InputTranslator::new());
        left.touch(&touch(TouchPhase::Move, -0.01, 0.0), screen());
        assert!(
            left.last_cursor.0 < 500.0,
            "a negative dx must move the cursor toward smaller x, got {:?}",
            left.last_cursor
        );

        // Equal and opposite deltas must travel equally far, so no gain or
        // scale factor can make this pass while the axis is flipped.
        let travelled_right = right.last_cursor.0 - 500.0;
        let travelled_left = 500.0 - left.last_cursor.0;
        assert!(
            (travelled_right - travelled_left).abs() < 0.01,
            "opposite deltas must travel equally far, {travelled_right} vs {travelled_left}"
        );
    }

    /// The same invariant on the vertical axis, which the mirror path flips
    /// relative to the camera path — so it gets its own assertion rather than
    /// being folded into the horizontal one.
    #[test]
    fn a_move_preserves_the_sign_of_a_vertical_delta() {
        let mut down = InputTranslator::new();
        down.touch(&touch(TouchPhase::Move, 0.0, 0.5), screen());
        assert_eq!(down.last_cursor.1, 500.0);
        down.touch(&touch(TouchPhase::Move, 0.0, 0.01), screen());
        assert!(
            down.last_cursor.1 > 500.0,
            "a positive dy must move the cursor toward larger y, got {:?}",
            down.last_cursor
        );

        let mut up = InputTranslator::new();
        up.touch(&touch(TouchPhase::Move, 0.0, 0.5), screen());
        up.touch(&touch(TouchPhase::Move, 0.0, -0.01), screen());
        assert!(
            up.last_cursor.1 < 500.0,
            "a negative dy must move the cursor toward smaller y, got {:?}",
            up.last_cursor
        );
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
        match &actions[0] {
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
        assert_eq!(
            end,
            vec![MouseAction::ScrollPhase(ScrollPhase::MomentumEnd)]
        );
    }

    #[test]
    fn pinch_becomes_ctrl_scroll() {
        let mut t = InputTranslator::new();
        let actions = t.touch(&touch(TouchPhase::Pinch, 0.1, 0.0), screen());
        // dy = -(0.1) * 1200 = -120 (allow f32 rounding).
        assert_eq!(actions.len(), 1);
        match &actions[0] {
            MouseAction::CtrlWheel { dx, dy } => {
                assert_eq!(*dx, 0.0);
                assert!((*dy + 120.0).abs() < 0.01, "dy = {dy}");
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
    fn swipe_shortcut_picks_task_view_for_vertical() {
        assert_eq!(swipe_shortcut(0.0, -0.2), Some(SwipeShortcut::TaskView));
        assert_eq!(swipe_shortcut(0.01, 0.2), Some(SwipeShortcut::TaskView));
    }

    #[test]
    fn swipe_shortcut_picks_desktops_for_horizontal() {
        assert_eq!(swipe_shortcut(-0.2, 0.0), Some(SwipeShortcut::DesktopLeft));
        assert_eq!(swipe_shortcut(0.2, 0.0), Some(SwipeShortcut::DesktopRight));
    }

    #[test]
    fn swipe_shortcut_ignores_tiny_travel() {
        assert_eq!(swipe_shortcut(0.01, 0.01), None);
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
        ScreenInputAction::Click => {
            // Windows has no click-state field; post the down/up pair
            // `clickCount` times so the OS sees a real double/triple click
            // (word / paragraph select), matching the Mac's clickState.
            let count = input.click_count.clamp(1, 3) as usize;
            let mut actions = Vec::with_capacity(count * 2 + 1);
            actions.push(MouseAction::Move { x, y });
            for _ in 0..count {
                actions.push(MouseAction::LeftDown { x, y });
                actions.push(MouseAction::LeftUp { x, y });
            }
            actions
        }
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
        let actions = screen_actions(
            &input(ScreenInputAction::Click, 0.5, 0.5),
            (100.0, 50.0),
            (200.0, 100.0),
        );
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
        let start = screen_actions(
            &input(ScreenInputAction::DragStart, 0.0, 0.0),
            (10.0, 20.0),
            (100.0, 50.0),
        );
        assert_eq!(
            start,
            vec![
                MouseAction::Move { x: 10, y: 20 },
                MouseAction::LeftDown { x: 10, y: 20 }
            ]
        );
        let end = screen_actions(
            &input(ScreenInputAction::DragEnd, 1.0, 1.0),
            (10.0, 20.0),
            (100.0, 50.0),
        );
        assert_eq!(
            end,
            vec![
                MouseAction::Move { x: 110, y: 70 },
                MouseAction::LeftUp { x: 110, y: 70 }
            ]
        );
    }

    #[test]
    fn clamp_keeps_clicks_inside_the_window() {
        let actions = screen_actions(
            &input(ScreenInputAction::Click, 2.0, -1.0),
            (0.0, 0.0),
            (100.0, 100.0),
        );
        assert_eq!(actions[0], MouseAction::Move { x: 100, y: 0 });
    }

    #[test]
    fn double_click_posts_two_down_up_pairs() {
        let mut d = input(ScreenInputAction::Click, 0.5, 0.5);
        d.click_count = 2;
        let actions = screen_actions(&d, (0.0, 0.0), (200.0, 200.0));
        let downs = actions
            .iter()
            .filter(|a| matches!(a, MouseAction::LeftDown { .. }))
            .count();
        let ups = actions
            .iter()
            .filter(|a| matches!(a, MouseAction::LeftUp { .. }))
            .count();
        assert_eq!(
            (downs, ups),
            (2, 2),
            "double click = two down/up pairs; got {actions:?}"
        );
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

#[cfg(test)]
mod modifier_tests {
    use super::*;
    use crate::keymap::vk;

    fn touch(phase: TouchPhase, modifiers: u8) -> TouchEvent {
        TouchEvent {
            phase,
            x: 0.5,
            y: 0.5,
            dx: 0.0,
            dy: 0.0,
            modifiers,
            momentum: None,
            timestamp_micros: 0,
        }
    }

    fn vks_for(actions: &[MouseAction], pressed: bool) -> Vec<u16> {
        actions
            .iter()
            .filter_map(|a| match a {
                MouseAction::ModifierKeys { vks, pressed: p } if *p == pressed => Some(vks.clone()),
                _ => None,
            })
            .flatten()
            .collect()
    }

    /// ⇧-click is how a trackpad user extends a selection, and on Windows it
    /// used to perform a plain click: `TouchEvent.modifiers` was read nowhere
    /// in this crate, so the bitmask the phone sends was simply dropped.
    #[test]
    fn shift_click_holds_shift() {
        let mut t = InputTranslator::new();
        let screen = ScreenSize::new(1000.0, 1000.0);
        let actions = t.touch(&touch(TouchPhase::Click, Modifier::SHIFT), screen);
        assert_eq!(vks_for(&actions, true), vec![vk::SHIFT]);
        assert!(
            vks_for(&actions, false).is_empty(),
            "still held after the tap"
        );
        // …and released when the user lets go.
        let up = t.touch(&touch(TouchPhase::Up, Modifier::NONE), screen);
        assert_eq!(vks_for(&up, false), vec![vk::SHIFT]);
    }

    /// ⌥-drag is how a Mac user moves a window. On Windows it used to be a
    /// plain drag, which drags a *selection* instead.
    #[test]
    fn option_drag_holds_alt_for_the_whole_drag() {
        let mut t = InputTranslator::new();
        let screen = ScreenSize::new(1000.0, 1000.0);
        let start = t.touch(&touch(TouchPhase::DragStart, Modifier::OPTION), screen);
        assert_eq!(vks_for(&start, true), vec![vk::MENU]);
        let mid = t.touch(&touch(TouchPhase::Move, Modifier::OPTION), screen);
        assert!(
            vks_for(&mid, true).is_empty() && vks_for(&mid, false).is_empty(),
            "a held modifier must not be re-sent every move: {mid:?}"
        );
        let end = t.touch(&touch(TouchPhase::Up, Modifier::NONE), screen);
        assert_eq!(vks_for(&end, false), vec![vk::MENU]);
    }

    /// ⌘ and ⌃ both collapse to Ctrl, so a user sliding from one to the other
    /// mid-gesture changes the bits without changing the key. Diffing the raw
    /// bits would emit "press Ctrl, release Ctrl" and drop the modifier.
    #[test]
    fn sliding_from_command_to_control_keeps_the_modifier_held() {
        let mut t = InputTranslator::new();
        let screen = ScreenSize::new(1000.0, 1000.0);
        t.touch(&touch(TouchPhase::DragStart, Modifier::COMMAND), screen);
        let swapped = t.touch(&touch(TouchPhase::Move, Modifier::CONTROL), screen);
        assert!(
            vks_for(&swapped, false).is_empty(),
            "Ctrl must stay held across a ⌘→⌃ slide: {swapped:?}"
        );
    }

    #[test]
    fn a_chord_holds_every_modifier() {
        let mut t = InputTranslator::new();
        let screen = ScreenSize::new(1000.0, 1000.0);
        let actions = t.touch(
            &touch(
                TouchPhase::Click,
                Modifier::SHIFT | Modifier::CONTROL | Modifier::OPTION,
            ),
            screen,
        );
        let mut held = vks_for(&actions, true);
        held.sort_unstable();
        // VK_SHIFT 0x10, VK_CONTROL 0x11, VK_MENU 0x12.
        let mut want = vec![vk::SHIFT, vk::CONTROL, vk::MENU];
        want.sort_unstable();
        assert_eq!(
            held, want,
            "every held modifier must reach the platform layer"
        );
    }

    #[test]
    fn no_modifier_means_no_key_traffic_at_all() {
        let mut t = InputTranslator::new();
        let screen = ScreenSize::new(1000.0, 1000.0);
        let actions = t.touch(&touch(TouchPhase::Click, Modifier::NONE), screen);
        assert!(vks_for(&actions, true).is_empty());
        assert!(vks_for(&actions, false).is_empty());
        assert!(
            actions
                .iter()
                .all(|a| !matches!(a, MouseAction::ModifierKeys { .. })),
            "a plain tap must not inject any key: {actions:?}"
        );
    }
}

/// Windows counts the wheel in **notches of 120 units**; macOS has no such
/// unit and takes continuous pixel deltas. The port posted `delta.round()` per
/// event behind a `|d| >= 1.0` guard, which is wrong twice over: a slow scroll
/// produced deltas below 1.0 and was **silently dropped**, and a delta of 1.4
/// became one whole notch. The result is a trackpad that either does nothing
/// or jumps — the single biggest reason it felt unlike the Mac's.
///
/// Real Windows precision touchpads do not have that problem because the driver
/// **accumulates** fractional deltas and emits a notch when the accumulator
/// crosses 120. Same total travel, delivered evenly, and nothing is lost on the
/// way. Pure and I/O-free so the pacing is testable without a mouse.
#[derive(Debug, Clone)]
pub struct WheelAccumulator {
    vertical: f64,
    horizontal: f64,
    units_per_notch: f64,
}

impl Default for WheelAccumulator {
    fn default() -> Self {
        Self::new(Self::WHEEL_DELTA)
    }
}

impl WheelAccumulator {
    pub const WHEEL_DELTA: f64 = 120.0;

    pub fn new(units_per_notch: f64) -> Self {
        assert!(units_per_notch > 0.0, "a notch has to be worth something");
        WheelAccumulator {
            vertical: 0.0,
            horizontal: 0.0,
            units_per_notch,
        }
    }

    /// Feed a pixel delta; get back whole notches to post this event.
    ///
    /// Both axes are consumed independently so a diagonal flick does not leak
    /// leftover into the other direction, and both are truncated rather than
    /// rounded so the accumulator never gains or loses distance — a rounded
    /// remainder would bias scrolling by up to half a notch per event.
    pub fn take(&mut self, dx: f64, dy: f64) -> (i32, i32) {
        let per = self.units_per_notch;
        self.vertical += dy;
        self.horizontal += dx;
        let v = (self.vertical / per).trunc();
        let h = (self.horizontal / per).trunc();
        self.vertical -= v * per;
        self.horizontal -= h * per;
        (h as i32, v as i32)
    }

    /// Fraction of a notch still owed, per axis. Exposed so the platform layer
    /// can show a partial wheel in a diagnostics view, and so a test can prove
    /// nothing is discarded at the end of a gesture.
    pub fn remainder(&self) -> (f64, f64) {
        (self.horizontal, self.vertical)
    }

    /// Drop the remainder — the end of a gesture.
    ///
    /// Only for a gesture that is *cancelled* (the finger went down, or the
    /// link dropped). A gesture that simply ends must keep the remainder:
    /// throwing away up to 119 units is a visible stutter on the way out.
    pub fn flush(&mut self) {
        self.vertical = 0.0;
        self.horizontal = 0.0;
    }
}

#[cfg(test)]
mod wheel_tests {
    use super::WheelAccumulator;

    #[test]
    fn a_slow_scroll_accumulates_instead_of_being_dropped() {
        let mut w = WheelAccumulator::default();
        // 20 events of 3 units: every one of them is below the old `>= 1.0`
        // round threshold's useful range and the old code posted 20 notches.
        // The right answer is zero notches now and one notch once 120 units
        // of travel have actually happened.
        let mut notches = 0;
        for _ in 0..20 {
            notches += w.take(0.0, 3.0).1;
        }
        assert_eq!(notches, 0, "60 units is half a notch");
        assert_eq!(w.remainder().1, 60.0);
        notches += w.take(0.0, 3.0).1;
        assert_eq!(notches, 0);
        notches += w.take(0.0, 3.0).1; // 66
        assert_eq!(notches, 0);
        for _ in 0..18 {
            notches += w.take(0.0, 3.0).1;
        }
        assert_eq!(notches, 1, "120 units is exactly one notch");
    }

    /// The property that matters: the total distance posted must equal the
    /// distance travelled, no matter how it is chopped up. An accumulator that
    /// rounds per event is off by up to half a notch each time.
    #[test]
    fn distance_is_conserved_however_the_gesture_is_chopped() {
        for chunk in [1.0, 3.0, 7.5, 119.0, 121.0, 500.0] {
            let mut w = WheelAccumulator::default();
            let mut travelled = 0.0;
            let mut posted = 0;
            for _ in 0..10 {
                travelled += chunk;
                posted += w.take(0.0, chunk).1.abs();
            }
            let owed = w.remainder().1;
            assert_eq!(
                posted as f64 * WheelAccumulator::WHEEL_DELTA + owed,
                travelled,
                "chunk {chunk}: posted {posted} notches + {owed} owed != {travelled}"
            );
        }
    }

    /// A single large flick must come out as the right number of notches at
    /// once, not truncated to one.
    #[test]
    fn a_big_flick_emits_every_notch_it_earned() {
        let mut w = WheelAccumulator::default();
        // One phone-height swipe with the port's 1.2x gain on a 1000px screen.
        let (h, v) = w.take(0.0, 1200.0);
        assert_eq!(v, 10);
        assert_eq!(h, 0);
        assert_eq!(w.remainder(), (0.0, 0.0));
    }

    #[test]
    fn the_two_axes_do_not_leak_into_each_other() {
        let mut w = WheelAccumulator::default();
        let (h, v) = w.take(60.0, 0.0);
        assert_eq!((h, v), (0, 0), "half a notch horizontally is nothing");
        let (h, v) = w.take(60.0, 0.0);
        assert_eq!(h, 1, "…and the second half completes it");
        assert_eq!(v, 0, "a horizontal gesture must not scroll vertically");
        assert_eq!(w.remainder().1, 0.0);
    }

    #[test]
    fn flushing_drops_the_remainder_only_when_asked() {
        let mut w = WheelAccumulator::default();
        w.take(0.0, 100.0);
        assert_eq!(w.remainder().1, 100.0, "a real gesture keeps the remainder");
        w.flush();
        assert_eq!(w.remainder().1, 0.0);
    }
}
