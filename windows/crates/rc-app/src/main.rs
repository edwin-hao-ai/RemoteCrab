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

#[cfg(windows)]
use rc_net::settings::NameList;
use rc_net::{Config, Event, Session, State};
#[cfg(windows)]
use rc_protocol::SystemCommandKind;
use rc_protocol::TouchPhase;
use rc_protocol::{
    encode_app_list, encode_file_ack, encode_installed_apps, encode_notification,
    encode_window_list,
};

use args::parse_args;
use console::{spawn_console_reader, ActiveRecording};

mod args;
mod console;
mod diagnostics;
mod notify_relay;
#[cfg(windows)]
mod selfcheck_win;
#[cfg(windows)]
mod settings_win;
mod wizard;
#[cfg(windows)]
mod wizard_win;

mod doctor;
mod elevate;
mod help;
mod i18n;
mod mirror;
mod scan;
mod selftest;
mod single_instance;
mod speaker;
mod status;
mod stream_stats;
mod tray;
mod tray_menu;
mod updater;
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
            rc_render::window::run_preview_window(
                i18n::t("RemoteCrab 预览", "RemoteCrab Preview"),
                slot,
                shutdown,
                status,
            );
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

/// Detach from the console when this process is the only thing attached to it,
/// and point the process's own output at the log file first.
///
/// `remotecrab.exe` is a console-subsystem binary on purpose: `--help`, `--scan`,
/// `doctor` and the interactive console all write to stdout, and a
/// GUI-subsystem binary has no stdout to write to. The cost of that choice is
/// that a launch from Explorer or the Start Menu gets a console of its own, so
/// the user double-clicks RemoteCrab and meets a black terminal window — the
/// single most "this is a developer tool" thing about the install, and the first
/// thing they see.
///
/// `GetConsoleProcessList` separates the two cases: it returns every process
/// attached to the console. Exactly one means *we* own it, which means nobody
/// launched us from a shell and there is nobody to read the output.
///
/// `FreeConsole` rather than `ShowWindow(SW_HIDE)`: hiding the window returned
/// by `GetConsoleWindow` does nothing when the console is hosted by Windows
/// Terminal through a pseudoconsole, which is the default on Windows 11 — the
/// window that is actually on screen belongs to the terminal, not to us.
/// Detaching closes the console itself, which is what makes the window go away
/// under both hosts.
///
/// **The output has to survive the detach.** The first version threw the console
/// away and with it every status line — `RemoteCrab.log` held nothing but the
/// launch banner, so a tray app whose entire UI is a tray icon became impossible
/// to diagnose at the exact moment a user would want to. With the console gone,
/// the log is the only surface left, so stdout and stderr are repointed at it
/// before detaching. A shell attachment is untouched: `--help` still prints.
#[cfg(windows)]
fn hide_console_if_we_own_it() {
    use windows::Win32::System::Console::{
        FreeConsole, GetConsoleMode, GetConsoleProcessList, GetStdHandle, SetStdHandle,
        STD_ERROR_HANDLE, STD_OUTPUT_HANDLE,
    };

    // A two-element buffer is enough: the function only has to tell "exactly
    // one" from "more than one", and it reports the true count when the buffer
    // is too small.
    let mut pids = [0u32; 2];
    // SAFETY: `pids` is a valid writable buffer, and the binding passes its
    // length to the API.
    let attached = unsafe { GetConsoleProcessList(&mut pids) };
    // Exactly one: more than one means a shell shares it and is being read, and
    // zero means there is no console to detach from at all.
    if attached != 1 {
        return;
    }

    // Whether to *also* take over stdout is a separate question, and it is not
    // answered by the console count. `Start-Process -RedirectStandardOutput`
    // gives the child a console of its own — so the count is 1 — while pointing
    // its stdout at a pipe, so a program that trusted the count appended to its
    // own log and left the caller's file empty: `remotecrab --scan | grep …`
    // printed nothing anywhere.
    //
    // `GetConsoleMode` succeeds only for a console handle. Anything else (a pipe,
    // a file, NUL) is a destination the caller chose, and it is left alone.
    let stdout = unsafe { GetStdHandle(STD_OUTPUT_HANDLE) }.unwrap_or(windows::Win32::Foundation::HANDLE::default());
    let mut mode = windows::Win32::System::Console::CONSOLE_MODE(0);
    let stdout_is_a_console = unsafe { GetConsoleMode(stdout, &mut mode) }.is_ok();

    if stdout_is_a_console {
        if let Some(handle) = append_log_handle() {
            // SAFETY: these only swap one process-wide handle for another. The
            // handle stays open for the life of the process — deliberately, since
            // every later `println!` writes through it.
            unsafe {
                let _ = SetStdHandle(STD_OUTPUT_HANDLE, handle);
                let _ = SetStdHandle(STD_ERROR_HANDLE, handle);
            }
        }
    }

    // SAFETY: no preconditions. Detaching only removes this process from the
    // console; the console itself survives if another process still holds it,
    // which the count above has already ruled out.
    unsafe {
        let _ = FreeConsole();
    }
}

/// A handle to the log file, opened for appending, or `None` if it cannot be
/// opened. The handle is intentionally leaked into the process: it becomes
/// stdout, and closing it would turn every later write into a silent failure.
#[cfg(windows)]
fn append_log_handle() -> Option<windows::Win32::Foundation::HANDLE> {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::Foundation::HANDLE;

    let path = diagnostics::log_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .ok()?;
    let handle = HANDLE(file.as_raw_handle());
    // The `File` must outlive this function; its handle is now the process's
    // stdout, so dropping it would close a handle the runtime is still writing
    // through.
    std::mem::forget(file);
    Some(handle)
}

/// Send a file-transfer acknowledgement, and say so if it cannot be encoded.
///
/// The callers used `encode_file_ack(&ack).unwrap_or_default()`, and
/// `unwrap_or_default()` on an error is a **zero-length** frame. The phone then
/// reads an empty body where a JSON ack should be: at best it ignores it, at
/// worst it desynchronises the transfer, and either way nothing anywhere says
/// why the file stopped moving. Sending nothing is both correct and visible.
fn send_file_ack(session: &rc_net::Session, ack: &rc_protocol::FileAck) {
    match encode_file_ack(ack) {
        Ok(frame) => session.send_frame(frame),
        Err(e) => eprintln!("  file: could not encode a transfer ack — {e}"),
    }
}

/// Tell the phone how a command it asked for turned out.
///
/// The Mac has always sent this (`launchApp` / `quitApp` / `showDesktop`), so a
/// Windows receiver that stayed silent made those buttons look broken: the user
/// taps, nothing visibly happens on the phone, and the app is blamed. Windows
/// did not send one at all.
///
/// Silently does nothing when the request carried no `requestId`. That is not a
/// shortcut — it is the compatibility rule: a phone that omits the id predates
/// `commandResult` and cannot read the answer, and the Mac receiver treats that
/// same silence as "your receiver is too old to confirm" rather than as a
/// failure. Inventing an id would make this side look newer than it is.
fn send_command_result(session: &rc_net::Session, request_id: Option<&str>, ok: bool) {
    let Some(request_id) = request_id else {
        return;
    };
    let result = rc_protocol::CommandResult {
        request_id: request_id.to_string(),
        status: if ok {
            rc_protocol::CommandStatus::Ok
        } else {
            rc_protocol::CommandStatus::Failed
        },
        detail: None,
    };
    match rc_protocol::encode_command_result(&result) {
        Ok(frame) => session.send_frame(frame),
        Err(e) => eprintln!("  command result: could not encode — {e}"),
    }
}

/// Check the release feed, and install a newer release if the user agrees.
///
/// Runs on a worker thread, because `updater` is blocking and both callers —
/// the Settings button and the launch-time check — are on threads that must not
/// wait for a network.
///
/// `interactive` decides how much the user is asked:
///
/// * from Settings, an update is confirmed before anything is downloaded, and
///   the outcome is written into the window;
/// * at launch, the check is silent and only its failure is worth a word —
///   nobody wants a dialog on startup because a release host is unreachable.
#[cfg(windows)]
fn spawn_update_check(interactive: bool) {
    std::thread::spawn(move || {
        if !interactive {
            // Late, and off the startup path: see the call site.
            std::thread::sleep(std::time::Duration::from_secs(20));
        }
        let current = env!("CARGO_PKG_VERSION");
        let key = updater::UPDATE_PUBLIC_KEY;

        let line = match updater::check(current) {
            Ok(None) => {
                if interactive {
                    Some(i18n::t(
                        "已经是最新版本。",
                        "RemoteCrab is up to date.",
                    )
                    .to_string())
                } else {
                    None
                }
            }
            Ok(Some(manifest)) => install_offered(&manifest, current, &key, interactive),
            Err(e) => {
                // A failed check is not worth a dialog at launch, but it is
                // worth a line in the log — "it never updates" is otherwise
                // indistinguishable from "there is never an update".
                eprintln!("[update] check failed: {e}");
                if interactive {
                    Some(
                        i18n::t("检查更新失败（详情见日志）。", "The update check failed — see the log.")
                            .to_string(),
                    )
                } else {
                    None
                }
            }
        };

        if let Some(line) = line {
            settings_win::set_update_message(line);
            settings_win::refresh_if_open();
        }
    });
}

/// A release is published: say so, and install it if the user says yes.
///
/// The confirmation comes **before** the download, not after: asking someone to
/// approve a 2 MB download and then an install in two steps is two chances to
/// change their mind for no reason, and the version number is the only fact they
/// need to decide.
#[cfg(windows)]
fn install_offered(
    manifest: &updater::Manifest,
    current: &str,
    key: &[u8; 32],
    interactive: bool,
) -> Option<String> {
    let found = i18n::t(
        &format!("有可用的新版本 {}（当前 {current}）。", manifest.version),
        &format!("Version {} is available (you have {current}).", manifest.version),
    )
    .to_string();
    eprintln!("[update] {} {}", found, manifest.notes.as_deref().unwrap_or(""));

    if !interactive {
        // Launch-time: report, do not act. An update that installs itself while
        // the user is in the middle of something is a worse product than one
        // that waits to be asked.
        return None;
    }

    let question = match &manifest.notes {
        Some(notes) => format!("{found}\n\n{notes}\n\n{}", i18n::t("现在安装？", "Install now?")),
        None => format!("{found}\n\n{}", i18n::t("现在安装？", "Install now?")),
    };
    if !confirm(&question) {
        return Some(i18n::t("已跳过这次更新。", "Update skipped.").to_string());
    }

    let staged = match updater::stage(manifest, &updater::update_dir(), key) {
        Ok(path) => path,
        Err(e) => {
            eprintln!("[update] {e}");
            return Some(
                i18n::t(
                    "更新包校验失败，已放弃（详情见日志）。",
                    "The update failed verification and was discarded — see the log.",
                )
                .to_string(),
            );
        }
    };
    if let Err(e) = updater::install(&staged) {
        eprintln!("[update] {e}");
        return Some(
            i18n::t("安装没能启动（详情见日志）。", "The installer could not be started — see the log.")
                .to_string(),
        );
    }
    // The installer has been handed control. Windows will not replace a running
    // executable, so this process has to be gone before it finishes.
    std::process::exit(0);
}

/// Yes/no dialog. `MB_ICONINFORMATION` rather than a warning: an update is not
/// a problem.
#[cfg(windows)]
fn confirm(question: &str) -> bool {
    use windows::core::{HSTRING, PCWSTR};
    use windows::Win32::UI::WindowsAndMessaging::{
        MessageBoxW, IDYES, MB_ICONINFORMATION, MB_YESNO,
    };

    let text = HSTRING::from(question);
    let title = HSTRING::from(i18n::t("RemoteCrab 更新", "RemoteCrab update"));
    // SAFETY: both strings outlive the call; no parent window means the box is
    // owned by the thread, which is what we want from a worker.
    let answer = unsafe {
        MessageBoxW(
            None,
            PCWSTR(text.as_ptr()),
            PCWSTR(title.as_ptr()),
            MB_YESNO | MB_ICONINFORMATION,
        )
    };
    answer == IDYES
}

/// How long to ignore knocks after acting on one.
///
/// The alternative to a floor is a receiver that can be made to re-dial in a
/// loop by anything on the LAN, which is a denial of service against the user's
/// own session. Two seconds is far below the time it takes a person to tap a
/// computer twice and far above anything a flood can do.
#[cfg(windows)]
const KNOCK_MIN_INTERVAL: Duration = Duration::from_secs(2);

/// Listen on the knock port: an inbound connection means "dial me back now".
///
/// The phone is the TCP server, so it cannot open the data socket — tapping a
/// computer on the phone used to mean waiting for that computer's own retry
/// poll. A knock closes that gap without changing the session at all: the phone
/// connects to this port, hangs up, and the receiver dials it immediately. No
/// handshake happens here, no bytes are exchanged; **the connection itself is
/// the message**.
///
/// Two guards, and neither needs the knock to be authenticated — a knock cannot
/// do anything except ask for a dial the receiver would have made anyway:
///
/// * ignored while already streaming, so a knock cannot tear down a live
///   session (the phone knocking is usually the phone that is already here);
/// * rate-limited, so a flood costs a reconnect rather than a loop of them.
#[cfg(windows)]
fn spawn_knock_listener(session: rc_net::Session) {
    tokio::spawn(async move {
        let listener =
            match tokio::net::TcpListener::bind(("0.0.0.0", rc_discovery::KNOCK_PORT)).await {
                Ok(listener) => listener,
                Err(e) => {
                    // Not fatal, and deliberately not retried: the phone falls
                    // back to "remember this computer and wait for it to dial",
                    // which is exactly what it did before this existed.
                    eprintln!(
                        "[knock] could not listen on {}: {e}\n\
                         [knock]     tap-to-connect will wait for our own retry instead",
                        rc_discovery::KNOCK_PORT
                    );
                    return;
                }
            };
        println!(
            "  knock: listening on port {} (tap this computer on the phone to connect at once)",
            rc_discovery::KNOCK_PORT
        );

        let state = session.state();
        let mut last_acted = std::time::Instant::now() - KNOCK_MIN_INTERVAL;
        loop {
            let Ok((stream, peer)) = listener.accept().await else {
                // A failed accept on a bound listener is transient (EMFILE and
                // friends); dropping the listener over it would take the feature
                // away for the rest of the run.
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            };
            // Nothing is read and nothing is written: closing immediately is the
            // contract, and it also means a caller cannot make us wait.
            drop(stream);

            if matches!(*state.borrow(), rc_net::State::Streaming { .. }) {
                println!("[knock] {peer} knocked while already streaming — ignored");
                continue;
            }
            if last_acted.elapsed() < KNOCK_MIN_INTERVAL {
                // Silent on purpose: a flood is not worth a log line per
                // connection, and the user cannot act on it either way.
                continue;
            }
            last_acted = std::time::Instant::now();
            println!("[knock] {peer} asked us to dial back");
            session.retry_now();
        }
    });
}

#[tokio::main]
async fn main() -> ExitCode {
    let args = parse_args();

    // Before anything can print: a double-clicked launch should not leave a black
    // terminal window sitting behind the tray icon.
    #[cfg(windows)]
    hide_console_if_we_own_it();

    // FIRST, before anything else can fail. If a previous run muted this PC
    // while the phone was playing and then died — a crash, a force-quit, a
    // power cut — the user came back to a silent computer with no way to know
    // why. The marker file is written before the volume is ever touched, so this
    // is the only place that has to look, and it costs one file read.
    #[cfg(windows)]
    speaker::recover_volume_if_needed();

    // `--version` first, and it works with no other argument and no window:
    // a user reporting a bug has to be able to say which build they are on
    // without starting a receiver, and before anything can fail.
    if args.version {
        println!("remotecrab {}", env!("CARGO_PKG_VERSION"));
        return ExitCode::SUCCESS;
    }
    // Before the single-instance check and before any window: this is a question
    // about the audio hardware, so a running receiver must not be in the way.
    #[cfg(windows)]
    if args.speaker_probe {
        return speaker::probe();
    }
    // A release build does not carry the fake sender, so these two cannot
    // work. Saying so beats a flag that quietly does nothing.
    #[cfg(feature = "selftest")]
    if args.selftest {
        return selftest::selftest().await;
    }
    #[cfg(feature = "selftest")]
    if args.preview_selftest {
        return selftest::preview_selftest().await;
    }
    #[cfg(not(feature = "selftest"))]
    if args.selftest || args.preview_selftest {
        eprintln!("{}", selftest::not_built_in());
        return ExitCode::FAILURE;
    }
    // The two one-shot elevated jobs. They are started by the app re-launching
    // itself with the `runas` verb, do exactly one thing, and exit — which is
    // why they run *before* the single-instance check. A UAC-elevated copy
    // shares the mutex name with the tray instance, and refusing to start
    // because "another copy is already running" is the one thing that must
    // never happen to the process that is trying to fix the installation.
    #[cfg(windows)]
    if args.install_vcam || args.uninstall_vcam || args.uninstall_vcam_machine || args.uninstall_vcam_user
    {
        return vcam::run_one_shot(args.install_vcam, args.uninstall_vcam_machine, args.uninstall_vcam_user);
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
    // The first-run wizard is opened later, once the tray exists — it has to be
    // built on the thread that pumps messages, and that thread is the tray's.
    // See `maybe_show_wizard` and `tray::TrayHandle::open_wizard`.
    //
    // An update check, quietly and late. Late because a release host is the
    // least important thing at startup — a home network with no route to it
    // would otherwise compete with discovery for the first seconds — and quietly
    // because the answer is only actionable, not urgent: Settings has the button
    // when someone wants to act on it.
    spawn_update_check(false);
    println!(
        "{}\n",
        i18n::t(
            "正在当前 WiFi 下寻找 iPhone…",
            "Looking for your iPhone on this WiFi…"
        )
    );

    let session = Session::spawn(Config::default());
    #[cfg(windows)]
    let _ = SESSION.set(session.clone());

    // Announce this computer on the LAN, so the phone's "choose a computer"
    // list can tell online from merely-previously-seen. Held for the life of the
    // process: dropping the advertiser unregisters the service, and a computer
    // that vanishes from the list the moment the variable goes out of scope is
    // worse than one that was never listed.
    //
    // Failure is a log line, not a fatal: the phone can still connect to a
    // computer it cannot see (the pairing list is history, not discovery), and a
    // security suite blocking multicast must not stop the product working.
    #[cfg(windows)]
    let _presence = {
        let (id, name) = rc_net::Session::pc_identity();
        // A short, stable instance key. Not a correctness requirement — the
        // failure that kept this advertisement off the network was mdns-sd's cap
        // on the service *type*, fixed in `rc-discovery::advertise` — but a
        // 36-byte UUID is what a generic mDNS browser would show, and the
        // readable name is already in the TXT where the phone reads it.
        let instance: String = format!("rc-{}", id.chars().take(8).collect::<String>());
        match rc_discovery::advertise(&instance, &id, &name, "windows") {
            Ok(advertiser) => {
                println!("  presence: advertising as {name} ({id})");
                Some(advertiser)
            }
            Err(e) => {
                eprintln!(
                    "[presence] could not advertise: {e}\n\
                     [presence]     the phone will not show this PC as online; pairing still works"
                );
                None
            }
        }
    };

    // The knock port. See `spawn_knock_listener`.
    #[cfg(windows)]
    spawn_knock_listener(session.clone());

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

    // The notification relay, if the user turned it on. It runs on its own
    // thread and pushes straight into the session, because a notification
    // arriving is not an *event from the phone* and has no business going
    // around the `select!` to get there — the loop is busy reconnecting, and a
    // banner that waits for a reconnect to finish is a banner that never
    // arrives.
    #[cfg(windows)]
    let _notify = {
        let session = session.clone();
        notify_relay::start_listener(std::sync::Arc::new(
            move |n: rc_net::notify::Notification| {
                // The decision layer's `Notification` is platform-neutral; the
                // wire type is the phone's contract. They are two structs on
                // purpose — the wire one must not gain a field the phone cannot
                // read — so the conversion is explicit and lives here.
                let wire = rc_protocol::Notification {
                    app: n.app,
                    title: n.title,
                    subtitle: n.subtitle,
                    body: n.body,
                    window_title: n.window_title,
                };
                if let Ok(frame) = encode_notification(&wire) {
                    session.send_frame(frame);
                }
            },
        ))
    };

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

    // Pointer-direction diagnostic. TEMPORARY and inert unless
    // REMOTECRAB_E2E_TRACKPAD_DIR=1 — see the `Event::Touch` arm.
    let direction_diag = std::env::var("REMOTECRAB_E2E_TRACKPAD_DIR").as_deref() == Ok("1");
    let mut touch_dir_count: u32 = 0;

    // App-window mirror: started/stopped by the iPhone's screenControl.
    #[cfg(windows)]
    let mut mirror = mirror::MirrorController::new(session.clone());

    // Video preview: decode in this task, blit from the window thread. The
    // virtual camera consumes the same decoded frames, so the decoder is also
    // needed when only `--vcam` is on (e.g. `--no-preview --vcam`), and when
    // only `--decode-only` is on. `Args::decode_pipeline_needed` owns that
    // question so it cannot drift from the flag's meaning again.
    let mut preview: Option<rc_render::PreviewPipeline> = if args.decode_pipeline_needed() {
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
    let status_text = std::sync::Arc::new(std::sync::Mutex::new(
        i18n::t("等待画面…", "Waiting for video…").to_string(),
    ));
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
    // Portable per-capability counters, so each of the ten things a parity run
    // checks has a marker on BOTH receivers. Rate-limited on the high-rate ones
    // because 30 touches a second is noise, not evidence.
    let mut touch_frames: u64 = 0;
    let mut key_events: u64 = 0;
    let mut audio_packets: u64 = 0;
    // While another computer owns the iPhone we retry quietly — printing a
    // line every 10 s would be noise. We only re-announce when something
    // actually changes.
    let mut stuck_owner: Option<String> = None;
    // What the phone *claims* it is sending, from its metadata. Kept so the
    // periodic readout can print it next to what actually arrives — on iOS the
    // claim is computed from a bitrate property that `Quality` overrides, so it
    // is not a measurement of anything.
    let mut claimed_fps: Option<u32> = None;
    let mut claimed_kbps: Option<f64> = None;
    // Total video bytes, so the achieved rate can be measured rather than taken
    // on trust.
    let mut video_bytes: u64 = 0;
    let mut stream_started: Option<std::time::Instant> = None;
    // Keyframe-request throttling. One request per interval is enough: the phone
    // answers with an IDR immediately, and a stream that needs more than that is
    // broken in a way one more IDR will not fix.
    // Windows-gated with its only reader below. The declaration was ungated and
    // the read was gated, so `cargo build -p rc-app` failed off Windows — the
    // third variant of "a Windows-gated thing reached from shared code", and the
    // one `scripts/test.sh`'s host-build step exists to catch.
    #[cfg(windows)]
    let mut last_keyframe_ask_at = std::time::Instant::now() - KEYFRAME_REQUEST_INTERVAL;
    let mut last_keyframe_asked_at_refusals: u64 = 0;
    // Whether the trackpad currently believes it is connected, so the
    // streaming→not transition can be caught exactly once per link.
    let mut trackpad_was_connected = false;
    let mut last_spike_report = std::time::Instant::now();

    // Console feature control: the receiver can toggle the iPhone's camera /
    // mic / voice / surfaces the same way the Mac menu bar does.
    let mut console_rx = spawn_console_reader();
    let mut console_alive = true;
    let mut last_features: Option<rc_protocol::FeatureStateSnapshot> = None;
    let mut quit_requested = false;
    // "Use the iPhone as the speaker" (kind 0x24). The capture and its pump live
    // on their own thread inside `Speaker`; this loop only decides when.
    let mut speaker = speaker::Speaker::new();
    let mut speaker_running = false;
    let mut connected = false;
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
    // Now that there is a thread with a message pump, the first-run wizard can
    // be built. Before the tray existed this was called from the runtime thread,
    // which never pumps — so the window was created, shown, and then answered
    // nothing, and Windows labelled it "(Not Responding)".
    #[cfg(windows)]
    maybe_show_wizard(&tray);
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

                        // Release whatever the trackpad is still holding the
                        // moment the link drops.
                        //
                        // `WindowsInjector::end_gesture` had no caller anywhere
                        // in the tree, so a Shift held for a range-select
                        // survived a disconnect as a physically stuck key:
                        // `SendInput` posted a real key-down and nothing ever
                        // posted the key-up, so every later keystroke was
                        // shifted until the user pressed and released it
                        // themselves. Nothing in any log said so. It also
                        // flushes the fractional wheel accumulators, which
                        // otherwise drop a partial notch of scroll.
                        //
                        // On the streaming *edge*, not on every state change,
                        // so it does not run per heartbeat — and it is
                        // idempotent, so a duplicate state is harmless.
                        #[cfg(windows)]
                        if matches!(st, State::Streaming { .. }) {
                            trackpad_was_connected = true;
                        } else if trackpad_was_connected {
                            trackpad_was_connected = false;
                            if let Some(inj) = injector.as_mut() {
                                inj.end_gesture();
                            }
                        }

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

                        // Speaker capture follows the SESSION, not just the
                        // toggle: a phone that disconnects leaves the capture
                        // running with nobody to send to, which is the one state
                        // the Mac receiver guards against too
                        // (`sessionGranted && connection.state == .ready`).
                        let now_connected = matches!(st, State::Streaming { .. });
                        if !now_connected && speaker_running {
                            speaker.stop();
                            speaker_running = false;
                        }
                        connected = now_connected;

                        let label = status::state_line(&st, stats.last_frame.is_some());
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
                        // `frames` is what separates "streaming" from "claiming
                        // to stream": a phone that handshakes and then sends
                        // nothing produces no error and no event, so without it
                        // the tray asserts success forever.
                        tray.set_status(&status::tray_status(
                            &st,
                            stats.last_frame.is_some(),
                            i18n::is_chinese(),
                        ));

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
                                claimed_fps = Some(m.fps.max(0) as u32);
                                claimed_kbps = Some(m.bitrate_bps.max(0) as f64 / 1000.0);
                                println!(
                                    "  → streaming: {} {}x{} @ {}fps ({} kbps) — claimed by the phone",
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
                                if stream_started.is_none() {
                                    stream_started = Some(std::time::Instant::now());
                                }
                                if nal.kind == rc_protocol::NalKind::Video {
                                    video_bytes += nal.data.len() as u64;
                                }
                                // The NAL's byte count is the only real bitrate
                                // measurement available: the phone's metadata
                                // number is a *request*, and on iOS it is inert.
                                stats.record_video_bytes(nal.data.len());
                                // A decoded frame is the only proof the camera is
                                // actually on, as opposed to merely enabled.
                                // The zeros mean "dimensions unknown here" and
                                // leave the metadata's resolution alone — passing
                                // them through used to overwrite 1920x1080 with
                                // 0x0 on the very first frame.
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
                                        // `--decode-only` has no window and no
                                        // virtual camera, so nothing else would
                                        // ever say whether a single frame came
                                        // out. This line is the entire point of
                                        // the mode, and it carries numbers a
                                        // harness can assert on rather than a
                                        // "looks fine".
                                        if args.decode_only
                                            && p.frames_decoded().is_multiple_of(150)
                                        {
                                            println!(
                                                "  decode: {} frames ({}x{})",
                                                p.frames_decoded(),
                                                p.latest().map_or(0, |f| f.width),
                                                p.latest().map_or(0, |f| f.height)
                                            );
                                        }
                                        // One shared handle, two consumers. Both
                                        // of the `clone()`s this used to do were
                                        // deep copies of an 8.3 MB buffer, per
                                        // frame — the preview window and the
                                        // virtual camera each got their own.
                                        if let Some(frame) = p.latest_shared() {
                                            frame_slot.set(frame.clone());
                                            #[cfg(windows)]
                                            if let Some(vc) = vcam.as_mut() {
                                                let fps = metadata
                                                    .as_ref()
                                                    .map(|m| m.fps.max(1) as u32)
                                                    .unwrap_or(30);
                                                vc.publish(&frame, fps);
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
                                    if p.frames_decoded().is_multiple_of(150)
                                        || video_frames.is_multiple_of(150)
                                    {
                                        let (w, h) = p.dimensions();
                                        // `frames_decoded() == 0` is a multiple of
                                        // 150, so this line used to print on
                                        // *every* NAL while nothing decoded — which
                                        // is both noise and, printed twice in a
                                        // minute, indistinguishable from "no video
                                        // is arriving". Counting the kinds says which.
                                        //
                                        // Startup refusals are counted apart: every
                                        // real stream opens with NALs no decoder can
                                        // use, and a counter that always begins with
                                        // "22 refused" is one people learn to ignore.
                                        let tail = match (p.frames_decoded(), p.refusals_after_start())
                                        {
                                            (0, _) => String::new(),
                                            (_, 0) => format!(
                                                "  ({} refused before the first frame)",
                                                p.warmup_refusals()
                                            ),
                                            (_, n) => format!("  ({n} refused since the first frame)"),
                                        };

                                        // Ask for a keyframe when the decoder is
                                        // refusing slices.
                                        //
                                        // A refused P-slice usually means the
                                        // reference is gone, and the only
                                        // recovery is a fresh IDR — which,
                                        // without this, happens whenever the
                                        // phone's keyframe interval next
                                        // elapses. OpenH264's own issue tracker
                                        // recommends exactly this
                                        // (#1998, #1163). Rate-limited, because
                                        // a phone that cannot satisfy it must
                                        // not be asked on every slice.
                                        #[cfg(windows)]
                                        if p.refusals_after_start()
                                            > last_keyframe_asked_at_refusals
                                        {
                                            last_keyframe_asked_at_refusals =
                                                p.refusals_after_start();
                                            if last_keyframe_ask_at
                                                .elapsed()
                                                >= KEYFRAME_REQUEST_INTERVAL
                                            {
                                                last_keyframe_ask_at =
                                                    std::time::Instant::now();
                                                session.send_frame(
                                                    rc_protocol::wire::encode_request_keyframe(),
                                                );
                                                println!(
                                                    "     asking the phone for a keyframe ({} refusals so far)",
                                                    p.refusals_after_start()
                                                );
                                            }
                                        }
                                        println!(
                                            "  video: {} decoded / {} received ({}x{}){}",
                                            p.frames_decoded(),
                                            video_frames,
                                            w,
                                            h,
                                            p.last_error()
                                                .map(|e| format!("  last: {e}"))
                                                .unwrap_or(tail)
                                        );
                                        // What the phone *claims* against what is
                                        // actually arriving.
                                        //
                                        // The claim is metadata, and on iOS it is
                                        // computed rather than measured — the
                                        // AverageBitRate that produced it is
                                        // overridden by `Quality` and does nothing.
                                        // So a receiver that only prints the claim
                                        // reports success for a stream that may be
                                        // delivering an eighth of it. Measured on a
                                        // real iPhone: promised 30 fps and 9331 kbps,
                                        // delivered 3.5 fps and 1878 kbps, while the
                                        // status line read "streaming @ 30fps".
                                        if let (Some(cfps), Some(ckbps), Some(t0)) =
                                            (claimed_fps, claimed_kbps, stream_started)
                                        {
                                            let secs = t0.elapsed().as_secs_f64().max(0.001);
                                            let got_fps = video_frames as f64 / secs;
                                            let got_kbps = video_bytes as f64 * 8.0 / 1000.0 / secs;
                                            if let Some(line) = crate::status::stream_shortfall(
                                                cfps as f64,
                                                ckbps,
                                                got_fps,
                                                got_kbps,
                                            ) {
                                                println!("     ⚠ {line}");
                                                println!(
                                                    "       the phone is not sending what it says. This is an encoder or"
                                                );
                                                println!(
                                                    "       transport fault on the phone, not something the receiver can fix."
                                                );
                                            }
                                        }
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
                                // Portable marker. Receiving a touch is a fact about
                                // the wire and holds on every platform; only the
                                // *injection* needs Windows. Without this line the
                                // capability has no cell at all in a parity run
                                // hosted on a Mac, which reads as "not tested"
                                // rather than "cannot be injected here".
                                touch_frames += 1;
                                if touch_frames.is_multiple_of(30) {
                                    println!("  touch events received: {touch_frames}");
                                }
                                // TEMPORARY DIAGNOSTIC — inert unless
                                // REMOTECRAB_E2E_TRACKPAD_DIR=1.
                                //
                                // A user reports the pointer travelling right when the
                                // finger goes left, on Windows only. The phone has been
                                // measured doing the right thing (its own
                                // `REMOTECRAB_E2E_TRACKPAD_DIR` log shows `out.dx`
                                // carrying the finger's own sign, magnified ~1.5-2.9x
                                // by TrackpadMath), and `rc-input`'s move maths is
                                // covered by `a_move_preserves_the_sign_of_its_delta`.
                                // So this prints the received delta and the cursor
                                // travel it produced on ONE line: if `in.dx` and
                                // `cursor_dx` disagree in sign, the inversion is here.
                                #[cfg(windows)]
                                if direction_diag && t.phase == TouchPhase::Move {
                                    if let Some(inj) = injector.as_mut() {
                                        let before = inj.cursor();
                                        inj.inject_touch(&t);
                                        let after = inj.cursor();
                                        touch_dir_count += 1;
                                        if touch_dir_count % 12 == 1 {
                                            println!(
                                                "  [dir] n={touch_dir_count} in.dx={:+.5} cursor_dx={:+.1} cursor_dy={:+.1} at=({:.0},{:.0})",
                                                t.dx,
                                                after.0 - before.0,
                                                after.1 - before.1,
                                                after.0,
                                                after.1
                                            );
                                        }
                                        // Already injected above; don't run it twice.
                                        continue;
                                    }
                                }
                                #[cfg(windows)]
                        publish_stats(&stats);
                                #[cfg(windows)]
                                if let Some(inj) = injector.as_mut() {
                                    inj.inject_touch(&t);
                                }
                                #[cfg(not(windows))]
                                let _ = &t;
                            }
                            Event::Key(k) => {
                                stats.record_key(&k);
                                // Same reasoning as the touch marker above.
                                key_events += 1;
                                println!("  key events received: {key_events}");
                                #[cfg(windows)]
                        publish_stats(&stats);
                                #[cfg(windows)]
                                if let Some(inj) = injector.as_ref() {
                                    inj.inject_key(&k);
                                }
                                #[cfg(not(windows))]
                                let _ = &k;
                            }
                            Event::Audio(packet) => {
                                audio.consume(&packet);
                                // Portable marker, for the same reason. Also the one
                                // place a parity run can prove the Opus encode path
                                // end to end without a speaker: packets arriving and
                                // being handed to the decoder is what is being
                                // asserted, not that anything came out of it.
                                audio_packets += 1;
                                if audio_packets.is_multiple_of(100) {
                                    println!("  audio packets received: {audio_packets}");
                                }
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
                                tray.set_details(tray_rows(&stats, &speaker));
                            }
                            Event::Latency(ms) => {
                                stats.record_latency(ms);
                                // Refresh the readout's contents; the tray re-renders
                                // the submenu on each popup, so this is the only write.
                                tray.set_details(tray_rows(&stats, &speaker));
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
                                send_file_ack(&session, &ack);
                                println!("  file: receiving {} ({} bytes)…", offer.name, offer.size);
                            }
                            Event::FileChunk(data) => {
                                if let Some(ack) = file_rx.append(&data) {
                                    // Only ack progress periodically to avoid flooding.
                                    if ack.received_bytes % (256 * 1024) < data.len() as i64 {
                                        send_file_ack(&session, &ack);
                                    }
                                }
                            }
                            Event::FileComplete(done) => {
                                if let Some((ack, path)) = file_rx.complete(&done.id) {
                                    send_file_ack(&session, &ack);
                                    println!("  file: saved to {}", path.display());
                                    #[cfg(windows)]
                                    {
                                        rc_os::files::reveal(&path);
                                        last_received_file = Some(path);
                                    }
                                    tray.set_has_last_file(true);
                                }
                            }
                            // A relayed desktop notification, admitted by
                            // `rc_net::notify` (off unless enabled, denylisted apps
                            // dropped, unnamed senders dropped).
                            Event::Notification(n) => {
                                if !notify_relay::is_enabled() {
                                    // The user turned it off while a banner was in
                                    // flight. Dropping it is the whole point of the
                                    // switch being immediate.
                                    continue;
                                }
                                match encode_notification(&n) {
                                    Ok(frame) => {
                                        session.send_frame(frame);
                                        let (app, _why) = (n.app.clone(), ());
                                        println!(
                                            "  notify: {} → {}",
                                            i18n::t("已转发通知", "relayed a notification"),
                                            app
                                        );
                                    }
                                    Err(e) => eprintln!("  notify: encode failed: {e}"),
                                }
                            }
        Event::SystemCommand(cmd) => {
                                // A command we cannot do has to say so in words the
                                // user reads, and say what *is* possible.
                                //
                                // The `{:?}` of the protocol enum used to be printed
                                // here: English, an implementation detail, and — for
                                // a Chinese user hitting a brightness button — not an
                                // explanation of anything.
                                #[cfg(windows)]
                                let handled = rc_os::system_keys::handle(&cmd);
                                #[cfg(not(windows))]
                                let handled = false;
                                // A freshly launched app has to become a card in the
                                // phone's still-open window picker, which renders
                                // the *window* list — `appList` alone left the app
                                // invisible there. It is not in the list the instant
                                // the launch is accepted, so poll for the window
                                // instead of sleeping a guessed interval (the Mac
                                // gets the same effect from its launch + activation
                                // observers).
#[cfg(windows)]
                        if handled
                            && cmd.command == SystemCommandKind::LaunchApp
                            && window_list_wanted.load(std::sync::atomic::Ordering::Relaxed)
                        {
                            spawn_window_refresh(&session);
                        }
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
                                    tray.set_details(tray_rows(&stats, &speaker));
                                }
                                send_command_result(&session, cmd.request_id.as_deref(), handled);
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
                                // Portable marker: the *request* arrived and names
                                // this app. Whether it came to the front is the
                                // injection half, and that is a separate question
                                // with a separate answer on this platform.
                                println!("  app switch requested: {}", a.id);
                                #[cfg(windows)]
                                {
                                    let mut switched = false;
                                    if args.no_input {
                                        println!("  app switch ignored (--no-input)");
                                    } else if rc_os::apps::activate_id_with_title(&a.id, a.window_title.as_deref()) {
                                        println!("  activated app {}", a.id);
                                        switched = true;
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
                                    send_command_result(&session, a.request_id.as_deref(), switched);
                                }
                                #[cfg(not(windows))]
                                let _ = &a;
                            }
                            Event::QuitApp(q) => {
                                #[cfg(windows)]
                                {
                                    let mut quit = false;
                                    if args.no_input {
                                        println!("  app quit ignored (--no-input)");
                                    } else if rc_os::apps::quit_id(&q.id, q.force) {
                                        println!("  quit app {}", q.id);
                                        quit = true;
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
                                    send_command_result(&session, q.request_id.as_deref(), quit);
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
                                // "Use the iPhone as the speaker" (wire kind 0x24).
                                // The phone owns this toggle, so the receiver follows
                                // the ECHOED state rather than acting on a request
                                // twice — the same rule the Mac receiver applies to
                                // `snap.speakerOn`. `decide` is a pure function, and
                                // this arm is its only caller.
                                match speaker::decide(
                                    s.speaker_on,
                                    connected,
                                    speaker_running,
                                ) {
                                    speaker::Action::StartCapture => {
                                        speaker_running = speaker.start(&session);
                                    }
                                    speaker::Action::StopCapture => {
                                        speaker.stop();
                                        speaker_running = false;
                                    }
                                    speaker::Action::NoChange => {}
                                }
                                tray.set_features(Some(s.clone()));
                                tray.set_details(tray_rows(&stats, &speaker));
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

/// Republish the window list once a just-launched app's window exists.
///
/// Polls for the change rather than sleeping a guessed interval: a cold app
/// can take seconds to open its first window, and a fixed sleep either
/// publishes too early (the card is still missing, which is the complaint
/// this fixes) or wastes time on a fast launch. Off the select loop, so a
/// slow launch can't stall reconnect or input — the same reason the
/// notification relay pushes from its own thread.
#[cfg(windows)]
fn spawn_window_refresh(session: &rc_net::Session) {
    let session = session.clone();
    std::thread::spawn(move || {
        const POLL: Duration = Duration::from_millis(250);
        const DEADLINE: Duration = Duration::from_secs(6);
        let mut waited = Duration::ZERO;
        let mut sent = 0usize;
        while waited < DEADLINE {
            std::thread::sleep(POLL);
            waited += POLL;
            let list = rc_os::windows::build_window_list();
            if list.windows.len() != sent {
                sent = list.windows.len();
                session.send_frame(encode_window_list(&list).unwrap_or_default());
                println!("  window list refreshed after launch ({sent} windows)");
                return;
            }
        }
        // Nothing changed inside the deadline — publish once anyway so the
        // picker at least drops the app that is gone.
        let list = rc_os::windows::build_window_list();
        if list.windows.len() != sent {
            session.send_frame(encode_window_list(&list).unwrap_or_default());
        }
    });
}

/// The tray's live readout: the stream stats, plus a speaker row when the
/// speaker has something to say.
///
/// Composed in one place because there are four call sites and the speaker half
/// has to travel with all of them — a status that only refreshes on a latency
/// packet is a status that is wrong whenever the audio changes without the
/// latency changing. A *working* speaker contributes no row at all
/// (`speaker::status_row`), so this costs nothing in the common case.
fn tray_rows(
    stats: &stream_stats::StreamStats,
    speaker: &speaker::Speaker,
) -> Vec<(String, String)> {
    let mut rows = stream_stats::detail_rows(stats);
    if let Some(row) = speaker.view().status.and_then(speaker::status_row) {
        rows.push(row);
    }
    rows
}

/// The state the wizard reports on, read fresh each time.
#[cfg(windows)]
fn current_first_run() -> rc_net::firstrun::FirstRun {
    use rc_net::firstrun::{Camera, FirstRun};
    FirstRun {
        camera: if vcam::is_registered() {
            Camera::Ready
        } else {
            Camera::Missing
        },
        integrity: notify_relay::integrity(),
        autostart: rc_os::autostart::is_enabled(),
        notify_relay: notify_relay::is_enabled(),
    }
}

/// Ask the tray thread to open the wizard on the first run, and only then.
///
/// The gate is "has the user seen it", **not** "is something wrong". A wizard
/// that appears only when it has something to fix is a wizard most first-time
/// users never see — and the whole value of walking someone through a setup is
/// that they learn what it does. A wizard that reappears is a nag, so the flag
/// is written the moment it opens, not when it is finished: a user who quits
/// halfway has still been introduced.
///
/// It goes through the tray rather than calling `open_wizard` here, because this
/// runs on the runtime thread and that one never pumps messages.
#[cfg(windows)]
fn maybe_show_wizard(tray: &tray::TrayHandle) {
    if notify_relay::wizard_seen() {
        return;
    }
    notify_relay::mark_wizard_seen();
    tray.open_wizard();
}

#[cfg(not(windows))]
fn maybe_show_wizard() {}

/// Open the settings window.
#[cfg(windows)]
fn open_settings() {
    settings_win::show(settings_win::Actions {
        // The denylist, round-tripped through the pure `NameList` so the
        // validation rules are the tested ones rather than whatever the window
        // happens to check.
        deny: Box::new(|raw| {
            let mut list = NameList::new(notify_relay::denylist());
            list.add(raw).map_err(|e| e.message())?;
            notify_relay::set_denylist(list.items().to_vec());
            Ok(())
        }),
        undeny: Box::new(|name| {
            let mut list = NameList::new(notify_relay::denylist());
            list.remove(name);
            notify_relay::set_denylist(list.items().to_vec());
        }),
        denylist: Box::new(notify_relay::denylist),
        // Routed through the session, which owns the store. A direct file write
        // from here would be a second writer, and the supervisor's next save
        // would silently undo the user's action.
        forget: Box::new(session_forget_phone),
        phones: Box::new(rc_net::Session::paired_phones),
        relay: Box::new(notify_relay::is_enabled),
        set_relay: Box::new(notify_relay::set_enabled),
        camera: Box::new(vcam::is_registered),
        quality: Box::new(notify_relay::quality),
        set_quality: Box::new(notify_relay::set_quality),
        autostart: Box::new(rc_os::autostart::is_enabled),
        set_autostart: Box::new(|on| {
            rc_os::autostart::set_enabled(on);
        }),
        // The same one the wizard's action button and the tray's install row
        // use. Three surfaces, one implementation: a private copy here would be
        // a second UAC flow that behaves slightly differently from the other two
        // and nobody would notice until it failed.
        install_camera: Box::new(|| {
            // The button exists only while the camera is unregistered, so its
            // two failure outcomes are the ones worth a sentence. Discarding the
            // result -- which is what this used to do -- means a user who clicks
            // "No" at the UAC prompt watches the button come straight back with
            // no explanation at all.
            wizard::install_outcome(vcam::install_with_elevation())
        }),
        check_update: Box::new(|| spawn_update_check(true)),
    });
}

/// Mirror the stats into the copy the self-check panel reads.
///
/// Called on the events that change them, rather than on a timer, so the panel
/// updates the moment a key arrives instead of up to 200 ms later — which for a
/// panel whose entire purpose is "did that just work?" is the difference between
/// a readout and a guess.
#[cfg(windows)]
fn publish_stats(s: &stream_stats::StreamStats) {
    if let Ok(mut g) = stats().lock() {
        *g = s.clone();
    }
}

/// Open the four-quadrant self-check, fed from the live stats.
#[cfg(windows)]
fn open_self_check() {
    selfcheck_win::show(Box::new(|| {
        use rc_net::selfcheck::Evidence;
        // A snapshot, read under the same lock the tray uses, so the panel
        // shows what the rest of the UI is showing rather than a second,
        // slightly different truth.
        let stats = stats().lock().map(|g| g.clone()).unwrap_or_default();
        let now = std::time::Instant::now();
        let since = |t: Option<std::time::Instant>| t.map(|t| now.saturating_duration_since(t));
        Evidence {
            fps: stats.fps.map(|f| f as i64),
            width: stats.resolution.map(|r| r.0 as i64).unwrap_or(0),
            height: stats.resolution.map(|r| r.1 as i64).unwrap_or(0),
            since_frame: since(stats.last_frame),
            last_key: stats.last_key.clone(),
            since_key: since(stats.last_key_at),
            last_touch: stats.last_touch.clone(),
            since_touch: since(stats.last_touch_at),
            mic_level: stats.mic_level.map(|l| (l * 100.0) as i64),
            session_live: stats.device_name.is_some(),
        }
    }));
}

#[cfg(windows)]
static STATS: std::sync::OnceLock<std::sync::Mutex<stream_stats::StreamStats>> =
    std::sync::OnceLock::new();

/// How often the receiver may ask the phone for a keyframe.
///
/// Generous, because the phone answers immediately and a stream that needs
/// asking more often than this is not going to be fixed by asking again. Also
/// keeps a phone that cannot satisfy the request from being asked on every
/// single slice, which would be its own kind of traffic problem.
#[cfg(windows)]
const KEYFRAME_REQUEST_INTERVAL: std::time::Duration = std::time::Duration::from_secs(2);

/// The live stats, shared with the self-check panel.
///
/// Behind a `Mutex` because the main loop writes it and the panel's timer reads
/// it, and behind `OnceLock` because `Mutex::new` needs a const value and
/// `Default::default()` is not one.
#[cfg(windows)]
fn stats() -> &'static std::sync::Mutex<stream_stats::StreamStats> {
    STATS.get_or_init(|| std::sync::Mutex::new(stream_stats::StreamStats::default()))
}

/// Ask the session to forget a paired phone.
///
/// A command rather than a file write: the supervisor owns the token store, and
/// two writers to one file means a forget that the next save undoes.
#[cfg(windows)]
fn session_forget_phone(name: &str) {
    if let Some(s) = SESSION.get() {
        s.forget_phone(name);
    }
}

#[cfg(windows)]
static SESSION: std::sync::OnceLock<rc_net::Session> = std::sync::OnceLock::new();

/// Open the wizard now, from the tray or from first run.
#[cfg(windows)]
fn open_wizard() {
    wizard_win::show(
        current_first_run(),
        Box::new(|| {
            // The action on the camera page: the same one-click, UAC-raising path
            // the tray's install row uses. The wizard does not get a private way
            // to do it, so the two cannot drift.
            wizard::record_action(wizard::install_outcome(
                vcam::install_with_elevation(),
            ))
        }),
    );
}

#[cfg(not(windows))]
#[allow(dead_code)] // the tray row that opens it is Windows-shaped
fn open_wizard() {}
