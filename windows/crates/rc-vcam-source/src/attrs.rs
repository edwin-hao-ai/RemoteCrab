//! `IMFAttributes` plumbing shared by the activator, the media source and the
//! stream.
//!
//! Media Foundation hands the frame server these objects and expects them to
//! *be* `IMFAttributes` (the `MF_DEVICESTREAM_*` / sensor attributes live on
//! them). Rather than re-implement the attribute store, every wrapper owns a
//! real `IMFAttributes` (created by `MFCreateAttributes`) and forwards.

#![cfg(windows)]

use windows::core::Result;
use windows::Win32::Foundation::E_POINTER;
use windows::Win32::Media::MediaFoundation::{IMFAttributes, MFCreateAttributes};

/// A fresh attribute store backed by Media Foundation.
pub fn new_attributes(capacity: u32) -> Result<IMFAttributes> {
    let mut attrs: Option<IMFAttributes> = None;
    unsafe { MFCreateAttributes(&mut attrs, capacity)? };
    attrs.ok_or_else(|| windows::core::Error::from(E_POINTER))
}

/// Build a mutable slice from a COM `(ptr, len)` output buffer, tolerating the
/// "size query" call where the pointer is null.
pub(crate) unsafe fn out_slice_mut<'a, T>(ptr: *mut T, len: u32) -> &'a mut [T] {
    if ptr.is_null() || len == 0 {
        &mut []
    } else {
        std::slice::from_raw_parts_mut(ptr, len as usize)
    }
}

/// Build a shared slice from a COM `(ptr, len)` input buffer.
pub(crate) unsafe fn in_slice<'a, T>(ptr: *const T, len: u32) -> &'a [T] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len as usize)
    }
}

/// Implement `IMFAttributes_Impl` on a `#[implement]` wrapper by forwarding to
/// its `attrs` field (a real `IMFAttributes`).
#[macro_export]
macro_rules! impl_imf_attributes {
    ($t:ty) => {
        impl windows::Win32::Media::MediaFoundation::IMFAttributes_Impl for $t {
            fn GetItem(
                &self,
                guidkey: *const windows::core::GUID,
                pvalue: *mut windows::Win32::System::Com::StructuredStorage::PROPVARIANT,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.GetItem(guidkey, Some(pvalue)) }
            }
            fn GetItemType(
                &self,
                guidkey: *const windows::core::GUID,
            ) -> windows::core::Result<windows::Win32::Media::MediaFoundation::MF_ATTRIBUTE_TYPE>
            {
                unsafe { self.attrs.GetItemType(guidkey) }
            }
            fn GetStringLength(
                &self,
                guidkey: *const windows::core::GUID,
            ) -> windows::core::Result<u32> {
                unsafe { self.attrs.GetStringLength(guidkey) }
            }
            fn GetUINT32(
                &self,
                guidkey: *const windows::core::GUID,
            ) -> windows::core::Result<u32> {
                unsafe { self.attrs.GetUINT32(guidkey) }
            }
            fn GetUINT64(
                &self,
                guidkey: *const windows::core::GUID,
            ) -> windows::core::Result<u64> {
                unsafe { self.attrs.GetUINT64(guidkey) }
            }
            fn CompareItem(
                &self,
                guidkey: *const windows::core::GUID,
                value: *const windows::Win32::System::Com::StructuredStorage::PROPVARIANT,
            ) -> windows::core::Result<windows::core::BOOL> {
                unsafe { self.attrs.CompareItem(guidkey, value) }
            }
            fn Compare(
                &self,
                ptheirs: windows::core::Ref<
                    windows::Win32::Media::MediaFoundation::IMFAttributes,
                >,
                matchtype: windows::Win32::Media::MediaFoundation::MF_ATTRIBUTES_MATCH_TYPE,
            ) -> windows::core::Result<windows::core::BOOL> {
                unsafe { self.attrs.Compare(ptheirs.ok()?, matchtype) }
            }
            fn GetDouble(&self, guidkey: *const windows::core::GUID) -> windows::core::Result<f64> {
                unsafe { self.attrs.GetDouble(guidkey) }
            }
            fn GetGUID(
                &self,
                guidkey: *const windows::core::GUID,
            ) -> windows::core::Result<windows::core::GUID> {
                unsafe { self.attrs.GetGUID(guidkey) }
            }
            fn GetString(
                &self,
                guidkey: *const windows::core::GUID,
                pwszvalue: windows::core::PWSTR,
                cchbufsize: u32,
                pcchlength: *mut u32,
            ) -> windows::core::Result<()> {
                let buf = unsafe { $crate::attrs::out_slice_mut(pwszvalue.0, cchbufsize) };
                unsafe { self.attrs.GetString(guidkey, buf, Some(pcchlength)) }
            }
            fn GetBlobSize(
                &self,
                guidkey: *const windows::core::GUID,
            ) -> windows::core::Result<u32> {
                unsafe { self.attrs.GetBlobSize(guidkey) }
            }
            fn GetBlob(
                &self,
                guidkey: *const windows::core::GUID,
                pbuf: *mut u8,
                cbbufsize: u32,
                pcbblobsize: *mut u32,
            ) -> windows::core::Result<()> {
                let buf = unsafe { $crate::attrs::out_slice_mut(pbuf, cbbufsize) };
                unsafe { self.attrs.GetBlob(guidkey, buf, Some(pcbblobsize)) }
            }
            fn GetAllocatedBlob(
                &self,
                guidkey: *const windows::core::GUID,
                ppbuf: *mut *mut u8,
                pcbsize: *mut u32,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.GetAllocatedBlob(guidkey, ppbuf, pcbsize) }
            }
            fn GetUnknown(
                &self,
                guidkey: *const windows::core::GUID,
                riid: *const windows::core::GUID,
                ppv: *mut *mut core::ffi::c_void,
            ) -> windows::core::Result<()> {
                let unknown: windows::core::IUnknown =
                    unsafe { self.attrs.GetUnknown::<windows::core::IUnknown>(guidkey) }?;
                let hr = unsafe { windows::core::Interface::query(&unknown, riid, ppv) };
                hr.ok()
            }
            fn SetItem(
                &self,
                guidkey: *const windows::core::GUID,
                value: *const windows::Win32::System::Com::StructuredStorage::PROPVARIANT,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.SetItem(guidkey, value) }
            }
            fn SetString(
                &self,
                guidkey: *const windows::core::GUID,
                wszvalue: &windows::core::PCWSTR,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.SetString(guidkey, *wszvalue) }
            }
            fn SetUnknown(
                &self,
                guidkey: *const windows::core::GUID,
                punknown: windows::core::Ref<windows::core::IUnknown>,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.SetUnknown(guidkey, punknown.ok()?) }
            }
            fn DeleteAllItems(&self) -> windows::core::Result<()> {
                unsafe { self.attrs.DeleteAllItems() }
            }
            fn SetUINT32(
                &self,
                guidkey: *const windows::core::GUID,
                unvalue: u32,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.SetUINT32(guidkey, unvalue) }
            }
            fn SetUINT64(
                &self,
                guidkey: *const windows::core::GUID,
                unvalue: u64,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.SetUINT64(guidkey, unvalue) }
            }
            fn SetDouble(
                &self,
                guidkey: *const windows::core::GUID,
                fvalue: f64,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.SetDouble(guidkey, fvalue) }
            }
            fn SetGUID(
                &self,
                guidkey: *const windows::core::GUID,
                guidvalue: *const windows::core::GUID,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.SetGUID(guidkey, guidvalue) }
            }
            fn SetBlob(
                &self,
                guidkey: *const windows::core::GUID,
                pbuf: *const u8,
                cbbufsize: u32,
            ) -> windows::core::Result<()> {
                let buf = unsafe { $crate::attrs::in_slice(pbuf, cbbufsize) };
                unsafe { self.attrs.SetBlob(guidkey, buf) }
            }
            fn LockStore(&self) -> windows::core::Result<()> {
                unsafe { self.attrs.LockStore() }
            }
            fn UnlockStore(&self) -> windows::core::Result<()> {
                unsafe { self.attrs.UnlockStore() }
            }
            fn GetCount(&self) -> windows::core::Result<u32> {
                unsafe { self.attrs.GetCount() }
            }
            fn GetItemByIndex(
                &self,
                unindex: u32,
                pguidkey: *mut windows::core::GUID,
                pvalue: *mut windows::Win32::System::Com::StructuredStorage::PROPVARIANT,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.GetItemByIndex(unindex, pguidkey, Some(pvalue)) }
            }
            fn CopyAllItems(
                &self,
                pdest: windows::core::Ref<
                    windows::Win32::Media::MediaFoundation::IMFAttributes,
                >,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.CopyAllItems(pdest.ok()?) }
            }
            fn GetAllocatedString(
                &self,
                guidkey: *const windows::core::GUID,
                ppwszvalue: *mut windows::core::PWSTR,
                pcchlength: *mut u32,
            ) -> windows::core::Result<()> {
                unsafe { self.attrs.GetAllocatedString(guidkey, ppwszvalue, pcchlength) }
            }
            fn DeleteItem(&self, guidkey: *const windows::core::GUID) -> windows::core::Result<()> {
                unsafe { self.attrs.DeleteItem(guidkey) }
            }
        }
    };
}


