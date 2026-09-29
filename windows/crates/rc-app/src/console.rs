//! The interactive console surface: the stdin reader, the command
//! dispatcher, and the recording/clipboard work those commands drive.

use rc_net::Session;

use crate::help::print_console_help;
use crate::i18n;

/// Read stdin on a background thread and forward each non-empty line over a
/// channel, so the main `tokio::select!` can accept console commands without
/// blocking. The thread exits on EOF (e.g. when stdin is a pipe).
pub fn spawn_console_reader() -> tokio::sync::mpsc::UnboundedReceiver<String> {
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
/// An in-progress recording. The muxer is pure; the Opus decoder is private
/// to recording (the playback player keeps its own decoder state).
pub struct ActiveRecording {
    pub(crate) recorder: rc_record::Recorder,
    pub(crate) opus: Option<rc_audio::OpusDecoder>,
}
/// Filename stem: `recording-<unix seconds>` (the Mac uses a date stamp).
pub fn recording_stem() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("recording-{secs}")
}
pub fn start_recording(width: i64, height: i64, fps: i64) -> Option<ActiveRecording> {
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
pub fn stop_recording(rec: ActiveRecording) {
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
pub fn decode_for_record(
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
pub fn send_clipboard_to_iphone(session: &Session) {
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
pub fn handle_console_command(
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

