//! RemoteCrab for Windows — receiver CLI + status window.
//!
//! Wires the crates together exactly like the Mac receiver's `ReceiverSession`
//! does: discovery → TCP handshake → stream → input injection. For the first
//! runnable milestone the UI is a console status board (plus an optional
//! always-on-top window on Windows); a Tauri shell can be layered on top
//! without changing the session crate.
//!
//! Usage:
//!   remotecrab                  # discover + auto-connect
//!   remotecrab --connect IP[:P] # connect to a specific iPhone (bypasses mDNS)
//!   remotecrab --no-input       # observe only (don't drive the cursor)
//!   remotecrab --list           # print discovered iPhones and keep running

use std::process::ExitCode;
use std::time::Duration;

use rc_net::{Config, Event, Session, State};
use rc_protocol::{encode_app_list, encode_file_ack, encode_installed_apps, encode_window_list};

#[cfg(windows)]
mod doctor;
mod mirror;
#[cfg(windows)]
mod vcam;
mod i18n;
mod tray;

#[derive(Debug, Default)]
struct Args {
    connect: Option<String>,
    no_input: bool,
    list_only: bool,
    selftest: bool,
    preview_selftest: bool,
    audio_selftest: bool,
    vcam: bool,
    vcam_selftest: bool,
    preview: bool,
    no_preview: bool,
    scan: bool,
    unmute: bool,
    record: bool,
    no_tray: bool,
    /// `remotecrab doctor [ip[:port]]` — diagnose "it won't connect".
    doctor: bool,
}

fn parse_args() -> Args {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    parse_args_from(&raw)
}

/// Parse an already-collected argument list.
///
/// Takes a slice so it can be unit-tested; `parse_args` is the only caller
/// that touches the real process arguments.
fn parse_args_from(raw: &[String]) -> Args {
    let mut args = Args::default();
    let mut help = false;
    let mut i = 0;
    while i < raw.len() {
        match raw[i].as_str() {
            "--connect" => {
                i += 1;
                args.connect = raw.get(i).cloned();
            }
            "--no-input" => args.no_input = true,
            "--list" => args.list_only = true,
            "--selftest" => args.selftest = true,
            "--preview-selftest" => args.preview_selftest = true,
            "--preview" => args.preview = true,
            "--no-preview" => args.no_preview = true,
            "--scan" => args.scan = true,
            "--unmute" => args.unmute = true,
            "--audio-selftest" => args.audio_selftest = true,
            "--vcam" => args.vcam = true,
            "--vcam-selftest" => args.vcam_selftest = true,
            "--record" => args.record = true,
            "--no-tray" => args.no_tray = true,
            // `--doctor [ip[:port]]`: the operand is optional and
            // position-sensitive, so it is consumed here rather than left to
            // fall through to the generic `--connect` handling.
            "--doctor" => {
                args.doctor = true;
                if raw.get(i + 1).is_some_and(|n| !n.starts_with("--")) {
                    i += 1;
                    args.connect = raw.get(i).cloned();
                }
            }
            "--help" | "-h" => help = true,
            _ => {}
        }
        i += 1;
    }
    if help {
        print_help();
        std::process::exit(0);
    }
    // The preview window opens by default; `--no-preview` is the opt-out.
    if !args.no_preview {
        args.preview = true;
    }
    args
}

/// One row per `--help` line: `(argument, Chinese, English)`.
///
/// Data-driven on purpose: two hand-copied help blocks drift the moment a flag
/// is added, and the flag list is exactly the part a user copy-pastes.
const USAGE: &[(&str, &str, &str)] = &[
    (
        "remotecrab",
        "自动发现并连接 iPhone，打开预览窗口",
        "Discover, connect, and open a preview window",
    ),
    ("--connect IP[:P]", "直接连接（mDNS 被拦截时）", "Connect directly (when mDNS is blocked)"),
    ("--no-input", "只看不操作（不控制本机）", "Watch only (do not drive this PC)"),
    ("--no-preview", "只显示状态，不开视频窗口", "Console status only (no video window)"),
    ("--list", "列出已发现的 iPhone 并等待", "List discovered iPhones and wait"),
    ("--selftest", "本地假 iPhone 自检整条链路", "Run a fake iPhone locally and verify the pipeline"),
    ("--preview-selftest", "把假 H.264 喂进预览窗口验证解码", "Stream fake H.264 into the preview window and verify decode"),
    ("--scan", "扫描本机 /24 网段中 8765 端口的 iPhone", "Scan this PC's /24 for an iPhone on port 8765"),
    ("--audio-selftest", "生成测试音 → 编码 Opus → 解码播放", "Generate a tone, encode to Opus, decode, and play it"),
    ("--vcam", "把画面发布为 \"RemoteCrab\" 虚拟摄像头", "Publish the video to a \"RemoteCrab\" virtual camera"),
    ("--vcam-selftest", "给虚拟摄像头喂动态测试图（无需手机）", "Feed a moving test pattern to the virtual camera (no phone)"),
    ("--unmute", "把 iPhone 麦克风播到本机扬声器", "Play the iPhone mic on this PC's speakers"),
    ("--record", "录制当前画面（见下方 record 命令）", "Record the live stream (see `record` below)"),
    ("--doctor [ip[:port]]", "诊断“为什么连不上 iPhone”并给出解决办法", "Explain why the iPhone will not connect, and what to do about it"),
    ("--no-tray", "不显示托盘图标", "Skip the notification-area tray icon"),
];

/// Live console commands, shown by both `--help` and the `help` command, so
/// the two can never disagree: `(command, Chinese, English)`.
const COMMANDS: &[(&str, &str, &str)] = &[
    ("camera [on|off]", "摄像头开关", "Camera on/off"),
    ("mic [on|off]", "麦克风开关", "Microphone on/off"),
    ("voice [on|off]", "语音输入开关", "Dictation on/off"),
    ("trackpad [on|off]", "触控板开关", "Trackpad on/off"),
    ("keyboard [on|off]", "键盘开关", "Keyboard on/off"),
    ("switch-camera", "切换前后摄像头", "Switch camera"),
    ("clipboard", "把本机剪贴板发到 iPhone", "Send this PC's clipboard to the iPhone"),
    ("record", "开始 / 停止录制", "Start / stop recording"),
    ("autostart", "开机自启动开关", "Toggle start at login"),
    ("help", "显示这份帮助", "Show this help"),
    ("doctor [ip[:port]]", "诊断连接问题（见上方 --doctor）", "Diagnose the connection (see --doctor above)"),
    ("quit", "退出", "Quit"),
];

fn print_help() {
    println!("RemoteCrab for Windows\n");
    println!("{}", i18n::t("用法：", "Usage:"));
    let wide = USAGE.iter().map(|(a, _, _)| a.chars().count()).max().unwrap_or(0);
    for (arg, zh, en) in USAGE {
        let desc = i18n::t(zh, en);
        println!("  {arg:<wide$}  {desc}", wide = wide + 1);
    }
    println!();
    println!(
        "{}",
        i18n::t(
            "运行时可以输入下面这些控制台命令（回车确认）：",
            "While running, type these console commands (then Enter):"
        )
    );
    print_console_help();
    println!();
    println!(
        "{}",
        i18n::t(
            "请先打开 RemoteCrab iOS app；两台设备必须在同一 WiFi 下。",
            "Run the RemoteCrab iOS app first; both devices must share the same WiFi."
        )
    );
}

/// Read stdin on a background thread and forward each non-empty line over a
/// channel, so the main `tokio::select!` can accept console commands without
/// blocking. The thread exits on EOF (e.g. when stdin is a pipe).
fn spawn_console_reader() -> tokio::sync::mpsc::UnboundedReceiver<String> {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    std::thread::spawn(move || {
        use std::io::BufRead;
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            let line = line.trim().to_string();
            if !line.is_empty() && tx.send(line).is_err() {
                break;
            }
        }
    });
    rx
}

fn print_console_help() {
    println!(
        "  {}",
        i18n::t("命令：", "commands:")
    );
    let wide = COMMANDS.iter().map(|(c, _, _)| c.chars().count()).max().unwrap_or(0);
    for (cmd, zh, en) in COMMANDS {
        let desc = i18n::t(zh, en);
        println!("  {cmd:<wide$}  {desc}", wide = wide + 1);
    }
}

/// An in-progress recording. The muxer is pure; the Opus decoder is private
/// to recording (the playback player keeps its own decoder state).
struct ActiveRecording {
    recorder: rc_record::Recorder,
    opus: Option<rc_audio::OpusDecoder>,
}

/// Filename stem: `recording-<unix seconds>` (the Mac uses a date stamp).
fn recording_stem() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("recording-{secs}")
}

fn start_recording(width: i64, height: i64, fps: i64) -> Option<ActiveRecording> {
    let dir = rc_os::recording_directory();
    let stem = recording_stem();
    let rec = match rc_record::Recorder::new(
        &dir,
        &stem,
        width.max(1) as u32,
        height.max(1) as u32,
        fps.max(1) as u32,
    ) {
        Ok(rec) => rec,
        Err(e) => {
            println!("  {} {e}", i18n::t("录制启动失败：", "recording failed to start:"));
            return None;
        }
    };
    println!("  ● {} → {}", i18n::t("录制中", "recording"), rec.mp4_path().display());
    Some(ActiveRecording {
        recorder: rec,
        opus: rc_audio::OpusDecoder::new().ok(),
    })
}

fn stop_recording(rec: ActiveRecording) {
    let mp4 = rec.recorder.mp4_path().to_path_buf();
    let (video_ok, _audio_ok) = rec.recorder.finish();
    if video_ok {
        println!("  ■ {} {}", i18n::t("录制已保存：", "recording saved:"), mp4.display());
        #[cfg(windows)]
        rc_os::files::reveal(&mp4);
    } else {
        println!(
            "  {} {}",
            i18n::t("录制结束，但没有视频帧：", "recording stopped with no video frames:"),
            mp4.display()
        );
    }
}

/// Decode one audio packet to PCM for recording (Opus, or raw Int16 fallback,
/// mirroring the playback player).
fn decode_for_record(
    opus: &mut Option<rc_audio::OpusDecoder>,
    packet: &rc_protocol::AudioPacket,
) -> Vec<i16> {
    if packet.codec == rc_protocol::AUDIO_CODEC_OPUS {
        opus.as_mut()
            .map(|d| d.decode(&packet.opus_data))
            .unwrap_or_default()
    } else {
        packet
            .opus_data
            .chunks_exact(2)
            .map(|b| i16::from_le_bytes([b[0], b[1]]))
            .collect()
    }
}

/// Push this PC's clipboard to the iPhone (`clipboardSet`, 0x13) — the tray
/// row and the `clipboard` console command share this path.
fn send_clipboard_to_iphone(session: &Session) {
    #[cfg(windows)]
    match rc_os::clipboard::get_text() {
        Some(text) if !text.is_empty() => {
            let msg = rc_protocol::Clipboard { text: text.clone() };
            match rc_protocol::encode_clipboard(&msg) {
                Ok(frame) => {
                    session.send_frame(frame);
                    println!(
                        "  → {} ({} {})",
                        i18n::t("剪贴板已发到 iPhone", "sent clipboard to iPhone"),
                        text.chars().count(),
                        i18n::t("字符", "chars")
                    );
                }
                Err(_) => println!("  {}", i18n::t("剪贴板发送失败", "clipboard send failed")),
            }
        }
        _ => println!("  {}", i18n::t("剪贴板为空或不是文本", "clipboard is empty or not text")),
    }
    #[cfg(not(windows))]
    {
        let _ = session;
        println!("  {}", i18n::t("剪贴板功能仅限 Windows", "clipboard send is Windows-only"));
    }
}

/// Apply one console command: toggle (or explicitly set) an iPhone feature,
/// flip the camera, print help, or request shutdown.
fn handle_console_command(
    line: &str,
    session: &Session,
    last_features: &mut Option<rc_protocol::FeatureStateSnapshot>,
    quit_requested: &mut bool,
    recording: &mut Option<ActiveRecording>,
    metadata: Option<&rc_protocol::StreamMetadata>,
) {
    let mut parts = line.split_whitespace();
    let Some(cmd) = parts.next() else { return };
    let want = match parts.next() {
        None => None,
        Some("on") | Some("1") | Some("true") => Some(true),
        Some("off") | Some("0") | Some("false") => Some(false),
        Some(other) => {
            println!(
                "  {} '{other}' {}",
                i18n::t("未知状态", "unknown state"),
                i18n::t("（用 on / off）", "(use on/off)")
            );
            return;
        }
    };
    let feature = |which: rc_protocol::Feature, cur: bool, zh: &str, en: &str| {
        let on = want.unwrap_or(!cur);
        session.set_feature(which, on);
        let name = i18n::t(zh, en);
        let state = if on { i18n::t("开", "on") } else { i18n::t("关", "off") };
        println!("  → {name} {state}");
    };
    let get = |pick: fn(&rc_protocol::FeatureStateSnapshot) -> bool| -> bool {
        last_features.as_ref().map(pick).unwrap_or(false)
    };
    match cmd {
        "camera" => feature(
            rc_protocol::Feature::Camera,
            get(|f| f.camera_on),
            "摄像头",
            "camera",
        ),
        "mic" | "microphone" => feature(
            rc_protocol::Feature::Microphone,
            get(|f| f.mic_on),
            "麦克风",
            "mic",
        ),
        "voice" => feature(
            rc_protocol::Feature::Voice,
            get(|f| f.voice_on),
            "语音输入",
            "voice",
        ),
        "trackpad" => feature(
            rc_protocol::Feature::Trackpad,
            get(|f| f.trackpad_on),
            "触控板",
            "trackpad",
        ),
        "keyboard" => feature(
            rc_protocol::Feature::Keyboard,
            get(|f| f.keyboard_on),
            "键盘",
            "keyboard",
        ),
        "switch-camera" | "flip-camera" => {
            session.switch_camera();
            println!("  → {}", i18n::t("正在切换摄像头", "switching camera"));
        }
        "clipboard" | "send-clipboard" => send_clipboard_to_iphone(session),
        "autostart" => {
            #[cfg(windows)]
            {
                let want = want.unwrap_or(!rc_os::autostart::is_enabled());
                let ok = rc_os::autostart::set_enabled(want);
                let state = if want { i18n::t("开", "on") } else { i18n::t("关", "off") };
                let result = if ok { i18n::t("成功", "ok") } else { i18n::t("失败", "failed") };
                println!("  → {} {state} ({result})", i18n::t("开机自启动", "autostart"));
            }
            #[cfg(not(windows))]
            println!("  {}", i18n::t("开机自启动仅限 Windows", "autostart is Windows-only"));
        }
        "record" => {
            if let Some(rec) = recording.take() {
                stop_recording(rec);
            } else {
                match metadata {
                    Some(m) => *recording = start_recording(m.width, m.height, m.fps),
                    None => println!(
                        "  {}",
                        i18n::t("还没连上手机，没什么可录的", "not connected yet — nothing to record")
                    ),
                }
            }
        }
        "help" | "?" => print_console_help(),
        "quit" | "exit" => *quit_requested = true,
        other => println!(
            "  {} '{other}' — {}",
            i18n::t("未知命令", "unknown command"),
            i18n::t("输入 help 查看帮助", "type `help`")
        ),
    }
}

/// Owns the toggleable preview window thread (tray → Show/Hide Preview).
struct PreviewWindow {
    slot: rc_render::window::FrameSlot,
    status: std::sync::Arc<std::sync::Mutex<String>>,
    shutdown: std::sync::Arc<std::sync::atomic::AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl PreviewWindow {
    fn new(slot: rc_render::window::FrameSlot, status: std::sync::Arc<std::sync::Mutex<String>>) -> Self {
        Self {
            slot,
            status,
            shutdown: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            handle: None,
        }
    }

    /// True while the window thread is alive. The user closing the window
    /// (its own ✕ / Esc) ends the thread, which this notices.
    fn is_open(&mut self) -> bool {
        if let Some(handle) = self.handle.as_ref() {
            if handle.is_finished() {
                self.handle = None;
            }
        }
        self.handle.is_some()
    }

    fn open(&mut self) {
        if self.handle.is_some() {
            return;
        }
        self.shutdown
            .store(false, std::sync::atomic::Ordering::Relaxed);
        let slot = self.slot.clone();
        let status = self.status.clone();
        let shutdown = self.shutdown.clone();
        self.handle = Some(std::thread::spawn(move || {
            rc_render::window::run_preview_window("RemoteCrab Preview", slot, shutdown, status);
        }));
    }

    fn close(&mut self) {
        self.shutdown
            .store(true, std::sync::atomic::Ordering::Relaxed);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }

    /// Returns the new state (true = now open).
    fn toggle(&mut self) -> bool {
        if self.is_open() {
            self.close();
            false
        } else {
            self.open();
            true
        }
    }
}

#[tokio::main]
async fn main() -> ExitCode {
    let args = parse_args();

    if args.selftest {
        return selftest().await;
    }
    if args.preview_selftest {
        return preview_selftest().await;
    }
    if args.scan {
        return run_scan().await;
    }
    if args.doctor {
        return run_doctor(args.connect.as_deref()).await;
    }
    if args.audio_selftest {
        return audio_selftest();
    }
    if args.vcam_selftest {
        return vcam_selftest().await;
    }
    println!("RemoteCrab for Windows v{}", env!("CARGO_PKG_VERSION"));
    println!("{}\n", i18n::t("正在当前 WiFi 下寻找 iPhone…", "Looking for your iPhone on this WiFi…"));

    let session = Session::spawn(Config::default());
    let mut events = session.subscribe();
    let mut state_rx = session.state();

    if let Some(target) = &args.connect {
        match rc_discovery::parse_host_port(target, rc_net::DEFAULT_PORT) {
            Some((host, port)) => {
                println!("{} {host}:{port} …", i18n::t("正在连接", "Connecting to"));
                session.connect_manual(&host, port);
            }
            None => {
                eprintln!("{}: {target}", i18n::t("--connect 参数无效", "Invalid --connect value"));
                return ExitCode::from(2);
            }
        }
    }

    #[cfg(windows)]
    let mut injector = if args.no_input {
        None
    } else {
        Some(rc_input::windows_impl::WindowsInjector::new())
    };
    #[cfg(not(windows))]
    // Only read inside `#[cfg(windows)]` event arms, so on a non-Windows dev
    // build this binding looks unused — silence clippy rather than `cfg` the
    // whole surrounding logic.
    #[allow(unused_variables)]
    let injector: Option<()> = None;

    // App-window mirror: started/stopped by the iPhone's screenControl.
    #[cfg(windows)]
    let mut mirror = mirror::MirrorController::new(session.clone());

    // Video preview: decode in this task, blit from the window thread. The
    // virtual camera consumes the same decoded frames, so the decoder is also
    // needed when only `--vcam` is on (e.g. `--no-preview --vcam`).
    let mut preview: Option<rc_render::PreviewPipeline> = if args.preview || args.vcam {
        match rc_render::PreviewPipeline::new() {
            Ok(p) => Some(p),
            Err(e) => {
                eprintln!(
                    "{} ({e}); {}",
                    i18n::t("视频解码器不可用", "video decoder unavailable"),
                    i18n::t("继续运行，但不会有预览画面", "continuing without preview")
                );
                None
            }
        }
    } else {
        None
    };

    // Virtual camera: register the COM source DLL and publish decoded frames
    // into the shared-memory ring. Off unless `--vcam` is passed — it writes a
    // per-user COM registration and creates a session-scoped device.
    #[cfg(windows)]
    let mut vcam = if args.vcam {
        vcam::Vcam::start("RemoteCrab")
    } else {
        None
    };
    #[cfg(not(windows))]
    #[allow(unused_variables, unused_mut)]
    let mut vcam: Option<()> = {
        if args.vcam {
            eprintln!("--vcam is Windows-only");
        }
        None
    };
    let frame_slot = rc_render::window::FrameSlot::new();
    let status_text = std::sync::Arc::new(std::sync::Mutex::new("Waiting for video…".to_string()));
    // The preview window is toggleable at runtime (tray → Show/Hide Preview),
    // so it owns its own thread + shutdown flag instead of one launched here.
    let mut preview_window = PreviewWindow::new(frame_slot.clone(), status_text.clone());
    if args.preview {
        preview_window.open();
    }

    // Audio: Opus decode + speaker playback. Muted by default (the Mac
    // receiver does the same — playing the iPhone mic on the speakers next
    // to the live phone is a feedback loop). `--unmute` enables it.
    let mut audio = rc_audio::AudioPlayer::new();
    audio.set_muted(!args.unmute);
    if !args.unmute {
        println!("  (audio is muted by default to avoid feedback — --unmute to hear it)");
    }

    // Receives files from the iPhone into ~/Downloads/RemoteCrab.
    let mut file_rx = rc_os::files::FileReceiver::new(rc_os::incoming_directory());

    let mut last_label = String::new();
    let mut video_frames: u64 = 0;
    // While another computer owns the iPhone we retry quietly — printing a
    // line every 10 s would be noise. We only re-announce when something
    // actually changes.
    let mut stuck_owner: Option<String> = None;
    let mut last_spike_report = std::time::Instant::now();

    // Console feature control: the receiver can toggle the iPhone's camera /
    // mic / voice / surfaces the same way the Mac menu bar does.
    let mut console_rx = spawn_console_reader();
    let mut console_alive = true;
    let mut last_features: Option<rc_protocol::FeatureStateSnapshot> = None;
    let mut quit_requested = false;
    // Recording: `--record` arms it, the `record` console command toggles it.
    let mut metadata: Option<rc_protocol::StreamMetadata> = None;
    let mut recording: Option<ActiveRecording> = None;
    // The most recent received file, for the tray's "Show last received".
    #[cfg(windows)]
    let mut last_received_file: Option<std::path::PathBuf> = None;
    // Notification-area tray (menu mirrors the Mac's menu-bar popover).
    #[cfg(windows)]
    let (tray, mut tray_rx) = if args.no_tray {
        tray::disabled()
    } else {
        tray::start("RemoteCrab")
    };
    #[cfg(not(windows))]
    let (tray, mut tray_rx) = tray::start("RemoteCrab");
    #[cfg(windows)]
    tray.set_autostart(rc_os::autostart::is_enabled());
    tray.set_preview(preview_window.is_open());
    let mut tray_alive = true;
    println!("{}", i18n::t("输入 help 查看可用的实时控制命令。", "Type `help` for live iPhone feature commands."));

    loop {
        tokio::select! {
            changed = state_rx.changed() => {
                if changed.is_err() {
                    break;
                }
                let st = state_rx.borrow().clone();

                // Collapse the busy→connecting→busy churn into silence.
                match &st {
                    State::Busy { owner } => {
                        if stuck_owner.as_deref() == Some(owner.as_str()) {
                            continue;
                        }
                        stuck_owner = Some(owner.clone());
                    }
                    State::Streaming { .. } => stuck_owner = None,
                    _ => {
                        // Intermediate states during a busy retry are hidden.
                        if stuck_owner.is_some() {
                            continue;
                        }
                    }
                }

                let label = state_line(&st);
                if label != last_label {
                    println!("{label}");
                    last_label = label;
                }
                if let State::Error(_) = st {
                    println!("   (if the iPhone is running RemoteCrab, try: remotecrab --connect <iphone-ip>)");
                }
                // Keep the tray's status row in sync (single-line pill-style).
                tray.set_status(&tray_status(&st));
            }
            ev = events.recv() => {
                let Ok(ev) = ev else { continue };
                match ev {
                    Event::Discovered(phones) => {
                        if args.list_only || last_label.is_empty() {
                            if phones.is_empty() {
                                println!("  {}", i18n::t("还没发现 iPhone…", "no iPhones found yet…"));
                            } else {
                                for p in &phones {
                                    let addr = p.host.as_deref().unwrap_or("(resolving)");
                                    println!(
                                        "  {} {}  @ {}:{}",
                                        i18n::t("已发现：", "found:"),
                                        p.name,
                                        addr,
                                        p.port
                                    );
                                }
                            }
                        }
                    }
                    Event::Metadata(m) => {
                        println!(
                            "  → streaming: {} {}x{} @ {}fps ({} kbps)",
                            m.resolution_label(),
                            m.width,
                            m.height,
                            m.fps,
                            m.bitrate_bps / 1000
                        );
                        if args.record && recording.is_none() {
                            recording = start_recording(m.width, m.height, m.fps);
                        }
                        metadata = Some(m);
                    }
                    Event::Video(nal) => {
                        video_frames += 1;
                        if let Some(rec) = recording.as_mut() {
                            match nal.kind {
                                rc_protocol::NalKind::Sps => rec.recorder.set_sps(&nal.data),
                                rc_protocol::NalKind::Pps => rec.recorder.set_pps(&nal.data),
                                rc_protocol::NalKind::Video => rec.recorder.add_video(&nal.data),
                            }
                        }
                        if let Some(p) = preview.as_mut() {
                            if p.push(&nal) {
                                if let Some(frame) = p.latest() {
                                    frame_slot.set(frame.clone());
                                    #[cfg(windows)]
                                    if let Some(vc) = vcam.as_mut() {
                                        let fps = metadata
                                            .as_ref()
                                            .map(|m| m.fps.max(1) as u32)
                                            .unwrap_or(30);
                                        vc.publish(frame, fps);
                                        if vc.frames_written().is_multiple_of(150) {
                                            println!(
                                                "  vcam: {} frames published ({}x{})",
                                                vc.frames_written(),
                                                frame.width,
                                                frame.height
                                            );
                                        }
                                    }
                                }
                            } else if video_frames.is_multiple_of(600) {
                                if let Ok(mut s) = status_text.lock() {
                                    *s = format!("Receiving video… ({video_frames} NALs)");
                                }
                            }
                            if p.frames_decoded().is_multiple_of(150) {
                                let (w, h) = p.dimensions();
                                println!(
                                    "  video: {} frames decoded ({}x{})",
                                    p.frames_decoded(),
                                    w,
                                    h
                                );
                            }
                        } else if video_frames.is_multiple_of(150) {
                            println!("  video: {video_frames} NALs received");
                        }
                    }
                    Event::Touch(t) => {
                        #[cfg(windows)]
                        if let Some(inj) = injector.as_mut() {
                            inj.inject_touch(&t);
                        }
                        #[cfg(not(windows))]
                        let _ = &t;
                    }
                    Event::Key(k) => {
                        #[cfg(windows)]
                        if let Some(inj) = injector.as_ref() {
                            inj.inject_key(&k);
                        }
                        #[cfg(not(windows))]
                        let _ = &k;
                    }
                    Event::Audio(packet) => {
                        audio.consume(&packet);
                        if let Some(rec) = recording.as_mut() {
                            let pcm = decode_for_record(&mut rec.opus, &packet);
                            if !pcm.is_empty() {
                                let rate = if packet.sample_rate > 0 {
                                    packet.sample_rate as u32
                                } else {
                                    48000
                                };
                                let channels = if packet.channels > 0 {
                                    packet.channels as u16
                                } else {
                                    1
                                };
                                rec.recorder.add_audio(&pcm, rate, channels);
                            }
                        }
                        // Surface the level alongside the video counter.
                        if frame_slot.get().is_some() {
                            // (level is shown in the console periodically)
                        }
                    }
                    Event::Latency(ms) => {
                        // Keep the console readable: report a lag spike only
                        // when it is both large AND rare (a rolling gate), not
                        // on every ping.
                        if ms >= 500 && last_spike_report.elapsed() > Duration::from_secs(5) {
                            last_spike_report = std::time::Instant::now();
                            println!("  latency spike: {ms} ms");
                        }
                    }
                    // --- P2: clipboard / files / system commands / app list ---
                    Event::Clipboard(c) => {
                        #[cfg(windows)]
                        {
                            if rc_os::clipboard::set_text(&c.text) {
                                println!("  clipboard: received {} chars from iPhone", c.text.chars().count());
                            }
                        }
                        #[cfg(not(windows))]
                        let _ = &c;
                    }
                    Event::FileOffer(offer) => {
                        let ack = file_rx.begin(offer.clone());
                        session.send_frame(encode_file_ack(&ack).unwrap_or_default());
                        println!("  file: receiving {} ({} bytes)…", offer.name, offer.size);
                    }
                    Event::FileChunk(data) => {
                        if let Some(ack) = file_rx.append(&data) {
                            // Only ack progress periodically to avoid flooding.
                            if ack.received_bytes % (256 * 1024) < data.len() as i64 {
                                session.send_frame(encode_file_ack(&ack).unwrap_or_default());
                            }
                        }
                    }
                    Event::FileComplete(done) => {
                        if let Some((ack, path)) = file_rx.complete(&done.id) {
                            session.send_frame(encode_file_ack(&ack).unwrap_or_default());
                            println!("  file: saved to {}", path.display());
                            #[cfg(windows)]
                            {
                                rc_os::files::reveal(&path);
                                last_received_file = Some(path);
                            }
                            tray.set_has_last_file(true);
                        }
                    }
                    Event::SystemCommand(cmd) => {
                        #[cfg(windows)]
                        if !rc_os::system_keys::handle(&cmd) {
                            println!("  system command not supported on Windows: {:?}", cmd.command);
                        }
                        #[cfg(not(windows))]
                        let _ = &cmd;
                    }
                    Event::TextCommand(cmd) => {
                        #[cfg(windows)]
                        match rc_os::selection::rewrite_selection(cmd.command) {
                            Some((before, after)) => println!(
                                "  text command {:?}: {} chars rewritten",
                                cmd.command,
                                before.chars().count().max(after.chars().count())
                            ),
                            None => println!("  text command: nothing selected"),
                        }
                        #[cfg(not(windows))]
                        let _ = &cmd;
                    }
                    Event::AppListRequested => {
                        // The iPhone explicitly asked — include the 48 px
                        // icon PNGs (the launcher/window cards' fallback).
                        #[cfg(windows)]
                        let list = rc_os::apps::build_app_list(true);
                        #[cfg(not(windows))]
                        let list = rc_protocol::AppList { apps: vec![] };
                        session.send_frame(encode_app_list(&list).unwrap_or_default());
                    }
                    Event::WindowListRequested => {
                        #[cfg(windows)]
                        let list = rc_os::windows::build_window_list();
                        #[cfg(not(windows))]
                        let list = rc_protocol::WindowList { windows: vec![], can_capture: false };
                        session.send_frame(encode_window_list(&list).unwrap_or_default());
                    }
                    Event::InstalledAppsRequested => {
                        #[cfg(windows)]
                        let list = rc_os::apps::build_installed_apps();
                        #[cfg(not(windows))]
                        let list = rc_protocol::InstalledApps { apps: vec![] };
                        session.send_frame(encode_installed_apps(&list).unwrap_or_default());
                    }
                    Event::ActivateApp(a) => {
                        #[cfg(windows)]
                        {
                            if args.no_input {
                                println!("  app switch ignored (--no-input)");
                            } else if rc_os::apps::activate_id_with_title(&a.id, a.window_title.as_deref()) {
                                println!("  activated app {}", a.id);
                            } else {
                                println!("  app switch failed: {}", a.id);
                            }
                        }
                        #[cfg(not(windows))]
                        let _ = &a;
                    }
                    Event::QuitApp(q) => {
                        #[cfg(windows)]
                        {
                            if args.no_input {
                                println!("  app quit ignored (--no-input)");
                            } else if rc_os::apps::quit_id(&q.id, q.force) {
                                println!("  quit app {}", q.id);
                            } else {
                                println!("  app quit failed: {}", q.id);
                            }
                        }
                        #[cfg(not(windows))]
                        let _ = &q;
                    }
                    Event::FeatureState(s) => {
                        tray.set_features(Some(s.clone()));
                        last_features = Some(s);
                    }
                    Event::ScreenControl(control) => {
                        #[cfg(windows)]
                        {
                            use rc_protocol::ScreenControlCommand;
                            match control.command {
                                ScreenControlCommand::Start => {
                                    mirror.start(control.max_pixel.map(|p| p.max(0) as u32));
                                    println!("  mirror: started");
                                }
                                ScreenControlCommand::Stop => {
                                    mirror.stop();
                                    println!("  mirror: stopped");
                                }
                                ScreenControlCommand::Select => {
                                    mirror.select(control.window_id.clone());
                                    println!("  mirror: pinned to {:?}", control.window_id);
                                }
                                ScreenControlCommand::Follow => mirror.select(None),
                                ScreenControlCommand::Extend => {
                                    // The Windows receiver has no virtual-display
                                    // driver yet, so "Extended Display" is honest
                                    // about being unavailable.
                                    println!("  mirror: extended display is not supported on Windows yet");
                                }
                            }
                        }
                        #[cfg(not(windows))]
                        let _ = &control;
                    }
                    Event::ScreenInput(input) => {
                        #[cfg(windows)]
                        if let (Some(inj), Some((ox, oy, w, h))) =
                            (injector.as_mut(), mirror.geometry())
                        {
                            inj.inject_screen_input(&input, (ox, oy), (w, h));
                        }
                        #[cfg(not(windows))]
                        let _ = &input;
                    }
                    Event::State(_) => {}
                    _ => {}
                }
            }
            _ = tokio::signal::ctrl_c() => {
                println!("\nShutting down…");
                break;
            }
            line = console_rx.recv(), if console_alive => {
                match line {
                    Some(l) => {
                        handle_console_command(
                            &l,
                            &session,
                            &mut last_features,
                            &mut quit_requested,
                            &mut recording,
                            metadata.as_ref(),
                        );
                        tray.set_recording(recording.is_some());
                        if quit_requested {
                            println!("\nShutting down…");
                            break;
                        }
                    }
                    // The reader thread hit EOF (stdin was a pipe) — stop
                    // polling a closed channel or `select!` would spin.
                    None => console_alive = false,
                }
            }
            cmd = tray_rx.recv(), if tray_alive => {
                match cmd {
                    Some(tray::TrayCommand::SetFeature(feature, on)) => {
                        session.set_feature(feature, on);
                    }
                    Some(tray::TrayCommand::ToggleRecord) => {
                        if let Some(rec) = recording.take() {
                            stop_recording(rec);
                        } else if let Some(m) = metadata.as_ref() {
                            recording = start_recording(m.width, m.height, m.fps);
                        }
                        tray.set_recording(recording.is_some());
                    }
                    Some(tray::TrayCommand::SendClipboard) => send_clipboard_to_iphone(&session),
                    Some(tray::TrayCommand::ShowLastFile) => {
                        #[cfg(windows)]
                        match last_received_file.as_ref() {
                            Some(path) => rc_os::files::reveal(path),
                            None => println!(
                                "  {}",
                                i18n::t("还没有收到过文件", "no file received yet")
                            ),
                        }
                        #[cfg(not(windows))]
                        println!(
                            "  {}",
                            i18n::t("显示最后接收的文件仅限 Windows", "show-last-file is Windows-only")
                        );
                    }
                    Some(tray::TrayCommand::TogglePreview) => {
                        let on = preview_window.toggle();
                        tray.set_preview(on);
                        let state = if on {
                            i18n::t("已显示", "shown")
                        } else {
                            i18n::t("已隐藏", "hidden")
                        };
                        println!("  {} {state}", i18n::t("预览窗口", "preview window"));
                    }
                    Some(tray::TrayCommand::Reconnect) => session.retry_now(),
                    Some(tray::TrayCommand::Disconnect) => session.disconnect(),
                    Some(tray::TrayCommand::ToggleAutostart) => {
                        #[cfg(windows)]
                        {
                            let want = !rc_os::autostart::is_enabled();
                            let ok = rc_os::autostart::set_enabled(want);
                            tray.set_autostart(rc_os::autostart::is_enabled());
                            let state = if want { i18n::t("开", "on") } else { i18n::t("关", "off") };
                            let result = if ok { i18n::t("成功", "ok") } else { i18n::t("失败", "failed") };
                            println!("  {} {state} ({result})", i18n::t("开机自启动", "autostart"));
                        }
                        #[cfg(not(windows))]
                        println!("  {}", i18n::t("开机自启动仅限 Windows", "autostart is Windows-only"));
                    }
                    Some(tray::TrayCommand::Quit) => {
                        println!("\nShutting down…");
                        break;
                    }
                    // The tray thread ended (or `--no-tray` stub) — disable.
                    None => tray_alive = false,
                }
            }
        }
    }

    // Close the preview window and let its thread finish.
    #[cfg(windows)]
    mirror.stop();
    if let Some(rec) = recording.take() {
        stop_recording(rec);
    }
    preview_window.close();
    // Stop the virtual camera and remove its COM registration (Drop does the
    // same; explicit here so the log line is in the shutdown sequence).
    #[cfg(windows)]
    if let Some(vc) = vcam.take() {
        let n = vc.frames_written();
        println!("  vcam: stopping (published {n} frames)");
        drop(vc);
    }

    ExitCode::SUCCESS
}

/// `--selftest`: spin up a fake iPhone on localhost and drive the full
/// receive pipeline. No phone, no Mac, no admin rights required.
async fn selftest() -> ExitCode {
    use rc_testkit::{FakeIphone, FakeIphoneConfig};

    println!("Self-test: starting a fake iPhone on 127.0.0.1 …");
    let phone = match FakeIphone::start(FakeIphoneConfig::default()).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("  FAILED to start fake iPhone: {e}");
            return ExitCode::from(1);
        }
    };
    println!("  fake iPhone listening on {}", phone.addr);

    let session = Session::spawn(Config {
        token_path: None,
        ..Config::default()
    });
    let mut events = session.subscribe();

    // Connect directly to the fake phone.
    session.connect_manual("127.0.0.1", phone.addr.port());

    let mut got_metadata = false;
    let mut got_streaming = false;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    while tokio::time::Instant::now() < deadline && !(got_metadata && got_streaming) {
        match tokio::time::timeout(Duration::from_millis(400), events.recv()).await {
            Ok(Ok(Event::Metadata(m))) => {
                println!("  PASS  metadata: {}x{} @ {}fps", m.width, m.height, m.fps);
                got_metadata = true;
            }
            Ok(Ok(Event::State(State::Streaming { name, .. }))) => {
                println!("  PASS  streaming from {name}");
                got_streaming = true;
            }
            Ok(Ok(Event::Latency(ms))) if ms >= 0 => {
                println!("  PASS  ping round-trip: {ms} ms");
            }
            _ => {}
        }
    }

    if got_metadata && got_streaming {
        println!("\nSELF-TEST PASSED — the receive pipeline works.");
        println!("Next: run the RemoteCrab iOS app and start `remotecrab` again.");
        ExitCode::SUCCESS
    } else {
        eprintln!("\nSELF-TEST FAILED (metadata={got_metadata}, streaming={got_streaming})");
        ExitCode::from(1)
    }
}

/// `--preview-selftest`: a fake iPhone **streams real H.264**, the decoder
/// decodes it, and the preview window shows it. Proves "video on screen"
/// end-to-end without a phone or a network.
async fn preview_selftest() -> ExitCode {
    use rc_testkit::{FakeIphone, FakeIphoneConfig};

    println!("Preview self-test: fake iPhone will stream real H.264 …");
    let phone = match FakeIphone::start(FakeIphoneConfig {
        stream_video: true,
        video_frames: 90,
        ..Default::default()
    })
    .await
    {
        Ok(p) => p,
        Err(e) => {
            eprintln!("  FAILED to start fake iPhone: {e}");
            return ExitCode::from(1);
        }
    };
    println!("  fake iPhone on {} (streaming 90 frames @ ~30 fps)", phone.addr);

    let session = Session::spawn(Config {
        token_path: None,
        ..Config::default()
    });
    let mut events = session.subscribe();

    let mut pipeline = match rc_render::PreviewPipeline::new() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("  FAILED to create decoder: {e}");
            return ExitCode::from(1);
        }
    };

    let frame_slot = rc_render::window::FrameSlot::new();
    let shutdown = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let status_text =
        std::sync::Arc::new(std::sync::Mutex::new("Waiting for video…".to_string()));
    let window_handle = {
        let slot = frame_slot.clone();
        let shutdown = shutdown.clone();
        let status = status_text.clone();
        std::thread::spawn(move || {
            rc_render::window::run_preview_window("RemoteCrab Preview (self-test)", slot, shutdown, status);
        })
    };

    session.connect_manual("127.0.0.1", phone.addr.port());

    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let mut last_reported = 0u64;
    while tokio::time::Instant::now() < deadline && pipeline.frames_decoded() < 10 {
        if let Ok(Ok(Event::Video(nal))) =
            tokio::time::timeout(Duration::from_millis(300), events.recv()).await
        {
            if pipeline.push(&nal) {
                if let Some(frame) = pipeline.latest() {
                    frame_slot.set(frame.clone());
                }
            }
            let n = pipeline.frames_decoded();
            if n >= last_reported + 10 {
                last_reported = n;
                let (w, h) = pipeline.dimensions();
                println!("  decoded {n} frames ({w}x{h})");
            }
        }
    }

    let decoded = pipeline.frames_decoded();
    let (w, h) = pipeline.dimensions();

    // Leave the window up for a moment so a human can see the picture.
    if decoded > 0 {
        println!("  PASS  {decoded} frames decoded ({w}x{h}) — window is showing the video");
        tokio::time::sleep(Duration::from_secs(4)).await;
    }

    shutdown.store(true, std::sync::atomic::Ordering::Relaxed);
    let _ = window_handle.join();

    if decoded >= 10 && w > 0 && h > 0 {
        println!("\nPREVIEW SELF-TEST PASSED — video decodes and renders.");
        ExitCode::SUCCESS
    } else {
        eprintln!("\nPREVIEW SELF-TEST FAILED (decoded {decoded} frames, {w}x{h})");
        ExitCode::from(1)
    }
}

/// `--vcam-selftest`: start the virtual camera and feed it a moving test
/// pattern — no phone, no network. Open the Windows Camera app, pick
/// "RemoteCrab", and watch the bar sweep. Any consuming app proves the
/// shared-memory ring + COM source path end to end.
#[cfg(windows)]
async fn vcam_selftest() -> ExitCode {
    use rc_vcam::shm;

    const W: u32 = 1280;
    const H: u32 = 720;
    const FPS: u32 = 30;
    const SECONDS: u64 = 60;

    println!("Virtual-camera self-test: publishing a test pattern for {SECONDS}s …");
    println!("  open the Windows Camera app (or OBS) and pick \"RemoteCrab\"");
    println!("  (the COM source is registered under HKLM\\Software\\Classes\\CLSID)");

    // The ring must exist *before* the camera: the COM source reads its
    // geometry when a consumer activates it.
    let mut writer = match rc_vcam::writer::FrameWriter::create(W, H, FPS) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("  FAILED to create the frame ring: {e}");
            return ExitCode::from(1);
        }
    };
    if let Err(e) = rc_vcam::install_source() {
        eprintln!("  FAILED to register the COM source DLL: {e}");
        return ExitCode::from(1);
    }
    let camera = match rc_vcam::start_camera("RemoteCrab") {
        Ok(c) => c,
        Err(e) => {
            eprintln!("\nVCAM SELF-TEST FAILED — {e}");
            return ExitCode::from(1);
        }
    };
    if !camera.is_started() {
        eprintln!("\nVCAM SELF-TEST FAILED — Start() did not succeed");
        eprintln!("  (the CLSID is registered; check that the source DLL activates)");
        return ExitCode::from(1);
    }

    // A second `--vcam-selftest` in another shell is harmless: the name is
    // shared, and whoever wrote last supplies the pixels. We write directly
    // (bypassing `Vcam::publish`) so the pattern does not need a decoder.
    let start = std::time::Instant::now();
    let mut frame_no: u64 = 0;
    let mut reported = 0u64;
    while start.elapsed() < Duration::from_secs(SECONDS) {
        let bgra = shm::test_pattern_bgra(W, H, frame_no);
        if let Err(e) = writer.publish(&bgra) {
            eprintln!("  publish failed: {e}");
            break;
        }
        frame_no += 1;
        if frame_no.is_multiple_of(FPS as u64 * 5) && frame_no != reported {
            reported = frame_no;
            println!("  published {frame_no} frames ({}s)", start.elapsed().as_secs());
        }
        tokio::time::sleep(Duration::from_millis(1000 / FPS as u64)).await;
    }

    println!("\nVCAM SELF-TEST PASSED — {frame_no} frames written to the ring.");
    println!("If the Camera app showed a moving bar, the virtual camera works.");
    camera.stop();
    ExitCode::SUCCESS
}

/// `--vcam-selftest` on a non-Windows dev host (the flag exists so the CLI
/// surface is identical; the feature is Windows-only).
#[cfg(not(windows))]
async fn vcam_selftest() -> ExitCode {
    eprintln!("--vcam-selftest is Windows-only");
    ExitCode::from(2)
}

/// `--scan`: sweep the local `/24` for anything on port 8765. This is the
/// diagnostic for "mDNS found nothing" — it tells you whether the network
/// allows your devices to see each other at all.
/// `remotecrab doctor [ip[:port]]` — print the evidence, then the ranked
/// causes with what to do about each. Exits 0 when nothing is wrong, 1 when it
/// found something to fix, so a CI or support script can use it as a gate.
async fn run_doctor(target: Option<&str>) -> ExitCode {
    println!(
        "RemoteCrab doctor {}\n",
        i18n::t("— 诊断为什么 iPhone 连不上", "— why the iPhone will not connect")
    );
    let evidence = doctor::collect(target).await;

    println!(
        "{}",
        i18n::t(
            "本机地址 / this PC:",
            "this PC:"
        )
    );
    for a in &evidence.local_addrs {
        println!("  {a}");
    }
    match &evidence.route {
        rc_net::route::RouteVerdict::Direct => println!(
            "  {}",
            i18n::t("路由正常：走真实网卡", "route: direct (real adapter)")
        ),
        other => println!("  route: {}", rc_net::route::describe(other)),
    }
    if let Some(t) = &evidence.target {
        let open = evidence.tcp_open.unwrap_or(false);
        let state = if open {
            i18n::t("通", "open")
        } else {
            i18n::t("不通", "closed")
        };
        println!(
            "  {} {t} {state}",
            i18n::t("目标端口探测 / target probe:", "target probe:"),
        );
    }
    if evidence.mdns.is_empty() {
        println!(
            "  {}",
            i18n::t("mDNS：没有发现任何 iPhone", "mDNS: no iPhone advertised")
        );
    } else {
        println!("  mDNS: {}", evidence.mdns.join(", "));
    }

    let findings = doctor::rank(&evidence);
    if findings.is_empty() {
        println!(
            "\n{}",
            i18n::t(
                "没发现问题 —— 网络和手机都正常。",
                "Nothing wrong here — the network and the phone look fine."
            )
        );
        return ExitCode::SUCCESS;
    }
    println!();
    for f in &findings {
        println!("{}. {}", f.rank, f.problem);
        println!("   → {}\n", f.fix);
    }
    ExitCode::from(1)
}

async fn run_scan() -> ExitCode {
    let port = rc_net::DEFAULT_PORT;
    let ips = rc_discovery::local_ipv4_addresses();
    if ips.is_empty() {
        eprintln!("Could not determine this PC's LAN address (are you online?)");
        return ExitCode::from(1);
    }
    println!("This PC's LAN address(es): {}", ips.join(", "));

    let mut any = false;
    for ip in ips {
        println!(
            "Scanning {}.0/24 for port {port} (254 hosts, ~{}s) …",
            ip.rsplit_once('.').map(|(p, _)| p).unwrap_or(&ip),
            4
        );
        let found = rc_discovery::scan_subnet_for_port(
            &ip,
            port,
            std::time::Duration::from_millis(1200),
            128,
        )
        .await;
        if found.is_empty() {
            println!("  no device on {port} found in this subnet");
        } else {
            any = true;
            for host in found {
                println!("  FOUND  {host}:{port}");
                println!("         → connect with:  remotecrab --connect {host}:{port}");
            }
        }
    }

    if !any {
        println!(
            "\nNothing found. Likely causes, in order:\n\
             \x20 1. The iPhone's RemoteCrab app is not open + streaming\n\
             \x20 2. The iPhone is on a different WiFi / band\n\
             \x20 3. This router has AP isolation ON (clients can't see each other)\n\
             \x20    → turn off 'AP isolation / wireless isolation' in the router settings"
        );
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

/// `--audio-selftest`: feed the embedded Opus tone through the real decode +
/// playback path and report the level. Proves audio works without a phone.
fn audio_selftest() -> ExitCode {
    use rc_protocol::{AudioPacket, AUDIO_CODEC_OPUS};

    println!("Audio self-test: decoding the embedded 440 Hz Opus tone …");

    // Decode-only check first (no device needed).
    let mut decoder = match rc_audio::OpusDecoder::new() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("  FAILED to create Opus decoder: {e}");
            return ExitCode::from(1);
        }
    };
    let mut total_samples = 0usize;
    let mut peak = 0i16;
    let mut sum_abs: u64 = 0;
    for packet in rc_audio::tone_data::TONE_PACKETS {
        let pcm = decoder.decode(packet);
        total_samples += pcm.len();
        for &s in &pcm {
            peak = peak.max(s.abs());
            sum_abs += s.unsigned_abs() as u64;
        }
    }
    if total_samples == 0 {
        eprintln!("  FAILED: decoded 0 samples");
        return ExitCode::from(1);
    }
    let mean_abs = sum_abs as f64 / total_samples as f64;
    println!(
        "  decoded {total_samples} samples (peak {peak}, mean |x| {mean_abs:.0})"
    );
    if peak < 1000 {
        eprintln!("  FAILED: the tone decoded as silence");
        return ExitCode::from(1);
    }

    // Then the full player path (opens the default output device).
    let mut player = rc_audio::AudioPlayer::new();
    player.set_muted(false);
    let mut packets_fed = 0;
    for packet in rc_audio::tone_data::TONE_PACKETS {
        let ap = AudioPacket {
            opus_data: packet.to_vec(),
            sample_rate: 48_000,
            channels: 1,
            timestamp_micros: 0,
            codec: AUDIO_CODEC_OPUS.to_string(),
        };
        player.consume(&ap);
        packets_fed += 1;
    }
    let level = player.level();
    println!(
        "  queued {packets_fed} packets, {} samples buffered, level {:.3}",
        player.queued_samples(),
        level
    );

    if level > 0.01 {
        println!("\nAUDIO SELF-TEST PASSED — Opus decodes and the player is fed.");
        println!("(If you heard nothing on the speakers, the device is muted or absent —");
        println!(" the decode path is still verified.)");
        ExitCode::SUCCESS
    } else {
        eprintln!("\nAUDIO SELF-TEST FAILED (level {level:.3})");
        ExitCode::from(1)
    }
}

fn state_line(state: &State) -> String {
    match state {
        State::Searching => format!("[LOOKING]  {}", i18n::t("正在搜索 iPhone…", "searching for an iPhone…")),
        State::Connecting { name } => format!("[CONNECTING]  {}{name}…", i18n::t("正在连接 ", "connecting to ")),
        State::Handshaking { name } => format!("[CONNECTING]  {}{name}…", i18n::t("正在握手 ", "handshaking with ")),
        State::AwaitingApproval { name } => format!(
            "[CONNECTING]  {}{name}{}",
            i18n::t("请在 ", "waiting for you to approve on "),
            i18n::t(" 上确认…", "…")
        ),
        // NOTE: the label deliberately omits latency — including it made the
        // state line reprint on every 2 s ping (visual spam). Latency is
        // surfaced only for real spikes, by the Latency event handler.
        State::Streaming { name, .. } => format!("[LIVE]  {}{name}", i18n::t("正在投屏 ", "streaming from ")),
        State::Busy { owner } => {
            if i18n::is_chinese() {
                format!(
                    "[IN USE]  iPhone 已被 {owner} 占用。\n\
                     \x20          请在那边断开连接（菜单栏 → RemoteCrab → 断开连接，或 iPhone → 选择电脑），本机将自动连接。"
                )
            } else {
                format!(
                    "[IN USE]  {owner} is already connected to this iPhone.\n\
                     \x20          Disconnect there (menu bar → RemoteCrab → Disconnect, or iPhone → Choose a Mac)\n\
                     \x20          and this PC will connect automatically."
                )
            }
        }
        State::Error(reason) => format!("[OFFLINE]  {reason}"),
    }
}

/// One-line, pill-language status for the tray menu — same wording the Mac's
/// menu-bar popover and the iOS status pill use (`State::pill_label` /
/// `Status.latency`), without the console's [TAG] + wrapped explanation.
pub fn tray_status(state: &State) -> String {
    match state {
        State::Streaming { name, latency_ms } if *latency_ms > 0 => {
            format!("{}{name} · {latency_ms} ms", i18n::t("正在投屏 ", "Streaming from "))
        }
        State::Streaming { name, .. } => {
            format!("{}{name}", i18n::t("正在投屏 ", "Streaming from "))
        }
        State::AwaitingApproval { name } => {
            format!("{}{name}{}", i18n::t("请在 ", "Approve on "), i18n::t(" 上确认", ""))
        }
        State::Connecting { name } | State::Handshaking { name } => {
            format!("{}{name}…", i18n::t("正在连接 ", "Connecting to "))
        }
        State::Busy { owner } => {
            format!("{}{owner}{}", i18n::t("已被 ", "In use by "), i18n::t(" 占用", ""))
        }
        State::Searching => i18n::t("等待 iPhone…", "Waiting for an iPhone…").to_string(),
        State::Error(reason) => reason.clone(),
    }
}

#[cfg(test)]
mod arg_tests {
    use super::*;

    fn args(list: &[&str]) -> Args {
        parse_args_from(&list.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn flags_map_one_to_one() {
        let a = args(&["--vcam", "--no-input", "--no-tray", "--record"]);
        assert!(a.vcam && a.no_input && a.no_tray && a.record);
        assert!(!a.doctor && !a.scan && !a.selftest);
    }

    #[test]
    fn the_preview_window_is_on_unless_opted_out() {
        assert!(args(&[]).preview, "preview is the default");
        assert!(!args(&["--no-preview"]).preview);
    }

    #[test]
    fn connect_takes_the_next_argument() {
        assert_eq!(args(&["--connect", "10.0.0.2:1234"]).connect.as_deref(), Some("10.0.0.2:1234"));
        // A trailing flag with no value must not panic or invent a target.
        assert_eq!(args(&["--connect"]).connect, None);
    }

    #[test]
    fn doctor_operand_is_optional() {
        assert!(args(&["--doctor"]).doctor);
        assert_eq!(args(&["--doctor"]).connect, None, "bare --doctor browses mDNS");

        let with_ip = args(&["--doctor", "192.168.31.5"]);
        assert!(with_ip.doctor);
        assert_eq!(with_ip.connect.as_deref(), Some("192.168.31.5"));
    }

    #[test]
    fn doctor_does_not_swallow_the_next_flag() {
        let a = args(&["--doctor", "--vcam"]);
        assert!(a.doctor && a.vcam);
        assert_eq!(a.connect, None, "--vcam is a flag, not a doctor operand");
    }

    #[test]
    fn unknown_arguments_are_ignored_rather_than_fatal() {
        let a = args(&["--nonsense", "--vcam"]);
        assert!(a.vcam);
    }
}