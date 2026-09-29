//! The class factory's output: an `IMFActivate` (+ `IMFAttributes`) built by
//! hand with a native vtable and a plain reference count.
//!
//! We deliberately do **not** use `windows-rs`'s `#[implement]` here: its
//! generated object (weak/strong ref-count bookkeeping, implicit
//! `IInspectable`/`IMarshal`) behaves differently enough from the C++/WinRT
//! `winrt::implements` reference virtual camera that the Windows Frame Server
//! sets the device attributes and then bails out before calling
//! `ActivateObject`. A plain COM object matches the reference.

use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};

use windows::core::{HRESULT, BOOL, GUID, IUnknown, Interface, PCWSTR, PWSTR};
use windows::Win32::Foundation::{E_NOINTERFACE, E_POINTER, S_OK};
use windows::Win32::Media::MediaFoundation::{
    IMFActivate, IMFActivate_Vtbl, IMFAttributes, IMFAttributes_Vtbl, IMFMediaSource,
    MF_ATTRIBUTES_MATCH_TYPE, MF_ATTRIBUTE_TYPE, MFT_TRANSFORM_CLSID_Attribute,
    MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES,
};
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
use windows::Win32::System::Com::IAgileObject;

use crate::{build_source, SOURCE_CLSID};

/// The COM object. Its first field is the vtable pointer, so the COM `this`
/// pointer doubles as `*mut Activator`.
#[repr(C)]
struct Activator {
    vtbl: *const IMFActivate_Vtbl,
    refs: AtomicU32,
    attrs: IMFAttributes,
    source: IMFMediaSource,
}

// --- IUnknown -------------------------------------------------------------

unsafe extern "system" fn query_interface(
    this: *mut c_void,
    iid: *const GUID,
    out: *mut *mut c_void,
) -> HRESULT {
    if iid.is_null() || out.is_null() {
        return E_POINTER;
    }
    let obj = this as *mut Activator;
    let iid = *iid;
    let known = iid == IUnknown::IID
        || iid == IMFActivate::IID
        || iid == IMFAttributes::IID
        || iid == IAgileObject::IID;
    if known {
        *out = this;
        (*obj).refs.fetch_add(1, Ordering::SeqCst);
        S_OK
    } else {
        *out = std::ptr::null_mut();
        E_NOINTERFACE
    }
}

unsafe extern "system" fn add_ref(this: *mut c_void) -> u32 {
    let obj = this as *mut Activator;
    (*obj).refs.fetch_add(1, Ordering::SeqCst) + 1
}

unsafe extern "system" fn release(this: *mut c_void) -> u32 {
    let obj = this as *mut Activator;
    let remaining = (*obj).refs.fetch_sub(1, Ordering::SeqCst) - 1;
    if remaining == 0 {
        drop(Box::from_raw(obj));
    }
    remaining
}

// --- IMFAttributes: forward every call to the real MF store ---------------

macro_rules! forward {
    ($name:ident, $field:ident, ($($arg:ident : $ty:ty),*)) => {
        unsafe extern "system" fn $name(this: *mut c_void, $($arg: $ty),*) -> HRESULT {
            let obj = &*(this as *const Activator);
            let vt = windows::core::Interface::vtable(&obj.attrs);
            let raw = windows::core::Interface::as_raw(&obj.attrs);
            (vt.$field)(raw, $($arg),*)
        }
    };
}

forward!(get_item, GetItem, (key: *const GUID, val: *mut PROPVARIANT));
forward!(get_item_type, GetItemType, (key: *const GUID, out: *mut MF_ATTRIBUTE_TYPE));
forward!(compare_item, CompareItem, (key: *const GUID, val: *const PROPVARIANT, out: *mut BOOL));
forward!(compare, Compare, (theirs: *mut c_void, mt: MF_ATTRIBUTES_MATCH_TYPE, out: *mut BOOL));
forward!(get_uint32, GetUINT32, (key: *const GUID, out: *mut u32));
forward!(get_uint64, GetUINT64, (key: *const GUID, out: *mut u64));
forward!(get_double, GetDouble, (key: *const GUID, out: *mut f64));
forward!(get_guid, GetGUID, (key: *const GUID, out: *mut GUID));
forward!(get_string_length, GetStringLength, (key: *const GUID, out: *mut u32));
forward!(get_string, GetString, (key: *const GUID, buf: PWSTR, len: u32, out: *mut u32));
forward!(get_allocated_string, GetAllocatedString, (key: *const GUID, out: *mut PWSTR, len: *mut u32));
forward!(get_blob_size, GetBlobSize, (key: *const GUID, out: *mut u32));
forward!(get_blob, GetBlob, (key: *const GUID, buf: *mut u8, len: u32, out: *mut u32));
forward!(get_allocated_blob, GetAllocatedBlob, (key: *const GUID, out: *mut *mut u8, len: *mut u32));
forward!(get_unknown, GetUnknown, (key: *const GUID, iid: *const GUID, out: *mut *mut c_void));
forward!(set_item, SetItem, (key: *const GUID, val: *const PROPVARIANT));
forward!(delete_item, DeleteItem, (key: *const GUID));
forward!(delete_all_items, DeleteAllItems, ());
forward!(set_uint32, SetUINT32, (key: *const GUID, v: u32));
forward!(set_uint64, SetUINT64, (key: *const GUID, v: u64));
forward!(set_double, SetDouble, (key: *const GUID, v: f64));
forward!(set_guid, SetGUID, (key: *const GUID, v: *const GUID));
forward!(set_string, SetString, (key: *const GUID, v: PCWSTR));
forward!(set_blob, SetBlob, (key: *const GUID, buf: *const u8, len: u32));
forward!(set_unknown, SetUnknown, (key: *const GUID, v: *mut c_void));
forward!(lock_store, LockStore, ());
forward!(unlock_store, UnlockStore, ());
forward!(get_count, GetCount, (out: *mut u32));
forward!(get_item_by_index, GetItemByIndex, (i: u32, key: *mut GUID, val: *mut PROPVARIANT));
forward!(copy_all_items, CopyAllItems, (dest: *mut c_void));

// --- IMFActivate ----------------------------------------------------------

unsafe extern "system" fn activate_object(
    this: *mut c_void,
    iid: *const GUID,
    out: *mut *mut c_void,
) -> HRESULT {
    if iid.is_null() || out.is_null() {
        return E_POINTER;
    }
    *out = std::ptr::null_mut();
    let obj = &*(this as *const Activator);
    let unknown: IUnknown = match obj.source.cast() {
        Ok(u) => u,
        Err(e) => return e.code(),
    };
    let hr = unknown.query(iid, out);
    crate::trace::log(format!(
        "ActivateObject riid={:?} -> hr={:#010X} ptr_null={}",
        *iid,
        hr.0,
        (*out).is_null()
    ));
    hr
}

unsafe extern "system" fn shutdown_object(_this: *mut c_void) -> HRESULT {
    S_OK
}

unsafe extern "system" fn detach_object(_this: *mut c_void) -> HRESULT {
    S_OK
}

static VTABLE: IMFActivate_Vtbl = IMFActivate_Vtbl {
    base__: IMFAttributes_Vtbl {
        base__: windows::core::IUnknown_Vtbl {
            QueryInterface: query_interface,
            AddRef: add_ref,
            Release: release,
        },
        GetItem: get_item,
        GetItemType: get_item_type,
        CompareItem: compare_item,
        Compare: compare,
        GetUINT32: get_uint32,
        GetUINT64: get_uint64,
        GetDouble: get_double,
        GetGUID: get_guid,
        GetStringLength: get_string_length,
        GetString: get_string,
        GetAllocatedString: get_allocated_string,
        GetBlobSize: get_blob_size,
        GetBlob: get_blob,
        GetAllocatedBlob: get_allocated_blob,
        GetUnknown: get_unknown,
        SetItem: set_item,
        DeleteItem: delete_item,
        DeleteAllItems: delete_all_items,
        SetUINT32: set_uint32,
        SetUINT64: set_uint64,
        SetDouble: set_double,
        SetGUID: set_guid,
        SetString: set_string,
        SetBlob: set_blob,
        SetUnknown: set_unknown,
        LockStore: lock_store,
        UnlockStore: unlock_store,
        GetCount: get_count,
        GetItemByIndex: get_item_by_index,
        CopyAllItems: copy_all_items,
    },
    ActivateObject: activate_object,
    ShutdownObject: shutdown_object,
    DetachObject: detach_object,
};

/// Create a fresh activation object (reference count 1, wrapped as `IUnknown`).
pub fn create() -> windows::core::Result<IUnknown> {
    crate::ensure_mf();
    let attrs = crate::attrs::new_attributes(4)?;
    unsafe {
        let _ = attrs.SetUINT32(&MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES, 1);
        let _ = attrs.SetGUID(&MFT_TRANSFORM_CLSID_Attribute, &SOURCE_CLSID);
    }
    let source = build_source()?;
    let obj = Box::new(Activator {
        vtbl: &VTABLE,
        refs: AtomicU32::new(1),
        attrs,
        source,
    });
    let raw = Box::into_raw(obj) as *mut c_void;
    Ok(unsafe { IUnknown::from_raw(raw) })
}
