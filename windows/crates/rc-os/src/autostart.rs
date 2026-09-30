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

/// Is RemoteCrab registered to start at login — **and would it actually run?**
///
/// The second half is the point. This used to answer "does the Run value
/// exist?", which is how the menu ends up insisting that start-at-login is on
/// while pointing at a file the user has since deleted or moved. That is the
/// same stale tick as everywhere else in this project: a green check that
/// describes the registry rather than the world.
///
/// So the value is read, the path parsed out of it, and the path is checked.
/// A Run value naming a missing file reports **off**, because from the user's
/// point of view it *is* off.
pub fn is_enabled() -> bool {
    let Some(cmd) = read_run_value() else {
        return false;
    };
    run_target(&cmd).is_some_and(|p| p.is_file())
}

/// The registered command, if any.
pub fn registered_command() -> Option<String> {
    read_run_value()
}

/// The path a Run value points at, if it has the shape we wrote.
///
/// Written by [`exe_command`] as `"<path>"`, but a user or another installer
/// may have edited it, so this parses rather than assumes: strip surrounding
/// whitespace, strip one layer of quotes, and ignore anything with arguments.
fn run_target(command: &str) -> Option<std::path::PathBuf> {
    let t = command.trim();
    // A command with arguments is not ours, and guessing at its path is how a
    // check starts reporting on some other program's file.
    if t.contains(" --") || t.contains(" /") {
        return None;
    }
    let unquoted = t.strip_prefix('"').and_then(|s| s.strip_suffix('"')).unwrap_or(t);
    if unquoted.is_empty() {
        return None;
    }
    Some(std::path::PathBuf::from(unquoted))
}

fn read_run_value() -> Option<String> {
    let hkey = open(false)?;
    let name = wide(VALUE_NAME);
    let mut size = 0u32;
    let rc = unsafe {
        RegQueryValueExW(hkey, PCWSTR(name.as_ptr()), None, None, None, Some(&mut size))
    };
    if rc != ERROR_SUCCESS || size == 0 {
        unsafe {
            let _ = RegCloseKey(hkey);
        }
        return None;
    }
    let mut buf = vec![0u16; (size as usize) / 2 + 1];
    let mut bytes = size;
    let rc = unsafe {
        RegQueryValueExW(
            hkey,
            PCWSTR(name.as_ptr()),
            None,
            None,
            Some(buf.as_mut_ptr() as *mut u8),
            Some(&mut bytes),
        )
    };
    unsafe {
        let _ = RegCloseKey(hkey);
    }
    if rc != ERROR_SUCCESS {
        return None;
    }
    let n = (bytes as usize / 2).saturating_sub(1);
    Some(String::from_utf16_lossy(&buf[..n.min(buf.len())]))
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

#[cfg(test)]
mod tests {
    use super::run_target;

    /// The shape `exe_command` writes, and the normal install path with a space
    /// in it. If the quotes are not stripped, the check compares against a path
    /// that begins with a quote character and always reports "off".
    #[test]
    fn a_quoted_path_with_a_space_is_parsed() {
        assert_eq!(
            run_target(r#""C:\Program Files\RemoteCrab\remotecrab.exe""#),
            Some(std::path::PathBuf::from(r"C:\Program Files\RemoteCrab\remotecrab.exe"))
        );
    }

    #[test]
    fn an_unquoted_path_is_parsed_too() {
        assert_eq!(
            run_target(r"C:\Tools\remotecrab.exe"),
            Some(std::path::PathBuf::from(r"C:\Tools\remotecrab.exe"))
        );
    }

    /// A Run value with arguments is not the one we wrote. Reporting on some
    /// other program's file is worse than reporting nothing.
    #[test]
    fn a_command_with_arguments_is_not_ours() {
        assert_eq!(run_target(r#""C:\x\a.exe" --minimized"#), None);
        assert_eq!(run_target(r"C:\x\a.exe /background"), None);
    }

    #[test]
    fn empty_and_quote_only_values_are_rejected() {
        assert_eq!(run_target(""), None);
        assert_eq!(run_target("   "), None);
        assert_eq!(run_target(r#""""#), None);
    }
}
