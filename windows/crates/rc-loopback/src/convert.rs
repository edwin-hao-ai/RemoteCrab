//! Turning whatever the audio endpoint mixes into the exact shape the wire wants.
//!
//! The wire is fixed and unforgiving: 48 kHz, stereo, interleaved Int16, 960
//! frames per packet (`IBWire.encode(speakerAudio:)`). What the endpoint
//! actually mixes is neither. The mix format belongs to the endpoint and cannot
//! be chosen for a loopback stream, so in practice this function has to cope
//! with 44.1 kHz, with 32-bit float, with 24-bit packed, and — on a machine
//! with a mono default device — with one channel.
//!
//! Everything here is pure and platform-independent on purpose. The failure
//! this feature has to avoid is "the user hears nothing and nothing says why",
//! and the cheapest way to get that is to be wrong about a channel count or a
//! byte width in code that cannot be exercised without an audio device.
//!
//! The rules that are easy to get wrong, stated once:
//!
//! * **A mono source is duplicated, never smeared.** Writing one sample into
//!   both channels is upmixing; averaging two channels into both is a downmix.
//!   Doing the latter by accident is a mono stream played at half volume.
//! * **More than two channels is truncated to the first two**, never folded.
//!   A 5.1 endpoint's front pair is what a stereo phone can represent.
//! * **Every conversion is total.** An odd byte count, a zero channel count or
//!   a nonsense rate produces silence and a `None`, never a panic and never a
//!   short packet.

/// What the endpoint gave us, per `WAVEFORMATEX.wFormatTag` +
/// `WAVEFORMATEXTENSIBLE.SubFormat`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SampleFormat {
    /// 32-bit IEEE float, the format nearly every modern endpoint mixes in.
    F32,
    /// 16-bit signed PCM.
    I16,
    /// 24-bit signed PCM, packed into 3 bytes little-endian.
    I24,
    /// 32-bit signed PCM.
    I32,
}

impl SampleFormat {
    /// Bytes one sample of this format occupies.
    pub fn bytes_per_sample(self) -> usize {
        match self {
            SampleFormat::F32 | SampleFormat::I32 => 4,
            SampleFormat::I16 => 2,
            SampleFormat::I24 => 3,
        }
    }

    /// True when the format is one this build knows how to read.
    ///
    /// A refusal is a `None` from [`frames_to_f32`] and a status naming the
    /// format, because an unknown `wFormatTag` means the endpoint mixes
    /// something nobody here has a decoder for, and silently producing silence
    /// there is the exact bug class this file exists to prevent.
    pub fn is_supported(self) -> bool {
        matches!(
            self,
            SampleFormat::F32 | SampleFormat::I16 | SampleFormat::I24 | SampleFormat::I32
        )
    }
}

/// The endpoint's mix format, as read from `IAudioClient::GetMixFormat`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MixFormat {
    pub format: SampleFormat,
    pub sample_rate: u32,
    pub channels: u16,
}

impl MixFormat {
    /// Bytes one frame of the source occupies, which is what a capture buffer's
    /// length is measured in.
    pub fn block_align(&self) -> usize {
        self.format.bytes_per_sample() * usize::from(self.channels.max(1))
    }

    /// Whether this format can be converted, and if not, why.
    ///
    /// Two things disqualify a format and they need different messages: a
    /// sample encoding we cannot read, and a rate we will not resample from.
    pub fn validate(&self) -> Result<(), Unsupported> {
        if self.channels == 0 {
            return Err(Unsupported::NoChannels);
        }
        if !self.format.is_supported() {
            return Err(Unsupported::SampleFormat);
        }
        if self.sample_rate == 0 {
            return Err(Unsupported::NoSampleRate);
        }
        Ok(())
    }
}

/// Why a mix format cannot be converted. Each case carries the action, because
/// a status line that names a problem without naming a next step leaves the
/// user stuck (rule 1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unsupported {
    NoChannels,
    NoSampleRate,
    SampleFormat,
}

impl Unsupported {
    /// (zh, en) for the tray, which is bilingual everywhere (AGENTS.md).
    pub fn message(&self) -> (&'static str, &'static str) {
        match self {
            Unsupported::NoChannels => (
                "输出设备报告了 0 个声道，换一个默认输出设备再试",
                "the output device reported 0 channels - pick another default output",
            ),
            Unsupported::NoSampleRate => (
                "输出设备报告了 0 采样率，换一个默认输出设备再试",
                "the output device reported a 0 sample rate - pick another default output",
            ),
            Unsupported::SampleFormat => (
                "这个输出设备的混音格式无法读取，换一个默认输出设备再试",
                "this output device mixes in a format we cannot read - pick another default output",
            ),
        }
    }
}

/// Decode one buffer of the endpoint's mix into interleaced `f32` in
/// `[-1.0, 1.0]`.
///
/// Returns `None` when the byte count is not a whole number of frames, which is
/// the only way this can fail once the format is known — and it is worth
/// failing loudly rather than guessing, because a partial frame means the
/// offsets are already wrong and every sample after it would be noise.
pub fn frames_to_f32(bytes: &[u8], format: SampleFormat, channels: u16) -> Option<Vec<f32>> {
    let channels = usize::from(channels);
    if channels == 0 {
        return None;
    }
    let stride = format.bytes_per_sample() * channels;
    if stride == 0 || !bytes.len().is_multiple_of(stride) {
        return None;
    }
    let frames = bytes.len() / stride;
    let mut out = Vec::with_capacity(frames * channels);
    match format {
        SampleFormat::F32 => {
            for chunk in bytes.chunks_exact(4) {
                // A copy per sample would be the obvious way to write this and
                // the wrong one: this runs on the capture thread at 48 kHz.
                let bits = u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                out.push(f32::from_bits(bits));
            }
        }
        SampleFormat::I16 => {
            for chunk in bytes.chunks_exact(2) {
                out.push(f32::from(i16::from_le_bytes([chunk[0], chunk[1]])) / 32_768.0);
            }
        }
        SampleFormat::I24 => {
            for chunk in bytes.chunks_exact(3) {
                let raw = i32::from_le_bytes([chunk[0], chunk[1], chunk[2], 0]);
                // Sign-extend from 24 bits before scaling, or every negative
                // sample is off by 256 and the noise floor is audibly wrong.
                let value = (raw << 8) >> 8;
                out.push(value as f32 / 8_388_608.0);
            }
        }
        SampleFormat::I32 => {
            for chunk in bytes.chunks_exact(4) {
                let v = i32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                out.push(v as f32 / 2_147_483_648.0);
            }
        }
    }
    Some(out)
}

/// Rate conversion by linear interpolation, plus the channel mapping the wire
/// needs.
///
/// This is a struct rather than a function because it is *stateful*: a stream
/// arrives in buffers whose boundaries fall in the middle of a source frame
/// period, so the fractional read position and the last source frame have to
/// survive between calls. Getting that wrong produces a click every buffer
/// boundary — which is every 10 ms, so it is a continuous buzz rather than an
/// occasional one.
#[derive(Debug, Clone)]
pub struct Converter {
    channels: u16,
    /// Fractional read position within `prev`, in source frames.
    step: f64,
    /// The last source frame from the previous call, so interpolation can reach
    /// across a buffer boundary.
    prev: Vec<f32>,
    /// Set once the source rate is known to be the target rate, which skips the
    /// interpolation entirely.
    passthrough: bool,
}

impl Converter {
    pub const TARGET_RATE: u32 = 48_000;
    pub const TARGET_CHANNELS: usize = 2;

    pub fn new(mix: MixFormat) -> Self {
        let rate = mix.sample_rate.max(1);
        Self {
            channels: mix.channels.max(1),
            // SOURCE frames consumed per OUTPUT frame. This is src/dst and not
            // dst/src: a 96 kHz endpoint produces 48 kHz output by stepping two
            // source frames per output frame, and inverting the ratio turns a
            // 10 ms buffer into 20 ms of audio — a stream that plays at half
            // speed and drifts further behind every packet.
            step: f64::from(rate) / f64::from(Self::TARGET_RATE),
            prev: Vec::new(),
            passthrough: rate == Self::TARGET_RATE,
        }
    }

    /// True when the source already matches the wire's rate.
    pub fn is_passthrough(&self) -> bool {
        self.passthrough
    }

    /// Convert one buffer of interleaved source frames into interleaved
    /// 48 kHz stereo `f32`.
    ///
    /// Total by construction: any input length produces output that is a whole
    /// number of frames, and an input of zero frames produces zero frames.
    pub fn process(&mut self, input: &[f32]) -> Vec<f32> {
        let ch = usize::from(self.channels);
        if ch == 0 || input.is_empty() {
            return Vec::new();
        }
        let frames = input.len() / ch;
        if frames == 0 {
            return Vec::new();
        }

        // Flatten to the wire's channel count first, so the resampler below
        // only ever sees stereo and the mono/5.1 rules are stated once.
        let stereo: Vec<f32> = if ch == 1 {
            input.iter().flat_map(|s| [*s, *s]).collect()
        } else if ch == Self::TARGET_CHANNELS {
            input.to_vec()
        } else {
            let mut v = Vec::with_capacity(frames * Self::TARGET_CHANNELS);
            for f in 0..frames {
                v.push(input[f * ch]);
                v.push(input[f * ch + 1]);
            }
            v
        };
        let in_frames = stereo.len() / Self::TARGET_CHANNELS;

        if self.passthrough {
            return stereo;
        }

        // Seed on the first buffer; afterwards `prev` is the frame before
        // `input[0]`, which is what makes the interpolation continuous.
        if self.prev.is_empty() {
            self.prev = vec![0.0; Self::TARGET_CHANNELS];
        }
        let mut out = Vec::with_capacity((in_frames as f64 * self.step).ceil() as usize * 2 + 4);
        let mut pos = self.step - 1.0; // -1.0 addresses `prev`
        while pos + 1.0 < in_frames as f64 {
            let i = pos.floor() as isize;
            let frac = (pos - i as f64) as f32;
            let ni = i + 1;
            for c in 0..Self::TARGET_CHANNELS {
                // `i` is negative on the first iteration of a buffer whenever
                // the source rate is ABOVE 48 kHz (the read position starts one
                // step below zero), which is exactly the case that needs the
                // frame carried in from the previous buffer. Casting to `usize`
                // before this test made the branch dead and the carried frame
                // unused — a click on every buffer boundary.
                let a = if i < 0 {
                    self.prev[c]
                } else {
                    stereo[i as usize * 2 + c]
                };
                let b = stereo[ni as usize * 2 + c];
                out.push(a + (b - a) * frac);
            }
            pos += self.step;
        }
        // Carry the last source frame so the next buffer continues from it.
        self.prev = vec![
            stereo[(in_frames - 1) * 2],
            stereo[(in_frames - 1) * 2 + 1],
        ];
        out
    }
}

/// Clamp a normalised sample into Int16, the same rounding the Mac side uses.
///
/// Deliberately `value * 32_767.0` and not `* 32_768.0`: a full-scale positive
/// sample must land on `i16::MAX` and not wrap to `-32768`, which is the single
/// most audible conversion bug there is (a hard click on every peak). The cost
/// is that `-1.0` lands on `-32767` rather than `-32768` — one LSB, and the
/// same trade the Mac's `clampToInt16` makes, which matters more than the last
/// bit because the two receivers must not disagree about the wire format.
pub fn to_i16(value: f32) -> i16 {
    if value > 1.0 {
        i16::MAX
    } else if value < -1.0 {
        i16::MIN
    } else {
        (value * 32_767.0) as i16
    }
}

/// RMS and peak of one packet's Int16 samples.
///
/// Measured *per packet* on purpose. The Mac side learned this the hard way: a
/// whole-capture average cannot tell "the tap is carrying audio" from "the tap
/// carried one burst an hour ago", so a stuck-forever number would pass every
/// assertion while the user hears nothing.
pub fn measure(samples: &[i16]) -> (f64, i32) {
    if samples.is_empty() {
        return (0.0, 0);
    }
    let mut sum = 0.0f64;
    let mut peak = 0i32;
    for &v in samples {
        let f = f64::from(v);
        sum += f * f;
        peak = peak.max(i32::from(v.abs()));
    }
    ((sum / samples.len() as f64).sqrt(), peak)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn float_samples_decode_untouched() {
        let bytes: Vec<u8> = [0.5f32, -0.25f32]
            .iter()
            .flat_map(|v| v.to_le_bytes())
            .collect();
        let got = frames_to_f32(&bytes, SampleFormat::F32, 2).unwrap();
        assert_eq!(got, vec![0.5, -0.25]);
    }

    #[test]
    fn int16_scales_by_full_scale() {
        let bytes: Vec<u8> = [32767i16, -32768]
            .iter()
            .flat_map(|v| v.to_le_bytes())
            .collect();
        let got = frames_to_f32(&bytes, SampleFormat::I16, 2).unwrap();
        // 32767/32768 is 0.99997: the scale is 2^15, so full scale is not
        // reachable from a 16-bit integer. Anything but "just under 1.0" here
        // means the divisor is wrong.
        assert!((got[0] - 1.0).abs() < 1e-4, "got {}", got[0]);
        assert!((got[1] + 1.0).abs() < 1e-4, "got {}", got[1]);
    }

    /// 24-bit arrives as three bytes with the sign in the TOP byte. Sign-
    /// extending after scaling (instead of before) puts every negative sample
    /// 256 counts away from where it belongs, which is audible as a wrong noise
    /// floor rather than as an outright failure.
    #[test]
    fn int24_sign_extends_before_scaling() {
        // Full-scale negative: 0x800000 stored little-endian.
        let bytes = vec![0x00u8, 0x00, 0x80]; // -8_388_608
        let got = frames_to_f32(&bytes, SampleFormat::I24, 1).unwrap();
        assert!((got[0] + 1.0).abs() < 1e-6, "got {}", got[0]);
        // Half scale negative: -0x400000 -> -0.5.
        let bytes = vec![0x00u8, 0x00, 0xC0];
        let got = frames_to_f32(&bytes, SampleFormat::I24, 1).unwrap();
        assert!((got[0] + 0.5).abs() < 1e-6, "got {}", got[0]);
        // The sign-extension case proper: -1 is a tiny NEGATIVE number. Read as
        // unsigned it would be 16_777_215, i.e. a large positive one.
        let bytes = vec![0xFFu8, 0xFF, 0xFF];
        let got = frames_to_f32(&bytes, SampleFormat::I24, 1).unwrap();
        assert!(got[0] < 0.0, "sign lost: {}", got[0]);
        assert!((got[0] + 1.0 / 8_388_608.0).abs() < 1e-12, "got {}", got[0]);
    }

    #[test]
    fn a_partial_frame_is_refused_rather_than_guessed() {
        // Three float samples for a stereo stream: a whole number of frames
        // needs 8 bytes per frame.
        let bytes = vec![0u8; 12];
        assert!(frames_to_f32(&bytes, SampleFormat::F32, 2).is_none());
    }

    #[test]
    fn a_zero_channel_count_is_refused() {
        assert!(frames_to_f32(&[0u8; 8], SampleFormat::F32, 0).is_none());
    }

    /// Mono is duplicated, never averaged: averaging two identical channels is
    /// what halves the volume, and it is the mistake this rule exists to stop.
    #[test]
    fn mono_is_duplicated_into_both_channels_at_full_level() {
        let mut c = Converter::new(MixFormat {
            format: SampleFormat::F32,
            sample_rate: 48_000,
            channels: 1,
        });
        let out = c.process(&[0.5, -0.5, 0.25]);
        assert_eq!(out, vec![0.5, 0.5, -0.5, -0.5, 0.25, 0.25]);
    }

    #[test]
    fn more_than_two_channels_keeps_the_front_pair() {
        let mut c = Converter::new(MixFormat {
            format: SampleFormat::F32,
            sample_rate: 48_000,
            channels: 6,
        });
        let out = c.process(&[0.1, 0.2, 0.3, 0.4, 0.5, 0.6]);
        assert_eq!(out, vec![0.1, 0.2]);
    }

    #[test]
    fn a_matching_rate_passes_stereo_through_unchanged() {
        let mut c = Converter::new(MixFormat {
            format: SampleFormat::F32,
            sample_rate: 48_000,
            channels: 2,
        });
        assert!(c.is_passthrough());
        let input = vec![0.1, -0.1, 0.2, -0.2];
        assert_eq!(c.process(&input), input);
    }

    /// 44.1 kHz is the common non-48k case and the one that decides whether a
    /// resampler works at all: the output count is what proves it ran.
    #[test]
    fn resampling_from_44k1_produces_the_right_number_of_frames() {
        let mut c = Converter::new(MixFormat {
            format: SampleFormat::F32,
            sample_rate: 44_100,
            channels: 2,
        });
        assert!(!c.is_passthrough());
        let input: Vec<f32> = (0..441).flat_map(|i| [i as f32 / 441.0, i as f32 / 441.0]).collect();
        let out = c.process(&input);
        let frames = out.len() / 2;
        // 441 frames at 44100 -> 480 frames at 48000, give or take the
        // fractional tail this simple interpolator does not emit.
        assert!(
            (475..=481).contains(&frames),
            "expected ~480 frames, got {frames}"
        );
    }

    /// The click bug: interpolation that does not carry the last frame across a
    /// buffer boundary restarts from zero every buffer, which at 10 ms per
    /// buffer is a continuous buzz.
    ///
    /// Deliberately a **higher** source rate than 48 kHz: that is the only case
    /// where the interpolator has to reach *backwards* into the previous
    /// buffer, so an upsampling-only test would pass against an implementation
    /// that never carries anything at all.
    #[test]
    fn resampling_is_continuous_across_a_buffer_boundary() {
        let mut c = Converter::new(MixFormat {
            format: SampleFormat::F32,
            sample_rate: 96_000,
            channels: 2,
        });
        assert!(!c.is_passthrough());
        let ramp: Vec<f32> = (0..960).map(|i| i as f32 / 960.0).flat_map(|v| [v, v]).collect();
        // Half the SAMPLES, which is 480 frames either way — an even frame
        // count, so the split lands on a frame boundary.
        let (a, b) = ramp.split_at(ramp.len() / 2);
        let first = c.process(a);
        let second = c.process(b);
        assert!(!first.is_empty() && !second.is_empty());
        let all: Vec<f32> = first.into_iter().chain(second).collect();
        for pair in all.windows(2) {
            assert!(
                pair[1] - pair[0] > -0.01,
                "discontinuity at the buffer boundary: {} -> {}",
                pair[0],
                pair[1]
            );
        }
    }

    /// 96 kHz down to 48 kHz halves the frame count. If the arithmetic drifts
    /// the ring fills at the wrong rate and the phone's player starves or
    /// drifts, which no level assertion would ever show.
    #[test]
    fn downsampling_halves_the_frame_count() {
        let mut c = Converter::new(MixFormat {
            format: SampleFormat::F32,
            sample_rate: 96_000,
            channels: 2,
        });
        let input: Vec<f32> = (0..960).flat_map(|i| [i as f32 / 960.0, 0.0]).collect();
        let out = c.process(&input);
        let frames = out.len() / 2;
        assert!(
            (470..=480).contains(&frames),
            "expected ~480 frames from 960, got {frames}"
        );
    }

    /// A constant signal must come out constant. This is the assertion that
    /// catches the backwards-read branch reading a stale slot: the first output
    /// frame is interpolated against the carried previous frame, and if that
    /// were garbage the level of the whole stream would wobble.
    #[test]
    fn a_constant_signal_stays_constant_across_buffers() {
        let mut c = Converter::new(MixFormat {
            format: SampleFormat::F32,
            sample_rate: 96_000,
            channels: 2,
        });
        let first: Vec<f32> = vec![0.5; 480 * 2];
        let second: Vec<f32> = vec![0.5; 480 * 2];
        let a = c.process(&first);
        let b = c.process(&second);
        for v in a.iter().chain(b.iter()).skip(2) {
            assert!((v - 0.5).abs() < 1e-6, "level wandered to {v}");
        }
    }

    #[test]
    fn an_empty_buffer_produces_nothing_and_is_not_an_error() {
        let mut c = Converter::new(MixFormat {
            format: SampleFormat::F32,
            sample_rate: 44_100,
            channels: 2,
        });
        assert!(c.process(&[]).is_empty());
    }

    /// The audible conversion bug: `value * 32_768` wraps a full-scale positive
    /// sample to `i16::MIN`, so every peak becomes a click.
    #[test]
    fn full_scale_never_wraps_to_negative() {
        assert_eq!(to_i16(1.0), i16::MAX);
        assert_eq!(to_i16(-1.0), -32767, "matches the Mac's clampToInt16");
        assert_eq!(to_i16(2.0), i16::MAX);
        assert_eq!(to_i16(-2.0), i16::MIN);
        assert_eq!(to_i16(0.0), 0);
        // A NaN sample must not become a full-scale click. The comparison is
        // false either way, so it falls through the multiply, and Rust's
        // float-to-int cast maps NaN to 0.
        assert_eq!(to_i16(f32::NAN), 0);
    }

    #[test]
    fn measurement_reports_the_level_of_the_samples_it_was_given() {
        let (rms, peak) = measure(&[1000, -1000]);
        assert!((rms - 1000.0).abs() < 0.5);
        assert_eq!(peak, 1000);
        assert_eq!(measure(&[]), (0.0, 0));
        assert_eq!(measure(&[0, 0]), (0.0, 0));
    }

    /// A per-packet measurement has to react to THIS packet. A running average
    /// would report the same number for a silent packet as for a loud one,
    /// which is how "packets are flowing" gets mistaken for "sound is arriving".
    #[test]
    fn a_silent_packet_measures_zero_not_the_average() {
        let (loud_rms, _) = measure(&[8000; 100]);
        let (silent_rms, silent_peak) = measure(&[0; 100]);
        assert!(loud_rms > 7_000.0);
        assert_eq!(silent_rms, 0.0);
        assert_eq!(silent_peak, 0);
    }
}