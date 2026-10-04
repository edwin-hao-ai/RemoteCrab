//! "Use the iPhone as the speaker" on Windows: when to capture, how to get the
//! audio onto the wire, and how to keep the user's volume out of a corner.
//!
//! This is the counterpart of the Mac receiver's speaker section in
//! `ReceiverSession` (`startSpeakerCapture` / `pumpSpeakerAudio` /
//! `stopSpeakerCapture`), and it makes the same decisions for the same reasons:
//!
//! * **The phone owns the toggle.** It arrives as `featureState.speakerOn`, and
//!   the Mac follows the *echoed* state rather than acting on a request twice.
//!   Same here — see [`decide`].
//! * **Starting is idempotent.** The flag can arrive from a phone that just woke,
//!   from a reconnect, and from a user tapping the button, in any order.
//! * **A failure carries an action.** Every status string names what to do, and
//!   the tray shows it. A switch that silently does nothing is the failure mode
//!   rule 1 exists to prevent.
//! * **The pump is on its own thread**, not on the select loop, so a slow audio
//!   device cannot stall reconnect or input.
//!
//! # Why muting this PC is opt-in here and default on the Mac
//!
//! macOS gets it from `muteBehavior = .mutedWhenTapped`, which the OS restores
//! for us the moment the tap stops. Windows has no such thing: the only lever is
//! the endpoint's master volume, and a process that dies while holding it at
//! zero leaves the user with a silent computer and no way to know why.
//!
//! So [`default_behaviour`] is [`MuteBehaviour::KeepLocal`], the choice that
//! cannot strand anyone, and [`MuteBehaviour::MuteLocal`] is a row in the tray
//! menu. Choosing it is what arms the recovery path: a marker file is written
//! *before* the volume is touched, so a crash is recoverable on the next launch
//! (see [`recover_volume_if_needed`]).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rc_loopback::{CaptureStats, LoopbackCapture, LoopbackError, MuteBehaviour};

/// How often the pump wakes.
///
/// 10 ms matches the Mac side and lines up with the ~10 ms buffer WASAPI hands
/// over, so this is roughly one poll per incoming buffer: finer would add CPU
/// wakeups for nothing, coarser would add latency to a feature whose weakest
/// point is already latency.
pub const PUMP_INTERVAL: Duration = Duration::from_millis(10);

/// The most packets one pump tick will send.
///
/// The ring holds 500 ms, so a long stall leaves a large backlog. Sending it all
/// in one tick would put a burst of ~50 frames on the wire — which competes with
/// the video stream and, on a phone playing 20 ms packets, is indistinguishable
/// from a stall. The cap is the Mac's, for the same reason: never let a backlog
/// starve the rest of the link.
pub const MAX_PACKETS_PER_TICK: usize = 20;

/// How long the capture may deliver nothing before the tray says so. Not
/// instant: WASAPI needs a moment to hand over its first buffer, and a status
/// that flashes "no audio" on every start is worse than none.
pub const SILENCE_GRACE: Duration = Duration::from_secs(3);

/// The default, and the reason it is this one: on Windows the only way to silence
/// this PC is its master volume, and nothing restores that if the process dies.
pub fn default_behaviour() -> MuteBehaviour {
    MuteBehaviour::KeepLocal
}

/// What to do about a `speakerOn` flag arriving.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Nothing: the flag matches what is already happening.
    NoChange,
    StartCapture,
    StopCapture,
}

/// The policy, as a pure function so it can be tested without an audio device.
///
/// `connected` is there because the Mac side has the same guard and the same
/// reason: capturing with nobody listening is work for nothing, and the phone
/// will ask again on the next session.
pub fn decide(requested: bool, connected: bool, already_running: bool) -> Action {
    if requested && connected && !already_running {
        Action::StartCapture
    } else if !requested && already_running {
        Action::StopCapture
    } else {
        Action::NoChange
    }
}

/// Why the capture is not working.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Status {
    /// Running and healthy. The tray row is omitted entirely in this state.
    Working,
    /// The capture thread died or could not start. Carries a reason AND an action.
    Failed(LoopbackError),
    /// Running, but not one sample has arrived. Almost always the wrong output
    /// device: loopback only hears the default one, which the Mac side does not
    /// have to deal with.
    NoAudioYet,
    /// Running and carrying audio, but dropping frames because this machine
    /// cannot keep up.
    Dropping(u64),
    /// We muted this PC and the capture then went silent, which would leave the
    /// user with no sound anywhere. The volume has been put back.
    MuteBrokeTheAudio,
}

/// What the counters mean.
///
/// The order matters. A failure outranks everything (there is no audio *because*
/// the capture is dead). A mute that killed the audio outranks "no audio yet",
/// because the user's own action caused it and they need to know. Dropping only
/// matters once audio is arriving, because a drop counter climbing while the
/// system is silent is normal rather than a fault. And within the first few
/// seconds there is no verdict at all, because WASAPI has not had time to hand
/// over anything.
pub fn classify(stats: &CaptureStats, muted_broke_audio: bool) -> Option<Status> {
    if let Some(e) = stats.failure {
        return Some(Status::Failed(e));
    }
    if muted_broke_audio {
        return Some(Status::MuteBrokeTheAudio);
    }
    if stats.captured_seconds < SILENCE_GRACE.as_secs_f64() {
        return None;
    }
    if stats.captured_frames == 0 {
        return Some(Status::NoAudioYet);
    }
    if stats.dropped_frames > 0 {
        return Some(Status::Dropping(stats.dropped_frames));
    }
    Some(Status::Working)
}

/// The tray row for a status, bilingual (AGENTS.md), or `None` when there is
/// nothing to say.
pub fn status_row(status: Status) -> Option<(String, String)> {
    let label = crate::i18n::t("扬声器", "Speaker").to_string();
    // `(zh, en)` pairs, so one message is written once and the tray picks.
    let (zh, en): (&str, String) = match status {
        Status::Working => return None,
        Status::Failed(e) => {
            let (zh, en) = e.message();
            (zh, en.to_string())
        }
        Status::NoAudioYet => (
            "已连上，但默认输出设备一直没有声音 — 在「设置 → 系统 → 声音」里换一个默认输出设备；如果声音本来就在耳机或显示器上，请把它改回本机扬声器",
            "Connected, but the default output device has produced no audio - pick another default output in Settings > System > Sound; if your sound is on headphones or a monitor, set it back to this PC's speakers".to_string(),
        ),
        Status::Dropping(n) => (
            "音频在丢帧 — 这台电脑处理不过来，关掉其他占用音频的软件再试",
            format!("Audio is being dropped ({n} frames) - this PC cannot keep up; close other audio apps and try again"),
        ),
        Status::MuteBrokeTheAudio => (
            "静音本机会让采集也变静音，已经自动取消静音，改成本机继续播放",
            "Muting this PC also silenced the capture, so the mute was undone and this PC keeps playing".to_string(),
        ),
    };
    Some((label, crate::i18n::t(zh, &en).to_string()))
}

// ---------------------------------------------------------------------------
// The preference, and the marker that makes muting crash-recoverable

fn app_data_dir() -> Option<std::path::PathBuf> {
    // `%APPDATA%` and nothing else. A literal Windows fallback here once created
    // `crates/rc-app/C:\Users\Default\AppData\Roaming` inside the source tree,
    // because the variable is unset when the tests run on a Mac.
    std::env::var_os("APPDATA")
        .map(std::path::PathBuf::from)
        .map(|d| d.join("RemoteCrab"))
}

fn speaker_mute_path() -> Option<std::path::PathBuf> {
    app_data_dir().map(|d| d.join("speaker-mutes-local"))
}

fn mute_marker_path() -> Option<std::path::PathBuf> {
    app_data_dir().map(|d| d.join("speaker-muted-marker"))
}

/// One word, or the default.
///
/// A separate file rather than a field in the relay's JSON, for the reason
/// `notify_relay.rs` gives for `wizard-seen`: the two decisions are unrelated, so
/// one unreadable file must not be able to change the other's meaning.
fn parse_mute_pref(text: &str) -> MuteBehaviour {
    match text.trim() {
        "1" | "mute" | "true" => MuteBehaviour::MuteLocal,
        "0" | "keep" | "false" => MuteBehaviour::KeepLocal,
        // A settings file that cannot be read must not become a preference the
        // user never chose. On Windows the safe direction is also the default.
        _ => default_behaviour(),
    }
}

fn render_mute_pref(b: MuteBehaviour) -> &'static str {
    match b {
        MuteBehaviour::MuteLocal => "1",
        MuteBehaviour::KeepLocal => "0",
    }
}

/// The user's choice, or the default. Read fresh, like every other setting here.
pub fn mute_preference() -> MuteBehaviour {
    speaker_mute_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|t| parse_mute_pref(&t))
        .unwrap_or_else(default_behaviour)
}

/// Store the choice. `true` mutes this PC while the phone plays.
pub fn set_mute_preference(mutes_local: bool) {
    let _ = write_mute_preference(if mutes_local {
        MuteBehaviour::MuteLocal
    } else {
        MuteBehaviour::KeepLocal
    });
}

fn write_mute_preference(b: MuteBehaviour) -> bool {
    if let Some(p) = speaker_mute_path() {
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        return std::fs::write(p, render_mute_pref(b)).is_ok();
    }
    false
}

/// The same pair against an explicit directory, so the round trip is testable on
/// the machine that runs the suite — `%APPDATA%` does not exist there. Mirrors
/// `notify_relay`'s `quality_in` / `set_quality_in`, `cfg(test)` and all.
#[cfg(test)]
fn mute_preference_in(dir: &std::path::Path) -> MuteBehaviour {
    std::fs::read_to_string(dir.join("speaker-mutes-local"))
        .map(|t| parse_mute_pref(&t))
        .unwrap_or_else(|_| default_behaviour())
}

#[cfg(test)]
fn set_mute_preference_in(dir: &std::path::Path, b: MuteBehaviour) -> bool {
    let _ = std::fs::create_dir_all(dir);
    std::fs::write(dir.join("speaker-mutes-local"), render_mute_pref(b)).is_ok()
}

/// Put the PC's volume back if a previous run left it muted.
///
/// Called on the startup path, BEFORE anything else, because the failure it
/// exists for is a user whose computer came back silent. Returns whether the
/// volume was restored, so the caller can say so.
pub fn recover_volume_if_needed() -> bool {
    let Some(marker) = mute_marker_path() else {
        return false;
    };
    if !marker.is_file() {
        return false;
    }
    #[cfg(windows)]
    {
        match rc_loopback::LoopbackCapture::restore_master_volume_if_silent() {
            Ok(true) => {
                let _ = std::fs::remove_file(&marker);
                println!("  speaker: restored this PC's volume (a previous run left it muted)");
                return true;
            }
            Ok(false) => {}
            Err(e) => {
                eprintln!("  speaker: could not check the master volume: {e:?}");
                // The marker stays: a later run may succeed, and a marker that
                // lies about being needed is worse than a stale one.
                return false;
            }
        }
        let _ = std::fs::remove_file(&marker);
        false
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// Write the marker. Called before the volume is touched, so a crash between the
/// two is still recoverable.
fn mark_muted() {
    if let Some(dir) = app_data_dir() {
        let _ = std::fs::create_dir_all(&dir);
        if let Some(p) = mute_marker_path() {
            let _ = std::fs::write(p, b"1");
        }
    }
}

fn clear_muted() {
    if let Some(p) = mute_marker_path() {
        let _ = std::fs::remove_file(p);
    }
}

// ---------------------------------------------------------------------------
// The pump

/// What the tray and the select loop read.
#[derive(Debug, Default, Clone)]
pub struct SpeakerView {
    pub running: bool,
    pub captured_frames: u64,
    pub dropped_frames: u64,
    pub endpoint_id: Option<String>,
    pub muted: bool,
    /// `None` when there is nothing to tell the user.
    pub status: Option<Status>,
}

/// Owns the capture and the thread that ships it.
pub struct Speaker {
    /// Shared with the pump thread. A `Mutex` rather than a move because the
    /// select loop has to be able to stop and inspect a capture that another
    /// thread is driving. The lock is only ever held for a packet copy and a
    /// stats read — the audio thread itself never touches it, it goes straight
    /// to the lock-free ring.
    capture: Arc<Mutex<LoopbackCapture>>,
    stop: Arc<AtomicBool>,
    view: Arc<Mutex<SpeakerView>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Speaker {
    pub fn new() -> Self {
        Self {
            capture: Arc::new(Mutex::new(LoopbackCapture::new())),
            stop: Arc::new(AtomicBool::new(false)),
            view: Arc::new(Mutex::new(SpeakerView::default())),
            thread: None,
        }
    }

    pub fn running(&self) -> bool {
        self.capture.lock().map(|c| c.running()).unwrap_or(false)
    }

    pub fn view(&self) -> SpeakerView {
        self.view.lock().map(|v| v.clone()).unwrap_or_default()
    }

    /// Start capturing and shipping. Returns `false` if it was already running,
    /// which is a success for every caller here.
    pub fn start(&mut self, session: &rc_net::Session) -> bool {
        if self.running() {
            return false;
        }
        let behaviour = mute_preference();
        if behaviour.is_muting() {
            // Before the volume is touched, not after: a crash between the two is
            // exactly the case this marker exists for.
            mark_muted();
        }
        let started = {
            let mut c = match self.capture.lock() {
                Ok(c) => c,
                Err(_) => return false,
            };
            c.start(behaviour)
        };
        match started {
            Ok(true) => {}
            Ok(false) => {
                clear_muted();
                return false;
            }
            Err(e) => {
                clear_muted();
                self.set_status(Status::Failed(e));
                println!("  speaker: capture did not start ({e:?})");
                return false;
            }
        }

        self.stop.store(false, Ordering::Release);
        self.set_view(|v| *v = SpeakerView::default());
        self.thread = None;

        let capture = Arc::clone(&self.capture);
        let stop = Arc::clone(&self.stop);
        let view = Arc::clone(&self.view);
        let session = session.clone();
        match std::thread::Builder::new()
            .name("remotecrab-speaker-pump".into())
            .spawn(move || pump(capture, &session, &stop, &view))
        {
            Ok(h) => {
                self.thread = Some(h);
                println!("  speaker: capture started ({})", behaviour.label().1);
                true
            }
            Err(_) => {
                clear_muted();
                if let Ok(mut c) = self.capture.lock() {
                    c.stop();
                }
                self.set_status(Status::Failed(LoopbackError::ThreadSpawn));
                false
            }
        }
    }

    /// Stop capturing, join the pump and restore the volume. Idempotent.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
        if let Ok(mut c) = self.capture.lock() {
            c.stop();
        }
        clear_muted();
        self.set_view(|v| *v = SpeakerView::default());
        println!("  speaker: capture stopped");
    }

    fn set_status(&self, s: Status) {
        self.set_view(|v| v.status = Some(s));
    }

    fn set_view(&self, f: impl FnOnce(&mut SpeakerView)) {
        if let Ok(mut v) = self.view.lock() {
            f(&mut v);
        }
    }
}

impl Default for Speaker {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for Speaker {
    fn drop(&mut self) {
        self.stop();
    }
}

fn pump(
    capture: Arc<Mutex<LoopbackCapture>>,
    session: &rc_net::Session,
    stop: &AtomicBool,
    view: &Arc<Mutex<SpeakerView>>,
) {
    let mut last_level_report = Duration::ZERO;
    loop {
        if stop.load(Ordering::Acquire) {
            // The volume and the marker are restored from whichever thread got
            // here first — `Speaker::stop` does both — so this is belt to braces
            // for the case where the pump is the one that noticed.
            if let Ok(mut c) = capture.lock() {
                c.stop();
            }
            clear_muted();
            return;
        }
        std::thread::sleep(PUMP_INTERVAL);

        let mut sent = 0usize;
        let mut last = (0.0f64, 0i32, 0usize);
        let stats;
        let mute_broke;
        {
            let Ok(mut c) = capture.lock() else { return };
            while sent < MAX_PACKETS_PER_TICK {
                let Some(packet) = c.take_packet() else { break };
                let pcm = packet.pcm;
                last = (packet.rms, packet.peak, pcm.len());
                let out = rc_protocol::AudioPacket {
                    opus_data: pcm,
                    sample_rate: 48_000,
                    channels: 2,
                    timestamp_micros: now_micros(),
                    codec: rc_protocol::AUDIO_CODEC_PCM.to_string(),
                };
                match rc_protocol::encode_speaker_audio(&out) {
                    Ok(frame) => session.send_frame(frame),
                    Err(e) => {
                        eprintln!("  speaker: could not encode a packet: {e}");
                        c.stop();
                        clear_muted();
                        return;
                    }
                }
                sent += 1;
            }
            // The capture owns the mute A/B: if it concluded the volume change
            // silenced it, it has already put the volume back and recorded why.
            mute_broke = c.mute_broke_audio();
            stats = c.stats();
        }

        let status = classify(&stats, mute_broke);
        // Published for the tray, which is rebuilt on the Win32 thread and has no
        // access to this loop's locals.
        publish(status);
        if let Ok(mut v) = view.lock() {
            v.running = stats.running;
            v.captured_frames = stats.captured_frames;
            v.dropped_frames = stats.dropped_frames;
            v.endpoint_id = stats.endpoint_id.clone();
            v.muted = stats.muted;
            v.status = status;
        }

        // Once a second, and only the level: this is the line that separates
        // "the capture is dead" from "this PC is not making any sound", which the
        // packet counts cannot.
        let elapsed = Duration::from_secs_f64(stats.captured_seconds);
        if sent > 0 && (sent == 1 || elapsed > last_level_report + Duration::from_secs(1)) {
            last_level_report = elapsed;
            println!(
                "  speaker packet: bytes={} rms={} peak={} sent={sent} captured={} dropped={} rms_total={} peak_total={}{}",
                last.2,
                last.0 as i64,
                last.1,
                stats.captured_frames,
                stats.dropped_frames,
                stats.captured_rms as i64,
                stats.captured_peak,
                match &stats.mix {
                    Some(m) => format!(" mix={:?} {}Hz {}ch", m.format, m.sample_rate, m.channels),
                    None => String::new(),
                }
            );
        }
    }
}

/// What the pump last published, for surfaces that are not the select loop.
///
/// A module global rather than a value threaded through, and the reason is
/// `notify_relay`: the tray menu is rebuilt on a Win32 thread that has no access
/// to the select loop's locals, and the alternative — a channel, a handle, or a
/// `static mut` — is worse. One writer (the pump), one reader (the tray), and a
/// `Mutex` so the copy is atomic. The tray's own state comes from
/// `FeatureStateSnapshot`, which it already receives.
static PUBLISHED: Mutex<Option<Status>> = Mutex::new(None);

/// Record the latest status for the tray. Called by the pump.
pub fn publish(status: Option<Status>) {
    if let Ok(mut slot) = PUBLISHED.lock() {
        *slot = status;
    }
}

/// The tray's line for this feature, mirroring the Mac's `FeatureStatusRow`
/// (`MenuBarMenu.swift`, `speakerSubtitle`) exactly in shape:
///
/// | state | says |
/// |---|---|
/// | not connected | connect the phone first |
/// | a failure the user can fix **here** | that failure, with its action |
/// | on | where to turn it off |
/// | off | where to turn it on |
///
/// It is a **status and not a control**, for the reason the Mac commit gives:
/// this feature routes the computer's audio to the phone, so the phone is where
/// the user decides, and a switch on the other machine is a second place to look
/// for the same decision. A row that only points elsewhere has still told the
/// user nothing about *now*, so both the state and the place are in one string.
///
/// # Why the wording is not copied verbatim from the Mac
///
/// The Mac's hint says the computer's own speakers go quiet while it is on. That
/// is `CATapMuteBehavior.mutedWhenTapped` and the OS restores it. On Windows the
/// default is the opposite — see [`default_behaviour`] — so the same sentence
/// would be a lie, which is the exact failure the four-implementations trap
/// produces.
pub fn status_line(connected: bool, speaker_on: bool) -> String {
    let (zh, en): (&str, String) = match published() {
        // A failure the user can fix on this machine speaks for itself, because
        // there is a control to go and use.
        Some(status) => {
            let (zh, en): (&str, String) = match status {
                // Working: fall through to the state report below.
                Status::Working => return state_sentence(connected, speaker_on),
                Status::Failed(e) => {
                    let (a, b) = e.message();
                    (a, b.to_string())
                }
                Status::NoAudioYet => (
                    "已连上，但默认输出设备一直没有声音 — 在「设置 → 系统 → 声音」里换一个默认输出设备",
                    "connected, but the default output device has produced no audio - pick another default output in Settings > System > Sound".to_string(),
                ),
                Status::Dropping(n) => (
                    "音频在丢帧 — 关掉其他占用音频的软件",
                    format!("audio is being dropped ({n} frames) - close other audio apps"),
                ),
                Status::MuteBrokeTheAudio => (
                    "静音本机会让采集也变静音，已自动取消静音",
                    "muting this PC also silenced the capture, so the mute was undone".to_string(),
                ),
            };
            (zh, en)
        }
        None => return state_sentence(connected, speaker_on),
    };
    crate::i18n::t(zh, &en).to_string()
}

fn state_sentence(connected: bool, speaker_on: bool) -> String {
    let (zh, en): (&str, &str) = if !connected {
        (
            "先连接 iPhone 才能打开",
            "Connect your iPhone to switch this on",
        )
    } else if speaker_on {
        ("开 — 在 iPhone 上关掉它", "On — switch it off on your iPhone")
    } else {
        (
            "关 — 在 iPhone 的声音菜单里打开",
            "Off — switch it on from your iPhone's sound menu",
        )
    };
    crate::i18n::t(zh, en).to_string()
}

fn published() -> Option<Status> {
    PUBLISHED.lock().ok().and_then(|s| *s)
}

/// The row's title. Matches the Mac's `IBLocale.Speaker.title` so the two menus
/// name the same feature the same way.
pub const TITLE: (&str, &str) = ("播放电脑声音", "Play computer sound");

/// Capture this PC's system audio for a few seconds and report what arrived.
///
/// The one thing about this feature that cannot be reasoned about from code is
/// whether WASAPI loopback hears anything **on a particular machine** — it
/// depends on the output endpoint, the driver, and whether the user's sound is
/// going to the default device at all. So it is measurable, and the measurement
/// is one command away in the shipping binary.
///
/// Deliberately NOT behind the `selftest` feature: the machines that need
/// answering this are user machines running the release build, and a diagnostic
/// that needs a rebuild is a diagnostic nobody runs.
#[cfg(windows)]
fn now_micros() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0)
}

#[cfg(windows)]
pub fn probe() -> std::process::ExitCode {
    use std::process::ExitCode;

    const WARMUP: Duration = Duration::from_millis(700);
    const LISTEN: Duration = Duration::from_millis(2500);

    println!(
        "{}",
        crate::i18n::t(
            "扬声器探测：正在监听本机默认输出设备 2.5 秒…",
            "Speaker probe: listening to this PC's default output device for 2.5s..."
        )
    );
    println!(
        "{}",
        crate::i18n::t(
            "（探测期间请播放一点声音；这一步不占用麦克风，也不改任何设置）",
            "(play something while it runs; this touches no microphone and changes no settings)"
        )
    );

    // Never mutes: a diagnostic that silences the user's machine to prove a
    // point is not a diagnostic.
    let mut capture = LoopbackCapture::new();
    match capture.start(MuteBehaviour::KeepLocal) {
        Ok(true) => {}
        Ok(false) => {
            println!("  {}", crate::i18n::t("已经在运行了。", "already running."));
            return ExitCode::FAILURE;
        }
        Err(e) => {
            let (zh, en) = e.message();
            println!("  {} {}", crate::i18n::t("失败：", "FAILED: "), crate::i18n::t(zh, en));
            return ExitCode::FAILURE;
        }
    }
    // Counters, and a drain helper, declared before either loop uses them.
    let mut packets = 0usize;
    let mut bytes = 0usize;
    let mut loudest = 0f64;
    let mut peak = 0i32;
    // A named fn rather than a closure over five `&mut`s: five simultaneous
    // mutable borrows in a closure is how a probe ends up compiling against the
    // previous build instead of the current one.
    fn drain(
        capture: &mut LoopbackCapture,
        packets: &mut usize,
        bytes: &mut usize,
        loudest: &mut f64,
        peak: &mut i32,
    ) {
        while let Some(p) = capture.take_packet() {
            *packets += 1;
            *bytes += p.pcm.len();
            *loudest = (*loudest).max(p.rms);
            *peak = (*peak).max(p.peak);
        }
    }

    // Drain during the warm-up too. Skipping it lets the 500 ms ring fill while
    // the probe sleeps, and the resulting "dropped frames" line would blame the
    // steady state for a backlog this function created itself.
    let warm = std::time::Instant::now();
    while warm.elapsed() < WARMUP {
        drain(&mut capture, &mut packets, &mut bytes, &mut loudest, &mut peak);
        std::thread::sleep(PUMP_INTERVAL);
    }
    // `packets` and friends are what a run would really have sent, so the
    // numbers below describe packets that existed rather than bytes that were
    // counted on the way past.
    let measured_from = packets;
    let bytes_from = bytes;
    let deadline = std::time::Instant::now() + LISTEN;
    while std::time::Instant::now() < deadline {
        drain(&mut capture, &mut packets, &mut bytes, &mut loudest, &mut peak);
        std::thread::sleep(PUMP_INTERVAL);
    }
    // Window-scoped, so the packet count and the byte count describe the same
    // interval. A cumulative byte count next to a windowed packet count reads as
    // a packet size, and it is not one.
    let listen_packets = packets - measured_from;
    let listen_bytes = bytes - bytes_from;
    let stats = capture.stats();
    capture.stop();

    println!();
    if let Some(m) = stats.mix {
        println!("  mix format     : {:?} {} Hz, {} ch", m.format, m.sample_rate, m.channels);
    }
    if let Some(id) = &stats.endpoint_id {
        println!("  endpoint       : {id}");
    }
    println!("  captured       : {} frames ({:.2} s)", stats.captured_frames, stats.captured_seconds);
    println!(
        "  packets        : {listen_packets} in the {LISTEN:?} window ({listen_bytes} bytes of PCM)"
    );
    println!("  level          : rms={} peak={peak}", loudest as i64);
    println!("  dropped        : {} frames", stats.dropped_frames);
    println!();

    if let Some(e) = stats.failure {
        let (zh, en) = e.message();
        println!("{} {}", crate::i18n::t("失败：", "FAILED: "), crate::i18n::t(zh, en));
        // The HRESULT, because "initialise failed" is not a diagnosis. It names
        // the exact reason and it is the number to put in a bug report; the
        // human sentence above is the part a user can act on.
        println!("  HRESULT: 0x{:08X}", e.code());
        return ExitCode::FAILURE;
    }
    if listen_packets == 0 {
        println!(
            "{}",
            crate::i18n::t(
                "没有收到任何音频 —— 采集启动了，但默认输出设备没有声音。\n\
                 如果你的声音正在输出到耳机、显示器或蓝牙音箱，请在「设置 → 系统 → 声音」里\n\
                 把默认输出改回本机扬声器，然后重跑一次。",
                "No audio arrived - the capture started, but the default output device has none.\n\
                 If your sound is on headphones, a monitor or a Bluetooth speaker, set the\n\
                 default output back to this PC's speakers in Settings > System > Sound, and run this again."
            )
        );
        return ExitCode::FAILURE;
    }
    if peak == 0 {
        println!(
            "{}",
            crate::i18n::t(
                "收到了 {packets} 个包，但全是数字静音 —— 采集在跑，系统没有输出声音。\n\
                 放一段音乐再重跑一次；如果还是这样，检查默认输出设备的音量。",
                "Received {packets} packets, all of them digital silence - the capture is\n\
                 running and the system is outputting nothing. Play some music and run this\n\
                 again; if it still reports this, check the default output's volume."
            )
        );
        return ExitCode::FAILURE;
    }

    println!(
        "{}",
        crate::i18n::t(
            "✅ 正常 —— 这台电脑可以把系统声音发给手机。",
            "OK - this PC can send its system audio to the phone."
        )
    );
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stats_with(frames: u64, dropped: u64, seconds: f64) -> CaptureStats {
        CaptureStats {
            running: true,
            captured_frames: frames,
            dropped_frames: dropped,
            captured_seconds: seconds,
            ..Default::default()
        }
    }

    // ---- the policy

    #[test]
    fn the_first_request_starts_and_a_repeat_does_not() {
        assert_eq!(decide(true, true, false), Action::StartCapture);
        assert_eq!(decide(true, true, true), Action::NoChange);
    }

    /// The Mac side has the same guard: capturing with nobody listening is work
    /// for nothing, and the phone asks again next session.
    #[test]
    fn nothing_starts_without_a_session() {
        assert_eq!(decide(true, false, false), Action::NoChange);
    }

    /// Turning it off has to work even if the session has already gone — that is
    /// precisely when the capture is still running and needs stopping.
    #[test]
    fn turning_it_off_works_even_when_disconnected() {
        assert_eq!(decide(false, false, true), Action::StopCapture);
        assert_eq!(decide(false, true, true), Action::StopCapture);
    }

    #[test]
    fn an_idle_flag_is_never_an_action() {
        assert_eq!(decide(false, true, false), Action::NoChange);
        assert_eq!(decide(false, false, false), Action::NoChange);
    }

    /// All eight combinations, because this is the whole state machine. A policy
    /// that starts twice or never stops is exactly what this pins down.
    #[test]
    fn the_policy_is_total_and_consistent() {
        for requested in [false, true] {
            for connected in [false, true] {
                for running in [false, true] {
                    match decide(requested, connected, running) {
                        Action::NoChange => assert!(
                            !(requested && connected && !running),
                            "asked for the speaker, connected, not running, and nothing happened"
                        ),
                        Action::StartCapture => {
                            assert!(requested && connected && !running)
                        }
                        Action::StopCapture => assert!(!requested && running),
                    }
                }
            }
        }
    }

    // ---- classification

    #[test]
    fn a_dead_capture_outranks_everything_else() {
        // Even with audio "arrived": if the capture reports a failure, that is
        // the reason, and reporting anything else sends the user hunting.
        let mut s = stats_with(48_000, 0, 10.0);
        s.failure = Some(LoopbackError::Capture(0));
        assert!(matches!(
            classify(&s, false),
            Some(Status::Failed(LoopbackError::Capture(0)))
        ));
    }

    /// The mute case has to be its own message: the user's own action caused it,
    /// and "no audio yet" would point them at the wrong thing entirely.
    #[test]
    fn a_mute_that_silenced_the_capture_is_reported_as_its_own_thing() {
        assert_eq!(
            classify(&stats_with(0, 0, 10.0), true),
            Some(Status::MuteBrokeTheAudio)
        );
    }

    /// Within the grace period there is no verdict at all. Reporting "no audio"
    /// the instant the capture starts would flash on every single start, and a
    /// message that flashes is a message nobody reads.
    #[test]
    fn the_first_few_seconds_earn_no_verdict() {
        assert_eq!(classify(&stats_with(0, 0, 0.0), false), None);
        assert_eq!(classify(&stats_with(0, 0, 2.9), false), None);
        assert_eq!(
            classify(&stats_with(0, 0, SILENCE_GRACE.as_secs_f64()), false),
            Some(Status::NoAudioYet)
        );
    }

    /// A drop counter that climbs while the system is silent is normal, not a
    /// fault: nothing was dropped because there was nothing to drop.
    #[test]
    fn dropping_only_matters_once_audio_is_arriving() {
        assert_eq!(
            classify(&stats_with(48_000, 0, 10.0), false),
            Some(Status::Working)
        );
        assert_eq!(
            classify(&stats_with(48_000, 960, 10.0), false),
            Some(Status::Dropping(960))
        );
    }

    // ---- the tray line

    /// Every unhappy status must tell the user either **what to do** or **that it
    /// has already been handled**. A status that reports a problem and leaves
    /// the user with neither leaves them stuck (rule 1) — but a message that
    /// says "we switched to the working alternative" is not missing an action,
    /// and demanding one there would push the code to invent busywork.
    ///
    /// The marker lists are deliberately broad. The point is to catch a message
    /// that is only a noun ("audio capture broke"), not to grade prose — a narrow
    /// list just makes the test fail on wording and get weakened.
    #[test]
    fn every_unhappy_status_tells_the_user_what_to_do() {
        const ZH_ACTION: [&str; 7] = ["选", "换", "重启", "关掉", "重新", "再试", "打开"];
        const EN_ACTION: [&str; 8] = [
            "settings", "close", "restart", "pick", "turn", "try", "open", "choose",
        ];
        const ZH_HANDLED: [&str; 3] = ["已改为", "不受影响", "已经自动"];
        const EN_HANDLED: [&str; 4] = ["switched", "already", "automatically", "undone"];
        let cases = [
            Status::Failed(LoopbackError::NoOutputDevice(0)),
            Status::Failed(LoopbackError::Volume(0)),
            Status::NoAudioYet,
            Status::Dropping(960),
            Status::MuteBrokeTheAudio,
        ];
        for s in cases {
            let (label, value) = status_row(s).expect("an unhappy status needs a row");
            assert!(!label.is_empty());
            assert!(value.len() > 20, "too terse to act on: {value}");
            // Checked in whichever language this machine shows, so the assertion
            // cannot pass by accident on a locale that happens to suit the text.
            let (action, handled) = if crate::i18n::is_chinese() {
                (&ZH_ACTION[..], &ZH_HANDLED[..])
            } else {
                (&EN_ACTION[..], &EN_HANDLED[..])
            };
            let says_something_useful = action.iter().any(|m| value.contains(m))
                || handled.iter().any(|m| value.contains(m));
            assert!(
                says_something_useful,
                "neither an action nor \"already handled\": {value}"
            );
        }
    }

    /// The same for every failure variant, checked in the raw pair rather than
    /// through the locale, so neither language can hide behind the other.
    #[test]
    fn every_failure_variant_says_something_useful_in_both_languages() {
        const ZH_ACTION: [&str; 7] = ["选", "换", "重启", "关掉", "重新", "再试", "打开"];
        const ZH_HANDLED: [&str; 3] = ["已改为", "不受影响", "已经自动"];
        const EN_ACTION: [&str; 8] = [
            "settings", "close", "restart", "pick", "turn", "try", "open", "choose",
        ];
        const EN_HANDLED: [&str; 4] = ["switched", "already", "automatically", "undone"];
        let all = [
            LoopbackError::NoOutputDevice(0),
            LoopbackError::ComInit(0),
            LoopbackError::Activate(0),
            LoopbackError::MixFormat(0),
            LoopbackError::Unsupported(rc_loopback::Unsupported::NoChannels),
            LoopbackError::Unsupported(rc_loopback::Unsupported::NoSampleRate),
            LoopbackError::Unsupported(rc_loopback::Unsupported::SampleFormat),
            LoopbackError::Initialize(0),
            LoopbackError::Start(0),
            LoopbackError::Capture(0),
            LoopbackError::Volume(0),
            LoopbackError::ThreadSpawn,
        ];
        for e in all {
            let (zh, en) = e.message();
            assert!(!zh.is_empty() && !en.is_empty(), "{e:?} has an empty message");
            assert!(zh.len() > 15, "{e:?} zh is too terse: {zh}");
            assert!(en.len() > 20, "{e:?} en is too terse: {en}");
            for (text, action, handled, tag) in [
                (zh.to_string(), &ZH_ACTION[..], &ZH_HANDLED[..], "zh"),
                (
                    en.to_lowercase(),
                    &EN_ACTION[..],
                    &EN_HANDLED[..],
                    "en",
                ),
            ] {
                assert!(
                    action.iter().any(|m| text.contains(m))
                        || handled.iter().any(|m| text.contains(m)),
                    "{e:?} {tag} says neither what to do nor that it is handled: {text}"
                );
            }
        }
    }

    /// A working feature says nothing. A row that is always there is a row the
    /// user learns to skip, and then the one time it matters it is not read.
    #[test]
    fn a_working_capture_has_no_row() {
        assert!(status_row(Status::Working).is_none());
    }

    // ---- the preference

    #[test]
    fn a_stored_preference_round_trips() {
        let dir = std::env::temp_dir().join(format!("rc-speaker-pref-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for b in [MuteBehaviour::KeepLocal, MuteBehaviour::MuteLocal] {
            assert!(set_mute_preference_in(&dir, b));
            assert_eq!(mute_preference_in(&dir), b);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A file that cannot be read must not become a preference the user never
    /// chose — and on Windows the safe direction is also the default.
    #[test]
    fn an_unreadable_preference_falls_back_to_the_safe_default() {
        assert_eq!(parse_mute_pref(""), default_behaviour());
        assert_eq!(parse_mute_pref("nonsense"), MuteBehaviour::KeepLocal);
        assert_eq!(parse_mute_pref("2"), MuteBehaviour::KeepLocal);
        assert_eq!(parse_mute_pref("1"), MuteBehaviour::MuteLocal);
        assert_eq!(parse_mute_pref(" 1 \n"), MuteBehaviour::MuteLocal);
        assert_eq!(parse_mute_pref("0"), MuteBehaviour::KeepLocal);
        assert_eq!(parse_mute_pref("mute"), MuteBehaviour::MuteLocal);
        assert_eq!(parse_mute_pref("keep"), MuteBehaviour::KeepLocal);
    }

/// The default is the one that cannot leave a user with a silent computer.
#[test]
fn the_default_never_touches_the_volume() {
        assert!(!default_behaviour().is_muting());
    }

    // ---- the tray row, against the Mac's four cases
    //
    // `MenuBarMenu.swift`'s `speakerSubtitle` is the reference and this table is
    // it: connect-first, a locally-fixable failure speaks for itself, and the two
    // states each name where the user changes them. A Windows row that silently
    // differs is how the two receivers end up describing one feature two ways.

    #[test]
    fn disconnected_names_the_one_thing_that_would_change_it() {
        for on in [false, true] {
            let line = status_line(false, on);
            assert!(
                line.contains("连接") || line.contains("Connect"),
                "does not say the phone is the blocker: {line}"
            );
        }
    }

    /// A row that only says where to go elsewhere has told the user nothing
    /// about *now*, so both the state and the place are in the one string.
    #[test]
    fn both_states_name_the_state_and_the_place_that_changes_it() {
        let on = status_line(true, true);
        let off = status_line(true, false);
        assert_ne!(on, off, "the two states read identically");
        for line in [&on, &off] {
            assert!(
                line.contains("iPhone"),
                "does not say where the switch lives: {line}"
            );
        }
    }

    /// A failure the user CAN fix here outranks the state sentence, because
    /// there is a control to go and use — the Mac's rule for `speakerStatus`.
    #[test]
    fn a_locally_fixable_failure_speaks_instead_of_the_state() {
        publish(Some(Status::Failed(LoopbackError::NoOutputDevice(0))));
        let line = status_line(true, true);
        assert!(
            !line.contains("iPhone"),
            "the state sentence hid the failure: {line}"
        );
        assert!(line.contains("设置") || line.contains("Settings"), "{line}");
        publish(None);
    }

    #[test]
    fn a_working_capture_falls_back_to_the_state_sentence() {
        publish(Some(Status::Working));
        assert_eq!(status_line(true, true), state_sentence(true, true));
        assert_eq!(status_line(true, false), state_sentence(true, false));
        publish(None);
    }

    /// Publishing is how the tray learns, and it must be clearable — a stale
    /// failure would keep speaking after the feature recovered.
    #[test]
    fn publishing_and_clearing_round_trip() {
        assert_eq!(published(), None);
        publish(Some(Status::Dropping(42)));
        assert_eq!(published(), Some(Status::Dropping(42)));
        publish(None);
        assert_eq!(published(), None);
    }

    /// The row's title must match the Mac's, or the two menus name one feature
    /// two ways and support answers "which one?".
    #[test]
    fn the_row_is_titled_like_the_macs() {
        assert_eq!(TITLE.1, "Play computer sound");
        assert_eq!(TITLE.0, "播放电脑声音");
    }
}