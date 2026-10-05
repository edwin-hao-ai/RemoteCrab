//! Live Win32 smoke check for rc-os — run with
//! `cargo run -p rc-os --example live_check`.
//!
//! Prints PASS/FAIL per capability so a real machine verifies what the
//! headless unit tests cannot: clipboard round-trip, app/window enumeration,
//! icon extraction, file receive (incl. path-traversal defence), system keys.
//!
//! Deliberately an example, not a test — it mutates the real clipboard and
//! touches real windows, so it must not run in CI.

#[cfg(windows)]
fn main() {
    use rc_protocol::{FileAckStatus, FileOffer, SystemCommand, SystemCommandKind};
    use rc_os::{apps, clipboard, files, system_keys, windows};

    let mut failures = 0;

    // --- clipboard round-trip ---------------------------------------------
    let saved = clipboard::get_text();
    let probe = format!("RemoteCrab clipboard probe {}", std::process::id());
    if clipboard::set_text(&probe) && clipboard::get_text().as_deref() == Some(probe.as_str()) {
        println!("PASS  clipboard round-trip");
    } else {
        println!("FAIL  clipboard round-trip");
        failures += 1;
    }
    if let Some(s) = saved {
        let _ = clipboard::set_text(&s);
    }

    // --- app list (with icons) --------------------------------------------
    let list = apps::build_app_list(true);
    if list.apps.is_empty() {
        println!("FAIL  app list is empty");
        failures += 1;
    } else {
        let named = list.apps.iter().filter(|a| !a.name.is_empty()).count();
        let with_icon = list.apps.iter().filter(|a| a.icon_png.is_some()).count();
        println!(
            "PASS  app list ({} entries, {} named, {} with icons) e.g. {:?}",
            list.apps.len(),
            named,
            with_icon,
            list.apps.iter().take(3).map(|a| &a.name).collect::<Vec<_>>()
        );
        if named == 0 {
            println!("FAIL  no app had a non-empty name");
            failures += 1;
        }
    }

    // --- installed apps catalog -------------------------------------------
    let installed = apps::build_installed_apps();
    println!(
        "INFO  installed apps catalog: {} entries",
        installed.apps.len()
    );

    // --- window list ------------------------------------------------------
    let windows_list = windows::build_window_list();
    println!(
        "INFO  window list: {} entries (canCapture={})",
        windows_list.windows.len(),
        windows_list.can_capture
    );

    // --- file receive (incl. traversal defence) ---------------------------
    let dir = std::env::temp_dir().join("remotecrab-live-check");
    let _ = std::fs::remove_dir_all(&dir);
    let mut rx = files::FileReceiver::new(dir.clone());
    let _ = rx.begin(FileOffer {
        id: "1".into(),
        name: "../evil.txt".into(), // traversal attempt
        size: 5,
    });
    let _ = rx.append(b"hello");
    match rx.complete("1") {
        Some((ack, path)) => {
            let inside = path.starts_with(&dir);
            let content_ok = std::fs::read(&path).map(|b| b == b"hello").unwrap_or(false);
            if ack.status == FileAckStatus::Saved && inside && content_ok {
                println!("PASS  file receive -> {} (escaped: {})", path.display(), !inside);
            } else {
                println!(
                    "FAIL  file receive: status={:?} inside={} content_ok={} path={}",
                    ack.status,
                    inside,
                    content_ok,
                    path.display()
                );
                failures += 1;
            }
        }
        None => {
            println!("FAIL  file receive complete() returned None");
            failures += 1;
        }
    }
    let _ = std::fs::remove_dir_all(&dir);

    // --- system key (volume up) -------------------------------------------
    let handled = system_keys::handle(&SystemCommand {
        command: SystemCommandKind::VolumeUp,
        argument: None,
        request_id: None,
    });
    println!(
        "{}  system key volumeUp (audible/volume change; not auto-verified)",
        if handled { "PASS" } else { "FAIL" }
    );
    if !handled {
        failures += 1;
    }

    println!(
        "\n{}",
        if failures == 0 {
            "ALL LIVE CHECKS PASSED"
        } else {
            "SOME LIVE CHECKS FAILED"
        }
    );
    if failures > 0 {
        std::process::exit(1);
    }
}

#[cfg(not(windows))]
fn main() {
    println!("live_check only runs on Windows");
}
