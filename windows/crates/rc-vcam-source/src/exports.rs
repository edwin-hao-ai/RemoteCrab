//! COM in-proc server entry points.
//!
//! `regsvr32` is not used: `rc-vcam` writes the HKLM registration directly
//! (the Frame Server services can only see `HKLM`, not `HKCU`). Windows still
//! needs `DllGetClassObject` (and friends) exported, which this module
//! provides.

#![cfg(windows)]

use std::ffi::c_void;

use windows::core::{GUID, HRESULT, Interface, Ref, Result, IUnknown};
use windows::Win32::Foundation::{CLASS_E_CLASSNOTAVAILABLE, E_POINTER, S_FALSE};
use windows::Win32::System::Com::{IClassFactory, IClassFactory_Impl};

use crate::SOURCE_CLSID;

/// The class factory: hands out one `IMFActivate` per activation.
#[windows::core::implement(IClassFactory)]
struct VcamClassFactory;

impl IClassFactory_Impl for VcamClassFactory_Impl {
    fn CreateInstance(
        &self,
        punkouter: Ref<IUnknown>,
        riid: *const GUID,
        ppv: *mut *mut c_void,
    ) -> Result<()> {
        if riid.is_null() || ppv.is_null() {
            return Err(windows::core::Error::from(E_POINTER));
        }
        unsafe { *ppv = std::ptr::null_mut() };
        // We do not support aggregation.
        if !punkouter.is_null() {
            return Err(windows::core::Error::from(
                windows::Win32::Foundation::CLASS_E_NOAGGREGATION,
            ));
        }
        // Return the IMFActivate (the frame server sets device attributes on
        // it and then calls ActivateObject to get the media source).
        let unknown = crate::activator::create()?;
        let hr = unsafe { unknown.query(riid, ppv) };
        crate::trace::log(format!(
            "CreateInstance riid={:?} -> {:#010X}",
            unsafe { *riid },
            hr.0
        ));
        hr.ok()?;
        Ok(())
    }

    fn LockServer(&self, _flock: windows::core::BOOL) -> Result<()> {
        Ok(())
    }
}

/// Standard COM export: return the class factory for our CLSID.
///
/// # Safety
/// Called by COM with a valid `riid`/`ppv` pair.
#[no_mangle]
pub unsafe extern "system" fn DllGetClassObject(
    rclsid: *const GUID,
    riid: *const GUID,
    ppv: *mut *mut c_void,
) -> HRESULT {
    if rclsid.is_null() || riid.is_null() || ppv.is_null() {
        return E_POINTER;
    }
    crate::trace::log(format!(
        "DllGetClassObject rclsid={:?} riid={:?}",
        *rclsid, *riid
    ));
    if *rclsid != SOURCE_CLSID {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    let factory: IClassFactory = VcamClassFactory.into();
    let hr = factory.query(riid, ppv);
    crate::trace::log(format!("DllGetClassObject -> {:#010X}", hr.0));
    hr
}

/// No self-registration: `rc-vcam` writes the HKLM registry keys instead.
///
/// # Safety
/// Unused pointers per the COM contract.
#[no_mangle]
pub unsafe extern "system" fn DllRegisterServer() -> HRESULT {
    S_FALSE
}

/// See [`DllRegisterServer`].
///
/// # Safety
/// Unused pointers per the COM contract.
#[no_mangle]
pub unsafe extern "system" fn DllUnregisterServer() -> HRESULT {
    S_FALSE
}

/// `DllCanUnloadNow` — we never unload while activated, so report "no".
///
/// # Safety
/// No arguments.
#[no_mangle]
pub unsafe extern "system" fn DllCanUnloadNow() -> HRESULT {
    S_FALSE
}
