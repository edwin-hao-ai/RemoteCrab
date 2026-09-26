//! `rc-record` — write the received stream to disk.
//!
//! The iPhone already sends H.264, so the video track is a **passthrough**
//! mux into MP4 (no re-encode, no quality loss, no encoder dependency): the
//! NAL units arrive length-prefixed AVCC in samples, and SPS/PPS go into the
//! `avcC` box. Audio is written as a 16-bit PCM WAV sidecar — the MP4 crate
//! only muxes AAC, and we refuse to pull an FFI AAC encoder, so the mic track
//! lives next to the video until a native Media Foundation path lands.
//!
//! Pure and platform-free so the muxing/downscale logic is unit-tested
//! without a phone.

use std::fs::File;
use std::io::{BufWriter, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use mp4::{AvcConfig, MediaConfig, Mp4Config, Mp4Sample, Mp4Writer, TrackConfig};

/// A recording in progress. `finish()` finalizes both files.
pub struct Recorder {
    mp4_path: PathBuf,
    wav_path: PathBuf,
    width: u16,
    height: u16,
    frame_duration_ms: u32,
    sps: Option<Vec<u8>>,
    pps: Option<Vec<u8>>,
    mp4: Option<Mp4Writer<BufWriter<File>>>,
    video_track: u32,
    video_samples: u64,
    wav: Option<WavWriter>,
}

impl Recorder {
    /// Begin a recording under `dir`, named `<stem>.mp4` / `<stem>.wav`.
    /// The MP4 is only opened once SPS/PPS and the first frame arrive.
    pub fn new(
        dir: &Path,
        stem: &str,
        width: u32,
        height: u32,
        fps: u32,
    ) -> std::io::Result<Self> {
        std::fs::create_dir_all(dir)?;
        let fps = fps.max(1);
        let frame_duration_ms = ((1000.0 / fps as f64).round() as u32).max(1);
        Ok(Self {
            mp4_path: dir.join(format!("{stem}.mp4")),
            wav_path: dir.join(format!("{stem}.wav")),
            width: width.clamp(1, u16::MAX as u32) as u16,
            height: height.clamp(1, u16::MAX as u32) as u16,
            frame_duration_ms,
            sps: None,
            pps: None,
            mp4: None,
            video_track: 1,
            video_samples: 0,
            wav: None,
        })
    }

    pub fn mp4_path(&self) -> &Path {
        &self.mp4_path
    }

    pub fn wav_path(&self) -> &Path {
        &self.wav_path
    }

    /// Cache a parameter set. The MP4 header is built from these, so they
    /// must be present before the first `add_video` is muxed.
    pub fn set_sps(&mut self, sps: &[u8]) {
        self.sps = Some(sps.to_vec());
    }

    pub fn set_pps(&mut self, pps: &[u8]) {
        self.pps = Some(pps.to_vec());
    }

    /// Mux one raw H.264 NAL unit. Frames that arrive before both parameter
    /// sets are dropped (the stream always re-sends SPS/PPS with each IDR).
    pub fn add_video(&mut self, nal: &[u8]) {
        if nal.is_empty() {
            return;
        }
        if self.mp4.is_none() && !self.open_mp4() {
            return;
        }
        let writer = self.mp4.as_mut().expect("opened above");
        let is_sync = (nal[0] & 0x1F) == 5;

        let mut avcc = Vec::with_capacity(nal.len() + 4);
        avcc.extend_from_slice(&(nal.len() as u32).to_be_bytes());
        avcc.extend_from_slice(nal);

        let sample = Mp4Sample {
            start_time: self.video_samples * self.frame_duration_ms as u64,
            duration: self.frame_duration_ms,
            rendering_offset: 0,
            is_sync,
            bytes: avcc.into(),
        };
        if writer.write_sample(self.video_track, &sample).is_ok() {
            self.video_samples += 1;
        }
    }

    /// Append decoded mono/stereo 16-bit PCM. Opens the WAV lazily with the
    /// first packet's format; later packets with a different rate are ignored.
    pub fn add_audio(&mut self, pcm: &[i16], sample_rate: u32, channels: u16) {
        if pcm.is_empty() || sample_rate == 0 || channels == 0 {
            return;
        }
        if self.wav.is_none() {
            match WavWriter::create(&self.wav_path, sample_rate, channels) {
                Ok(w) => self.wav = Some(w),
                Err(_) => return,
            }
        }
        if let Some(wav) = self.wav.as_mut() {
            if wav.sample_rate == sample_rate && wav.channels == channels {
                let _ = wav.write(pcm);
            }
        }
    }

    fn open_mp4(&mut self) -> bool {
        let (Some(sps), Some(pps)) = (self.sps.as_ref(), self.pps.as_ref()) else {
            return false;
        };
        if sps.len() < 4 || pps.is_empty() {
            return false;
        }
        let Ok(file) = File::create(&self.mp4_path) else {
            return false;
        };
        let config = Mp4Config {
            major_brand: str::parse("isom").expect("static brand"),
            minor_version: 512,
            compatible_brands: ["isom", "iso2", "avc1", "mp41"]
                .into_iter()
                .map(|b| str::parse(b).expect("static brand"))
                .collect(),
            // Trivial timescale so sample durations are milliseconds.
            timescale: 1000,
        };
        let Ok(mut writer) = Mp4Writer::write_start(BufWriter::new(file), &config) else {
            return false;
        };
        let avc = AvcConfig {
            width: self.width,
            height: self.height,
            seq_param_set: sps.clone(),
            pic_param_set: pps.clone(),
        };
        if writer
            .add_track(&TrackConfig::from(MediaConfig::AvcConfig(avc)))
            .is_err()
        {
            return false;
        }
        self.video_track = 1;
        self.mp4 = Some(writer);
        true
    }

    /// Finalize both files. Returns `(mp4_done, wav_done)`.
    pub fn finish(mut self) -> (bool, bool) {
        let video_ok = if let Some(mut writer) = self.mp4.take() {
            writer.write_end().is_ok()
        } else {
            false
        };
        let audio_ok = if let Some(wav) = self.wav.take() {
            wav.finish().is_ok()
        } else {
            false
        };
        (video_ok, audio_ok)
    }
}

// ---------------------------------------------------------------------------
// WAV (16-bit PCM)
// ---------------------------------------------------------------------------

struct WavWriter {
    file: BufWriter<File>,
    sample_rate: u32,
    channels: u16,
    data_len: u32,
}

impl WavWriter {
    fn create(path: &Path, sample_rate: u32, channels: u16) -> std::io::Result<Self> {
        let mut file = BufWriter::new(File::create(path)?);
        write_wav_header(&mut file, sample_rate, channels, 0)?;
        Ok(Self {
            file,
            sample_rate,
            channels,
            data_len: 0,
        })
    }

    fn write(&mut self, pcm: &[i16]) -> std::io::Result<()> {
        let mut bytes = Vec::with_capacity(pcm.len() * 2);
        for sample in pcm {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        self.file.write_all(&bytes)?;
        self.data_len = self.data_len.saturating_add(bytes.len() as u32);
        Ok(())
    }

    fn finish(mut self) -> std::io::Result<()> {
        self.file.flush()?;
        let mut file: File = self.file.into_inner().map_err(|e| e.into_error())?;
        file.seek(SeekFrom::Start(0))?;
        write_wav_header(&mut file, self.sample_rate, self.channels, self.data_len)?;
        file.flush()
    }
}

fn write_wav_header(
    out: &mut impl Write,
    sample_rate: u32,
    channels: u16,
    data_len: u32,
) -> std::io::Result<()> {
    let channel_bytes = channels as u32 * 2; // 16-bit
    let byte_rate = sample_rate * channel_bytes;
    out.write_all(b"RIFF")?;
    out.write_all(&(36 + data_len).to_le_bytes())?;
    out.write_all(b"WAVE")?;
    out.write_all(b"fmt ")?;
    out.write_all(&16u32.to_le_bytes())?; // PCM fmt chunk size
    out.write_all(&1u16.to_le_bytes())?; // audio format: PCM
    out.write_all(&channels.to_le_bytes())?;
    out.write_all(&sample_rate.to_le_bytes())?;
    out.write_all(&byte_rate.to_le_bytes())?;
    out.write_all(&(channel_bytes as u16).to_le_bytes())?; // block align
    out.write_all(&16u16.to_le_bytes())?; // bits per sample
    out.write_all(b"data")?;
    out.write_all(&data_len.to_le_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("rc-record-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    // Minimal but structurally valid parameter sets (only the profile/level
    // bytes are read by the muxer).
    const SPS: &[u8] = &[0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9];
    const PPS: &[u8] = &[0x68, 0xEB, 0xE3, 0xCB];
    const IDR: &[u8] = &[0x65, 0x88, 0x84, 0x00];
    const P: &[u8] = &[0x41, 0x9A, 0x22, 0x00];

    #[test]
    fn muxes_a_playable_h264_mp4() {
        let dir = scratch("mux");
        let mut rec = Recorder::new(&dir, "rec", 1920, 1080, 30).unwrap();
        // Frames before parameter sets are dropped.
        rec.add_video(IDR);
        rec.set_sps(SPS);
        rec.set_pps(PPS);
        rec.add_video(IDR);
        rec.add_video(P);
        rec.add_video(P);
        let (video_ok, _) = rec.finish();
        assert!(video_ok, "mp4 finalize failed");

        let file = File::open(dir.join("rec.mp4")).unwrap();
        let size = file.metadata().unwrap().len();
        let mp4 = mp4::Mp4Reader::read_header(std::io::BufReader::new(file), size).unwrap();
        assert_eq!(mp4.tracks().len(), 1);
        let track = mp4.tracks().values().next().unwrap();
        assert_eq!(track.track_type().unwrap(), mp4::TrackType::Video);
        assert_eq!(track.sample_count(), 3);
        assert!(track.width() > 0 && track.height() > 0);
    }

    #[test]
    fn writes_a_pcm_wav() {
        let dir = scratch("wav");
        let mut rec = Recorder::new(&dir, "rec", 640, 480, 30).unwrap();
        rec.add_audio(&[0i16, 1000, -1000, 2000], 48000, 1);
        rec.add_audio(&[1i16, 2, 3, 4], 48000, 1);
        let (_, audio_ok) = rec.finish();
        assert!(audio_ok, "wav finalize failed");

        let mut bytes = Vec::new();
        File::open(dir.join("rec.wav"))
            .unwrap()
            .read_to_end(&mut bytes)
            .unwrap();
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(&bytes[12..16], b"fmt ");
        assert_eq!(&bytes[36..40], b"data");
        // 8 samples * 2 bytes.
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 16);
        // channels = 1, sample rate = 48000.
        assert_eq!(u16::from_le_bytes(bytes[22..24].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(bytes[24..28].try_into().unwrap()), 48000);
    }

    #[test]
    fn finish_without_video_or_audio_reports_nothing_written() {
        let dir = scratch("empty");
        let rec = Recorder::new(&dir, "rec", 10, 10, 30).unwrap();
        assert_eq!(rec.finish(), (false, false));
    }
}
