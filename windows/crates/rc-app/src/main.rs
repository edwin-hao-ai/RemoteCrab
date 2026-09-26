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
mod mirror;
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
    preview: bool,
    no_preview: bool,
    scan: bool,
    unmute: bool,
    record: bool,
    no_tray: bool,
}

fn parse_args() -> Args {
    let mut args = Args::default();
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--connect" => args.connect = it.next(),
            "--no-input" => args.no_input = true,
            "--list" => args.list_only = true,
            "--selftest" => args.selftest = true,
            "--preview-selftest" => args.preview_selftest = true,
            "--preview" => args.preview = true,
            "--no-preview" => args.no_preview = true,
            "--scan" => args.scan = true,
            "--unmute" => args.unmute = true,
            "--audio-selftest" => args.audio_selftest = true,
            "--record" => args.record = true,
            "--no-tray" => args.no_tray = true,
            "--help" | "-h" => {
                print_help();
                std::process::exit(0);
            }
            _ => {}
        }
    }
    // The preview window opens by default; `--no-preview` is the opt-out.
    if !args.no_preview {
        args.preview = true;
    }
    args
}

fn print_help() {
    println!(
        "RemoteCrab for Windows\n\
         \n\
         Usage:\n\
         \x20 remotecrab                   Discover, connect, and open a preview window\n\
         \x20 remotecrab --connect IP[:P]   Connect directly (when mDNS is blocked)\n\
         \x20 remotecrab --no-input          Watch only (do not drive this PC)\n\
         \x20 remotecrab --no-preview        Console status only (no video window)\n\
         \x20 remotecrab --list              List discovered iPhones and wait\n\
         \x20 remotecrab --selftest          Run a fake iPhone locally and verify the pipeline\n\
         \x20 remotecrab --preview-selftest  Stream fake H.264 into the preview window and verify decode\n\
         \x20 remotecrab --scan              Scan this PC's /24 for an iPhone on port 8765\n\
         \x20 remotecrab --audio-selftest    Generate a tone, encode to Opus, decode, and play it\n\
         \x20 remotecrab --unmute            Play the iPhone mic on this PC's speakers\n\
         \x20 remotecrab --record            Record the live stream (see `record` below)\n\
         \x20 remotecrab --no-tray            Skip the notification-area tray icon\n\
         \n\
         While running, type these console commands (then Enter):\n\
         \x20 camera [on|off]  mic [on|off]  voice [on|off]  trackpad [on|off]\n\
         \x20 keyboard [on|off]  switch-camera  clipboard  record  help  quit\n\
         \n\
         Run the RemoteCrab iOS app first; both devices must share the same WiFi."
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
        "  commands: camera [on|off] · mic [on|off] · voice [on|off] · \
         trackpad [on|off] · keyboard [on|off] · switch-camera · clipboard · record · help · quit"
    );
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
            println!("  recording failed to start: {e}");
            return None;
        }
    };
    println!("  ● recording → {}", rec.mp4_path().display());
    Some(ActiveRecording {
        recorder: rec,
        opus: rc_audio::OpusDecoder::new().ok(),
    })
}

fn stop_recording(rec: ActiveRecording) {
    let mp4 = rec.recorder.mp4_path().to_path_buf();
    let (video_ok, _audio_ok) = rec.recorder.finish();
    if video_ok {
        println!("  ■ recording saved: {}", mp4.display());
        #[cfg(windows)]
        rc_os::files::reveal(&mp4);
    } else {
        println!("  recording stopped with no video frames: {}", mp4.display());
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
                        "  → sent clipboard to iPhone ({} chars)",
                        text.chars().count()
                    );
                }
                Err(_) => println!("  clipboard send failed"),
            }
        }
        _ => println!("  clipboard is empty or not text"),
    }
    #[cfg(not(windows))]
    {
        let _ = session;
        println!("  clipboard send is Windows-only");
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
            println!("  unknown state '{other}' (use on/off)");
            return;
        }
    };
    let feature = |which: rc_protocol::Feature, cur: bool, name: &str| {
        let on = want.unwrap_or(!cur);
        session.set_feature(which, on);
        println!("  → {name} {}", if on { "on" } else { "off" });
    };
    let get = |pick: fn(&rc_protocol::FeatureStateSnapshot) -> bool| -> bool {
        last_features.as_ref().map(pick).unwrap_or(false)
    };
    match cmd {
        "camera" => feature(rc_protocol::Feature::Camera, get(|f| f.camera_on), "camera"),
        "mic" | "microphone" => feature(rc_protocol::Feature::Microphone, get(|f| f.mic_on), "mic"),
        "voice" => feature(rc_protocol::Feature::Voice, get(|f| f.voice_on), "voice"),
        "trackpad" => feature(rc_protocol::Feature::Trackpad, get(|f| f.trackpad_on), "trackpad"),
        "keyboard" => feature(rc_protocol::Feature::Keyboard, get(|f| f.keyboard_on), "keyboard"),
        "switch-camera" | "flip-camera" => {
            session.switch_camera();
            println!("  → switching camera");
        }
        "clipboard" | "send-clipboard" => send_clipboard_to_iphone(session),
        "record" => {
            if let Some(rec) = recording.take() {
                stop_recording(rec);
            } else {
                match metadata {
                    Some(m) => *recording = start_recording(m.width, m.height, m.fps),
                    None => println!("  not connected yet — nothing to record"),
                }
            }
        }
        "help" | "?" => print_console_help(),
        "quit" | "exit" => *quit_requested = true,
        other => println!("  unknown command '{other}' — type `help`"),
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
    if args.audio_selftest {
        return audio_selftest();
    }
    println!("RemoteCrab for Windows v{}", env!("CARGO_PKG_VERSION"));
    println!("Looking for your iPhone on this WiFi…\n");

    let session = Session::spawn(Config::default());
    let mut events = session.subscribe();
    let mut state_rx = session.state();

    if let Some(target) = &args.connect {
        match rc_discovery::parse_host_port(target, rc_net::DEFAULT_PORT) {
            Some((host, port)) => {
                println!("Connecting to {host}:{port} …");
                session.connect_manual(&host, port);
            }
            None => {
                eprintln!("Invalid --connect value: {target}");
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

    // Video preview: decode in this task, blit from the window thread.
    let mut preview: Option<rc_render::PreviewPipeline> = if args.preview {
        match rc_render::PreviewPipeline::new() {
            Ok(p) => Some(p),
            Err(e) => {
                eprintln!("video decoder unavailable ({e}); continuing without preview");
                None
            }
        }
    } else {
        None
    };
    let frame_slot = rc_render::window::FrameSlot::new();
    let shutdown = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let status_text = std::sync::Arc::new(std::sync::Mutex::new("Waiting for video…".to_string()));
    let window_handle = if args.preview {
        let slot = frame_slot.clone();
        let shutdown = shutdown.clone();
        let status = status_text.clone();
        Some(std::thread::spawn(move || {
            rc_render::window::run_preview_window("RemoteCrab Preview", slot, shutdown, status);
        }))
    } else {
        None
    };

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
    // Notification-area tray (menu mirrors the Mac's menu-bar popover).
    #[cfg(windows)]
    let (tray, mut tray_rx) = if args.no_tray {
        tray::disabled()
    } else {
        tray::start("RemoteCrab")
    };
    #[cfg(not(windows))]
    let (tray, mut tray_rx) = tray::start("RemoteCrab");
    let mut tray_alive = true;
    println!("Type `help` for live iPhone feature commands.");

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
                                println!("  no iPhones found yet…");
                            } else {
                                for p in &phones {
                                    let addr = p.host.as_deref().unwrap_or("(resolving)");
                                    println!("  found: {}  @ {}:{}", p.name, addr, p.port);
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
                            rc_os::files::reveal(&path);
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
                    Some(tray::TrayCommand::Reconnect) => session.retry_now(),
                    Some(tray::TrayCommand::Disconnect) => session.disconnect(),
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
    shutdown.store(true, std::sync::atomic::Ordering::Relaxed);
    if let Some(handle) = window_handle {
        let _ = handle.join();
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

/// `--scan`: sweep the local `/24` for anything on port 8765. This is the
/// diagnostic for "mDNS found nothing" — it tells you whether the network
/// allows your devices to see each other at all.
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
