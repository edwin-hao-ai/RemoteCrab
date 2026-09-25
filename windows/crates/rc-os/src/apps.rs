//! Enumerate the desktop's top-level applications for the iPhone app
//! switcher (`IBAppList`, kind 0x0C) and bring one to the front.

use std::collections::HashSet;

use rc_protocol::{AppInfo, AppList};
use windows::core::BOOL;
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, MAX_PATH};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, TerminateProcess, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsWindowVisible,
    SetForegroundWindow, ShowWindow, SW_RESTORE,
};

/// Build the list of visible top-level windows as app entries. Each window
/// becomes one entry (id = `pid:<n>`), de-duplicated per process so an app
/// with several windows shows once.
pub fn build_app_list() -> AppList {
    let mut windows: Vec<(u32, String)> = Vec::new();

    unsafe {
        let _ = EnumWindows(Some(enum_proc), LPARAM(&mut windows as *mut _ as isize));
    }

    let mut seen: HashSet<u32> = HashSet::new();
    let mut apps: Vec<AppInfo> = Vec::new();
    let foreground_pid = foreground_pid();

    for (pid, title) in windows {
        if !seen.insert(pid) {
            continue;
        }
        let name = process_name(pid).unwrap_or_else(|| title.clone());
        apps.push(AppInfo {
            id: format!("pid:{pid}"),
            name,
            pid: pid as i32,
            is_active: pid == foreground_pid,
            icon_png: None,
        });
    }

    AppList { apps }
}

/// Bring the window owned by `pid` to the foreground.
pub fn activate_pid(pid: u32) -> bool {
    let mut target: Option<HWND> = None;
    unsafe {
        let _ = EnumWindows(
            Some(enum_find_proc),
            LPARAM(&mut FindTarget {
                pid,
                found: &mut target,
            } as *mut _ as isize),
        );
    }
    if let Some(hwnd) = target {
        unsafe {
            let _ = ShowWindow(hwnd, SW_RESTORE);
            SetForegroundWindow(hwnd).as_bool()
        }
    } else {
        false
    }
}

/// Parse an `AppInfo.id` (`pid:<n>`) back to the process id it names.
pub fn pid_from_id(id: &str) -> Option<u32> {
    id.strip_prefix("pid:")?.parse().ok()
}

/// Bring the app named by an `AppInfo.id` (`pid:<n>`) to the front. This is
/// how the iPhone's app switcher (`activateApp`, kind `0x0E`) takes effect.
pub fn activate_id(id: &str) -> bool {
    pid_from_id(id).is_some_and(activate_pid)
}

/// Terminate the process named by an `AppInfo.id` (`pid:<n>`), for the
/// iPhone's "quit" action (`quitApp`, kind `0x16`). Windows has no graceful
/// close request here, so the process is terminated (`force` is accepted for
/// protocol parity but does not change the behaviour).
pub fn quit_id(id: &str, force: bool) -> bool {
    let _ = force;
    let Some(pid) = pid_from_id(id) else {
        return false;
    };
    unsafe {
        let Ok(handle) = OpenProcess(PROCESS_TERMINATE, false, pid) else {
            return false;
        };
        let ok = TerminateProcess(handle, 1).as_bool();
        let _ = CloseHandle(handle);
        ok
    }
}

struct FindTarget<'a> {
    pid: u32,
    found: &'a mut Option<HWND>,
}

unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let out = &mut *(lparam.0 as *mut Vec<(u32, String)>);
    if !IsWindowVisible(hwnd).as_bool() {
        return BOOL(1);
    }
    let mut pid = 0u32;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    if pid == 0 {
        return BOOL(1);
    }
    let len = GetWindowTextLengthW(hwnd);
    if len <= 0 {
        return BOOL(1);
    }
    let mut buf = vec![0u16; (len + 1) as usize];
    let copied = GetWindowTextW(hwnd, &mut buf);
    let title = String::from_utf16_lossy(&buf[..copied as usize]);
    if !title.trim().is_empty() {
        out.push((pid, title));
    }
    BOOL(1)
}

unsafe extern "system" fn enum_find_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let target = &mut *(lparam.0 as *mut FindTarget);
    if !IsWindowVisible(hwnd).as_bool() {
        return BOOL(1);
    }
    let mut pid = 0u32;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    if pid == target.pid {
        *target.found = Some(hwnd);
        return BOOL(0); // stop enumeration
    }
    BOOL(1)
}

fn foreground_pid() -> u32 {
    use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;
    let mut pid = 0u32;
    unsafe {
        let hwnd = GetForegroundWindow();
        if !hwnd.is_invalid() {
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
        }
    }
    pid
}

fn process_name(pid: u32) -> Option<String> {
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; MAX_PATH as usize];
        let mut size = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut size);
        let _ = CloseHandle(handle);
        if ok.is_err() {
            return None;
        }
        let full = String::from_utf16_lossy(&buf[..size as usize]);
        // Trim to the executable stem for a friendlier label.
        let file = full.rsplit(['\\', '/']).next().unwrap_or(&full);
        Some(file.trim_end_matches(".exe").to_string())
    }
}
