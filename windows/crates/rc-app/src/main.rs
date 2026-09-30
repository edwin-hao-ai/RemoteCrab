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

use args::parse_args;
use console::{spawn_console_reader, ActiveRecording};

mod args;
mod console;
mod diagnostics;
mod doctor;
mod help;
mod i18n;
mod mirror;
mod scan;
mod selftest;
mod single_instance;
mod status;
mod stream_stats;
mod tray;
mod tray_menu;
#[cfg(windows)]
mod vcam;

/// Owns the toggleable preview window thread (tray → Show/Hide Preview).
struct PreviewWindow {
    slot: rc_render::window::FrameSlot,
    status: std::sync::Arc<std::sync::Mutex<String>>,
    shutdown: std::sync::Arc<std::sync::atomic::AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl PreviewWindow {
    fn new(
        slot: rc_render::window::FrameSlot,
        status: std::sync::Arc<std::sync::Mutex<String>>,
    ) -> Self {
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

    // `--version` first, and it works with no other argument and no window:
    // a user reporting a bug has to be able to say which build they are on
    // without starting a receiver, and before anything can fail.
    if args.version {
        println!("remotecrab {}", env!("CARGO_PKG_VERSION"));
        return ExitCode::SUCCESS;
    }
    if args.selftest {
        return selftest::selftest().await;
    }
    if args.preview_selftest {
        return selftest::preview_selftest().await;
    }
    if args.scan {
        return scan::run_scan(args.subnet.as_deref()).await;
    }
    if args.doctor {
        return doctor::run_doctor(args.connect.as_deref()).await;
    }
    if args.audio_selftest {
        return selftest::audio_selftest();
    }
    if args.vcam_selftest {
        return selftest::vcam_selftest().await;
    }
    // Crash visibility and the "only one of us" guard, before anything else
    // can fail: a panic from here on has to leave a trace, and a second copy
    // of this program competing for the same iPhone is worse than no copy.
    diagnostics::install_panic_hook();
    diagnostics::log_startup(
        env!("CARGO_PKG_VERSION"),
        &std::env::args().collect::<Vec<_>>(),
    );
    let instance = single_instance::acquire();
    if !instance.is_primary() {
        println!(
            "{}",
            i18n::t(
                "RemoteCrab 已经在运行了。",
                "RemoteCrab is already running."
            )
        );
        return ExitCode::SUCCESS;
    }

    println!("RemoteCrab for Windows v{}", env!("CARGO_PKG_VERSION"));
    println!(
        "{}\n",
        i18n::t(
            "正在当前 WiFi 下寻找 iPhone…",
            "Looking for your iPhone on this WiFi…"
        )
    );

    let session = Session::spawn(Config::default());
    let mut events = session.subscribe();
    let mut state_rx = session.state();
    // The live readout behind the tray's "connection details" submenu. See
    // `stream_stats` for why it is a submenu and not a window.
    let mut stats = stream_stats::StreamStats::default();
    // Commands the phone asked for that this platform cannot do, surfaced in
    // the readout rather than only in the console. A capability gap the user
    // cannot see is one they will report as a broken button.

    // Set while the iPhone is showing a list it asked for. Automatic
    // republishes of the *window* list are gated on it, because that frame
    // carries a JPEG per window and is far too expensive to send unasked —
    // the Mac gates the same way (`publishMacWindowsIfRecentlyRequested`).
    let window_list_wanted = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let health = session.health();

    if let Some(target) = &args.connect {
        match rc_discovery::parse_host_port(target, rc_net::DEFAULT_PORT) {
            Some((host, port)) => {
                println!("{} {host}:{port} …", i18n::t("正在连接", "Connecting to"));
                session.connect_manual(&host, port);
            }
            None => {
                eprintln!(
                    "{}: {target}",
                    i18n::t("--connect 参数无效", "Invalid --connect value")
                );
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
            eprintln!(
                "{}",
                i18n::t(
                    "--vcam 只在 Windows 上可用。",
                    "--vcam is only available on Windows.",
                )
            );
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
        println!(
            "  {}",
            i18n::t(
                "（默认静音以避免回声——加 --unmute 才能听见）",
                "(muted by default to avoid feedback — pass --unmute to hear it)",
            )
        );
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
    println!(
        "{}",
        i18n::t(
            "输入 help 查看可用的实时控制命令。",
            "Type `help` for live iPhone feature commands."
        )
    );

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

                let label = status::state_line(&st);
                if label != last_label {
                    println!("{label}");
                    last_label = label;
                }
                if let State::Error(_) = st {
                    // Point at the surface that explains itself, not at a
                    // developer-only flag (AGENTS.md rule 1).
                    println!(
                        "   {}",
                        crate::i18n::t(
                            "（点托盘菜单里的「为什么连不上」—— 它会写明原因和该做什么）",
                            "(choose \"Why not connected\" in the tray menu — it names the cause and what to do)"
                        )
                    );
                }
                // Keep the tray's status row in sync (single-line pill-style).
                tray.set_status(&status::tray_status(&st));

                // …and give the "why not connected" row something true to say.
                //
                // The route verdict is the one probe worth running here: a
                // single UDP connect, microseconds, and it is the difference
                // between "not found yet" and "your VPN is eating the LAN",
                // which look identical from the outside. Nothing else is
                // probed — the receiver already knows everything else.
                {
                    let h = health.borrow().clone();
                    let verdict = doctor::route_verdict(&h);
                    let zh = crate::i18n::is_chinese();
                    tray.set_diagnosis(
                        &doctor::panel_summary(&h, &verdict, zh),
                        &doctor::panel(&h, &verdict, zh),
                    );
                }
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
                        stats.record_metadata(&m);
                        println!(
                            "  → streaming: {} {}x{} @ {}fps ({} kbps)",
                            m.resolution_label(),
                            m.width,
                            m.height,
                            m.fps,
                            m.bitrate_bps / 1000
                        );
                        // `--record` no longer *arms* recording on the first
                        // metadata frame. It used to, so a user who passed the
                        // flag to "make recording available" got a recorder
                        // they never asked for, writing a file to disk. The
                        // flag now only announces readiness, exactly as the
                        // Mac's ⌘R is an explicit action, and the tray row or
                        // the `record` console command is what actually
                        // starts it.
                        metadata = Some(m);
                    }
                    Event::Video(nal) => {
                        video_frames += 1;
                        // A decoded frame is the only proof the camera is
                        // actually on, as opposed to merely enabled.
                        stats.record_video(0, 0);
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
                        // Recorded before injection so the readout shows where
                        // the phone *asked* the cursor to go, which is the only
                        // way to tell a dropped modifier from a stuck one.
                        stats.record_touch(&t);
                        #[cfg(windows)]
                        if let Some(inj) = injector.as_mut() {
                            inj.inject_touch(&t);
                        }
                        #[cfg(not(windows))]
                        let _ = &t;
                    }
                    Event::Key(k) => {
                        stats.record_key(&k);
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
                            let pcm = console::decode_for_record(&mut rec.opus, &packet);
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
                        // `AudioPlayer` already measures the decoded level
                        // (it has the samples; we only ever see the Opus
                        // packet), and its own doc comment says it exists "for
                        // the connection-test UI" — which nothing was reading
                        // until now.
                        stats.record_audio(audio.level());
                        tray.set_details(stream_stats::detail_rows(&stats));
                    }
                    Event::Latency(ms) => {
                        stats.record_latency(ms);
                        // Refresh the readout's contents; the tray re-renders
                        // the submenu on each popup, so this is the only write.
                        tray.set_details(stream_stats::detail_rows(&stats));
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
                        // A command we cannot do has to say so in words the
                        // user reads, and say what *is* possible.
                        //
                        // The `{:?}` of the protocol enum used to be printed
                        // here: English, an implementation detail, and — for a
                        // Chinese user hitting a brightness button — not an
                        // explanation of anything.
                        #[cfg(windows)]
                        let handled = rc_os::system_keys::handle(&cmd);
                        #[cfg(not(windows))]
                        let handled = false;
                        if !handled {
                            let name = stream_stats::system_command_name(cmd.command);
                            println!(
                                "  {}",
                                i18n::t(
                                    "这个命令这台电脑做不到：{}。音量、媒体播放键、以及「显示桌面」都可以用。",
                                    "This computer cannot do: {}. Volume, the media keys and Show desktop all work.",
                                )
                                .replace("{}", &name)
                            );
                            stats.unsupported_commands.push(name);
                            tray.set_details(stream_stats::detail_rows(&stats));
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
                        window_list_wanted.store(true, std::sync::atomic::Ordering::Relaxed);
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
                                // Republish without icons: the phone reuses its
                                // cached ones. The Mac does the same from its
                                // activation observer, and without it the
                                // switcher's "active" marker sticks on the app
                                // the user just left.
                                let list = rc_os::apps::build_app_list(false);
                                session.send_frame(encode_app_list(&list).unwrap_or_default());
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
                                // A quitting app must leave the phone's
                                // window picker, or it stays tappable until the
                                // user reopens the sheet. The Mac republishes
                                // from its termination observer for the same
                                // reason (`WindowCapture` lesson 38).
                                let list = rc_os::apps::build_app_list(false);
                                session.send_frame(encode_app_list(&list).unwrap_or_default());
                                if window_list_wanted.load(std::sync::atomic::Ordering::Relaxed) {
                                    let windows = rc_os::windows::build_window_list();
                                    session
                                        .send_frame(encode_window_list(&windows).unwrap_or_default());
                                }
                            } else {
                                println!("  app quit failed: {}", q.id);
                            }
                        }
                        #[cfg(not(windows))]
                        let _ = &q;
                    }
                    Event::FeatureState(s) => {
                        // "Camera: off" next to a live picture is exactly the
                        // kind of lie this product must not tell, so the note
                        // comes from the phone's own state and `record_video`
                        // clears it the moment a frame proves otherwise.
                        if !s.camera_on {
                            stats.set_camera_note(Some(i18n::t("已关闭", "off")));
                        }
                        tray.set_features(Some(s.clone()));
                        tray.set_details(stream_stats::detail_rows(&stats));
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
                        console::handle_console_command(
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
                            console::stop_recording(rec);
                        } else if let Some(m) = metadata.as_ref() {
                            recording = console::start_recording(m.width, m.height, m.fps);
                        }
                        tray.set_recording(recording.is_some());
                    }
                    Some(tray::TrayCommand::SwitchCamera) => {
                        session.switch_camera();
                        println!("  → {}", crate::i18n::t("正在切换摄像头", "switching camera"));
                    }
                    Some(tray::TrayCommand::SendClipboard) => console::send_clipboard_to_iphone(&session),
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
        console::stop_recording(rec);
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
