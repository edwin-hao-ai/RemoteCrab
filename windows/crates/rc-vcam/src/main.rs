//! `rc-vcam` — virtual-camera spike (Windows 11 22H2+).
//!
//! Usage: `rc-vcam [friendly-name] [seconds]` (defaults "RemoteCrab" / 20).
//! Run it, then open the Windows Camera app (or OBS) and check whether a
//! "RemoteCrab" camera appears while it is alive.

fn main() {
    let mut args = std::env::args().skip(1);
    let name = args.next().unwrap_or_else(|| "RemoteCrab".to_string());
    let seconds = args
        .next()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(20);

    if let Err(e) = rc_vcam::run_spike(&name, seconds) {
        eprintln!("vcam spike failed: {e}");
        std::process::exit(1);
    }
}
