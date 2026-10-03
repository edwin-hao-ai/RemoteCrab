//! `IMFMediaStream2` - the single video stream the frame server pulls from.
//!
//! The frame server starts it with `SetStreamState(RUNNING)` and then calls
//! `RequestSample` for each frame; we answer by queueing an `MEMediaSample`
//! copied out of the shared-memory ring.

#![cfg(windows)]

use std::sync::atomic::{AtomicI32, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use windows::core::{implement, Error, Ref, Result, GUID, IUnknown};
use windows::Win32::Foundation::ERROR_SET_NOT_FOUND;
use windows::Win32::Media::KernelStreaming::{
    IKsControl, IKsControl_Impl, KSIDENTIFIER, PINNAME_VIDEO_CAPTURE,
};
use windows::Win32::Media::MediaFoundation::{
    IMFAttributes, IMFMediaEvent, IMFMediaEventGenerator_Impl, IMFMediaSource, IMFMediaStream2,
    IMFMediaStream2_Impl, IMFMediaStream_Impl, IMFStreamDescriptor, MFCreateStreamDescriptor,
    MEStreamStarted, MEStreamStopped, MF_E_INVALID_STATE_TRANSITION,
    MF_E_SHUTDOWN, MF_STREAM_STATE, MF_STREAM_STATE_PAUSED, MF_STREAM_STATE_RUNNING,
    MF_STREAM_STATE_STOPPED, MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES,
    MF_DEVICESTREAM_FRAMESERVER_SHARED, MF_DEVICESTREAM_STREAM_CATEGORY, MF_DEVICESTREAM_STREAM_ID,
    MFFrameSourceTypes_Color, MFCreateEventQueue,
};
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;

use crate::attrs::new_attributes;
use crate::impl_imf_attributes;
use crate::{
    ensure_mf, make_video_type, ring, Inner, SharedState, StreamCore, DEFAULT_FPS, DEFAULT_H,
    DEFAULT_W,
};

#[implement(IMFMediaStream2, IMFAttributes, IKsControl)]
pub struct VcamStream {
    pub(crate) inner: Arc<Inner>,
    pub(crate) attrs: IMFAttributes,
    descriptor: IMFStreamDescriptor,
    pub(crate) core: Arc<StreamCore>,
    shared: Arc<SharedState>,
    state: AtomicI32,
}

/// How long to wait for the ring to declare a real geometry before advertising
/// [`DEFAULT_W`]×[`DEFAULT_H`] instead.
///
/// The stream descriptor is built **once**, and the frame server negotiates
/// against it. So the geometry we pick here is the geometry the consumer is
/// stuck with for the whole session — there is no renegotiation. Picking the
/// 720p default while the ring was merely *not ready yet* therefore locks a
/// 1080×1920 phone stream to 720p, permanently, and the user sees a soft image
/// with nothing in the log to explain it.
///
/// Bounded, because this runs on a Frame Server thread: an unbounded wait would
/// stall activation for every other app on the machine. 1.2 s is long enough to
/// cover the app decoding its first frame — which it does in tens of
/// milliseconds when it is already streaming — and short enough to be invisible
/// in the normal case where the ring is already there.
const GEOMETRY_WAIT: std::time::Duration = std::time::Duration::from_millis(1200);
const GEOMETRY_POLL: std::time::Duration = std::time::Duration::from_millis(40);

/// A geometry worth advertising. A zero dimension means "not written yet", not
/// "zero-sized camera".
fn usable_geometry(w: u32, h: u32) -> bool {
    w > 0 && h > 0
}

/// The geometry the ring currently claims, or `None` while it has none.
///
/// Pure, so the decision — which is the part that was wrong — is testable
/// without a live ring or a sleeping test.
fn geometry_from(hdr: Option<&rc_vcam::shm::Header>) -> Option<(u32, u32, u32)> {
    let hdr = hdr?;
    if !usable_geometry(hdr.width, hdr.height) {
        return None;
    }
    Some((hdr.width, hdr.height, hdr.fps.max(1)))
}

/// Open the ring and read its geometry, waiting briefly for it to appear.
///
/// Returns the reader to keep using, plus the geometry to advertise. The reader
/// is re-opened on each poll because the ring file may not exist yet at all, and
/// a reader that failed to open cannot start succeeding on its own.
fn open_ring_with_geometry() -> (Option<ring::RingReader>, (u32, u32, u32)) {
    let deadline = std::time::Instant::now() + GEOMETRY_WAIT;
    loop {
        let reader = ring::RingReader::open();
        if let Some(r) = reader.as_ref() {
            if let Some(g) = geometry_from(r.header().as_ref()) {
                return (reader, g);
            }
        }
        if std::time::Instant::now() >= deadline {
            // Nothing after the full wait. Advertise the default anyway: a camera
            // that appears and shows black is more useful than one missing from
            // the list, and this is the same answer the product gave before.
            return (reader, (DEFAULT_W, DEFAULT_H, DEFAULT_FPS));
        }
        std::thread::sleep(GEOMETRY_POLL);
    }
}

impl VcamStream {
    pub(crate) fn new(inner: Arc<Inner>, shared: Arc<SharedState>) -> Result<Self> {
        ensure_mf();
        let (reader, (w, h, fps)) = open_ring_with_geometry();

        // RGB32 only: the ring delivers BGRA and forcing one format avoids the
        // frame server negotiating NV12 and mis-rendering our samples.
        let rgb = make_video_type(
            &windows::Win32::Media::MediaFoundation::MFVideoFormat_RGB32,
            w * 4,
            w,
            h,
            fps,
        )?;
        let descriptor = unsafe { MFCreateStreamDescriptor(0, &[Some(rgb.clone())])? };
        if let Ok(handler) = unsafe { descriptor.GetMediaTypeHandler() } {
            let _ = unsafe { handler.SetCurrentMediaType(&rgb) };
        }

        // The frame server reads these off the stream (via
        // `IMFMediaSourceEx::GetStreamAttributes`). Put them on the stream
        // descriptor too, in case it enumerates the descriptor directly.
        let attrs = new_attributes(4)?;
        set_stream_attributes(&attrs, "stream.attrs");
        set_stream_attributes(&descriptor, "stream.descriptor");

        let queue = unsafe { MFCreateEventQueue()? };
        Ok(VcamStream {
            inner,
            attrs,
            descriptor,
            core: Arc::new(StreamCore {
                queue,
                reader: Mutex::new(reader),
                width: w,
                height: h,
                last_sample_time: AtomicI64::new(0),
            }),
            shared,
            state: AtomicI32::new(MF_STREAM_STATE_STOPPED.0),
        })
    }
}

/// Stamp the `MF_DEVICESTREAM_*` attributes the frame server expects.
fn set_stream_attributes(t: &IMFAttributes, label: &str) {
    unsafe {
        let cat = t.SetGUID(&MF_DEVICESTREAM_STREAM_CATEGORY, &PINNAME_VIDEO_CAPTURE);
        let id = t.SetUINT32(&MF_DEVICESTREAM_STREAM_ID, 0);
        let shared = t.SetUINT32(&MF_DEVICESTREAM_FRAMESERVER_SHARED, 1);
        let ty = t.SetUINT32(
            &MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES,
            MFFrameSourceTypes_Color.0 as u32,
        );
        if cat.is_err() || id.is_err() || shared.is_err() || ty.is_err() {
            crate::trace::log(format!("{label}: stream attributes incomplete"));
        }
    }
}

impl_imf_attributes!(VcamStream_Impl);

impl IMFMediaEventGenerator_Impl for VcamStream_Impl {
    fn GetEvent(
        &self,
        dwflags: windows::Win32::Media::MediaFoundation::MEDIA_EVENT_GENERATOR_GET_EVENT_FLAGS,
    ) -> Result<IMFMediaEvent> {
        if self.inner.shutdown.load(Ordering::Relaxed) {
            return Err(Error::from(MF_E_SHUTDOWN));
        }
        unsafe { self.core.queue.GetEvent(dwflags.0) }
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
        let state: Option<&IUnknown> = if punkstate.is_null() {
            None
        } else {
            Some(punkstate.ok()?)
        };
        unsafe { self.core.queue.BeginGetEvent(cb, state) }
    }

    fn EndGetEvent(
        &self,
        presult: Ref<windows::Win32::Media::MediaFoundation::IMFAsyncResult>,
    ) -> Result<IMFMediaEvent> {
        let result = presult.ok()?;
        unsafe { self.core.queue.EndGetEvent(result) }
    }

    // The COM signature passes raw pointers; forwarding them is sound because
    // Media Foundation owns their lifetime.
    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    fn QueueEvent(
        &self,
        met: u32,
        guidextendedtype: *const GUID,
        hrstatus: windows::core::HRESULT,
        pvvalue: *const PROPVARIANT,
    ) -> Result<()> {
        unsafe { self.core.queue.QueueEventParamVar(met, guidextendedtype, hrstatus, pvvalue) }
    }
}

impl IMFMediaStream_Impl for VcamStream_Impl {
    fn GetMediaSource(&self) -> Result<IMFMediaSource> {
        self.shared
            .source
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| Error::from(MF_E_SHUTDOWN))
    }

    fn GetStreamDescriptor(&self) -> Result<IMFStreamDescriptor> {
        Ok(self.descriptor.clone())
    }

    fn RequestSample(&self, ptoken: Ref<IUnknown>) -> Result<()> {
        if self.inner.shutdown.load(Ordering::Relaxed) {
            return Err(Error::from(MF_E_SHUTDOWN));
        }
        let token = if ptoken.is_null() {
            None
        } else {
            Some(ptoken.ok()?)
        };
        let _ = self.core.feed_once(token)?;
        Ok(())
    }
}

impl IMFMediaStream2_Impl for VcamStream_Impl {
    fn SetStreamState(&self, value: MF_STREAM_STATE) -> Result<()> {
        crate::trace::log(format!("Stream::SetStreamState {}", value.0));
        if self.inner.shutdown.load(Ordering::Relaxed) {
            return Err(Error::from(MF_E_SHUTDOWN));
        }
        let current = self.state.load(Ordering::Relaxed);
        if current == value.0 {
            return Ok(());
        }
        if value.0 == MF_STREAM_STATE_RUNNING.0 {
            self.inner.running.store(true, Ordering::Relaxed);
            self.state.store(value.0, Ordering::Relaxed);
            // The sample clock is restarted for every streaming session.
            self.core.reset_sample_clock();
            unsafe {
                self.core.queue.QueueEventParamVar(
                    MEStreamStarted.0 as u32,
                    &GUID::zeroed(),
                    windows::Win32::Foundation::S_OK,
                    std::ptr::null(),
                )?;
            }
            Ok(())
        } else if value.0 == MF_STREAM_STATE_STOPPED.0 {
            self.inner.running.store(false, Ordering::Relaxed);
            self.state.store(value.0, Ordering::Relaxed);
            unsafe {
                self.core.queue.QueueEventParamVar(
                    MEStreamStopped.0 as u32,
                    &GUID::zeroed(),
                    windows::Win32::Foundation::S_OK,
                    std::ptr::null(),
                )?;
            }
            Ok(())
        } else if value.0 == MF_STREAM_STATE_PAUSED.0 {
            if current == MF_STREAM_STATE_RUNNING.0 {
                self.state.store(value.0, Ordering::Relaxed);
                Ok(())
            } else {
                Err(Error::from(MF_E_INVALID_STATE_TRANSITION))
            }
        } else {
            Err(Error::from(MF_E_INVALID_STATE_TRANSITION))
        }
    }

    fn GetStreamState(&self) -> Result<MF_STREAM_STATE> {
        Ok(MF_STREAM_STATE(self.state.load(Ordering::Relaxed)))
    }
}

impl IKsControl_Impl for VcamStream_Impl {
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

/// `HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND)` - what the samples return for
/// unsupported KS properties.
pub(crate) fn ks_not_found() -> Error {
    Error::from(windows::core::HRESULT::from_win32(ERROR_SET_NOT_FOUND.0))
}

#[cfg(test)]
mod tests {
    use super::{geometry_from, usable_geometry, DEFAULT_H, DEFAULT_W};
    use rc_vcam::shm::Header;

    fn hdr(w: u32, h: u32, fps: u32) -> Header {
        Header {
            version: 1,
            width: w,
            height: h,
            fps,
            stride: w * 4,
            frame_seq: 1,
            write_idx: 0,
        }
    }

    /// The bug this file's wait exists for: a ring that has not been written
    /// yet reports zero dimensions, and treating that as a real geometry is what
    /// latched consumers to 720p for the rest of the session.
    #[test]
    fn a_ring_with_no_geometry_yields_none_not_a_default() {
        assert_eq!(geometry_from(None), None);
        assert_eq!(geometry_from(Some(&hdr(0, 0, 30))), None);
        assert_eq!(geometry_from(Some(&hdr(1080, 0, 30))), None);
        assert_eq!(geometry_from(Some(&hdr(0, 1920, 30))), None);
    }

    /// And the geometry that must survive is the phone's, not the default.
    #[test]
    fn a_ready_ring_reports_its_own_resolution() {
        assert_eq!(geometry_from(Some(&hdr(1080, 1920, 30))), Some((1080, 1920, 30)));
    }

    /// A frame rate of zero would divide by zero downstream, so it is floored
    /// rather than advertised.
    #[test]
    fn a_zero_frame_rate_is_floored_rather_than_advertised() {
        assert_eq!(geometry_from(Some(&hdr(640, 480, 0))), Some((640, 480, 1)));
    }

    #[test]
    fn usable_geometry_rejects_only_zero_dimensions() {
        assert!(usable_geometry(1, 1));
        assert!(usable_geometry(DEFAULT_W, DEFAULT_H));
        assert!(!usable_geometry(0, DEFAULT_H));
        assert!(!usable_geometry(DEFAULT_W, 0));
        assert!(!usable_geometry(0, 0));
    }
}