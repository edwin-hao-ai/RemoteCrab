//! A fake iPhone you can point the **real, shipped** receiver at.
//!
//! ## Why this exists
//!
//! Testing the Windows receiver against a real iPhone has a hard requirement
//! that no amount of engineering removes: **the phone has to be switched on,
//! unlocked, streaming, and on the same network.** That makes the test suite
//! depend on a person holding a device, which means it runs when someone
//! remembers, not when CI runs. It is why a regression can sit unnoticed for
//! weeks.
//!
//! `rc-net/tests/session.rs` already had a fake iPhone — but it lives *inside*
//! the test process and binds a random port, so it can only exercise
//! `Session` directly. It cannot check the thing that actually breaks: the
//! binary, its argument parsing, its tray, its reconnect loop.
//!
//! This is that fake phone as a **process**:
//!
//! ```sh
//! # terminal 1 — a phone on 8765
//! cargo run -p rc-phone-sim -- --port 8765
//!
//! # terminal 2 — the receiver you actually ship
//! remotecrab.exe --connect 127.0.0.1:8765
//! ```
//!
//! ## What it does and does not prove
//!
//! **Proves:** the handshake, the token exchange, metadata, video decode, the
//! ping/RTT path, feature toggles, the reconnect loop, and every code path in
//! the binary that only runs once bytes are flowing.
//!
//! **Does not prove:** anything about a real iOS encoder, a real camera, real
//! notifications, real WiFi discovery, or the real app's UI. Those still need
//! the phone. The point is not to replace the device — it is that the checks
//! which *do not need* a device stop needing one, so the device is only
//! needed for the things that genuinely require it.
//!
//! ## Scenarios
//!
//! `--scenario` picks how the phone behaves, so a failure mode can be
//! reproduced deliberately rather than waited for:
//!
//! | scenario | what it does | reproduces |
//! |---|---|---|
//! | `normal` | accepts, sends metadata, echoes pings, streams video | the happy path |
//! | `pending` | answers `pending` once, then `accepted` | the approval prompt |
//! | `denied` | answers `denied` | "this computer is not allowed" |
//! | `busy` | answers `busy` with an owner name | another Mac owns the session |
//! | `silent` | accepts and then sends nothing | a stream that stops without erroring |
//! | `no-token` | accepts but issues no token | the iPhone asking again next time |
//! | `drop` | accepts, then drops the connection | reconnect behaviour |

use std::time::Duration;

use rc_testkit::{FakeIphone, FakeIphoneConfig, Frame2};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Scenario {
    Normal,
    Pending,
    Denied,
    Busy,
    Silent,
    NoToken,
    Drop,
}

impl Scenario {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "normal" => Self::Normal,
            "pending" => Self::Pending,
            "denied" => Self::Denied,
            "busy" => Self::Busy,
            "silent" => Self::Silent,
            "no-token" => Self::NoToken,
            "drop" => Self::Drop,
            _ => return None,
        })
    }

    fn config(self) -> FakeIphoneConfig {
        let mut c = FakeIphoneConfig {
            // Video on by default: the decode path is the one most likely to
            // break silently, and a phone that sends nothing proves very little.
            stream_video: true,
            video_frames: 0, // 0 = keep going, see `video: true` below
            ..Default::default()
        };
        match self {
            Self::Normal => {}
            Self::Pending => {
                c.reply = rc_protocol::SessionReplyResult::Pending;
                // The testkit answers `pending` and then accepts on the second
                // hello, which is exactly the real flow.
            }
            Self::Denied => c.reply = rc_protocol::SessionReplyResult::Denied,
            Self::Busy => c.reply = rc_protocol::SessionReplyResult::Busy,
            Self::Silent => {
                c.stream_video = false;
                c.send_metadata = false;
            }
            Self::NoToken => c.token = None,
            Self::Drop => {}
        }
        c
    }
}

struct Args {
    port: u16,
    scenario: Scenario,
    /// Stop after this many frames the receiver sent, so a run ends on its own
    /// instead of hanging until someone interrupts it.
    max_frames: Option<usize>,
    seconds: Option<u64>,
}

fn parse_args() -> Result<Args, String> {
    let mut port = 8765u16;
    let mut scenario = Scenario::Normal;
    let mut max_frames = None;
    let mut seconds = None;
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--port" => {
                port = it
                    .next()
                    .ok_or("--port needs a number")?
                    .parse()
                    .map_err(|_| "bad port")?
            }
            "--scenario" => {
                let s = it.next().ok_or("--scenario needs a name")?;
                scenario = Scenario::parse(&s).ok_or_else(|| {
                    format!(
                        "unknown scenario {s:?} (normal/pending/denied/busy/silent/no-token/drop)"
                    )
                })?;
            }
            "--frames" => {
                max_frames = Some(
                    it.next()
                        .ok_or("--frames needs a number")?
                        .parse()
                        .map_err(|_| "bad frame count")?,
                )
            }
            "--seconds" => {
                seconds = Some(
                    it.next()
                        .ok_or("--seconds needs a number")?
                        .parse()
                        .map_err(|_| "bad duration")?,
                )
            }
            "--help" | "-h" => {
                println!(
                    "rc-phone-sim — a fake iPhone for testing the receiver\n\n\
                     USAGE:\n    rc-phone-sim [--port N] [--scenario NAME] [--frames N] [--seconds N]\n\n\
                     SCENARIOS:\n\
                       normal     accepts, streams video, echoes pings   (default)\n\
                       pending    answers pending once, then accepted\n\
                       denied     answers denied\n\
                       busy       answers busy, naming another owner\n\
                       silent     accepts, then sends nothing at all\n\
                       no-token   accepts but issues no pairing token\n\
                       drop       accepts, then drops the connection\n\n\
                     THEN, in another shell:\n    remotecrab.exe --connect 127.0.0.1:{port}\n"
                );
                std::process::exit(0);
            }
            other => return Err(format!("unexpected argument {other:?}")),
        }
    }
    Ok(Args {
        port,
        scenario,
        max_frames,
        seconds,
    })
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("rc-phone-sim: {e}\n(try --help)");
            std::process::exit(2);
        }
    };

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("rc-phone-sim: could not start a runtime: {e}");
            std::process::exit(1);
        }
    };

    runtime.block_on(async move {
        let phone = FakeIphone::start_on(args.scenario.config(), args.port).await;
        let mut phone: FakeIphone = match phone {
            Ok(p) => p,
            Err(e) => {
                eprintln!(
                    "rc-phone-sim: could not listen on 127.0.0.1:{} — {e}",
                    args.port
                );
                eprintln!(
                    "  (is something already on that port? the receiver itself is 8765 by default)"
                );
                std::process::exit(1);
            }
        };

        println!(
            "rc-phone-sim: listening on 127.0.0.1:{}  scenario={:?}",
            phone.addr.port(),
            args.scenario
        );
        println!("rc-phone-sim: point the receiver at it with");
        println!(
            "               remotecrab.exe --connect 127.0.0.1:{}",
            phone.addr.port()
        );
        println!("rc-phone-sim: Ctrl-C to stop");

        let deadline = args
            .seconds
            .map(Duration::from_secs)
            .map(|d| std::time::Instant::now() + d);
        let mut seen = 0usize;
        let mut pings = 0usize;
        let report = |seen: &mut usize, pings: &mut usize, f: &Frame2| {
            *seen += 1;
            match f {
                Frame2::ClientHello(h) => {
                    *pings = 0;
                    println!(
                        "  [{}] clientHello  name={:?} id={} token={}",
                        *seen,
                        h.name,
                        &h.id[..h.id.len().min(8)],
                        if h.token.is_some() { "yes" } else { "NO" }
                    );
                }
                Frame2::Ping(_) => {
                    *pings += 1;
                    if *pings == 1 || (*pings).is_multiple_of(10) {
                        println!("  [{}] ping #{pings}", *seen);
                    }
                }
                Frame2::FeatureControl(fc) => {
                    println!("  [{}] featureControl {fc:?}", *seen);
                }
                Frame2::Touch(t) => {
                    println!("  [{}] touch {:?} at ({}, {})", *seen, t.phase, t.x, t.y);
                }
                Frame2::Key(k) => {
                    println!("  [{}] key {k:?}", *seen);
                }
                Frame2::Notification(n) => {
                    println!("  [{}] notification from the receiver: {}", *seen, n.app);
                }
                Frame2::CommandResult(r) => {
                    println!(
                        "  [{}] commandResult {:?} {}",
                        *seen, r.request_id, r.status
                    );
                }
                Frame2::Other(k) => {
                    println!("  [{}] frame 0x{k:02X}", *seen);
                }
            }
        };

        loop {
            let frame = tokio::select! {
                f = phone.inbound.recv() => f,
                _ = tokio::time::sleep(Duration::from_millis(250)), if deadline.is_some() => {
                    // Tick, so the deadline below can be checked.
                    if let Some(d) = deadline {
                        if std::time::Instant::now() >= d { break; }
                    }
                    continue;
                }
            };
            let Some(frame) = frame else { break };
            report(&mut seen, &mut pings, &frame);
            if args.max_frames.is_some_and(|m| seen >= m) {
                break;
            }
        }

        println!("rc-phone-sim: {seen} frame(s) from the receiver, {pings} ping(s)");
    });
}
