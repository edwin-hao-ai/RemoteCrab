//! `rc-vcam-source` — the in-proc COM `IMFMediaSource` behind the virtual
//! camera.
//!
//! A consuming app (Camera.exe, Zoom, OBS) — and the Windows **Frame Server**
//! services — activate this by the CLSID registered under
//! `HKLM\Software\Classes\CLSID\...` (see `rc-vcam::install_source`). The
//! frame server activates an `IMFActivate` (not the media source directly),
//! so the class factory returns [`activator::VcamActivator`], whose
//! `ActivateObject` builds the [`source::VcamSource`] + [`stream::VcamStream`]
//! pair. The stream exposes one RGB32 video stream and pulls the newest BGRA
//! frame from the shared-memory ring the RemoteCrab app fills.
//!
//! Windows-only (it is a COM server).

#![cfg(windows)]

mod activator;
mod attrs;
mod exports;
mod ring;
mod source;
mod stream;
mod trace;

use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};

/// Lock that survives a poisoned mutex.
///
/// This DLL runs inside the Windows Frame Server, so a panic does not stay
/// local: `extern "system"` is not unwind-safe, and a panic crossing it aborts
/// the process — which is the Frame Server for *every* camera consumer, not
/// just ours. `lock().unwrap()` is the mechanism that turns one unrelated panic
/// into exactly that, because the next call after a poisoned lock panics again.
///
/// The guarded values are plain fields and an `Option`, so a poisoned lock still
/// holds valid data. Recover the guard and carry on.
pub(crate) fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

use windows::core::{Interface, Result, GUID, IUnknown};
use windows::Win32::Foundation::S_OK;
use windows::Win32::Media::KernelStreaming::{
    KSCAMERAPROFILE_HighFrameRate, KSCAMERAPROFILE_Legacy,
};
use windows::Win32::Media::MediaFoundation::{
    IMFAttributes, IMFMediaEventQueue, IMFMediaSource, IMFMediaSourceEx, IMFMediaStream2,
    IMFPresentationDescriptor, IMFSample, MFCreateEventQueue, MFCreateMediaType,
    MFCreateMemoryBuffer, MFCreatePresentationDescriptor, MFCreateSample, MFCreateSensorProfile,
    MFCreateSensorProfileCollection, MF_DEVICEMFT_SENSORPROFILE_COLLECTION, MFMediaType_Video,
    MFSTARTUP_LITE, MFStartup, MFSampleExtension_Token,
    MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES, MFT_TRANSFORM_CLSID_Attribute,
    MF_MT_ALL_SAMPLES_INDEPENDENT, MF_MT_AVG_BITRATE, MF_MT_DEFAULT_STRIDE, MF_MT_FRAME_RATE,
    MF_MT_FRAME_SIZE, MF_MT_INTERLACE_MODE, MF_MT_MAJOR_TYPE, MF_MT_PIXEL_ASPECT_RATIO,
    MF_MT_SUBTYPE, MFVideoInterlace_Progressive, MEMediaSample,
};

pub use ring::SOURCE_CLSID;

pub(crate) use attrs::new_attributes;
pub(crate) use source::VcamSource;
pub(crate) use stream::VcamStream;

pub(crate) const DEFAULT_W: u32 = 1280;
pub(crate) const DEFAULT_H: u32 = 720;
pub(crate) const DEFAULT_FPS: u32 = 30;

/// Process-wide state shared by the source and the stream.
pub(crate) struct Inner {
    pub running: AtomicBool,
    pub shutdown: AtomicBool,
}

impl Default for Inner {
    fn default() -> Self {
        Inner {
            running: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
        }
    }
}

/// Construction state, so the source and stream can be wired without casting
/// through COM (the `#[implement]` wrappers are not `Interface`).
pub(crate) struct SharedState {
    pub presentation: Mutex<Option<IMFPresentationDescriptor>>,
    pub source: Mutex<Option<IMFMediaSource>>,
    pub stream_attrs: Mutex<Option<IMFAttributes>>,
}

// SAFETY: with `ThreadingModel = Both` the wrapper may be called from any
// apartment, but every field is `Mutex`-guarded and the only shared payloads
// are agile in-proc COM pointers. The object never leaves this process.
unsafe impl Send for SharedState {}
unsafe impl Sync for SharedState {}

pub(crate) fn ensure_mf() {
    use std::sync::OnceLock;
    static ONCE: OnceLock<()> = OnceLock::new();
    ONCE.get_or_init(|| unsafe {
        let _ = MFStartup(0x0002_0070, MFSTARTUP_LITE);
    });
}

/// The stream's shared core: both the COM wrapper and the source's event
/// plumbing need it. One `Arc`, no leaking or re-casting.
pub(crate) struct StreamCore {
    pub queue: IMFMediaEventQueue,
    pub reader: Mutex<Option<ring::RingReader>>,
    /// The geometry declared in the media type; mismatched ring frames are
    /// skipped rather than handed to MF.
    pub width: u32,
    pub height: u32,
    /// Last sample timestamp handed to Media Foundation, in 100 ns units on
    /// `MFGetSystemTime()`'s timeline (reset every time the stream enters
    /// `RUNNING`). MF's source reader schedules samples against that clock —
    /// stamping a local counter (the ring's `frame_seq`, or 0-based ordinal)
    /// lands far outside MF's timeline and the samples are dropped, so
    /// `ReadSample` hangs behind a permanent `MFSRC_STREAMTICK`.
    pub last_sample_time: std::sync::atomic::AtomicI64,
}

// SAFETY: the only cross-thread access is the `Mutex`-guarded reader and the
// COM event queue (agile for our in-proc server). See `SharedState`.
unsafe impl Send for StreamCore {}
unsafe impl Sync for StreamCore {}

impl StreamCore {
    /// Restart the sample clock — called when the stream starts streaming.
    pub(crate) fn reset_sample_clock(&self) {
        self.last_sample_time
            .store(0, std::sync::atomic::Ordering::Relaxed);
    }

    /// Next strictly-increasing sample timestamp on MF's system timeline.
    fn next_sample_time(&self, duration: i64) -> i64 {
        use std::sync::atomic::Ordering::Relaxed;
        let now = unsafe { windows::Win32::Media::MediaFoundation::MFGetSystemTime() };
        let prev = self.last_sample_time.load(Relaxed);
        let t = if now > prev { now } else { prev + duration };
        self.last_sample_time.store(t, Relaxed);
        t
    }

    /// Queue the newest ring frame as `MEMediaSample`.
    pub(crate) fn feed_once(&self, token: Option<&IUnknown>) -> Result<bool> {
        let frame = {
            let mut guard = lock(&self.reader);
            // The camera source may be activated before the app has created
            // the ring (the user opens the Camera app first); open it lazily.
            if guard.is_none() {
                *guard = ring::RingReader::open();
                crate::trace::log(format!(
                    "feed_once: ring open -> {} path={:?}",
                    guard.is_some(),
                    ring::ring_path()
                ));
            }
            match guard.as_ref() {
                Some(r) => r.latest_frame(),
                None => None,
            }
        };
        let Some((hdr, bgra)) = frame else {
            crate::trace::log("feed_once -> no frame in ring");
            return Ok(false);
        };
        if hdr.width != self.width || hdr.height != self.height {
            crate::trace::log(format!(
                "feed_once -> size mismatch {}x{} vs {}x{}",
                hdr.width, hdr.height, self.width, self.height
            ));
            return Ok(false);
        }

        let buffer = unsafe { MFCreateMemoryBuffer(bgra.len() as u32)? };
        unsafe {
            let mut ptr = std::ptr::null_mut();
            buffer.Lock(&mut ptr, None, None)?;
            std::ptr::copy_nonoverlapping(bgra.as_ptr(), ptr, bgra.len());
            buffer.Unlock()?;
            buffer.SetCurrentLength(bgra.len() as u32)?;
        }
        let dur = 10_000_000i64 / hdr.fps.max(1) as i64;
        let sample: IMFSample = unsafe {
            let s = MFCreateSample()?;
            s.AddBuffer(&buffer)?;
            s.SetSampleTime(self.next_sample_time(dur))?;
            s.SetSampleDuration(dur)?;
            s
        };
        if let Some(t) = token {
            unsafe { sample.SetUnknown(&MFSampleExtension_Token, t)? };
        }

        let unknown: IUnknown = sample.cast()?;
        unsafe {
            self.queue.QueueEventParamUnk(
                MEMediaSample.0 as u32,
                &GUID::zeroed(),
                S_OK,
                &unknown,
            )?;
        }
        crate::trace::log(format!("feed_once -> queued MEMediaSample frame_seq={}", hdr.frame_seq));
        Ok(true)
    }
}

/// Build a video media type (RGB32 or NV12) at `w`×`h` @ `fps`.
pub(crate) fn make_video_type(
    subtype: &windows::core::GUID,
    stride: u32,
    w: u32,
    h: u32,
    fps: u32,
) -> Result<windows::Win32::Media::MediaFoundation::IMFMediaType> {
    ensure_mf();
    let mt = unsafe { MFCreateMediaType()? };
    unsafe {
        mt.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        mt.SetGUID(&MF_MT_SUBTYPE, subtype)?;
        mt.SetUINT64(&MF_MT_FRAME_SIZE, ((w as u64) << 32) | h as u64)?;
        mt.SetUINT64(&MF_MT_FRAME_RATE, ((fps.max(1) as u64) << 32) | 1)?;
        mt.SetUINT32(&MF_MT_DEFAULT_STRIDE, stride)?;
        mt.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        mt.SetUINT32(&MF_MT_ALL_SAMPLES_INDEPENDENT, 1)?;
        mt.SetUINT32(
            &MF_MT_AVG_BITRATE,
            stride
                .saturating_mul(h)
                .saturating_mul(8)
                .saturating_mul(fps.max(1)),
        )?;
        mt.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1)?;
    }
    Ok(mt)
}

/// Populate the source attributes the way the reference virtual camera does:
/// the vcam identity attributes plus a sensor-profile collection (the frame
/// server uses it to enumerate the stream's supported formats).
fn fill_source_attributes(attrs: &IMFAttributes) -> Result<()> {
    unsafe {
        let _ = attrs.SetUINT32(&MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES, 1);
        let _ = attrs.SetGUID(&MFT_TRANSFORM_CLSID_Attribute, &SOURCE_CLSID);
        let collection = MFCreateSensorProfileCollection()?;
        let legacy = MFCreateSensorProfile(&KSCAMERAPROFILE_Legacy, 0, windows::core::PCWSTR::null())?;
        legacy.AddProfileFilter(0, windows::core::w!("((RES==;FRT<=30,1;SUT==))"))?;
        collection.AddProfile(&legacy)?;
        let high = MFCreateSensorProfile(
            &KSCAMERAPROFILE_HighFrameRate,
            0,
            windows::core::PCWSTR::null(),
        )?;
        high.AddProfileFilter(0, windows::core::w!("((RES==;FRT>=60,1;SUT==))"))?;
        collection.AddProfile(&high)?;
        let collection_unknown: IUnknown = collection.cast()?;
        attrs.SetUnknown(&MF_DEVICEMFT_SENSORPROFILE_COLLECTION, &collection_unknown)?;
    }
    Ok(())
}

/// Build a matched (source, stream, presentation-descriptor) triple and
/// publish the source so `stream.GetMediaSource()` can answer.
pub(crate) fn build_source() -> Result<IMFMediaSource> {
    ensure_mf();
    let source_attrs = new_attributes(8)?;
    fill_source_attributes(&source_attrs)?;
    let inner = Arc::new(Inner::default());
    let shared = Arc::new(SharedState {
        presentation: Mutex::new(None),
        source: Mutex::new(None),
        stream_attrs: Mutex::new(None),
    });

    let stream_impl = VcamStream::new(inner.clone(), shared.clone())?;
    let stream: IMFMediaStream2 = stream_impl.into();

    // Expose the *stream object itself* as the stream's attribute store (it
    // implements IMFAttributes). The frame server reads `MF_DEVICESTREAM_*`
    // through it and also expects to be able to query IMFMediaStream2.
    let stream_attrs: IMFAttributes = stream.cast()?;
        *lock(&shared.stream_attrs) = Some(stream_attrs);

    let sd = unsafe { stream.GetStreamDescriptor()? };
    let presentation = unsafe { MFCreatePresentationDescriptor(Some(&[Some(sd.clone())]))? };
    // The stream must be selected for the frame server to stream it.
    unsafe {
        let _ = presentation.SelectStream(0);
    }
        *lock(&shared.presentation) = Some(presentation.clone());

    let source_impl = VcamSource::new(
        inner,
        source_attrs,
        unsafe { MFCreateEventQueue()? },
        stream,
        presentation,
        shared.clone(),
    );
    let source_ex: IMFMediaSourceEx = source_impl.into();
    let source: IMFMediaSource = source_ex.cast()?;
        *lock(&shared.source) = Some(source.clone());
    Ok(source)
}
