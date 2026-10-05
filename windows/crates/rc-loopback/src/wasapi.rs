//! The COM/WASAPI half: everything that can only run on Windows.
//!
//! # Why a dedicated thread owns everything
//!
//! Three constraints force this shape, and none of them are stylistic:
//!
//! 1. **COM apartment.** `CoInitializeEx` applies to the thread that calls it,
//!    and `CoUninitialize` has to happen on that same thread. Initialising from
//!    `start()` and uninitialising from `stop()` would be a cross-thread
//!    uninitialise, so the apartment has to live on a thread that starts and
//!    finishes in one place.
//! 2. **COM interfaces are not `Send`.** An `IAudioClient` cannot leave the
//!    thread that created it, so the capture thread has to be the thread that
//!    drains the buffers.
//! 3. **The wire path must not lock.** The buffer drain is what feeds the
//!    phone, so it publishes into the lock-free ring and nothing else. All the
//!    bookkeeping (format, counters, endpoint name) goes through one mutex,
//!    touched at most once per ~10 ms buffer.
//!
//! So the thread does everything COM and communicates through exactly two
//! things: the ring (lock-free, `Send + Sync`) and a mutex-guarded snapshot.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use windows::core::GUID;
use windows::Win32::Foundation::RPC_E_CHANGED_MODE;
use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
use windows::Win32::Media::Audio::{
    eConsole, eRender, IAudioCaptureClient, IAudioClient, IMMDevice, IMMDeviceEnumerator,
    MMDeviceEnumerator, AUDCLNT_BUFFERFLAGS_SILENT, AUDCLNT_SHAREMODE_SHARED,
    AUDCLNT_STREAMFLAGS_LOOPBACK, WAVEFORMATEX,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL,
    COINIT_MULTITHREADED,
};

use crate::convert::{frames_to_f32, to_i16, Converter, MixFormat, SampleFormat};
use crate::diagnostics::Diagnostics;
use crate::ring::PcmRing;
use crate::LoopbackError;

/// `KSDATAFORMAT_SUBTYPE_IEEE_FLOAT` — the subformat nearly every modern
/// endpoint mixes in, and the reason a "32-bit" mix format must not be assumed
/// to be integer PCM.
const SUBTYPE_IEEE_FLOAT: GUID = GUID::from_u128(0x00000003_0000_0010_8000_00aa00389b71);
/// `KSDATAFORMAT_SUBTYPE_PCM`.
const SUBTYPE_PCM: GUID = GUID::from_u128(0x00000001_0000_0010_8000_00aa00389b71);

/// `WAVE_FORMAT_EXTENSIBLE`.
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

/// How long to wait between `GetNextPacketSize` calls when there is nothing to
/// read. Finer than the ~10 ms buffer WASAPI hands over, so it never adds
/// latency, and coarse enough not to spin a core.
const IDLE_SLEEP: std::time::Duration = std::time::Duration::from_millis(5);

/// Owns the capture thread. Stopping it is what restores the volume.
pub(crate) struct CaptureThread {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl CaptureThread {
    pub(crate) fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for CaptureThread {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Spawn the capture thread. Returns `Err` with a reason the user can act on.
pub(crate) fn spawn(
    ring: Arc<PcmRing>,
    diag: Arc<Mutex<Diagnostics>>,
    mute: bool,
) -> Result<CaptureThread, LoopbackError> {
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let handle = std::thread::Builder::new()
        .name("remotecrab-loopback".into())
        .spawn(move || {
            let _ = capture_loop(ring, diag, thread_stop, mute);
        })
        .map_err(|_| LoopbackError::ThreadSpawn)?;
    Ok(CaptureThread {
        stop,
        handle: Some(handle),
    })
}

/// Everything below runs on the capture thread and nowhere else.
fn capture_loop(
    ring: Arc<PcmRing>,
    diag: Arc<Mutex<Diagnostics>>,
    stop: Arc<AtomicBool>,
    mute: bool,
) -> Result<(), LoopbackError> {
    // SAFETY: called once, on a thread created for this purpose, so no other
    // apartment choice is in play. `CoInitializeEx` returns a raw HRESULT:
    // S_FALSE (already initialised with the same model) is success, and
    // RPC_E_CHANGED_MODE cannot happen on a fresh thread but is tolerated
    // rather than treated as fatal.
    unsafe {
        let hr = CoInitializeEx(None, COINIT_MULTITHREADED);
        if hr.is_err() && hr != RPC_E_CHANGED_MODE {
            let err = LoopbackError::ComInit(hr.0);
            fail(&diag, err);
            return Err(err);
        }
    }
    // From here every exit has to uninitialise, so the body is one call rather
    // than a function with `?` sprinkled through it.
    let result = run_capture(&ring, &diag, &stop, mute);
    unsafe { CoUninitialize() };
    if let Err(e) = result {
        fail(&diag, e);
    }
    let mut d = diag.lock().unwrap_or_else(|e| e.into_inner());
    d.running = false;
    result
}

fn fail(diag: &Arc<Mutex<Diagnostics>>, e: LoopbackError) {
    let mut d = diag.lock().unwrap_or_else(|e| e.into_inner());
    d.running = false;
    d.failure = Some(e);
}

fn run_capture(
    ring: &Arc<PcmRing>,
    diag: &Arc<Mutex<Diagnostics>>,
    stop: &Arc<AtomicBool>,
    mute: bool,
) -> Result<(), LoopbackError> {
    let device = default_render_device()?;
    let endpoint_id = device_id(&device);

    // SAFETY: `Activate` with NULL activation params; the interface is created
    // on this thread and never leaves it.
    let client: IAudioClient = unsafe { device.Activate(CLSCTX_ALL, None) }
        .map_err(|e| LoopbackError::Activate(e.code().0))?;

    let (mix, owned) = read_mix_format(&client)?;
    mix.validate().map_err(LoopbackError::Unsupported)?;

    // Published BEFORE `Initialize`, deliberately. The mix format and the
    // endpoint are the two things that make an `Initialize` failure
    // interpretable — "it failed" is not a diagnosis, "it failed on this device,
    // which mixes 48000 Hz 2ch float" is — and they cost nothing to record
    // early. A probe that reported only "0 frames" sent the reader guessing.
    {
        let mut d = diag.lock().unwrap_or_else(|e| e.into_inner());
        d.running = true;
        d.mix = Some(mix);
        d.endpoint_id = endpoint_id;
    }

    // SAFETY: `owned` is a copy of WASAPI's own mix format, in full, and
    // outlives the call. `hnsBufferDuration = 0` takes the engine's recommended
    // period: asking for a specific one risks AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED
    // on some drivers, and a longer buffer would add latency to a feature whose
    // weakest point is already latency.
    unsafe {
        client
            .Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_LOOPBACK,
                0,
                0,
                owned.as_ptr() as *const WAVEFORMATEX,
                None,
            )
            .map_err(|e| LoopbackError::Initialize(e.code().0))?;
    }

    // SAFETY: as above; the capture interface is only valid on this thread.
    let capture: IAudioCaptureClient = unsafe { client.GetService() }
        .map_err(|e| LoopbackError::Activate(e.code().0))?;

    // Mute AFTER the stream is initialised, and before the first buffer is read.
    // Muting first would change what the first buffers contain, and the "before"
    // half of the mute A/B has to be measured against an endpoint we have not
    // touched yet.
    let mut muted = false;
    if mute {
        // A device that will not report its volume is not a reason to refuse the
        // capture: keep the PC audible and carry on.
        if let Ok(Some(previous)) = endpoint_master_volume() {
            if set_endpoint_master_volume(0.0).is_ok() {
                muted = true;
                let mut d = diag.lock().unwrap_or_else(|e| e.into_inner());
                d.muted = true;
                d.volume_before_mute = Some(previous);
            }
        }
    }

    let result = pump(&client, &capture, ring, diag, stop, mix);

    // Restore on EVERY exit path, including the error paths. A receiver that
    // dies with the user's system muted is the worst outcome this feature has.
    // The app layer additionally writes a marker before asking for the mute, so
    // a *process* crash is recoverable on the next launch.
    if muted {
        let previous = {
            let d = diag.lock().unwrap_or_else(|e| e.into_inner());
            d.volume_before_mute
        };
        if let Some(v) = previous {
            let _ = set_endpoint_master_volume(v);
        }
        let mut d = diag.lock().unwrap_or_else(|e| e.into_inner());
        d.muted = false;
    }
    unsafe {
        let _ = client.Stop();
    }
    result
}

fn pump(
    client: &IAudioClient,
    capture: &IAudioCaptureClient,
    ring: &Arc<PcmRing>,
    diag: &Arc<Mutex<Diagnostics>>,
    stop: &Arc<AtomicBool>,
    mix: MixFormat,
) -> Result<(), LoopbackError> {
    let mut converter = Converter::new(mix);
    let block_align = mix.block_align();

    // SAFETY: `Start` on a stream that is initialised and not already running.
    unsafe { client.Start() }.map_err(|e| LoopbackError::Start(e.code().0))?;

    while !stop.load(Ordering::Acquire) {
        // SAFETY: every call below is a method on a live COM interface created
        // on this thread; the out-parameters are locals whose lifetime covers
        // the call, and the buffer pointer is only read before `ReleaseBuffer`.
        let next = unsafe { capture.GetNextPacketSize() }
            .map_err(|e| LoopbackError::Capture(e.code().0))?;
        if next == 0 {
            std::thread::sleep(IDLE_SLEEP);
            continue;
        }

        let mut data: *mut u8 = std::ptr::null_mut();
        let mut frames: u32 = 0;
        let mut flags: u32 = 0;
        unsafe { capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None) }
            .map_err(|e| LoopbackError::Capture(e.code().0))?;

        if frames > 0 {
            let silent = flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0;
            if silent {
                // Silent by contract: reading it is undefined, so the timeline
                // is filled with zeros instead. Pushing the right number of
                // silent frames keeps the packet cadence honest, which matters
                // because a cadence that stops is how "the capture died" and
                // "the system is quiet" look identical from the wire.
                ring.push_frames(&vec![0i16; frames as usize * 2]);
            } else if !data.is_null() {
                // SAFETY: WASAPI guarantees `frames` frames are readable at
                // `data` until `ReleaseBuffer`, and exactly that many are read.
                let bytes = unsafe {
                    std::slice::from_raw_parts(data as *const u8, frames as usize * block_align)
                };
                if let Some(raw) = frames_to_f32(bytes, mix.format, mix.channels) {
                    let stereo = converter.process(&raw);
                    let pcm: Vec<i16> = stereo.iter().map(|s| to_i16(*s)).collect();
                    ring.push_frames(&pcm);
                }
            }
            let mut d = diag.lock().unwrap_or_else(|e| e.into_inner());
            d.captured_frames += frames as u64;
            if silent {
                d.silent_buffers += 1;
            }
            d.dropped_frames = ring.dropped_frames();
        }

        // SAFETY: released with exactly the frame count it was acquired with,
        // which is the contract.
        unsafe { capture.ReleaseBuffer(frames) }
            .map_err(|e| LoopbackError::Capture(e.code().0))?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Device / format helpers

fn default_render_device() -> Result<IMMDevice, LoopbackError> {
    // SAFETY: `CoCreateInstance` with the documented CLSID/IID; the enumerator is
    // a local, so it cannot outlive this function.
    unsafe {
        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None::<&windows::core::IUnknown>, CLSCTX_ALL)
                .map_err(|e| LoopbackError::ComInit(e.code().0))?;
        debug_assert_eq!(
            std::mem::size_of::<IMMDeviceEnumerator>(),
            std::mem::size_of::<usize>()
        );
        enumerator
            .GetDefaultAudioEndpoint(eRender, eConsole)
            .map_err(|e| LoopbackError::NoOutputDevice(e.code().0))
    }
}

fn device_id(device: &IMMDevice) -> Option<String> {
    // SAFETY: `GetId` returns an owned PWSTR, which the caller must free with
    // `CoTaskMemFree`.
    unsafe {
        let pw = device.GetId().ok()?;
        let id = pw.to_string().ok();
        CoTaskMemFree(Some(pw.0 as *const _));
        id
    }
}

/// The mix format, plus the **whole** format structure to hand to `Initialize`.
///
/// Both halves are returned because `GetMixFormat` hands out a WASAPI-owned
/// pointer that must be freed immediately, while `Initialize` needs the format to
/// still exist — so it is copied out.
///
/// The copy must be the *whole* structure, not the 18-byte header. A loopback
/// mix is `WAVEFORMATEXTENSIBLE` on most modern machines (that is where the
/// IEEE-float subformat lives), and handing WASAPI 18 bytes of a 40-byte
/// descriptor fails `Initialize` with `E_INVALIDARG` — **0x80070057** — on every
/// one of them. Measured on a real machine with a perfectly ordinary
/// `F32 48000 Hz 2ch` mix: `E_INVALIDARG`, zero frames, and no clue why.
/// `--speaker-probe` printing the HRESULT is what turned that into a diagnosis.
fn read_mix_format(client: &IAudioClient) -> Result<(MixFormat, Box<[u8]>), LoopbackError> {
    // SAFETY: the returned pointer is WASAPI-owned; it is copied out and freed
    // before this function returns, which is what the documentation requires.
    // Every field is read *by value* — `WAVEFORMATEX` is `repr(packed)`, so
    // taking a reference to one of its fields is an unaligned reference and the
    // compiler refuses it.
    unsafe {
        let raw = client
            .GetMixFormat()
            .map_err(|e| LoopbackError::MixFormat(e.code().0))?;
        if raw.is_null() {
            CoTaskMemFree(Some(raw as *const _));
            return Err(LoopbackError::MixFormat(0));
        }
        let tag = (*raw).wFormatTag;
        let bits = (*raw).wBitsPerSample;
        let channels = (*raw).nChannels;
        let sample_rate = (*raw).nSamplesPerSec;

        let extensible = tag == WAVE_FORMAT_EXTENSIBLE;
        let total = if extensible {
            SIZEOF_WAVEFORMATEXTENSIBLE
        } else {
            SIZEOF_WAVEFORMATEX
        };
        let mut owned: Box<[u8]> = vec![0u8; total].into_boxed_slice();
        std::ptr::copy_nonoverlapping(raw as *const u8, owned.as_mut_ptr(), total);
        CoTaskMemFree(Some(raw as *const _));

        // An extensible format carries the real encoding in its SubFormat GUID.
        // Reading the bit depth alone would call 32-bit float "integer PCM" and
        // produce noise at full scale. Plain `WAVE_FORMAT_PCM`, by definition,
        // is integer.
        let sample = if extensible {
            let sub = read_subformat(owned.as_ptr());
            if sub == SUBTYPE_IEEE_FLOAT {
                SampleFormat::F32
            } else if sub == SUBTYPE_PCM {
                by_bits(bits)
            } else {
                // An encoding we cannot read. Reported as the 32-bit shape and
                // refused by `validate()` with a message naming the action,
                // rather than guessed at.
                SampleFormat::I32
            }
        } else {
            by_bits(bits)
        };

        let mix = MixFormat {
            format: sample,
            sample_rate,
            channels,
        };
        Ok((mix, owned))
    }
}

/// Bytes in a `WAVEFORMATEX`.
const SIZEOF_WAVEFORMATEX: usize = 18;
/// Bytes in a `WAVEFORMATEXTENSIBLE`: the 18-byte header, 2 bytes of valid-bits,
/// a 4-byte channel mask, and a 16-byte `SubFormat` GUID.
const SIZEOF_WAVEFORMATEXTENSIBLE: usize = 40;
/// Offset of `SubFormat` inside a `WAVEFORMATEXTENSIBLE`.
const OFFSET_SUBFORMAT: usize = 24;

/// The `SubFormat` GUID out of a copied `WAVEFORMATEXTENSIBLE`.
///
/// # SAFETY
/// `base` must point at least 40 bytes, which is what the caller allocated for
/// an extensible format.
///
/// Read as raw bytes rather than by casting to the struct and touching the
/// field: `WAVEFORMATEXTENSIBLE` is `repr(packed)`, so a field reference would be
/// unaligned — and reading it unaligned is UB on x86 in the formal sense and
/// misbehaves on ARM.
unsafe fn read_subformat(base: *const u8) -> GUID {
    let mut g = [0u8; 16];
    std::ptr::copy_nonoverlapping(base.add(OFFSET_SUBFORMAT), g.as_mut_ptr(), 16);
    // A GUID's wire layout is Data1 (u32 LE), Data2 (u16), Data3 (u16), Data4
    // (8 bytes) — which is exactly the first 16 bytes in order. `windows_core`
    // 0.62 has no `GUID::from_bytes`, so it is rebuilt from its parts.
    let data1 = u32::from_le_bytes([g[0], g[1], g[2], g[3]]);
    let data2 = u16::from_le_bytes([g[4], g[5]]);
    let data3 = u16::from_le_bytes([g[6], g[7]]);
    let mut data4 = [0u8; 8];
    data4.copy_from_slice(&g[8..16]);
    GUID::from_values(data1, data2, data3, data4)
}

fn by_bits(bits: u16) -> SampleFormat {
    match bits {
        16 => SampleFormat::I16,
        24 => SampleFormat::I24,
        _ => SampleFormat::I32,
    }
}

// ---------------------------------------------------------------------------
// Master volume (the "don't play on both" lever)

/// The default output endpoint's master volume, or `None` when the endpoint
/// refuses to report one (some virtual devices).
pub(crate) fn endpoint_master_volume() -> Result<Option<f32>, LoopbackError> {
    // SAFETY: enumerator, device and volume interface are all locals on this
    // thread, created and destroyed in order.
    unsafe {
        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None::<&windows::core::IUnknown>, CLSCTX_ALL)
                .map_err(|e| LoopbackError::Volume(e.code().0))?;
        let device = enumerator
            .GetDefaultAudioEndpoint(eRender, eConsole)
            .map_err(|e| LoopbackError::Volume(e.code().0))?;
        let volume: IAudioEndpointVolume = device
            .Activate(CLSCTX_ALL, None)
            .map_err(|e| LoopbackError::Volume(e.code().0))?;
        volume
            .GetMasterVolumeLevelScalar()
            .map(Some)
            .map_err(|e| LoopbackError::Volume(e.code().0))
    }
}

/// Clamp a requested master volume into what an endpoint accepts.
///
/// Clamped rather than trusted: an out-of-range scalar is rejected by the
/// endpoint, and a rejected call here would be the one that leaves a user unable
/// to turn their sound back on. Infinities clamp to the nearest bound, which is
/// what they mean. A NaN becomes **full volume**, because every path that
/// reaches this with one is a bug on our side and "loud" is the recoverable
/// direction — `f32::clamp` would propagate the NaN and be rejected outright.
fn clamp_level(level: f32) -> f32 {
    if level.is_nan() {
        1.0
    } else {
        level.clamp(0.0, 1.0)
    }
}

pub(crate) fn set_endpoint_master_volume(level: f32) -> Result<(), LoopbackError> {
    let level = clamp_level(level);
    // SAFETY: as above.
    unsafe {
        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None::<&windows::core::IUnknown>, CLSCTX_ALL)
                .map_err(|e| LoopbackError::Volume(e.code().0))?;
        let device = enumerator
            .GetDefaultAudioEndpoint(eRender, eConsole)
            .map_err(|e| LoopbackError::Volume(e.code().0))?;
        let volume: IAudioEndpointVolume = device
            .Activate(CLSCTX_ALL, None)
            .map_err(|e| LoopbackError::Volume(e.code().0))?;
        volume
            .SetMasterVolumeLevelScalar(level, std::ptr::null())
            .map_err(|e| LoopbackError::Volume(e.code().0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The CLSID the crate does export is asserted here so a transposed digit in
    /// anything hand-written below it is visible in a test rather than as a bare
    /// `E_NOINTERFACE` at runtime.
    #[test]
    fn the_com_identifiers_are_the_documented_ones() {
        assert_eq!(
            MMDeviceEnumerator.to_u128(),
            0xbcde0395_e52f_467c_8e3d_c4579291692eu128
        );
        // The two subformats, which is the whole reason `read_mix_format`
        // bothers with the extensible struct.
        assert_eq!(
            SUBTYPE_IEEE_FLOAT.to_u128(),
            0x00000003_0000_0010_8000_00aa00389b71u128
        );
        assert_eq!(
            SUBTYPE_PCM.to_u128(),
            0x00000001_0000_0010_8000_00aa00389b71u128
        );
    }

    #[test]
    fn a_volume_outside_the_range_is_clamped_not_trusted() {
        assert_eq!(clamp_level(2.0), 1.0);
        assert_eq!(clamp_level(-1.0), 0.0);
        assert_eq!(clamp_level(0.35), 0.35);
        assert_eq!(clamp_level(0.0), 0.0);
        assert_eq!(clamp_level(1.0), 1.0);
        // `f32::clamp` returns NaN for NaN, and a NaN handed to the endpoint is
        // a rejected call — which on the restore path is the one failure that
        // leaves a user unable to turn their sound back on.
        assert_eq!(clamp_level(f32::NAN), 1.0);
        assert_eq!(clamp_level(f32::INFINITY), 1.0);
        assert_eq!(clamp_level(f32::NEG_INFINITY), 0.0);
    }
}