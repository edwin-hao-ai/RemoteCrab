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
            "--help" | "-h" => {
                print_help();
                std::process::exit(0);
            }
            _ => {}
        }
    }
    args
}

fn print_help() {
    println!(
        "RemoteCrab for Windows\n\
         \n\
         Usage:\n\
         \x20 remotecrab                   Discover and connect to your iPhone\n\
         \x20 remotecrab --connect IP[:P]   Connect directly (when mDNS is blocked)\n\
         \x20 remotecrab --no-input          Watch only (do not drive this PC)\n\
         \x20 remotecrab --list              List discovered iPhones and wait\n\
         \x20 remotecrab --selftest          Run a fake iPhone locally and verify the pipeline\n\
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
                    Event::Video(_) => {
                        video_frames += 1;
                        if video_frames.is_multiple_of(150) {
                            println!("  video: {video_frames} frames decoded");
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

    let _ = tokio::time::timeout(Duration::from_millis(300), async {}).await;
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
