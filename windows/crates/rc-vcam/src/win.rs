//! Windows implementation: COM registration of the source DLL and the
//! `MFCreateVirtualCamera` start/stop dance.

use std::time::Duration;

use windows::core::{implement, GUID, HSTRING, PCWSTR};
use windows::Win32::Media::MediaFoundation::{
    IMFAsyncCallback, IMFAsyncCallback_Impl, IMFVirtualCamera, MFCreateVirtualCamera,
    MFIsVirtualCameraTypeSupported, MFStartup, MFVirtualCameraAccess_CurrentUser,
    MFVirtualCameraLifetime_Session, MFVirtualCameraType_SoftwareCameraSource, MFSTARTUP_FULL,
    MF_VERSION,
};
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteTreeW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW,
    HKEY, HKEY_LOCAL_MACHINE, KEY_READ, KEY_WRITE, REG_OPTION_NON_VOLATILE, REG_SZ, REG_VALUE_TYPE,
};

use crate::error::VcamError;
use crate::to_wide;

/// The CLSID of the COM media source (`rc-vcam-source`). Fixed so repeated
/// runs re-open the same camera; keep in sync with the `rc-vcam-source` crate
/// and its `.def`/`build.rs`.
pub const SOURCE_CLSID: GUID = GUID::from_u128(0x9d4b0d4d_1d2a_4b3e_9c0a_7f6e5d4c3b2a);

/// `{XXXXXXXX-...}` uppercase, as `MFCreateVirtualCamera` wants.
pub fn clsid_string() -> String {
    format!("{{{:?}}}", SOURCE_CLSID).to_uppercase()
}

/// The cdylib file name Cargo produces for the `rc-vcam-source` crate.
pub const SOURCE_DLL_NAME: &str = "rc_vcam_source.dll";

/// Where the source DLL lives: next to the running executable.
///
/// Accepts the hyphenated spelling too, so a rename in a packaging step does
/// not silently break activation.
pub fn source_dll_path() -> Result<std::path::PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| format!("current_exe: {e}"))?;
    let dir = exe
        .parent()
        .ok_or_else(|| "executable has no parent directory".to_string())?;
    // `cargo` puts example binaries one level down (`target/<profile>/examples/`),
    // while the DLL lands in `target/<profile>/`. Probe both.
    for candidate_dir in [dir, dir.parent().unwrap_or(dir)] {
        let hyphenated = candidate_dir.join("rc-vcam-source.dll");
        if hyphenated.exists() {
            return Ok(hyphenated);
        }
        let underscored = candidate_dir.join(SOURCE_DLL_NAME);
        if underscored.exists() {
            return Ok(underscored);
        }
    }
    Ok(dir.join(SOURCE_DLL_NAME))
}

/// Register the source DLL under the machine-wide COM hive.
///
/// Writes `HKLM\Software\Classes\CLSID\{...}\InprocServer32` with the DLL path
/// and `ThreadingModel = Both`. **HKLM is mandatory**: the Windows Frame
/// Server / Frame Server Monitor services (which activate the source) run as
/// `LocalService` / `LocalSystem` and cannot see `HKCU`. This requires an
/// elevated process.
pub fn install_source() -> Result<(), VcamError> {
    // Resolving our own path cannot need elevation; if it fails there is no
    // user action that helps, so it stays a plain message.
    let dll = source_dll_path().map_err(VcamError::Other)?;
    if !dll.exists() {
        return Err(VcamError::SourceMissing(dll.display().to_string()));
    }
    // Already registered to this exact DLL (e.g. by an earlier elevated run)?
    // Then this is a no-op we can do without admin rights.
    if let Some(existing) = registered_dll() {
        if existing.eq_ignore_ascii_case(&dll.to_string_lossy()) {
            return Ok(());
        }
    }

    let subkey = format!("Software\\Classes\\CLSID\\{}", clsid_string());
    let subkey_w = to_wide(&subkey);
    let mut hkey = HKEY::default();
    let rc = unsafe {
        RegCreateKeyExW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(subkey_w.as_ptr()),
            None,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            None,
            &mut hkey,
            None,
        )
    };
    if rc.is_err() {
        if rc == windows::Win32::Foundation::ERROR_ACCESS_DENIED {
            return Err(VcamError::NeedsElevation("registering the camera"));
        }
        return Err(VcamError::Other(format!(
            "RegCreateKeyExW(CLSID) failed: {rc:?}"
        )));
    }

    // Default value = friendly name.
    set_string(hkey, "", "RemoteCrab Camera Source")?;

    // InprocServer32 subkey.
    let inproc_sub = format!(
        "Software\\Classes\\CLSID\\{}\\InprocServer32",
        clsid_string()
    );
    let inproc_w = to_wide(&inproc_sub);
    let mut inproc = HKEY::default();
    let rc = unsafe {
        RegCreateKeyExW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(inproc_w.as_ptr()),
            None,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            None,
            &mut inproc,
            None,
        )
    };
    if rc.is_err() {
        unsafe {
            let _ = RegCloseKey(hkey);
        }
        return Err(VcamError::Other(format!(
            "RegCreateKeyExW(InprocServer32) failed: {rc:?}"
        )));
    }
    set_string(inproc, "", &dll.to_string_lossy())?;
    // COM may call from any apartment; our source is free-threaded-safe
    // (it only touches atomics + a mapped view), so `Both` is correct.
    set_string(inproc, "ThreadingModel", "Both")?;

    unsafe {
        let _ = RegCloseKey(inproc);
        let _ = RegCloseKey(hkey);
    }
    Ok(())
}

/// Remove the machine-wide COM registration (needs the same elevation as
/// [`install_source`]).
pub fn uninstall_source() -> Result<(), VcamError> {
    let subkey = format!("Software\\Classes\\CLSID\\{}", clsid_string());
    let w = to_wide(&subkey);
    let rc = unsafe { RegDeleteTreeW(HKEY_LOCAL_MACHINE, PCWSTR(w.as_ptr())) };
    if rc.is_err() {
        if rc == windows::Win32::Foundation::ERROR_ACCESS_DENIED {
            return Err(VcamError::NeedsElevation("removing the camera"));
        }
        return Err(VcamError::Other(format!("RegDeleteTreeW failed: {rc:?}")));
    }
    Ok(())
}

/// Read the DLL path currently registered for our CLSID under HKLM, if any.
/// Reading HKLM needs no elevation, so this lets a normal run detect a
/// registration done once by an administrator.
fn registered_dll() -> Option<String> {
    let sub = format!(
        "Software\\Classes\\CLSID\\{}\\InprocServer32",
        clsid_string()
    );
    let sub_w = to_wide(&sub);
    let mut hkey = HKEY::default();
    let rc = unsafe {
        RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            PCWSTR(sub_w.as_ptr()),
            None,
            KEY_READ,
            &mut hkey,
        )
    };
    if rc.is_err() {
        return None;
    }
    let mut kind = REG_VALUE_TYPE::default();
    let mut buf = vec![0u16; 1024];
    let mut bytes = (buf.len() * 2) as u32;
    let rc = unsafe {
        RegQueryValueExW(
            hkey,
            PCWSTR::null(),
            None,
            Some(&mut kind),
            Some(buf.as_mut_ptr() as *mut u8),
            Some(&mut bytes),
        )
    };
    unsafe {
        let _ = RegCloseKey(hkey);
    }
    if rc.is_err() {
        return None;
    }
    let n = (bytes as usize / 2).saturating_sub(1);
    Some(String::from_utf16_lossy(&buf[..n.min(buf.len())]))
}

fn set_string(key: HKEY, name: &str, value: &str) -> Result<(), VcamError> {
    let name_w = to_wide(name);
    let value_w = to_wide(value);
    let bytes = unsafe {
        std::slice::from_raw_parts(
            value_w.as_ptr() as *const u8,
            value_w.len() * std::mem::size_of::<u16>(),
        )
    };
    let rc = unsafe {
        RegSetValueExW(
            key,
            if name.is_empty() {
                PCWSTR::null()
            } else {
                PCWSTR(name_w.as_ptr())
            },
            None,
            REG_SZ,
            Some(bytes),
        )
    };
    if rc.is_err() {
        if rc == windows::Win32::Foundation::ERROR_ACCESS_DENIED {
            return Err(VcamError::NeedsElevation("registering the camera"));
        }
        return Err(VcamError::Other(format!(
            "RegSetValueExW({name}) failed: {rc:?}"
        )));
    }
    Ok(())
}

/// A no-op `IMFAsyncCallback` — `Start` wants one for device events.
#[implement(IMFAsyncCallback)]
struct CameraCallback;

impl IMFAsyncCallback_Impl for CameraCallback_Impl {
    fn GetParameters(&self, _flags: *mut u32, _queue: *mut u32) -> windows::core::Result<()> {
        Ok(())
    }

    fn Invoke(
        &self,
        _result: windows::core::Ref<'_, windows::Win32::Media::MediaFoundation::IMFAsyncResult>,
    ) -> windows::core::Result<()> {
        Ok(())
    }
}

/// Result of starting a virtual camera, so a caller can tell the three
/// outcomes apart without parsing strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StartOutcome {
    /// The camera is registered and enumerable.
    Started,
    /// The software-camera type is unsupported (pre-Win11 22H2).
    Unsupported,
    /// `Start` failed — usually the source CLSID is not registered.
    Failed,
}

/// The original spike: support check → create → start → hold → stop.
pub fn run_spike(name: &str, seconds: u64) -> Result<(), String> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let _ = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    }

    let supported =
        unsafe { MFIsVirtualCameraTypeSupported(MFVirtualCameraType_SoftwareCameraSource) }
            .map_err(|e| format!("MFIsVirtualCameraTypeSupported failed: {e}"))?;
    println!("software-camera type supported: {}", supported.as_bool());

    let source_id = HSTRING::from(clsid_string());
    let camera: IMFVirtualCamera = unsafe {
        MFCreateVirtualCamera(
            MFVirtualCameraType_SoftwareCameraSource,
            MFVirtualCameraLifetime_Session,
            MFVirtualCameraAccess_CurrentUser,
            &HSTRING::from(name),
            &source_id,
            None,
        )
    }
    .map_err(|e| format!("MFCreateVirtualCamera failed: {e}"))?;
    println!("virtual camera object created (\"{name}\")");

    let callback: IMFAsyncCallback = CameraCallback.into();
    match unsafe { camera.Start(&callback) } {
        Ok(()) => println!("Start() OK — the camera should now be enumerable"),
        Err(e) => println!("Start() failed: {e}\n  (register the source DLL: `rc-vcam --install`)"),
    }

    println!("keeping the camera alive for {seconds}s — open the Windows Camera app / OBS and look for \"{name}\"");
    std::thread::sleep(Duration::from_secs(seconds));

    let _ = unsafe { camera.Stop() };
    let _ = unsafe { camera.Shutdown() };
    println!("camera stopped/shut down");
    Ok(())
}

/// A live session-scoped virtual camera. Dropping it stops and shuts the
/// camera down, so callers do not have to remember to.
pub struct VirtualCamera {
    camera: IMFVirtualCamera,
    outcome: StartOutcome,
}

impl VirtualCamera {
    pub fn outcome(&self) -> StartOutcome {
        self.outcome
    }

    /// True when `Start()` succeeded and the device is enumerable.
    pub fn is_started(&self) -> bool {
        self.outcome == StartOutcome::Started
    }

    /// Stop and shut down the camera now (also done by `Drop`).
    pub fn stop(&self) {
        let _ = unsafe { self.camera.Stop() };
        let _ = unsafe { self.camera.Shutdown() };
    }
}

impl Drop for VirtualCamera {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Start a session-scoped virtual camera named `name` and return the live
/// object (kept alive by the caller). Callers that only need "is it up" can
/// drop it when done.
pub fn start_camera(name: &str) -> Result<VirtualCamera, String> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let _ = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    }
    let supported =
        unsafe { MFIsVirtualCameraTypeSupported(MFVirtualCameraType_SoftwareCameraSource) }
            .map_err(|e| format!("MFIsVirtualCameraTypeSupported failed: {e}"))?
            .as_bool();
    if !supported {
        return Err("software-camera type unsupported on this Windows build".to_string());
    }

    let source_id = HSTRING::from(clsid_string());
    let camera: IMFVirtualCamera = unsafe {
        MFCreateVirtualCamera(
            MFVirtualCameraType_SoftwareCameraSource,
            MFVirtualCameraLifetime_Session,
            MFVirtualCameraAccess_CurrentUser,
            &HSTRING::from(name),
            &source_id,
            None,
        )
    }
    .map_err(|e| format!("MFCreateVirtualCamera failed: {e}"))?;

    let callback: IMFAsyncCallback = CameraCallback.into();
    let outcome = match unsafe { camera.Start(&callback) } {
        Ok(()) => StartOutcome::Started,
        Err(_) => StartOutcome::Failed,
    };
    Ok(VirtualCamera { camera, outcome })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clsid_string_is_braced_and_uppercase() {
        let s = clsid_string();
        assert!(s.starts_with('{') && s.ends_with('}'), "{s}");
        assert_eq!(s.to_uppercase(), s, "{s}");
        assert!(s.contains("9D4B0D4D"), "{s}");
    }

    #[test]
    fn source_dll_sits_next_to_the_exe() {
        let p = source_dll_path().expect("path");
        // Prefer the hyphenated name when present, else Cargo's underscore one.
        let name = p.file_name().unwrap().to_string_lossy().to_string();
        assert!(
            name == "rc-vcam-source.dll" || name == SOURCE_DLL_NAME,
            "unexpected DLL name: {name}"
        );
    }
}
