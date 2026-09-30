//! `rc-vcam` — virtual-camera helper (Windows 11 22H2+).
//!
//! Usage:
//!   rc-vcam install            # register the source DLL in HKLM (run elevated, once)
//!   rc-vcam uninstall          # remove that registration (run elevated)
//!   rc-vcam [name] [seconds]   # spike: start the camera and keep it alive for
//!                              # `seconds` so you can see it in the Camera app
//!
//! Registration is machine-wide on purpose: the Frame Server that activates the
//! source runs as `LocalService` and never reads `HKCU` (§3.17 of
//! `docs/WINDOWS_HANDOFF.md`). Leaving it registered is safe and intended —
//! only `uninstall` removes it.

use std::process::ExitCode;

/// `install` / `uninstall`, split out so the non-Windows build still compiles.
#[cfg(windows)]
fn register(uninstall: bool) -> Result<(), rc_vcam::VcamError> {
    if uninstall {
        rc_vcam::uninstall_source()
    } else {
        rc_vcam::install_source()
    }
}

#[cfg(not(windows))]
fn register(_uninstall: bool) -> Result<(), String> {
    Err("rc-vcam is Windows-only".to_string())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("install") | Some("uninstall") => {
            let uninstall = args[0] == "uninstall";
            match register(uninstall) {
                Ok(()) => {
                    println!(
                        "vcam: source DLL {} in HKLM\\Software\\Classes\\CLSID",
                        if uninstall { "unregistered" } else { "registered" }
                    );
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("vcam: {} failed: {e}", if uninstall { "uninstall" } else { "install" });
                    ExitCode::FAILURE
                }
            }
        }
        _ => {
            let name = args.first().cloned().unwrap_or_else(|| "RemoteCrab".to_string());
            let seconds = args
                .get(1)
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(20);
            match rc_vcam::run_spike(&name, seconds) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("vcam spike failed: {e}");
                    ExitCode::FAILURE
                }
            }
        }
    }
}
