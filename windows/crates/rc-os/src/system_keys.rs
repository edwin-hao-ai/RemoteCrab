//! Execute `IBSystemCommand` on Windows (volume / media keys / launch / URL).

use rc_protocol::{SystemCommand, SystemCommandKind};
use windows::core::HSTRING;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    MessageBoxW, MB_ICONINFORMATION, MB_OK, SW_SHOWNORMAL,
};
use windows::Win32::UI::Shell::ShellExecuteW;

// Windows virtual-key codes for the media/system keys.
const VK_VOLUME_MUTE: u16 = 0xAD;
const VK_VOLUME_DOWN: u16 = 0xAE;
const VK_VOLUME_UP: u16 = 0xAF;
const VK_MEDIA_NEXT_TRACK: u16 = 0xB0;
const VK_MEDIA_PREV_TRACK: u16 = 0xB1;
const VK_MEDIA_PLAY_PAUSE: u16 = 0xB3;

/// Execute a system command. Returns true when it was handled.
pub fn handle(command: &SystemCommand) -> bool {
    match command.command {
        SystemCommandKind::VolumeUp => tap(VK_VOLUME_UP),
        SystemCommandKind::VolumeDown => tap(VK_VOLUME_DOWN),
        SystemCommandKind::VolumeMute => tap(VK_VOLUME_MUTE),
        // Windows has no universal brightness virtual key; step via WMI is
        // out of scope, so report it as unhandled rather than doing nothing
        // silently.
        SystemCommandKind::BrightnessUp | SystemCommandKind::BrightnessDown => false,
        SystemCommandKind::MediaPlayPause => tap(VK_MEDIA_PLAY_PAUSE),
        SystemCommandKind::MediaNext => tap(VK_MEDIA_NEXT_TRACK),
        SystemCommandKind::MediaPrevious => tap(VK_MEDIA_PREV_TRACK),
        SystemCommandKind::LaunchApp => command
            .argument
            .as_deref()
            .map(open_path)
            .unwrap_or(false),
        SystemCommandKind::OpenUrl => command
            .argument
            .as_deref()
            .map(open_path)
            .unwrap_or(false),
    }
}

fn tap(vk: u16) -> bool {
    let down = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                wScan: 0,
                dwFlags: KEYBD_EVENT_FLAGS(0),
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let up = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                wScan: 0,
                dwFlags: KEYEVENTF_KEYUP,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let sent = unsafe { SendInput(&[down, up], std::mem::size_of::<INPUT>() as i32) };
    sent == 2
}

/// Launch an app (by name/path) or open a URL via the shell.
fn open_path(target: &str) -> bool {
    let wide: Vec<u16> = target.encode_utf16().chain(std::iter::once(0)).collect();
    let result = unsafe {
        ShellExecuteW(
            None,
            windows::core::w!("open"),
            windows::core::PCWSTR(wide.as_ptr()),
            None,
            None,
            SW_SHOWNORMAL,
        )
    };
    // ShellExecuteW returns a value > 32 on success.
    result.0 as usize > 32
}

/// A small info box — used to surface "launchApp" when the named app can't
/// be resolved, so the button isn't a silent no-op.
pub fn notify(title: &str, body: &str) {
    let title: Vec<u16> = title.encode_utf16().chain(std::iter::once(0)).collect();
    let body: Vec<u16> = body.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        MessageBoxW(
            None,
            windows::core::PCWSTR(body.as_ptr()),
            windows::core::PCWSTR(title.as_ptr()),
            MB_OK | MB_ICONINFORMATION,
        );
    }
    let _ = HSTRING::from("");
}
