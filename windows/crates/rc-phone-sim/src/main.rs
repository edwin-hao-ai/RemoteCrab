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
//! | `off` | answers `off` | the phone's Disconnect — must not read as a denial |
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
    Off,
    Busy,
    Silent,
    NoToken,
    Drive,
    Drop,
}

impl Scenario {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "normal" => Self::Normal,
            "pending" => Self::Pending,
            "denied" => Self::Denied,
            "off" => Self::Off,
            "busy" => Self::Busy,
            "silent" => Self::Silent,
            "drive" => Self::Drive,
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
            Self::Off => c.reply = rc_protocol::SessionReplyResult::Off,
            Self::Busy => c.reply = rc_protocol::SessionReplyResult::Busy,
            Self::Silent => {
                c.stream_video = false;
                c.send_metadata = false;
            }
            Self::NoToken => c.token = None,
            // `drive` sends nothing extra on connect; its frames are queued by
            // the main loop once the receiver is up. See `drive()`.
            Self::Drive => {}
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
    /// **Phone-initiated**: dial this receiver's knock address (`host:port`)
    /// instead of listening, sending `phoneHello` as the first frame.
    dial: Option<std::net::SocketAddr>,
    /// The computer id to name in that `phoneHello`. Required with `--dial`.
    target_pc: Option<String>,
    phone_id: String,
    phone_name: String,
    /// Seal the transport (F1): the phone does the peer-auth challenge and seals
    /// every post-grant frame. Requires the receiver to already hold the token
    /// (pair once first), because the key comes from it.
    transport: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut port = 8765u16;
    let mut scenario = Scenario::Normal;
    let mut max_frames = None;
    let mut video = None;
    let mut seconds = None;
    let mut dial = None;
    let mut target_pc = None;
    let mut phone_id = "rc-phone-sim".to_string();
    let mut phone_name = "rc-phone-sim".to_string();
    let mut transport = false;
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--transport" => transport = true,
            "--dial" => {
                let v = it.next().ok_or("--dial needs host:port")?;
                dial = Some(
                    v.parse()
                        .map_err(|_| format!("--dial wants an ip:port, got {v:?}"))?,
                );
            }
            "--target-pc" => {
                target_pc = Some(it.next().ok_or("--target-pc needs an id")?);
            }
            "--phone-id" => phone_id = it.next().ok_or("--phone-id needs a value")?,
            "--phone-name" => phone_name = it.next().ok_or("--phone-name needs a value")?,
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
        dial,
        target_pc,
        phone_id,
        phone_name,
        transport,
    })
}

/// Everything the receiver does *because* the phone asked: a clipboard write, a
/// pointer move, a command it cannot honour, and a file.
///
/// This is the half of the protocol `FakeIphone` could not reach before — it
/// only ever *read* — so input, clipboard, files and commands had never been
/// exercised against the shipped binary. Each is chosen to be checkable from
/// outside the receiver's process:
///
/// - clipboard: read the Windows clipboard back
/// - pointer: read the cursor position back
/// - brightness: the one system command Windows refuses, so what it proves is
///   the `commandResult` it sends, with no side effect on the machine running
///   the test
/// - a file: look in `Downloads\RemoteCrab`
///
/// Deliberately **not** sent: anything that leaves a lasting mark on the tester's
/// machine. Volume and "show desktop" would both work, and would also rearrange
/// someone's desktop on every run.
fn drive(phone: &FakeIphone) {
    println!("rc-phone-sim: driving the receiver (clipboard, pointer, command, file)");

    send(phone, rc_protocol::encode_clipboard(&rc_protocol::Clipboard {
        text: DRIVE_CLIPBOARD.to_string(),
    }));

    send(phone, rc_protocol::encode_touch(&rc_protocol::TouchEvent {
        phase: rc_protocol::TouchPhase::Move,
        x: 0.5,
        y: 0.5,
        dx: 0.0,
        dy: 0.0,
        modifiers: 0,
        momentum: None,
        timestamp_micros: 0,
    }));

    send(phone, rc_protocol::encode_system_command(&rc_protocol::SystemCommand {
        command: rc_protocol::SystemCommandKind::BrightnessUp,
        argument: None,
        request_id: Some(DRIVE_REQUEST_ID.to_string()),
    }));

    send(phone, rc_protocol::encode_file_offer(&rc_protocol::FileOffer {
        id: DRIVE_FILE_ID.to_string(),
        name: DRIVE_FILE_NAME.to_string(),
        size: DRIVE_FILE_BODY.len() as i64,
    }));
    // `encode_file_chunk` is the one encoder that takes raw bytes and returns
    // them framed, so it has no error case.
    // `encode_file_chunk` is the one encoder with no error case.
    let chunk = rc_protocol::encode_file_chunk(DRIVE_FILE_BODY);
    let n = chunk.len();
    println!("  -> {n} bytes{}", if phone.send(chunk) { " to the receiver" } else { " DROPPED (no connection)" });
    send(phone, rc_protocol::encode_file_complete(&rc_protocol::FileComplete {
        id: DRIVE_FILE_ID.to_string(),
    }));
}

/// Send one frame, or say why not. The encoders return `Result` — a payload that
/// cannot be serialised is a bug in this tool, not a reason to panic a test run.
///
/// Generic over the error type so this does not have to name `serde_json`, which
/// this crate does not depend on directly.
fn send<E: std::fmt::Display>(phone: &FakeIphone, frame: Result<Vec<u8>, E>) {
    match frame {
        Ok(bytes) => {
            let n = bytes.len();
            if phone.send(bytes) {
                println!("  -> {n} bytes to the receiver");
            } else {
                // Nothing is subscribed: the receiver is not connected yet, or
                // has gone. Worth saying — a drive that silently reaches nobody
                // looks exactly like a receiver that ignores it.
                println!("  -> {n} bytes DROPPED (no connection)");
            }
        }
        Err(e) => println!("rc-phone-sim: could not encode a drive frame: {e}"),
    }
}

/// What `drive` puts in the Windows clipboard. Checked by the acceptance script,
/// so it must not be something a run could plausibly leave behind by accident.
const DRIVE_CLIPBOARD: &str = "remote-crab drive marker";
/// The `requestId` the receiver must echo in its `commandResult`.
pub const DRIVE_REQUEST_ID: &str = "drive-1";
const DRIVE_FILE_ID: &str = "drive-file";
/// The file `drive` pushes, and its exact contents.
pub const DRIVE_FILE_NAME: &str = "remote-crab-drive.txt";
pub const DRIVE_FILE_BODY: &[u8] = b"written by the fake iPhone\n";

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
        let cfg = with_video(args.scenario.config(), args.video);
        let cfg = if args.transport {
            let mut c = cfg;
            c.transport = true;
            // The challenge secret is the token the receiver already holds (it
            // stores what this phone issued on first pairing).
            if c.peer_auth_token.is_none() {
                c.peer_auth_token = c.token.clone();
            }
            c
        } else {
            cfg
        };
        let phone = match args.dial {
            Some(addr) => {
                let Some(target) = args.target_pc.clone() else {
                    eprintln!("rc-phone-sim: --dial needs --target-pc <computer id>");
                    std::process::exit(2);
                };
                let hello = rc_protocol::PhoneHello {
                    phone_id: args.phone_id.clone(),
                    phone_name: args.phone_name.clone(),
                    target_pc_id: target,
                    app_version: "rc-phone-sim".to_string(),
                    nonce: None,
                    capabilities: Some(vec!["phoneInitiated".to_string()]),
                };
                FakeIphone::dial(cfg, addr, Some(hello)).await
            }
            None => FakeIphone::start_on(cfg, args.port).await,
        };
        let mut phone: FakeIphone = match phone {
            Ok(p) => p,
            Err(e) => {
                eprintln!(
                    "rc-phone-sim: could not {} — {e}",
                    if args.dial.is_some() {
                        "dial the receiver".to_string()
                    } else {
                        format!("listen on 127.0.0.1:{}", args.port)
                    }
                );
                eprintln!(
                    "  (is something already on that port? the receiver itself is 8765 by default)"
                );
                std::process::exit(1);
            }
        };

        match args.dial {
            Some(addr) => {
                println!(
                    "rc-phone-sim: dialed {addr} (phone-initiated)  scenario={:?}",
                    args.scenario
                );
            }
            None => {
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
            }
        }
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
                        "  [{}] clientHello  name={:?} id={} token={} caps={:?}",
                        *seen,
                        h.name,
                        &h.id[..h.id.len().min(8)],
                        if h.token.is_some() { "yes" } else { "NO" },
                        // Printed because the phone gates on this: it does not
                        // send a `requestId` to a receiver that has not declared
                        // `commandResult`, so a receiver that answers commands
                        // but omits the declaration is never asked and its
                        // buttons look dead.
                        h.capabilities.as_deref().unwrap_or(&[])
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

        // `drive` waits for the receiver to actually connect. It cannot wait for
        // an `inbound` frame: the `clientHello` travels on `hellos`, and
        // `inbound` stays empty until the receiver's first ping — seconds away,
        // and nothing guarantees one arrives. The first attempt at this used a
        // wall-clock delay and fired before the connection existed, so every
        // frame was dropped and the receiver looked like it was ignoring them.
        let mut drove = false;
        let mut connected = false;

        loop {
            tokio::select! {
                f = phone.inbound.recv() => {
                    let Some(f) = f else { break };
                    report(&mut seen, &mut pings, &f);
                    if args.max_frames.is_some_and(|m| seen >= m) {
                        break;
                    }
                }
                // Draining `hellos` is what tells us a receiver arrived; before
                // this, nothing in the sim ever looked at the channel, so the
                // tool could not tell "connected" from "not yet".
                h = phone.hellos.recv() => {
                    let Some(h) = h else { break };
                    seen += 1;
                    println!(
                        "  [{seen}] clientHello  name={:?} id={} token={} caps={:?}",
                        h.name,
                        h.id,
                        if h.token.is_some() { "yes" } else { "NO" },
                        h.capabilities.as_deref().unwrap_or(&[])
                    );
                    connected = true;
                }
                // An unconditional tick, so a `--seconds` deadline is honoured
                // even while the receiver is quiet.
                _ = tokio::time::sleep(Duration::from_millis(200)) => {}
            }

            if args.scenario == Scenario::Drive && connected && !drove {
                drove = true;
                drive(&phone);
            }
            if deadline.is_some_and(|d| std::time::Instant::now() >= d) {
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
