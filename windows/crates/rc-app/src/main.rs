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

#[derive(Debug, Default)]
struct Args {
    connect: Option<String>,
    no_input: bool,
    list_only: bool,
    selftest: bool,
    preview_selftest: bool,
    preview: bool,
    no_preview: bool,
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
         \n\
         Run the RemoteCrab iOS app first; both devices must share the same WiFi."
    );
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
    let mut injector: Option<()> = None;

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

    let mut last_label = String::new();
    let mut video_frames: u64 = 0;

    loop {
        tokio::select! {
            changed = state_rx.changed() => {
                if changed.is_err() {
                    break;
                }
                let st = state_rx.borrow().clone();
                let label = state_line(&st);
                if label != last_label {
                    println!("{label}");
                    last_label = label;
                }
                if let State::Error(_) = st {
                    println!("   (if the iPhone is running RemoteCrab, try: remotecrab --connect <iphone-ip>)");
                }
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
                    }
                    Event::Video(nal) => {
                        video_frames += 1;
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
                    Event::Latency(ms) => {
                        if ms > 0 {
                            // Keep the console readable: only report lag spikes.
                            if ms > 120 {
                                println!("  latency: {ms} ms");
                            }
                        }
                    }
                    Event::State(_) => {}
                    _ => {}
                }
            }
            _ = tokio::signal::ctrl_c() => {
                println!("\nShutting down…");
                break;
            }
        }
    }

    // Close the preview window and let its thread finish.
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

fn state_line(state: &State) -> String {
    match state {
        State::Searching => "[LOOKING]  searching for an iPhone…".to_string(),
        State::Connecting { name } => format!("[CONNECTING]  connecting to {name}…"),
        State::Handshaking { name } => format!("[CONNECTING]  handshaking with {name}…"),
        State::AwaitingApproval { name } => {
            format!("[CONNECTING]  waiting for you to approve on {name}…")
        }
        State::Streaming { name, latency_ms } => {
            if *latency_ms > 0 {
                format!("[LIVE]  streaming from {name}  ({latency_ms} ms)")
            } else {
                format!("[LIVE]  streaming from {name}")
            }
        }
        State::Error(reason) => format!("[OFFLINE]  {reason}"),
    }
}
