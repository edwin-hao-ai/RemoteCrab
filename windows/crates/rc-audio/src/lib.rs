//! `rc-audio` — play the iPhone microphone on Windows.
//!
//! The iOS sender ships 20 ms Opus packets (48 kHz mono; `codec == "opus"`)
//! or raw Int16 PCM (`codec == "pcm"`). We decode Opus with libopus (bundled)
//! and push Int16 samples into a lock-free ring that `cpal` drains on the
//! audio thread.
//!
//! Also computes an RMS level (~10 Hz) for the connection-test UI, matching
//! the Mac receiver's `AudioPlayer.onLevel`.

pub mod decoder;
pub mod tone_data;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rc_protocol::{AudioPacket, AUDIO_CODEC_OPUS};

pub use decoder::OpusDecoder;

/// Render-endpoint name fragments that identify a virtual audio cable.
///
/// These are the *output* endpoints an app plays into; the matching *input*
/// (capture) endpoint is what Zoom/OBS then select as a microphone. Ordered
/// most-preferred first, and the plain VB-CABLE before VoiceMeeter's
/// multi-channel variants (which the plain one is a subset of).
const CABLE_HINTS: &[&str] = &[
    "CABLE Input",          // VB-Audio Virtual Cable
    "VoiceMeeter Input",    // VoiceMeeter
    "Virtual Audio Cable",  // Muzychenko VAC
    "Line 1 (Virtual",      // VAC's endpoint
    "Virtual Audio Driver", // VirtualDrivers/Virtual-Audio-Driver
    "Virtual Speaker",      // generic virtual speakers
    "VB-Audio",
];

/// Pick a virtual audio cable from a list of output device names, or `None`.
///
/// Pure, so it is tested without any audio hardware: the caller enumerates the
/// machine's devices and this decides. The whole point of Path A — the phone's
/// mic becomes a *selectable Windows microphone* — depends on playing into a
/// cable the user installed, and this is the one place that decision is made.
pub fn pick_virtual_cable(names: &[String]) -> Option<String> {
    for hint in CABLE_HINTS {
        let h = hint.to_lowercase();
        if let Some(name) = names.iter().find(|n| n.to_lowercase().contains(&h)) {
            return Some(name.clone());
        }
    }
    None
}

/// The machine's output (render) device names, in cpal's order.
pub fn output_device_names() -> Vec<String> {
    let host = cpal::default_host();
    match host.output_devices() {
        Ok(devices) => devices.map(|d| d.to_string()).collect(),
        Err(_) => Vec::new(),
    }
}

/// Thread-safe sample queue shared between the network task (producer) and
/// the audio callback (consumer).
#[derive(Clone, Default)]
pub struct SampleQueue(Arc<Mutex<VecDeque<i16>>>);

impl SampleQueue {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&self, samples: &[i16]) {
        if let Ok(mut q) = self.0.lock() {
            q.extend(samples.iter().copied());
            // Cap the backlog (~2 s at 48 kHz) so a stalled speaker can't
            // grow the queue without bound.
            const MAX: usize = 96_000;
            while q.len() > MAX {
                q.pop_front();
            }
        }
    }

    /// Drain up to `count` samples into `out`; missing samples become 0.
    pub fn pop_into(&self, out: &mut [i16]) {
        if let Ok(mut q) = self.0.lock() {
            for slot in out.iter_mut() {
                *slot = q.pop_front().unwrap_or(0);
            }
        } else {
            out.fill(0);
        }
    }

    pub fn len(&self) -> usize {
        self.0.lock().map(|q| q.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Plays received audio through the default output device.
pub struct AudioPlayer {
    queue: SampleQueue,
    decoder: Option<OpusDecoder>,
    /// Held so the stream stays alive; dropping it stops playback.
    _stream: Option<cpal::Stream>,
    /// Output sample rate the stream was opened at.
    sample_rate: u32,
    /// RMS of the most recent packet (0..1), read by the UI.
    /// Read on every packet, so a poisoned lock must not become a second panic:
    /// `consume` runs on the session task, and a panic there ends the session.
    /// The value is one `f32`, so a poisoned lock still holds a usable level.
    level: Arc<Mutex<f32>>,
    /// When true, audio is decoded + metered but rendered as silence
    /// (avoids the speaker→mic feedback loop).
    muted: Arc<std::sync::atomic::AtomicBool>,
}

impl AudioPlayer {
    /// Open the default output device.
    pub fn new() -> Self {
        Self::open_on(None)
    }

    /// Open a **named** output device, or the default when `device_name` is
    /// `None` (or the name is no longer present).
    ///
    /// This is what makes the phone's mic a *selectable Windows microphone*:
    /// open the player on a virtual cable's render endpoint, and the cable's
    /// capture endpoint carries the phone's voice to Zoom/OBS.
    pub fn open_on(device_name: Option<&str>) -> Self {
        let queue = SampleQueue::new();
        let level = Arc::new(Mutex::new(0.0f32));
        let muted = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let decoder = OpusDecoder::new().ok();

        let (stream, sample_rate) =
            match Self::open_stream(device_name, queue.clone(), muted.clone()) {
                Ok((s, r)) => (Some(s), r),
                Err(e) => {
                    eprintln!("audio output unavailable ({e}); metering only");
                    (None, 48_000)
                }
            };

        AudioPlayer {
            queue,
            decoder,
            _stream: stream,
            sample_rate,
            level,
            muted,
        }
    }

    fn open_stream(
        device_name: Option<&str>,
        queue: SampleQueue,
        muted: Arc<std::sync::atomic::AtomicBool>,
    ) -> Result<(cpal::Stream, u32), Box<dyn std::error::Error>> {
        let host = cpal::default_host();
        let device = match device_name {
            Some(name) => host
                .output_devices()?
                .find(|d| d.to_string() == name)
                .ok_or_else(|| format!("output device {name:?} not found"))?,
            None => host
                .default_output_device()
                .ok_or("no default output device")?,
        };
        let config = device.default_output_config()?;
        let channels = config.channels() as usize;

        // The Opus decoder always emits 48 kHz. cpal does NOT resample, so
        // playing those samples on a 44.1 kHz device would pitch-shift the
        // voice (the Mac's AVAudioSourceNode converts for us). Prefer a
        // 48 kHz config when the device offers one; otherwise warn — the
        // audio will be slightly slow/low until a resampler lands.
        let config = if config.sample_rate() != 48_000 {
            let preferred = device
                .supported_output_configs()
                .ok()
                .and_then(|mut ranges| {
                    ranges.find(|c| {
                        c.min_sample_rate() <= 48_000 && 48_000 <= c.max_sample_rate()
                    })
                })
                .map(|c| c.with_sample_rate(48_000));
            match preferred {
                Some(c) => {
                    eprintln!(
                        "audio: using 48 kHz output (device default {} Hz)",
                        config.sample_rate()
                    );
                    c
                }
                None => {
                    eprintln!(
                        "audio: WARNING device is {} Hz but Opus decodes to 48000 Hz — \
                         audio will be pitch-shifted (no resampler yet)",
                        config.sample_rate()
                    );
                    config
                }
            }
        } else {
            config
        };
        let sample_rate = config.sample_rate();
        let stream_config: cpal::StreamConfig = config.into();

        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => build_output::<f32>(&device, stream_config, queue, muted, channels)?,
            cpal::SampleFormat::I16 => build_output::<i16>(&device, stream_config, queue, muted, channels)?,
            cpal::SampleFormat::U16 => build_output::<u16>(&device, stream_config, queue, muted, channels)?,
            cpal::SampleFormat::U8 => build_output::<u8>(&device, stream_config, queue, muted, channels)?,
            cpal::SampleFormat::F64 => build_output::<f64>(&device, stream_config, queue, muted, channels)?,
            // Remaining cpal formats are exotic (I8/I24/I32/I64/U24/U32/U64) and
            // none is a mix format any stock Windows audio stack produces. Named
            // rather than wildcarded so adding one is a compile error here rather
            // than a silent "metering only" at runtime.
            other => return Err(format!("unsupported output sample format: {other:?}").into()),
        };
        stream.play()?;
        Ok((stream, sample_rate))
    }

    /// Feed one packet: decode (if Opus), queue samples, update the level.
    pub fn consume(&mut self, packet: &AudioPacket) {
        let pcm: Vec<i16> = if packet.codec == AUDIO_CODEC_OPUS {
            match self.decoder.as_mut() {
                Some(d) => d.decode(&packet.opus_data),
                None => Vec::new(),
            }
        } else {
            // Raw Int16 little-endian.
            packet
                .opus_data
                .chunks_exact(2)
                .map(|b| i16::from_le_bytes([b[0], b[1]]))
                .collect()
        };

        if pcm.is_empty() {
            return;
        }
        *self.level.lock().unwrap_or_else(|e| e.into_inner()) = rms(&pcm);
        self.queue.push(&pcm);
    }

    /// RMS level (0..1) of the last packet.
    pub fn level(&self) -> f32 {
        *self.level.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn set_muted(&self, muted: bool) {
        self.muted
            .store(muted, std::sync::atomic::Ordering::Relaxed);
    }

    pub fn is_muted(&self) -> bool {
        self.muted.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn queued_samples(&self) -> usize {
        self.queue.len()
    }
}

impl Default for AudioPlayer {
    fn default() -> Self {
        Self::new()
    }}

/// Root-mean-square of Int16 samples, normalized to 0..1.
pub fn rms(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f64 = samples
        .iter()
        .map(|&s| {
            let v = s as f64;
            v * v
        })
        .sum();
    ((sum / samples.len() as f64).sqrt() / 32768.0) as f32
}

/// Build an output stream for one sample format.
///
/// Split out because the only thing that differs between formats is the final
/// conversion, and the previous version supported `F32` alone. Anything else
/// fell through to "audio output unavailable … metering only", so on a machine
/// whose default output format is `I16` or `U8` — which includes this project's
/// own test machine and a good many real ones — the speaker feature silently
/// played nothing, at full volume, while the app reported that audio was
/// running.
fn build_output<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    queue: SampleQueue,
    muted: Arc<std::sync::atomic::AtomicBool>,
    channels: usize,
) -> Result<cpal::Stream, cpal::Error>
where
    T: cpal::SizedSample + cpal::FromSample<f32>,
{
    device.build_output_stream(
        config,
        move |data: &mut [T], _| {
            let frames = data.len() / channels;
            let mut mono = vec![0i16; frames];
            queue.pop_into(&mut mono);
            let silent = muted.load(std::sync::atomic::Ordering::Relaxed);
            for (i, frame) in data.chunks_mut(channels).enumerate() {
                let v = if silent {
                    0.0f32
                } else {
                    mono[i] as f32 / 32768.0
                };
                // `u8` and `u16` are unsigned with a 0.5 offset, `i16`/`f32`/`f64`
                // are not; `FromSample` is what knows the difference, so this loop
                // does not have to.
                let s = T::from_sample(v);
                for x in frame.iter_mut() {
                    *x = s;
                }
            }
        },
        |e| eprintln!("audio stream error: {e}"),
        None,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sample_queue_push_pop_roundtrip() {
        let q = SampleQueue::new();
        q.push(&[1, 2, 3, 4]);
        let mut out = [0i16; 4];
        q.pop_into(&mut out);
        assert_eq!(out, [1, 2, 3, 4]);
    }

    #[test]
    fn sample_queue_undersupply_yields_silence() {
        let q = SampleQueue::new();
        q.push(&[10, 20]);
        let mut out = [99i16; 4];
        q.pop_into(&mut out);
        assert_eq!(out, [10, 20, 0, 0]);
    }

    #[test]
    fn sample_queue_is_bounded() {
        let q = SampleQueue::new();
        let big = vec![1i16; 200_000];
        q.push(&big);
        assert!(q.len() <= 96_000, "queue grew to {}", q.len());
    }

    #[test]
    fn rms_of_silence_is_zero() {
        assert_eq!(rms(&[0; 100]), 0.0);
    }

    #[test]
    fn rms_of_full_scale_is_near_one() {
        let v = rms(&[i16::MAX, i16::MIN, i16::MAX, i16::MIN]);
        assert!((v - 1.0).abs() < 0.01, "rms = {v}");
    }

    #[test]
    fn rms_of_small_signal_is_small() {
        let v = rms(&[327, -327, 327, -327]);
        assert!(v > 0.0 && v < 0.05, "rms = {v}");
    }

    /// A virtual cable is preferred over ordinary outputs, so the phone's mic
    /// goes where an app can select it rather than to the speakers.
    #[test]
    fn a_virtual_cable_beats_the_speakers() {
        let names = vec![
            "Speakers (Realtek(R) Audio)".to_string(),
            "CABLE Input (VB-Audio Virtual Cable)".to_string(),
        ];
        assert_eq!(
            pick_virtual_cable(&names).as_deref(),
            Some("CABLE Input (VB-Audio Virtual Cable)")
        );
    }

    /// The plain VB-CABLE is preferred over VoiceMeeter's variants.
    #[test]
    fn the_plain_cable_wins_over_voicemeeter() {
        let names = vec![
            "VoiceMeeter Input (VB-Audio VoiceMeeter VAIO)".to_string(),
            "CABLE Input (VB-Audio Virtual Cable)".to_string(),
        ];
        assert_eq!(
            pick_virtual_cable(&names).as_deref(),
            Some("CABLE Input (VB-Audio Virtual Cable)")
        );
    }

    /// No cable means the phone's mic plays on the ordinary output — and the UI
    /// has to say that a cable is what makes it a selectable microphone.
    #[test]
    fn no_cable_when_only_real_devices_exist() {
        let names = vec![
            "Speakers (Realtek(R) Audio)".to_string(),
            "Headphones (2- USB Audio)".to_string(),
        ];
        assert_eq!(pick_virtual_cable(&names), None);
    }

    #[test]
    fn other_virtual_cables_are_recognised() {
        for name in [
            "VoiceMeeter Input (VB-Audio VoiceMeeter",
            "Line 1 (Virtual Audio Cable)",
            "Virtual Audio Driver",
            "CABLE Input (VB-Audio Virtual Cable)",
        ] {
            assert!(
                pick_virtual_cable(&[name.to_string()]).is_some(),
                "not recognised: {name}"
            );
        }
    }
}
