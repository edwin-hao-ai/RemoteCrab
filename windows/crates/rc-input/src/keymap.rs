//! macOS `CGKeyCode` → Windows virtual-key (VK) mapping.
//!
//! The iOS app sends `KeyEvent.keycode` as a **macOS** virtual keycode (see
//! `CGEventInjector.swift`'s US-ANSI table). Windows needs its own key codes,
//! so this module translates. The mapping is pure and unit-tested.
//!
//! Modifier policy (deliberate): both the iOS `command` bit and the
//! `control` bit map to Windows `Ctrl`, so a Mac muscle-memory `⌘C` becomes
//! `Ctrl+C` on Windows. `option` maps to `Alt`, `shift` to `Shift`.

use rc_protocol::{KeyEvent, Modifier};

/// Windows virtual-key codes we use (subset of `winuser.h` `VK_*`).
pub mod vk {
    pub const BACK: u16 = 0x08;
    pub const TAB: u16 = 0x09;
    pub const RETURN: u16 = 0x0D;
    pub const SHIFT: u16 = 0x10;
    pub const CONTROL: u16 = 0x11;
    pub const MENU: u16 = 0x12; // Alt
    pub const ESCAPE: u16 = 0x1B;
    pub const SPACE: u16 = 0x20;
    pub const PRIOR: u16 = 0x21; // Page Up
    pub const NEXT: u16 = 0x22; // Page Down
    pub const END: u16 = 0x23;
    pub const HOME: u16 = 0x24;
    pub const LEFT: u16 = 0x25;
    pub const UP: u16 = 0x26;
    pub const RIGHT: u16 = 0x27;
    pub const DOWN: u16 = 0x28;
    pub const DELETE: u16 = 0x2E;
    pub const LWIN: u16 = 0x5B;
    pub const OEM_1: u16 = 0xBA; // ; :
    pub const OEM_PLUS: u16 = 0xBB; // = +
    pub const OEM_COMMA: u16 = 0xBC; // , <
    pub const OEM_MINUS: u16 = 0xBD; // - _
    pub const OEM_PERIOD: u16 = 0xBE; // . >
    pub const OEM_2: u16 = 0xBF; // / ?
    pub const OEM_3: u16 = 0xC0; // ` ~
    pub const OEM_4: u16 = 0xDB; // [ {
    pub const OEM_5: u16 = 0xDC; // \ |
    pub const OEM_6: u16 = 0xDD; // ] }
    pub const OEM_7: u16 = 0xDE; // ' "
    pub const F1: u16 = 0x70;
}

/// Translate a macOS `CGKeyCode` to a Windows VK code, if we know it.
pub fn cg_to_vk(cg: u16) -> Option<u16> {
    let vk = match cg {
        // Letters (CGKeyCode order is the classic Mac keyboard).
        0x00 => 0x41, // A
        0x01 => 0x53, // S
        0x02 => 0x44, // D
        0x03 => 0x46, // F
        0x04 => 0x48, // H
        0x05 => 0x47, // G
        0x06 => 0x5A, // Z
        0x07 => 0x58, // X
        0x08 => 0x43, // C
        0x09 => 0x56, // V
        0x0B => 0x42, // B
        0x0C => 0x51, // Q
        0x0D => 0x57, // W
        0x0E => 0x45, // E
        0x0F => 0x52, // R
        0x10 => 0x59, // Y
        0x11 => 0x54, // T
        0x1F => 0x4F, // O
        0x20 => 0x55, // U
        0x22 => 0x49, // I
        0x23 => 0x50, // P
        0x25 => 0x4C, // L
        0x26 => 0x4A, // J
        0x28 => 0x4B, // K
        0x2D => 0x4E, // N
        0x2E => 0x4D, // M
        // Digits
        0x12 => 0x31, // 1
        0x13 => 0x32, // 2
        0x14 => 0x33, // 3
        0x15 => 0x34, // 4
        0x16 => 0x36, // 6
        0x17 => 0x35, // 5
        0x19 => 0x39, // 9
        0x1A => 0x37, // 7
        0x1C => 0x38, // 8
        0x1D => 0x30, // 0
        // Punctuation
        0x18 => vk::OEM_PLUS,   // =
        0x1B => vk::OEM_MINUS,  // -
        0x1E => vk::OEM_6,      // ]
        0x21 => vk::OEM_4,      // [
        0x27 => vk::OEM_7,      // '
        0x29 => vk::OEM_1,      // ;
        0x2A => vk::OEM_5,      // backslash
        0x2B => vk::OEM_COMMA,  // ,
        0x2C => vk::OEM_2,      // /
        0x2F => vk::OEM_PERIOD, // .
        0x32 => vk::OEM_3,      // `
        // Whitespace / control
        0x24 => vk::RETURN,
        0x30 => vk::TAB,
        0x31 => vk::SPACE,
        0x33 => vk::BACK,   // Delete (backspace)
        0x35 => vk::ESCAPE,
        0x75 => vk::DELETE, // Forward delete
        // Modifiers
        0x37 | 0x36 => vk::LWIN,    // Command → Win (rarely used; see policy)
        0x38 | 0x3C => vk::SHIFT,   // Shift
        0x3A | 0x3D => vk::MENU,    // Option → Alt
        0x3B | 0x3E => vk::CONTROL, // Control
        0x39 => 0x14,              // Caps Lock
        // Navigation
        0x7B => vk::LEFT,
        0x7C => vk::RIGHT,
        0x7D => vk::DOWN,
        0x7E => vk::UP,
        0x73 => vk::HOME,
        0x77 => vk::END,
        0x74 => vk::PRIOR, // Page Up
        0x79 => vk::NEXT,  // Page Down
        // Function keys (F1..F12)
        0x7A => vk::F1,
        0x78 => vk::F1 + 1,
        0x63 => vk::F1 + 2,
        0x76 => vk::F1 + 3,
        0x60 => vk::F1 + 4,
        0x61 => vk::F1 + 5,
        0x62 => vk::F1 + 6,
        0x64 => vk::F1 + 7,
        0x65 => vk::F1 + 8,
        0x6D => vk::F1 + 9,
        0x67 => vk::F1 + 10,
        0x6F => vk::F1 + 11,
        _ => return None,
    };
    Some(vk)
}

/// Translate the iOS modifier bitmask to the Windows modifier VKs, in the
/// order they should be pressed.
///
/// `command` (⌘) and `control` (⌃) both collapse to Ctrl so that a Mac-style
/// `⌘C` becomes `Ctrl+C`.
pub fn modifier_vks(modifiers: u8) -> Vec<u16> {
    let mut out = Vec::new();
    let ctrl = modifiers & (Modifier::COMMAND | Modifier::CONTROL) != 0;
    if ctrl {
        out.push(vk::CONTROL);
    }
    if modifiers & Modifier::OPTION != 0 {
        out.push(vk::MENU);
    }
    if modifiers & Modifier::SHIFT != 0 {
        out.push(vk::SHIFT);
    }
    out
}

/// The result of resolving a `KeyEvent` into something injectable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Injected {
    /// A keycode event: press/release this VK with these modifiers held.
    Key { vk: u16, down: bool, modifiers: u8 },
    /// A text event: type these UTF-16 code units (IME already applied).
    Text(Vec<u16>),
    /// Unknown keycode — nothing to inject.
    Unknown,
}

/// Resolve a `KeyEvent` into an [`Injected`] action. Pure; the Windows
/// layer merely performs the `SendInput` calls.
pub fn resolve(event: &KeyEvent) -> Injected {
    use rc_protocol::KeyAction;
    match event.action {
        KeyAction::Text => match &event.text {
            Some(t) if !t.is_empty() => Injected::Text(t.encode_utf16().collect()),
            _ => Injected::Unknown,
        },
        KeyAction::Down | KeyAction::Up => match event.keycode.and_then(cg_to_vk) {
            Some(vk) => Injected::Key {
                vk,
                down: event.action == KeyAction::Down,
                modifiers: event.modifiers,
            },
            None => Injected::Unknown,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rc_protocol::{KeyAction, KeyEvent};

    #[test]
    fn maps_letters_and_digits() {
        assert_eq!(cg_to_vk(0x00), Some(0x41)); // A
        assert_eq!(cg_to_vk(0x08), Some(0x43)); // C
        assert_eq!(cg_to_vk(0x0C), Some(0x51)); // Q
        assert_eq!(cg_to_vk(0x12), Some(0x31)); // 1
    }

    #[test]
    fn maps_special_keys() {
        assert_eq!(cg_to_vk(0x24), Some(vk::RETURN));
        assert_eq!(cg_to_vk(0x30), Some(vk::TAB));
        assert_eq!(cg_to_vk(0x31), Some(vk::SPACE));
        assert_eq!(cg_to_vk(0x33), Some(vk::BACK));
        assert_eq!(cg_to_vk(0x35), Some(vk::ESCAPE));
        assert_eq!(cg_to_vk(0x7B), Some(vk::LEFT));
        assert_eq!(cg_to_vk(0x7E), Some(vk::UP));
    }

    #[test]
    fn maps_punctuation() {
        assert_eq!(cg_to_vk(0x18), Some(vk::OEM_PLUS)); // =
        assert_eq!(cg_to_vk(0x1B), Some(vk::OEM_MINUS)); // -
        assert_eq!(cg_to_vk(0x2F), Some(vk::OEM_PERIOD)); // .
        assert_eq!(cg_to_vk(0x32), Some(vk::OEM_3)); // `
    }

    #[test]
    fn unknown_keycode_is_none() {
        assert_eq!(cg_to_vk(0xFFFF), None);
    }

    #[test]
    fn command_and_control_both_map_to_ctrl() {
        // ⌘ alone → Ctrl.
        assert_eq!(modifier_vks(Modifier::COMMAND), vec![vk::CONTROL]);
        // ⌃ alone → Ctrl.
        assert_eq!(modifier_vks(Modifier::CONTROL), vec![vk::CONTROL]);
        // Both → a single Ctrl (no duplicate).
        assert_eq!(
            modifier_vks(Modifier::COMMAND | Modifier::CONTROL),
            vec![vk::CONTROL]
        );
    }

    #[test]
    fn option_maps_to_alt_shift_to_shift() {
        assert_eq!(modifier_vks(Modifier::OPTION), vec![vk::MENU]);
        assert_eq!(modifier_vks(Modifier::SHIFT), vec![vk::SHIFT]);
        assert_eq!(
            modifier_vks(Modifier::COMMAND | Modifier::SHIFT),
            vec![vk::CONTROL, vk::SHIFT]
        );
    }

    #[test]
    fn resolve_maps_command_c_to_ctrl_c() {
        // iOS sends ⌘C as keycode 0x08 (C) with the command bit.
        let ev = KeyEvent {
            action: KeyAction::Down,
            keycode: Some(0x08),
            text: None,
            modifiers: Modifier::COMMAND,
            timestamp_micros: 0,
        };
        assert_eq!(
            resolve(&ev),
            Injected::Key {
                vk: 0x43,
                down: true,
                modifiers: Modifier::COMMAND
            }
        );
        assert_eq!(modifier_vks(Modifier::COMMAND), vec![vk::CONTROL]);
    }

    #[test]
    fn resolve_text_produces_utf16() {
        let ev = KeyEvent {
            action: KeyAction::Text,
            keycode: None,
            text: Some("Hi中".to_string()),
            modifiers: 0,
            timestamp_micros: 0,
        };
        assert_eq!(
            resolve(&ev),
            Injected::Text(vec!['H' as u16, 'i' as u16, '中' as u16])
        );
    }

    #[test]
    fn resolve_unknown_keycode_is_unknown() {
        let ev = KeyEvent {
            action: KeyAction::Down,
            keycode: Some(0xFFFF),
            text: None,
            modifiers: 0,
            timestamp_micros: 0,
        };
        assert_eq!(resolve(&ev), Injected::Unknown);
    }
}
