//! Enumerate the desktop's top-level applications for the iPhone app
//! switcher (`IBAppList`, kind 0x0C) and bring one to the front.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

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
/// with several windows shows once. `with_icons` renders each entry's icon
/// as a 48 px PNG (mirrors the Mac's iconPNG) — the iPhone fills its cache
/// from these, so pass `true` on the launch-able `appListRequest`.
pub fn build_app_list(with_icons: bool) -> AppList {
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
        let icon_png = if with_icons { icon_png(pid) } else { None };
        apps.push(AppInfo {
            id: format!("pid:{pid}"),
            name,
            pid: pid as i32,
            is_active: pid == foreground_pid,
            icon_png,
        });
    }

    AppList { apps }
}

/// Render one process's icon as a 48 px RGBA PNG, cached by executable path
/// (the iPhone keeps its own copy, so renderer cost is paid once).
pub fn icon_png(pid: u32) -> Option<Vec<u8>> {
    render_icon_png_cached(&process_image_path(pid)?, 48)
}

/// Cached variant of [`render_icon_png`], keyed by the file/shortcut path
/// (both the running-app list and the installed-app launcher use it).
fn render_icon_png_cached(path: &str, size: i32) -> Option<Vec<u8>> {
    static CACHE: std::sync::LazyLock<
        std::sync::Mutex<std::collections::HashMap<String, Option<Vec<u8>>>>,
    > = std::sync::LazyLock::new(|| {
        std::sync::Mutex::new(std::collections::HashMap::new())
    });
    let mut cache = CACHE.lock().ok()?;
    if let Some(cached) = cache.get(path) {
        return cached.clone();
    }
    let rendered = render_icon_png(path, size);
    cache.insert(path.to_string(), rendered.clone());
    rendered
}

/// Bring the window owned by `pid` to the foreground.
pub fn activate_pid(pid: u32) -> bool {
    let mut target: Option<HWND> = None;
    unsafe {
        let _ = EnumWindows(
            Some(enum_find_proc),
            LPARAM(&mut FindTarget {
                pid,
                title: None,
                found: &mut target,
            } as *mut _ as isize),
        );
    }
    bring_to_front(target)
}

/// Bring the window of `pid` whose title matches `title` (exact, then
/// substring) to the foreground; falls back to `activate_pid`.
fn activate_pid_titled(pid: u32, title: &str) -> bool {
    for exact in [true, false] {
        let mut target: Option<HWND> = None;
        unsafe {
            let _ = EnumWindows(
                Some(enum_find_proc),
                LPARAM(&mut FindTarget {
                    pid,
                    title: Some(TitleMatch { text: title, exact }),
                    found: &mut target,
                } as *mut _ as isize),
            );
        }
        if bring_to_front(target) {
            return true;
        }
    }
    false
}

fn bring_to_front(target: Option<HWND>) -> bool {
    if let Some(hwnd) = target {
        unsafe {
            let _ = ShowWindow(hwnd, SW_RESTORE);
            return SetForegroundWindow(hwnd).as_bool();
        }
    }
    false
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

/// Like [`activate_id`], but prefers the window whose title matches (the
/// iPhone sends the tapped card's window title alongside the app id).
pub fn activate_id_with_title(id: &str, title: Option<&str>) -> bool {
    let Some(pid) = pid_from_id(id) else {
        return false;
    };
    if let Some(text) = title.filter(|t| !t.is_empty()) {
        if activate_pid_titled(pid, text) {
            return true;
        }
    }
    activate_pid(pid)
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
        let ok = TerminateProcess(handle, 1).is_ok();
        let _ = CloseHandle(handle);
        ok
    }
}

struct TitleMatch<'a> {
    text: &'a str,
    exact: bool,
}

struct FindTarget<'a> {
    pid: u32,
    title: Option<TitleMatch<'a>>,
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
    if pid != target.pid {
        return BOOL(1);
    }
    if let Some(matcher) = &target.title {
        let len = GetWindowTextLengthW(hwnd);
        if len <= 0 {
            return BOOL(1);
        }
        let mut buf = vec![0u16; (len + 1) as usize];
        let copied = GetWindowTextW(hwnd, &mut buf);
        let title = String::from_utf16_lossy(&buf[..copied as usize]);
        let matches = if matcher.exact {
            title == matcher.text
        } else {
            title.contains(matcher.text)
        };
        if !matches {
            return BOOL(1);
        }
    }
    *target.found = Some(hwnd);
    BOOL(0) // stop enumeration
}

pub(crate) fn foreground_pid() -> u32 {
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

/// The process's executable full path, e.g. `C:\Program Files\App\App.exe`.
pub(crate) fn process_image_path(pid: u32) -> Option<String> {
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; MAX_PATH as usize];
        let mut size = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut size);
        let _ = CloseHandle(handle);
        if ok.is_err() {
            return None;
        }
        Some(String::from_utf16_lossy(&buf[..size as usize]))
    }
}

pub(crate) fn process_name(pid: u32) -> Option<String> {
    let full = process_image_path(pid)?;
    // Trim to the executable stem for a friendlier label.
    let file = full.rsplit(['\\', '/']).next().unwrap_or(&full);
    Some(file.trim_end_matches(".exe").to_string())
}

/// Draw the file's default icon into a 32-bit BGRA DIB and PNG-encode it.
fn render_icon_png(image_path: &str, size: i32) -> Option<Vec<u8>> {
    use std::os::windows::ffi::OsStrExt;
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::Graphics::Gdi::{
        CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDC, ReleaseDC,
        SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HGDIOBJ,
    };
    use windows::Win32::Storage::FileSystem::FILE_ATTRIBUTE_NORMAL;
    use windows::Win32::UI::Shell::{SHGetFileInfoW, SHGFI_ICON, SHGFI_LARGEICON, SHFILEINFOW};
    use windows::Win32::UI::WindowsAndMessaging::{DestroyIcon, DrawIconEx, DI_NORMAL};

    let wide: Vec<u16> = std::ffi::OsStr::new(image_path)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let info = unsafe {
        let mut info = SHFILEINFOW::default();
        let ok = SHGetFileInfoW(
            windows::core::PCWSTR(wide.as_ptr()),
            FILE_ATTRIBUTE_NORMAL,
            Some(&mut info),
            std::mem::size_of::<SHFILEINFOW>() as u32,
            SHGFI_ICON | SHGFI_LARGEICON,
        );
        if ok == 0 {
            return None;
        }
        info
    };
    if info.hIcon.is_invalid() {
        return None;
    }

    let rgba = unsafe {
        let screen = GetDC(None);
        if screen.is_invalid() {
            return None;
        }
        let mem = CreateCompatibleDC(Some(screen));
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let mut bmi = BITMAPINFO::default();
        bmi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
        bmi.bmiHeader.biWidth = size;
        bmi.bmiHeader.biHeight = -size; // top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB.0;

        let dib = CreateDIBSection(
            Some(mem),
            &bmi,
            DIB_RGB_COLORS,
            &mut bits,
            Some(HANDLE::default()),
            0,
        );
        let mut rgba: Option<Vec<u8>> = None;
        if let Ok(bitmap) = dib {
            if !bits.is_null() {
                let old = SelectObject(mem, HGDIOBJ(bitmap.0));
                let _ = DrawIconEx(mem, 0, 0, info.hIcon, size, size, 0, None, DI_NORMAL);
                let len = (size * size * 4) as usize;
                let slice = std::slice::from_raw_parts(bits as *const u8, len);
                rgba = Some(crate::icon::bgra_to_rgba(slice));
                let _ = SelectObject(mem, old);
            }
            let _ = DeleteObject(HGDIOBJ(bitmap.0));
        }
        let _ = DeleteDC(mem);
        let _ = ReleaseDC(None, screen);
        let _ = DestroyIcon(info.hIcon);
        rgba
    };

    crate::icon::encode_rgba_png(&rgba?, size as u32, size as u32)
}

// --------------------------------------------------------------------------
// Installed-app launcher (Start Menu enumeration)
// --------------------------------------------------------------------------

/// Collect every Start-Menu shortcut (`*.lnk`) — the same launch-able set a
/// Windows user sees in the Start Menu — one entry per shortcut, deduped by
/// name (all-users entries shadow per-user duplicates).
///
/// `InstalledApp.id` carries the shortcut's absolute path, which is exactly
/// what `SystemCommandKind::LaunchApp` hands to `ShellExecuteW`.
pub fn build_installed_apps() -> rc_protocol::InstalledApps {
    let mut roots: Vec<PathBuf> = Vec::new();
    for env in ["PROGRAMDATA", "APPDATA"] {
        if let Some(base) = std::env::var_os(env) {
            roots.push(PathBuf::from(base)
                .join("Microsoft")
                .join("Windows")
                .join("Start Menu")
                .join("Programs"));
        }
    }

    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut apps: Vec<rc_protocol::InstalledApp> = Vec::new();
    for root in roots {
        for path in collect_lnk(&root, 4) {
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            let name = stem.trim().to_string();
            if name.is_empty() || !seen.insert(name.to_ascii_lowercase()) {
                continue;
            }
            apps.push(rc_protocol::InstalledApp {
                id: path.to_string_lossy().into_owned(),
                name: name.to_string(),
                icon_png: render_icon_png_cached(&path.to_string_lossy(), 96),
            });
        }
    }
    apps.sort_by_key(|a| a.name.to_lowercase());
    rc_protocol::InstalledApps { apps }
}

/// Recursively collect `*.lnk` files up to `depth` levels below `dir`.
fn collect_lnk(dir: &Path, depth: u8) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut dirs = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
        if is_dir {
            dirs.push(path);
        } else if path.extension().and_then(|e| e.to_str()).map(|e| e.eq_ignore_ascii_case("lnk")).unwrap_or(false) {
            out.push(path);
        }
    }
    if depth > 1 {
        for child in dirs {
            out.extend(collect_lnk(&child, depth - 1));
        }
    }
    out
}
