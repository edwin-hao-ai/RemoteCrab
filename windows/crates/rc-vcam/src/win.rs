//! Windows implementation of the virtual-camera spike.

use std::time::Duration;

use windows::core::{implement, GUID, HSTRING};
use windows::Win32::Media::MediaFoundation::{
    IMFAsyncCallback, IMFAsyncCallback_Impl, IMFVirtualCamera, MFCreateVirtualCamera,
    MFIsVirtualCameraTypeSupported, MFVirtualCameraAccess_CurrentUser,
    MFVirtualCameraLifetime_Session, MFVirtualCameraType_SoftwareCameraSource,
};
use windows::Win32::System::Com::{CoInitializeEx, COINIT_APARTMENTTHREADED};

/// The CLSID the media-source DLL will be registered under. Fixed so repeated
/// runs re-open the same camera (the docs key the camera on these params).
const SOURCE_CLSID: GUID = GUID::from_u128(0x9d4b_0d4d_1d2a_4b3e_9c0a_7f6e5d4c3b2a);

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

pub fn run_spike(name: &str, seconds: u64) -> Result<(), String> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
    }

    let supported = unsafe { MFIsVirtualCameraTypeSupported(MFVirtualCameraType_SoftwareCameraSource) }
        .map_err(|e| format!("MFIsVirtualCameraTypeSupported failed: {e}"))?;
    println!("software-camera type supported: {}", supported.as_bool());

    let source_id = HSTRING::from(format!("{{{SOURCE_CLSID:?}}}").to_uppercase());
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
        Err(e) => println!(
            "Start() failed: {e}\n  (expected until the IMFMediaSource DLL for {SOURCE_CLSID:?} is registered)"
        ),
    }

    println!("keeping the camera alive for {seconds}s — open the Windows Camera app / OBS and look for \"{name}\"");
    std::thread::sleep(Duration::from_secs(seconds));

    let _ = unsafe { camera.Stop() };
    let _ = unsafe { camera.Shutdown() };
    println!("camera stopped/shut down");
    Ok(())
}
