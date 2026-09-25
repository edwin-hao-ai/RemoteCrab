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
    level: Arc<Mutex<f32>>,
    /// When true, audio is decoded + metered but rendered as silence
    /// (avoids the speaker→mic feedback loop).
    muted: Arc<std::sync::atomic::AtomicBool>,
}

impl AudioPlayer {
    /// Open the default output device. Call once at startup; if the device
    /// can't be opened the player still decodes + meters (so the UI works),
    /// it just doesn't make sound.
    pub fn new() -> Self {
        let queue = SampleQueue::new();
        let level = Arc::new(Mutex::new(0.0f32));
        let muted = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let decoder = OpusDecoder::new().ok();

        let (stream, sample_rate) = match Self::open_stream(queue.clone(), muted.clone()) {
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
        queue: SampleQueue,
        muted: Arc<std::sync::atomic::AtomicBool>,
    ) -> Result<(cpal::Stream, u32), Box<dyn std::error::Error>> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or("no default output device")?;
        let config = device.default_output_config()?;
        let sample_rate = config.sample_rate();
        let channels = config.channels() as usize;
        let stream_config: cpal::StreamConfig = config.into();

        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_output_stream(
                stream_config,
                move |data: &mut [f32], _| {
                    let frames = data.len() / channels;
                    let mut mono = vec![0i16; frames];
                    queue.pop_into(&mut mono);
                    let silent = muted.load(std::sync::atomic::Ordering::Relaxed);
                    for (i, frame) in data.chunks_mut(channels).enumerate() {
                        let v = if silent {
                            0.0
                        } else {
                            mono[i] as f32 / 32768.0
                        };
                        for s in frame.iter_mut() {
                            *s = v;
                        }
                    }
                },
                |e| eprintln!("audio stream error: {e}"),
                None,
            )?,
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
        *self.level.lock().unwrap() = rms(&pcm);
        self.queue.push(&pcm);
    }

    /// RMS level (0..1) of the last packet.
    pub fn level(&self) -> f32 {
        *self.level.lock().unwrap()
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
    }
}

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
}
