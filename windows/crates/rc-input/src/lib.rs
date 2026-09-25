//! `rc-input` — inject iPhone input onto the Windows desktop.
//!
//! Two halves, deliberately separated:
//! - [`keymap`] + [`injector`] : **pure** translation logic
//!   (`CGKeyCode` → VK, `TouchEvent` → a list of mouse actions). Testable
//!   on any platform.
//! - [`windows_impl`] : the actual `SendInput` calls, `cfg(windows)` only.
//!
//! The cursor is **joystick-style relative**: `move` applies `dx/dy` deltas
//! to the tracked position (scaled by the screen height), and discrete
//! events fire wherever the cursor already is. This mirrors the Mac
//! receiver's `CGEventInjector` exactly so the feel matches.

pub mod injector;
pub mod keymap;

#[cfg(windows)]
pub mod windows_impl;

pub use injector::{MouseAction, ScrollPhase};
