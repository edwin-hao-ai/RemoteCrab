//! `IMFMediaSourceEx` — the top-level object the frame server talks to.
//!
//! It owns the event queue, the presentation descriptor and the single
//! stream, and implements the extra interfaces (`IMFAttributes`,
//! `IMFGetService`, `IKsControl`, `IMFSampleAllocatorControl`) the virtual
//! camera pipeline queries for.

#![cfg(windows)]

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use windows::core::{implement, Error, Interface, Ref, Result, GUID, IUnknown, IUnknownImpl};
use windows::Win32::Foundation::{E_INVALIDARG, S_OK};
use windows::Win32::Media::KernelStreaming::{IKsControl, IKsControl_Impl, KSIDENTIFIER};
use windows::Win32::Media::MediaFoundation::{
    IMFAttributes, IMFGetService, IMFGetService_Impl,
    IMFMediaEvent, IMFMediaEventGenerator_Impl,
    IMFMediaEventQueue, IMFMediaSourceEx, IMFMediaSourceEx_Impl, IMFMediaSource_Impl,
    IMFPresentationDescriptor, IMFSampleAllocatorControl, IMFSampleAllocatorControl_Impl,
    IMFMediaStream2, MENewStream, MESourceStarted, MESourceStopped, MF_E_INVALID_STATE_TRANSITION,
    MF_E_SHUTDOWN, MF_E_UNSUPPORTED_SERVICE, MF_STREAM_STATE_RUNNING, MFMEDIASOURCE_IS_LIVE,
    MFSampleAllocatorUsage_UsesProvidedAllocator,
};
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;

use crate::impl_imf_attributes;
use crate::stream::ks_not_found;
use crate::{Inner, SharedState};

#[implement(
    IMFMediaSourceEx,
    IMFAttributes,
    IMFGetService,
    IKsControl,
    IMFSampleAllocatorControl
)]
pub struct VcamSource {
    pub(crate) inner: Arc<Inner>,
    pub(crate) attrs: IMFAttributes,
    pub(crate) queue: IMFMediaEventQueue,
    stream: Mutex<Option<IMFMediaStream2>>,
    presentation: Mutex<Option<IMFPresentationDescriptor>>,
    shared: Arc<SharedState>,
}

impl VcamSource {
    pub(crate) fn new(
        inner: Arc<Inner>,
        attrs: IMFAttributes,
        queue: IMFMediaEventQueue,
        stream: IMFMediaStream2,
        presentation: IMFPresentationDescriptor,
        shared: Arc<SharedState>,
    ) -> Self {
        VcamSource {
            inner,
            attrs,
            queue,
            stream: Mutex::new(Some(stream)),
            presentation: Mutex::new(Some(presentation)),
            shared,
        }
    }
}

impl_imf_attributes!(VcamSource_Impl);

impl IMFMediaEventGenerator_Impl for VcamSource_Impl {
    fn GetEvent(
        &self,
        dwflags: windows::Win32::Media::MediaFoundation::MEDIA_EVENT_GENERATOR_GET_EVENT_FLAGS,
    ) -> Result<IMFMediaEvent> {
        if self.inner.shutdown.load(Ordering::Relaxed) {
            return Err(Error::from(MF_E_SHUTDOWN));
        }
        unsafe { self.queue.GetEvent(dwflags.0) }
    }

    fn BeginGetEvent(
        &self,
        pcallback: Ref<windows::Win32::Media::MediaFoundation::IMFAsyncCallback>,
        punkstate: Ref<IUnknown>,
    ) -> Result<()> {
        if self.inner.shutdown.load(Ordering::Relaxed) {
            return Err(Error::from(MF_E_SHUTDOWN));
        }
        let cb = pcallback.ok()?;
        // `punkState` is optional; MF passes NULL routinely.
        let state: Option<&IUnknown> = if punkstate.is_null() {
            None
        } else {
            Some(punkstate.ok()?)
        };
        unsafe { self.queue.BeginGetEvent(cb, state) }
    }

    fn EndGetEvent(
        &self,
        presult: Ref<windows::Win32::Media::MediaFoundation::IMFAsyncResult>,
    ) -> Result<IMFMediaEvent> {
        let result = presult.ok()?;
        unsafe { self.queue.EndGetEvent(result) }
    }

    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    fn QueueEvent(
        &self,
        met: u32,
        guidextendedtype: *const GUID,
        hrstatus: windows::core::HRESULT,
        pvvalue: *const PROPVARIANT,
    ) -> Result<()> {
        unsafe { self.queue.QueueEventParamVar(met, guidextendedtype, hrstatus, pvvalue) }
    }
}

impl IMFMediaSource_Impl for VcamSource_Impl {
    fn GetCharacteristics(&self) -> Result<u32> {
        Ok(MFMEDIASOURCE_IS_LIVE.0 as u32)
    }

    fn CreatePresentationDescriptor(&self) -> Result<IMFPresentationDescriptor> {
        let pd = crate::lock(&self.presentation)
            .clone()
            .ok_or_else(|| Error::from(MF_E_SHUTDOWN))?;
        // The contract says "a copy": hand the caller a clone, so it can
        // select/deselect streams without disturbing ours.
        unsafe { pd.Clone() }
    }

    fn Start(
        &self,
        _pd: Ref<IMFPresentationDescriptor>,
        time_format: *const GUID,
        _start_position: *const PROPVARIANT,
    ) -> Result<()> {
        crate::trace::log(format!(
            "Source::Start pd_null={} timefmt_null={} startpos_null={}",
            _pd.is_null(),
            time_format.is_null(),
            _start_position.is_null()
        ));
        if self.inner.shutdown.load(Ordering::Relaxed) {
            return Err(Error::from(MF_E_SHUTDOWN));
        }
        if !time_format.is_null() {
            let g = unsafe { *time_format };
            if g != GUID::zeroed() {
                return Err(Error::from(E_INVALIDARG));
            }
        }
        self.inner.running.store(true, Ordering::Relaxed);
        let stream = crate::lock(&self.stream).clone();
        unsafe {
            self.queue.QueueEventParamVar(
                MESourceStarted.0 as u32,
                &GUID::zeroed(),
                S_OK,
                std::ptr::null(),
            )?;
            if let Some(s) = stream.as_ref() {
                let unknown: IUnknown = s.cast()?;
                self.queue
                    .QueueEventParamUnk(MENewStream.0 as u32, &GUID::zeroed(), S_OK, &unknown)?;
            }
        }
        // Put the stream into RUNNING (queues MEStreamStarted on the stream's
        // own queue); without this the frame server never requests samples.
        if let Some(s) = stream.as_ref() {
            let _ = unsafe { s.SetStreamState(MF_STREAM_STATE_RUNNING) };
        }
        Ok(())
    }

    fn Stop(&self) -> Result<()> {
        crate::trace::log("Source::Stop");
        self.inner.running.store(false, Ordering::Relaxed);
        unsafe {
            self.queue.QueueEventParamVar(
                MESourceStopped.0 as u32,
                &GUID::zeroed(),
                S_OK,
                std::ptr::null(),
            )?;
        }
        Ok(())
    }

    fn Pause(&self) -> Result<()> {
        Err(Error::from(MF_E_INVALID_STATE_TRANSITION))
    }

    fn Shutdown(&self) -> Result<()> {
        crate::trace::log("Source::Shutdown");
        self.inner.running.store(false, Ordering::Relaxed);
        self.inner.shutdown.store(true, Ordering::Relaxed);
        let _ = unsafe { self.queue.Shutdown() };
        Ok(())
    }
}

impl IMFMediaSourceEx_Impl for VcamSource_Impl {
    fn GetSourceAttributes(&self) -> Result<IMFAttributes> {
        // Return *this* object as the attribute store (the reference sample
        // does the same); its IMFAttributes delegates to `self.attrs`.
        Ok(self.to_interface())
    }

    fn GetStreamAttributes(&self, dwstreamidentifier: u32) -> Result<IMFAttributes> {
        if dwstreamidentifier != 0 {
            return Err(Error::from(E_INVALIDARG));
        }
        crate::lock(&self.shared.stream_attrs)
            .clone()
            .ok_or_else(|| Error::from(E_INVALIDARG))
    }

    fn SetD3DManager(&self, _pmanager: Ref<IUnknown>) -> Result<()> {
        Ok(())
    }
}

impl IMFGetService_Impl for VcamSource_Impl {
    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    fn GetService(
        &self,
        _guidservice: *const GUID,
        _riid: *const GUID,
        ppvobject: *mut *mut std::ffi::c_void,
    ) -> Result<()> {
        if !ppvobject.is_null() {
            unsafe { *ppvobject = std::ptr::null_mut() };
        }
        // Media Foundation's contract: an unsupported service is
        // `MF_E_UNSUPPORTED_SERVICE`, not `E_NOINTERFACE`.
        Err(Error::from(MF_E_UNSUPPORTED_SERVICE))
    }
}

impl IKsControl_Impl for VcamSource_Impl {
    fn KsProperty(
        &self,
        _property: *const KSIDENTIFIER,
        _propertylength: u32,
        _propertydata: *mut std::ffi::c_void,
        _datalength: u32,
        bytesreturned: *mut u32,
    ) -> Result<()> {
        if !bytesreturned.is_null() {
            unsafe { *bytesreturned = 0 };
        }
        Err(ks_not_found())
    }

    fn KsMethod(
        &self,
        _method: *const KSIDENTIFIER,
        _methodlength: u32,
        _methoddata: *mut std::ffi::c_void,
        _datalength: u32,
        bytesreturned: *mut u32,
    ) -> Result<()> {
        if !bytesreturned.is_null() {
            unsafe { *bytesreturned = 0 };
        }
        Err(ks_not_found())
    }

    fn KsEvent(
        &self,
        _event: *const KSIDENTIFIER,
        _eventlength: u32,
        _eventdata: *mut std::ffi::c_void,
        _datalength: u32,
        bytesreturned: *mut u32,
    ) -> Result<()> {
        if !bytesreturned.is_null() {
            unsafe { *bytesreturned = 0 };
        }
        Err(ks_not_found())
    }
}

impl IMFSampleAllocatorControl_Impl for VcamSource_Impl {
    fn SetDefaultAllocator(
        &self,
        _dwoutputstreamid: u32,
        _pallocator: Ref<IUnknown>,
    ) -> Result<()> {
        // We report `UsesCustomAllocator`, so the frame server should not hand
        // us one; accept and ignore it if it does.
        Ok(())
    }

    fn GetAllocatorUsage(
        &self,
        dwoutputstreamid: u32,
        pdwinputstreamid: *mut u32,
        peusage: *mut windows::Win32::Media::MediaFoundation::MFSampleAllocatorUsage,
    ) -> Result<()> {
        if !pdwinputstreamid.is_null() {
            unsafe { *pdwinputstreamid = dwoutputstreamid };
        }
        if !peusage.is_null() {
            unsafe { *peusage = MFSampleAllocatorUsage_UsesProvidedAllocator };
        }
        Ok(())
    }
}
