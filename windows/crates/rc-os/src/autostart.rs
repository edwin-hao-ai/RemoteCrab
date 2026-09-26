//! "Start at login" via `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
//! — the Windows equivalent of the Mac receiver's `SMAppService.mainApp`
//! launch-at-login. No admin rights and no installer needed: the value just
//! names the current executable.

use windows::core::PCWSTR;
use windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
use windows::Win32::System::Registry::{
    RegCloseKey, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY,
    HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_SZ,
};

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const VALUE_NAME: &str = "RemoteCrab";

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Open the Run key; `write` also requests set/delete access.
fn open(write: bool) -> Option<HKEY> {
    let mut hkey = HKEY::default();
    let key = wide(RUN_KEY);
    let flags = if write {
        KEY_QUERY_VALUE | KEY_SET_VALUE
    } else {
        KEY_QUERY_VALUE
    };
    let rc = unsafe {
        RegOpenKeyExW(HKEY_CURRENT_USER, PCWSTR(key.as_ptr()), None, flags, &mut hkey)
    };
    (rc == ERROR_SUCCESS).then_some(hkey)
}

/// The exact command Windows should run at login: our own executable,
/// quoted because install paths commonly contain spaces.
fn exe_command() -> Option<String> {
    std::env::current_exe()
        .ok()
        .map(|p| format!("\"{}\"", p.display()))
}

/// Is RemoteCrab registered to start at login?
pub fn is_enabled() -> bool {
    let Some(hkey) = open(false) else {
        return false;
    };
    let name = wide(VALUE_NAME);
    let mut size = 0u32;
    let rc = unsafe {
        RegQueryValueExW(hkey, PCWSTR(name.as_ptr()), None, None, None, Some(&mut size))
    };
    unsafe {
        let _ = RegCloseKey(hkey);
    }
    rc == ERROR_SUCCESS && size > 0
}

/// Enable or disable start-at-login. Returns whether the registry now
/// reflects the request.
pub fn set_enabled(on: bool) -> bool {
    let Some(hkey) = open(true) else {
        return false;
    };
    let name = wide(VALUE_NAME);
    let ok = if on {
        match exe_command() {
            Some(cmd) => {
                let cmd = wide(&cmd);
                // RegSetValueExW wants the raw bytes, NUL terminator included.
                let bytes =
                    unsafe { std::slice::from_raw_parts(cmd.as_ptr() as *const u8, cmd.len() * 2) };
                let rc = unsafe {
                    RegSetValueExW(hkey, PCWSTR(name.as_ptr()), None, REG_SZ, Some(bytes))
                };
                rc == ERROR_SUCCESS
            }
            None => false,
        }
    } else {
        let rc = unsafe { RegDeleteValueW(hkey, PCWSTR(name.as_ptr())) };
        // Already absent counts as "off".
        rc == ERROR_SUCCESS || rc == ERROR_FILE_NOT_FOUND
    };
    unsafe {
        let _ = RegCloseKey(hkey);
    }
    ok
}
