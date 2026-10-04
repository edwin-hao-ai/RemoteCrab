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
//! **Proves:** the handshake, the token exchange, metadata, the ping/RTT path,
//! feature toggles, the reconnect loop, and every code path in the binary that
//! only runs once bytes are flowing.
//!
//! **Does not prove: video decoding.** Not because the encoder is fake — it is
//! not. `rc_testkit::encode_test_video` drives OpenH264's real encoder, so it
//! emits decodable H.264, and `--preview-selftest` decodes it. This tool simply
//! never asks for any: its config sets `stream_video: true` but
//! `video_frames: 0`, and `FakeIphone` streams nothing at all when the count is
//! zero. So the `streaming: 1080p` line you see comes from the metadata frame
//! alone, with zero video NALs behind it.
//!
//! The previous version of this note blamed `encode_test_video` for emitting
//! "synthetic bytes", which is false and was worth fixing for a second reason:
//! a reader who believed it would conclude the *shared* testkit encoder was
//! fake too, and would keep looking for a video path that already existed.
//!
//! This line used to claim the opposite ("video decode"), which is worse than a
//! gap — a green run looked like the decode path was covered. For video use
//! `--preview-selftest`, which runs the real encode → decode → window path, or
//! a real phone.
//!
//! **Also does not prove:** anything about a real iOS encoder, a real camera,
//! real notifications, real WiFi discovery, or the real app's UI. Those still
//! need the phone. The point is not to replace the device — it is that the
//! checks which *do not need* a device stop needing one, so the device is only
//! needed for the things that genuinely require it.
//!
//! ## Scenarios
//!
//! `--scenario` picks how the phone behaves, so a failure mode can be
//! reproduced deliberately rather than waited for:
//!
//! | scenario | what it does | reproduces |
//! |---|---|---|
//! | `normal` | accepts, sends metadata, echoes pings | the happy path |
//! | `pending` | answers `pending` once, then `accepted` | the approval prompt |
//! | `denied` | answers `denied` | "this computer is not allowed" |
//! | `busy` | answers `busy` with an owner name | another Mac owns the session |
//! | `silent` | accepts and then sends nothing | a stream that stops without erroring |
//! | `no-token` | accepts but issues no token | the iPhone asking again next time |
//! | `drop` | accepts, then hangs up mid-stream | an unexpected disconnect |

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
            stream_video: true,
            // 0 = do not stream, and it stays 0 for every scenario except `drop`.
            //
            // Tempting to set this so `normal` matches its help text, and wrong:
            // `encode_test_video` emits *synthetic* bytes, not real H.264, so a
            // decoder refuses every one. Turning it on made `normal` send garbage
            // and made the receiver report a lost connection -- strictly worse
            // than sending nothing. `check-windows-deps.sh` and
            // `--vcam-selftest` cover the real decode path; this tool cannot.
            video_frames: 0,
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
            // Was `Drop => {}` — an empty arm, so this scenario was the happy
            // path with a different name. Every "does the receiver come back?"
            // run had been green without a disconnect ever happening.
            Self::Drop => {
                // The one scenario that needs `video_frames > 0`, because
                // `drop_after_frames` is read inside the video branch. Sending
                // undecodable bytes is fine here: the point is that the socket
                // closes, and the receiver noticing is the thing under test.
                c.video_frames = 60;
                c.drop_after_frames = Some(5);
            }
        }
        c
    }
}

/// Opt the fake phone into streaming **real** H.264 (`rc_testkit::encode_test_video`
/// uses OpenH264's encoder), which is what makes the receiver's decode path
/// verifiable without a phone.
///
/// Both fields or neither: the stream branch is
/// `cfg.stream_video && cfg.video_frames > 0`, so setting one alone produces no
/// video and no error.
fn with_video(mut c: rc_testkit::FakeIphoneConfig, video: Option<usize>) -> rc_testkit::FakeIphoneConfig {
    match video {
        Some(n) if n > 0 => {
            c.stream_video = true;
            c.video_frames = n;
        }
        _ => {}
    }
    c
}

struct Args {
    port: u16,
    scenario: Scenario,
    /// NALs of real H.264 to stream. `None` = none, which is the default
    /// because most of what this fake phone tests is the handshake and the
    /// reconnect loop, not the codec.
    video: Option<usize>,
    /// Stop after this many frames the receiver sent, so a run ends on its own
    /// instead of hanging until someone interrupts it.
    max_frames: Option<usize>,
    seconds: Option<u64>,
}

fn parse_args() -> Result<Args, String> {
    let mut port = 8765u16;
    let mut scenario = Scenario::Normal;
    let mut max_frames = None;
    let mut video = None;
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
            "--video" => {
                video = Some(
                    it.next()
                        .ok_or("--video needs a number")?
                        .parse()
                        .map_err(|_| "--video needs a number".to_string())?,
                );
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
                     USAGE:\n    rc-phone-sim [--port N] [--scenario NAME] [--video N] [--frames N] [--seconds N]\n\n\
                     SCENARIOS:\n\
                       normal     accepts, sends metadata, echoes pings (default)\n\
                       pending    answers pending once, then accepted\n\
                       denied     answers denied\n\
                       busy       answers busy, naming another owner\n\
                       silent     accepts, then sends nothing at all\n\
                       no-token   accepts but issues no pairing token\n\
                       drop       accepts, then hangs up mid-stream\n\n\
                     NOTE: no scenario streams video by default -- not because the\n    testkit emits synthetic bytes (it emits REAL H.264 via OpenH264), but\n    because the default config leaves the stream branch off. Pass\n    `--video N` to switch it on, or use `remotecrab.exe --vcam-selftest`.\n\n    THEN, in another shell:\n    remotecrab.exe --connect 127.0.0.1:{port}\n"
                );
                std::process::exit(0);
            }
            other => return Err(format!("unexpected argument {other:?}")),
        }
    }
    Ok(Args {
        port,
        scenario,
        video,
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
        let phone = FakeIphone::start_on(with_video(args.scenario.config(), args.video), args.port).await;
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The fake phone could not stream video at all: `Normal` sets
    /// `stream_video: false, video_frames: 0`, and only `Drop` turned video on
    /// (for 60 frames, dropping at 5). So the receiver's decode path could not
    /// be exercised without a real phone — which is why `--decode-only` had no
    /// way to be verified on the machine that runs the harness.
    ///
    /// `--video N` is the opt-in. It must set **both** fields: `video_frames`
    /// alone is inert because the stream branch is guarded by
    /// `cfg.stream_video && cfg.video_frames > 0`, and a half-set pair fails
    /// silently — no video, no error, and a receiver that looks healthy.
    #[test]
    fn video_flag_turns_on_both_halves_of_the_pair() {
        let c = with_video(FakeIphoneConfig::default(), Some(300));
        assert!(c.stream_video, "the guard is `stream_video && video_frames > 0`");
        assert_eq!(c.video_frames, 300);
    }

    #[test]
    fn no_video_flag_streams_nothing() {
        let c = with_video(FakeIphoneConfig::default(), None);
        assert!(!c.stream_video);
        assert_eq!(c.video_frames, 0);
    }

    /// `--video 0` is not "stream forever", it is the same as not asking:
    /// `encode_test_video` is called up front and materialises every NAL in
    /// memory, so an unbounded count is not free.
    #[test]
    fn zero_frames_is_the_same_as_not_asking() {
        let c = with_video(FakeIphoneConfig::default(), Some(0));
        assert!(!c.stream_video);
        assert_eq!(c.video_frames, 0);
    }

    /// A scenario that already streams keeps its own count when `--video` is
    /// absent — `Drop` depends on `drop_after_frames: Some(5)` matching inside
    /// the video branch, so silently zeroing it would change what `Drop` tests.
    #[test]
    fn an_explicit_flag_overrides_a_scenario_that_already_streams() {
        let drop = Scenario::Drop.config();
        assert!(drop.stream_video, "precondition: Drop streams video");
        let drop_after = drop.drop_after_frames;
        let c = with_video(drop, Some(600));
        assert_eq!(c.video_frames, 600);
        assert_eq!(c.drop_after_frames, drop_after, "and leaves the rest alone");
    }
}
