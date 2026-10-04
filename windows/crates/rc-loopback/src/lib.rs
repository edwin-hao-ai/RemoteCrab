//! Capturing this PC's audio so the iPhone can play it — the Windows half of
//! "use the iPhone as the speaker".
//!
//! This is the counterpart of the Mac receiver's `SystemAudioTap.swift`, and it
//! is deliberately the same design so the two receivers cannot drift:
//!
//! | | macOS | Windows |
//! |---|---|---|
//! | mechanism | CoreAudio **process tap** | WASAPI **loopback** (`AUDCLNT_STREAMFLAGS_LOOPBACK`) |
//! | install / driver | none | none |
//! | packets | 20 ms, 48 kHz, stereo, Int16 | same |
//! | wire kind | `0x24` | same |
//! | ring | SPSC, 500 ms | same |
//! | index ownership | one writer per cursor | same, enforced by the API shape |
//! | mutes the PC while the phone plays | `muteBehavior = .mutedWhenTapped` | endpoint master volume (opt-in) |
//!
//! # The two differences worth knowing before you use it
//!
//! **1. Loopback only hears the DEFAULT output device.** The Mac's tap captures
//! every process regardless of where it plays — a tone sent to an unrelated
//! virtual output device was captured at full level. On Windows, a user whose
//! sound is going to headphones or a monitor will capture silence. That is a
//! property of the mechanism, not a bug, so the status names the endpoint it
//! captured instead of leaving the user guessing.
//!
//! **2. Muting the PC is a real risk here, and is opt-in.** Lowering the
//! endpoint's master volume is the only lever, and a process that dies while
//! holding it at zero leaves a user with a silent computer. So
//! [`MuteBehaviour::KeepLocal`] is the default, the marker file that makes a
//! crash recoverable lives in the app layer, and the capture measures whether
//! the mute silenced *it* (see [`mute`]) and puts the volume back if so.
//!
//! The pure logic — the ring, the sample-format and rate conversion, the mute
//! A/B — is in sibling modules and is tested without an audio device, because
//! the parts most likely to be wrong should not need a machine with speakers.

pub mod convert;
mod diagnostics;
pub mod mute;
pub mod ring;

#[cfg(windows)]
mod wasapi;

use std::sync::Arc;

pub use convert::{MixFormat, SampleFormat, Unsupported};
pub use mute::{MuteVerdict, MuteWatch};
pub use ring::{Packet, BYTES_PER_PACKET, CHANNELS, FRAMES_PER_PACKET};

use diagnostics::Diagnostics;

/// What happens to this PC's own speakers while the phone is playing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MuteBehaviour {
    /// The PC keeps playing out loud as well as sending. The default, because
    /// it cannot leave a user with a silent machine.
    KeepLocal,
    /// The PC's master volume goes to zero while the phone plays and comes back
    /// when the capture stops. AirPlay semantics, and the reason the Mac side
    /// defaults to it.
    MuteLocal,
}

impl MuteBehaviour {
    pub fn is_muting(self) -> bool {
        matches!(self, MuteBehaviour::MuteLocal)
    }

    /// (zh, en). The tray is bilingual everywhere (AGENTS.md).
    pub fn label(self) -> (&'static str, &'static str) {
        match self {
            MuteBehaviour::KeepLocal => ("本机继续播放", "Keep PC audio playing"),
            MuteBehaviour::MuteLocal => ("本机静音", "Mute this PC"),
        }
    }
}

/// Every way starting the capture can fail, each carrying what to DO.
///
/// A status line that reports a failure without an action leaves the user stuck
/// (rule 1), so `message()` is not a debug string — it is the text the user
/// reads, and there is a test that both halves are non-empty.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoopbackError {
    /// No default render endpoint (no sound card, or the service is stopped).
    NoOutputDevice(i32),
    /// `CoCreateInstance` / `CoInitializeEx` failed.
    ComInit(i32),
    /// `IMMDevice::Activate` refused.
    Activate(i32),
    /// `IAudioClient::GetMixFormat` failed or returned null.
    MixFormat(i32),
    /// The mix format is one this build will not convert.
    Unsupported(Unsupported),
    /// `IAudioClient::Initialize` failed. `AUDCLNT_E_DEVICE_INVALIDATED` or
    /// `AUDCLNT_E_UNSUPPORTED_FORMAT` land here.
    Initialize(i32),
    /// `IAudioClient::Start` failed.
    Start(i32),
    /// A read from the capture buffer failed — almost always the device being
    /// unplugged or the audio service restarting.
    Capture(i32),
    /// The master volume could not be read or written.
    Volume(i32),
    /// The capture thread could not be created.
    ThreadSpawn,
}

impl LoopbackError {
    /// (zh, en) for the tray. Every case names the next action.
    pub fn message(&self) -> (&'static str, &'static str) {
        match self {
            LoopbackError::NoOutputDevice(_) => (
                "没有找到默认的音频输出设备 — 在「设置 → 系统 → 声音」里选一个输出设备，然后重新打开扬声器",
                "No default audio output device - pick one in Settings > System > Sound, then turn the speaker on again",
            ),
            LoopbackError::ComInit(_) => (
                "Windows 的音频服务没有响应 — 重启「Windows 音频」服务后再试",
                "The Windows audio service did not respond - restart the Windows Audio service and try again",
            ),
            LoopbackError::Activate(_) => (
                "这个输出设备不支持音频回环采集 — 换一个默认输出设备，或改用「本机继续播放」",
                "This output device does not support loopback capture - pick another default output, or keep the PC audio playing",
            ),
            LoopbackError::MixFormat(_) => (
                "读不到输出设备的混音格式 — 换一个默认输出设备再试",
                "Could not read the output device's mix format - pick another default output and try again",
            ),
            LoopbackError::Unsupported(u) => u.message(),
            LoopbackError::Initialize(_) => (
                "音频回环采集初始化失败 — 换一个默认输出设备，或改用「本机继续播放」",
                "Loopback capture failed to initialise - pick another default output, or keep the PC audio playing",
            ),
            LoopbackError::Start(_) => (
                "音频回环采集无法启动 — 换一个默认输出设备，或改用「本机继续播放」",
                "Loopback capture would not start - pick another default output, or keep the PC audio playing",
            ),
            LoopbackError::Capture(_) => (
                "音频回环采集中断了 — 音频设备可能刚被拔出或重新插上；重新打开扬声器即可",
                "Loopback capture broke off - the audio device may have been unplugged; turn the speaker off and on again",
            ),
            LoopbackError::Volume(_) => (
                "无法改变本机音量 — 已改为「本机继续播放」，功能不受影响",
                "Could not change this PC's volume - switched to keeping the PC audio playing, which costs you nothing else",
            ),
            LoopbackError::ThreadSpawn => (
                "无法启动音频采集线程 — 重启接收端再试",
                "Could not start the audio capture thread - restart the receiver and try again",
            ),
        }
    }

    /// Whether retrying could plausibly work, which decides if the app keeps
    /// trying or stops and asks the user.
    pub fn is_transient(&self) -> bool {
        matches!(
            self,
            LoopbackError::Capture(_) | LoopbackError::ComInit(_) | LoopbackError::Start(_)
        )
    }

    /// The raw `HRESULT` behind this failure, or 0 when there isn't one.
    ///
    /// Exists for the same reason the probe prints it: "initialise failed" is not
    /// a diagnosis. `0x88890004` is `AUDCLNT_E_DEVICE_INVALIDATED`,
    /// `0x88890008` is `AUDCLNT_E_UNSUPPORTED_FORMAT`, `0x88890014` is
    /// `AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED` — three failures that need three
    /// different answers, and a user-facing sentence cannot tell them apart.
    pub fn code(&self) -> i32 {
        match self {
            LoopbackError::NoOutputDevice(c)
            | LoopbackError::ComInit(c)
            | LoopbackError::Activate(c)
            | LoopbackError::MixFormat(c)
            | LoopbackError::Initialize(c)
            | LoopbackError::Start(c)
            | LoopbackError::Capture(c)
            | LoopbackError::Volume(c) => *c,
            LoopbackError::Unsupported(_) | LoopbackError::ThreadSpawn => 0,
        }
    }
}

/// A read-only view of the capture, taken once per pump tick.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CaptureStats {
    pub running: bool,
    pub captured_frames: u64,
    pub dropped_frames: u64,
    /// RMS over everything captured. Diagnostic; `Packet::rms` is per-packet.
    pub captured_rms: f64,
    pub captured_peak: i32,
    /// Seconds of audio captured, which is what the "log the level once a
    /// second" decision is made on.
    pub captured_seconds: f64,
    pub mix: Option<MixFormat>,
    pub endpoint_id: Option<String>,
    pub failure: Option<LoopbackError>,
    pub muted: bool,
}

/// Owns one capture. Idempotent in both directions, because the feature can be
/// switched from the phone, from a feature-state echo and from a reconnect, in
/// any order.
pub struct LoopbackCapture {
    ring: Arc<ring::PcmRing>,
    shared: Arc<std::sync::Mutex<Diagnostics>>,
    watch: MuteWatch,
    #[cfg(windows)]
    thread: Option<wasapi::CaptureThread>,
    behaviour: MuteBehaviour,
    running: bool,
    /// Set by `take_packet` when the mute A/B concludes the volume change also
    /// silenced the capture. Sticky, and read by the app layer to explain itself.
    mute_broke_audio: bool,
}

#[cfg(windows)]
impl LoopbackCapture {
    pub fn new() -> Self {
        Self {
            ring: Arc::new(ring::PcmRing::new()),
            shared: Arc::new(std::sync::Mutex::new(Diagnostics::default())),
            watch: MuteWatch::new(false),
            #[cfg(windows)]
            thread: None,
            behaviour: MuteBehaviour::KeepLocal,
            running: false,
            mute_broke_audio: false,
        }
    }

    /// Start capturing. `Ok(false)` means it was already running, which is a
    /// success for every caller in this codebase.
    #[cfg(windows)]
    pub fn start(&mut self, mute: MuteBehaviour) -> Result<bool, LoopbackError> {
        if self.running {
            return Ok(false);
        }
        self.behaviour = mute;
        self.mute_broke_audio = false;
        self.ring.reset();
        {
            let mut d = self.shared.lock().expect("diag mutex poisoned");
            *d = Diagnostics::default();
        }
        self.watch = MuteWatch::new(mute.is_muting());
        let thread = wasapi::spawn(
            Arc::clone(&self.ring),
            Arc::clone(&self.shared),
            mute.is_muting(),
        )?;
        self.thread = Some(thread);
        self.running = true;
        Ok(true)
    }

    /// Stop capturing and restore the volume if we lowered it.
    pub fn stop(&mut self) {
        #[cfg(windows)]
        if let Some(mut t) = self.thread.take() {
            t.stop();
        }
        self.running = false;
        if self.behaviour.is_muting() {
            // The capture thread restores the volume itself; this is the belt to
            // its braces, for the case where it never got as far as muting.
            let previous = {
                let d = self.shared.lock().expect("diag mutex poisoned");
                d.volume_before_mute
            };
            if let Some(v) = previous {
                let _ = wasapi::set_endpoint_master_volume(v);
            }
        }
        self.watch.on_unmuted();
        self.ring.reset();
    }

    /// One 20 ms packet, or `None` when the buffer has not filled yet.
    pub fn take_packet(&mut self) -> Option<Packet> {
        let packet = self.ring.take_packet()?;
        // The A/B runs here, on the consumer side, because the consumer is the
        // only place that sees packets in order with a measurement attached.
        if self.behaviour.is_muting()
            && self.watch.feed(packet.rms) == MuteVerdict::MuteSilencedCapture
        {
            // Put the user's sound back rather than sitting on a dead feature,
            // and record that it happened so the app layer can say why.
            self.restore_volume();
            self.mute_broke_audio = true;
        }
        Some(packet)
    }

    /// True once the capture decided that muting this PC also silenced the
    /// capture, and put the volume back. Sticky: the app layer reads it to
    /// explain a change the user would otherwise see happen silently.
    pub fn mute_broke_audio(&self) -> bool {
        self.mute_broke_audio
    }

    /// Restore this PC's volume after the capture decided that muting it also
    /// silenced the capture. Public because the app layer drives the same
    /// recovery from its own status handling.
    pub fn restore_volume(&mut self) {
        #[cfg(windows)]
        {
            let previous = {
                let d = self.shared.lock().expect("diag mutex poisoned");
                d.volume_before_mute
            };
            if let Some(v) = previous {
                let _ = wasapi::set_endpoint_master_volume(v);
            }
            self.watch.on_unmuted();
        }
    }

    pub fn running(&self) -> bool {
        self.running
    }

    pub fn behaviour(&self) -> MuteBehaviour {
        self.behaviour
    }

    /// Whether the volume is currently down because of us.
    pub fn muted(&self) -> bool {
        self.behaviour.is_muting() && self.watch.is_muted()
    }

    pub fn stats(&self) -> CaptureStats {
        let d = self.shared.lock().expect("diag mutex poisoned");
        CaptureStats {
            running: d.running,
            captured_frames: d.captured_frames,
            dropped_frames: d.dropped_frames.max(self.ring.dropped_frames()),
            captured_rms: d.captured_rms(),
            captured_peak: d.peak,
            captured_seconds: d.captured_frames as f64 / 48_000.0,
            mix: d.mix,
            endpoint_id: d.endpoint_id.clone(),
            failure: d.failure,
            muted: d.muted,
        }
    }

    /// Whether the capture thread has died since the last check, with the
    /// reason. The app layer turns this into the status the user reads.
    pub fn failure(&self) -> Option<LoopbackError> {
        self.shared.lock().expect("diag mutex poisoned").failure
    }

    /// Put this PC's volume back if a previous run left it at zero.
    ///
    /// Called on the startup path, before anything else, because the failure it
    /// exists for is a user whose computer came back silent. Only a volume that
    /// is *actually* at zero is touched: someone who raised it since meant to,
    /// and a device that will not report a volume is left alone rather than
    /// guessed at.
    #[cfg(windows)]
    pub fn restore_master_volume_if_silent() -> Result<bool, LoopbackError> {
        match wasapi::endpoint_master_volume()? {
            Some(v) if v <= 0.001 => {
                wasapi::set_endpoint_master_volume(1.0)?;
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    /// The current master volume, or `None` when the endpoint will not say.
    #[cfg(windows)]
    pub fn master_volume() -> Option<f32> {
        wasapi::endpoint_master_volume().ok().flatten()
    }
}

/// Off Windows there is no loopback to run, and the honest answer is a refusal
/// rather than a stub that pretends. The policy layer above is still testable
/// there, which is the point of keeping it in the app layer.
#[cfg(not(windows))]
impl LoopbackCapture {
    pub fn start(&mut self, _mute: MuteBehaviour) -> Result<bool, LoopbackError> {
        Err(LoopbackError::ComInit(0))
    }

    pub fn stop(&mut self) {
        self.running = false;
    }
}

/// Windows-gated because the constructor is: on any other target this struct
/// is the refusal stub above, which has no capture to construct. `Drop` is not
/// gated — it only needs `stop`, which both impls have.
#[cfg(windows)]
impl Default for LoopbackCapture {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for LoopbackCapture {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
impl MuteBehaviour {
    /// The default the app layer uses, named so the test can assert it without
    /// the app layer having to exist yet. `speaker::default_behaviour` is the
    /// real one; this only has to agree with it.
    fn default_for_tests() -> Self {
        MuteBehaviour::KeepLocal
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_failure_names_an_action_in_both_languages() {
        // A status that says what went wrong but not what to do leaves the user
        // stuck, so both halves must be present and non-trivial.
        let all = [
            LoopbackError::NoOutputDevice(0),
            LoopbackError::ComInit(0),
            LoopbackError::Activate(0),
            LoopbackError::MixFormat(0),
            LoopbackError::Unsupported(Unsupported::NoChannels),
            LoopbackError::Unsupported(Unsupported::NoSampleRate),
            LoopbackError::Unsupported(Unsupported::SampleFormat),
            LoopbackError::Initialize(0),
            LoopbackError::Start(0),
            LoopbackError::Capture(0),
            LoopbackError::Volume(0),
            LoopbackError::ThreadSpawn,
        ];
        for e in all {
            let (zh, en) = e.message();
            assert!(!zh.is_empty() && !en.is_empty(), "{e:?} has an empty message");
            // An action, not just a noun: these messages have to contain a
            // "do this" in at least one language.
            assert!(
                en.contains("- ") || zh.contains("，") || en.contains(" again"),
                "{e:?} names no action: {en}"
            );
        }
    }

    #[test]
    fn a_device_that_went_away_is_treated_as_retryable() {
        assert!(LoopbackError::Capture(0).is_transient());
        assert!(LoopbackError::Start(0).is_transient());
        // No output device will not fix itself by retrying in a tight loop.
        assert!(!LoopbackError::NoOutputDevice(0).is_transient());
        assert!(!LoopbackError::Unsupported(Unsupported::SampleFormat).is_transient());
    }

    #[test]
    fn the_default_is_not_to_touch_the_users_volume() {
        // Windows has no `muteBehavior`, and a process that dies holding the
        // volume at zero leaves a silent machine, so this default is the whole
        // reason the risky option is opt-in.
        assert_eq!(MuteBehaviour::default_for_tests(), MuteBehaviour::KeepLocal);
        assert!(!MuteBehaviour::KeepLocal.is_muting());
        assert!(MuteBehaviour::MuteLocal.is_muting());
    }

    /// Windows-only, and that is the point: it asserts the state of a real
    /// `LoopbackCapture` before `start`. Off Windows there is no capture
    /// object to make that claim about — the stub refuses to start and has no
    /// constructor — so running it there would assert against a fiction.
    ///
    /// What *is* platform-neutral and does run everywhere is the ring, the
    /// sample conversion and the mute A/B, in the sibling modules.
    #[cfg(windows)]
    #[test]
    fn a_capture_that_never_started_reports_no_audio_rather_than_a_zero() {
        let mut c = LoopbackCapture::new();
        let s = c.stats();
        assert!(!s.running);
        assert_eq!(s.captured_rms, 0.0);
        assert_eq!(s.captured_frames, 0);
        assert_eq!(s.captured_seconds, 0.0);
        assert!(c.failure().is_none());
        assert!(c.take_packet().is_none());
    }
}
