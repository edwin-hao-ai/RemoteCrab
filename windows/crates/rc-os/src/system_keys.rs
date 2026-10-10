//! Execute `IBSystemCommand` on Windows (volume / media keys / launch / URL).

use rc_protocol::{SystemCommand, SystemCommandKind};
use windows::core::BOOL;
use windows::Win32::Foundation::{HWND, LPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY,
};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowThreadProcessId, IsIconic, IsWindowVisible, MessageBoxW, ShowWindow,
    MB_ICONINFORMATION, MB_OK, SW_MINIMIZE, SW_SHOWNORMAL,
};

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
        SystemCommandKind::LaunchApp => command.argument.as_deref().map(open_path).unwrap_or(false),
        SystemCommandKind::OpenUrl => command.argument.as_deref().map(open_path).unwrap_or(false),
        // See `show_desktop`: a real minimise, not the Win+D *toggle*.
        SystemCommandKind::ShowDesktop => show_desktop(),
    }
}

/// Reveal the desktop by minimising every top-level window — the same
/// one-way effect the Mac gets from `NSRunningApplication.hide()`, and the
/// same as Win+D.
///
/// It used to *send* Win+D, which is a **toggle**: the first press shows the
/// desktop, the second brings everything back. Two consequences, both bad. A
/// user tapping "Desktop" in the switcher twice (because nothing visibly
/// happened the first time) got their whole workspace restored, which reads as
/// the app misbehaving. And with the app-window mirror running, the second
/// press left the mirror pointed at a window the user had just hidden, so the
/// picture on the phone froze on something that was no longer on screen.
///
/// Minimising directly is idempotent: pressing it ten times is the same as
/// pressing it once, which is what a button should be.
fn show_desktop() -> bool {
    let own = std::process::id();
    let mut minimized_any = false;
    unsafe extern "system" fn minimize_one(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let (own, done) = &mut *(lparam.0 as *mut (u32, bool));
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        // Skip ourselves — a hidden RemoteCrab cannot be brought back from the
        // tray — and anything already minimised, so a second press is a no-op.
        if pid != 0 && pid != *own && IsWindowVisible(hwnd).as_bool() && !IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_MINIMIZE);
            *done = true;
        }
        BOOL(1)
    }
    let mut data = (own, &mut minimized_any as *mut bool);
    unsafe {
        let _ = EnumWindows(
            Some(minimize_one),
            LPARAM(std::ptr::addr_of_mut!(data) as isize),
        );
    }
    minimized_any
}

fn key_input(vk: u16, down: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                wScan: 0,
                dwFlags: if down {
                    KEYBD_EVENT_FLAGS(0)
                } else {
                    KEYEVENTF_KEYUP
                },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

fn tap(vk: u16) -> bool {
    unsafe {
        SendInput(
            &[key_input(vk, true), key_input(vk, false)],
            std::mem::size_of::<INPUT>() as i32,
        ) == 2
    }
}

/// Open a URL in the user's default browser via the shell.
pub fn open_url(url: &str) -> bool {
    open_path(url)
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
}
