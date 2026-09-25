//! Selection rewrite via synthetic Ctrl+C / Ctrl+V, mirroring the Mac
//! receiver. Windows has no reliable "read another app's selection" API
//! from an unprivileged process either, so we copy, transform, paste, and
//! restore the user's clipboard.

use rc_protocol::TextCommand;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY,
};

const VK_CONTROL: u16 = 0x11;
const VK_C: u16 = 0x43;
const VK_V: u16 = 0x56;

/// Apply `command` to the foreground app's selection.
///
/// Returns the before/after text so the caller can notify or log; `None`
/// when the clipboard had nothing to transform.
pub fn rewrite_selection(command: TextCommand) -> Option<(String, String)> {
    let saved = crate::clipboard::get_text();
    send_ctrl(VK_C);
    std::thread::sleep(std::time::Duration::from_millis(80));
    let selected = crate::clipboard::get_text()?;
    if selected.is_empty() {
        // Restore whatever was there before we hijacked the clipboard.
        if let Some(s) = &saved {
            crate::clipboard::set_text(s);
        }
        return None;
    }

    let transformed = command.apply(&selected);
    if crate::clipboard::set_text(&transformed) {
        send_ctrl(VK_V);
        std::thread::sleep(std::time::Duration::from_millis(80));
    }

    // Put the user's original clipboard back.
    if let Some(s) = saved {
        crate::clipboard::set_text(&s);
    }
    Some((selected, transformed))
}

fn send_ctrl(vk: u16) {
    let inputs = [
        key(VK_CONTROL, false),
        key(vk, false),
        key(vk, true),
        key(VK_CONTROL, true),
    ];
    unsafe {
        SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
    }
}

fn key(vk: u16, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                wScan: 0,
                dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}
