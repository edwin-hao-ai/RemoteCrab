//! Command-line surface: the flag set, the parser, and its tests.
//!
//! Kept apart from `main` so the parsing rules can be tested directly:
//! the parser is a pure function over an argument slice, and the only
//! caller that reads the real process arguments is `parse_args`.

use crate::help::print_help;

#[derive(Debug, Default)]
pub struct Args {
    pub connect: Option<String>,
    pub no_input: bool,
    pub list_only: bool,
    pub selftest: bool,
    pub preview_selftest: bool,
    pub audio_selftest: bool,
    pub vcam: bool,
    pub vcam_selftest: bool,
    pub preview: bool,
    pub no_preview: bool,
    pub scan: bool,
    pub unmute: bool,
    pub record: bool,
    pub version: bool,
    /// One-shot, elevated: register the virtual camera's COM source, exit.
    /// Reached two ways — the tray's `runas`, and typed by a user who self-elevates.
    pub install_vcam: bool,
    /// One-shot, elevated: undo the machine-wide bits, exit.
    pub uninstall_vcam: bool,
    /// One-shot: undo **only** the machine-wide bits, exit. Never touches
    /// per-user state, so it is safe to run as SYSTEM — which is exactly how the
    /// MSI's uninstall custom action invokes it. Running the full
    /// `--uninstall-vcam` there would delete the *system profile's* app data and
    /// leave the real user's untouched.
    pub uninstall_vcam_machine: bool,
    pub no_tray: bool,
    /// `remotecrab doctor [ip[:port]]` — diagnose "it won't connect".
    pub doctor: bool,
    /// `remotecrab --scan [subnet]` — the /24 prefix to sweep.
    pub subnet: Option<String>,
}

pub fn parse_args() -> Args {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    parse_args_from(&raw)
}

/// Parse an already-collected argument list.
///
/// Takes a slice so it can be unit-tested; `parse_args` is the only caller
/// that touches the real process arguments.
fn parse_args_from(raw: &[String]) -> Args {
    let mut args = Args::default();
    let mut help = false;
    let mut i = 0;
    while i < raw.len() {
        match raw[i].as_str() {
            "--connect" => {
                i += 1;
                args.connect = raw.get(i).cloned();
            }
            "--no-input" => args.no_input = true,
            "--list" => args.list_only = true,
            "--selftest" => args.selftest = true,
            "--preview-selftest" => args.preview_selftest = true,
            "--preview" => args.preview = true,
            "--no-preview" => args.no_preview = true,
            "--scan" => {
                args.scan = true;
                if raw.get(i + 1).is_some_and(|n| !n.starts_with("--")) {
                    i += 1;
                    args.subnet = raw.get(i).cloned();
                }
            }
            "--unmute" => args.unmute = true,
            "--audio-selftest" => args.audio_selftest = true,
            "--vcam" => args.vcam = true,
            "--vcam-selftest" => args.vcam_selftest = true,
            "--record" => args.record = true,
            "--version" | "-V" => args.version = true,
            "--install-vcam" => args.install_vcam = true,
            "--uninstall-vcam" => args.uninstall_vcam = true,
            "--uninstall-vcam-machine" => args.uninstall_vcam_machine = true,
            "--no-tray" => args.no_tray = true,
            // `--doctor [ip[:port]]`: the operand is optional and
            // position-sensitive, so it is consumed here rather than left to
            // fall through to the generic `--connect` handling.
            "--doctor" => {
                args.doctor = true;
                if raw.get(i + 1).is_some_and(|n| !n.starts_with("--")) {
                    i += 1;
                    args.connect = raw.get(i).cloned();
                }
            }
            "--help" | "-h" => help = true,
            _ => {}
        }
        i += 1;
    }
    if help {
        print_help();
        std::process::exit(0);
    }
    // The preview window opens by default; `--no-preview` is the opt-out.
    if !args.no_preview {
        args.preview = true;
    }
    args
}

#[cfg(test)]
mod arg_tests {
    use super::*;

    fn args(list: &[&str]) -> Args {
        parse_args_from(&list.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn flags_map_one_to_one() {
        let a = args(&["--vcam", "--no-input", "--no-tray", "--record", "--version"]);
        assert!(a.vcam && a.no_input && a.no_tray && a.record);
        assert!(!a.doctor && !a.scan && !a.selftest);
    }

    #[test]
    fn the_preview_window_is_on_unless_opted_out() {
        assert!(args(&[]).preview, "preview is the default");
        assert!(!args(&["--no-preview"]).preview);
    }

    #[test]
    fn connect_takes_the_next_argument() {
        assert_eq!(
            args(&["--connect", "10.0.0.2:1234"]).connect.as_deref(),
            Some("10.0.0.2:1234")
        );
        // A trailing flag with no value must not panic or invent a target.
        assert_eq!(args(&["--connect"]).connect, None);
    }

    #[test]
    fn doctor_operand_is_optional() {
        assert!(args(&["--doctor"]).doctor);
        assert_eq!(
            args(&["--doctor"]).connect,
            None,
            "bare --doctor browses mDNS"
        );

        let with_ip = args(&["--doctor", "192.168.31.5"]);
        assert!(with_ip.doctor);
        assert_eq!(with_ip.connect.as_deref(), Some("192.168.31.5"));
    }

    #[test]
    fn doctor_does_not_swallow_the_next_flag() {
        let a = args(&["--doctor", "--vcam"]);
        assert!(a.doctor && a.vcam);
        assert_eq!(a.connect, None, "--vcam is a flag, not a doctor operand");
    }

    #[test]
    fn scan_takes_an_optional_subnet() {
        let bare = args(&["--scan"]);
        assert!(bare.scan);
        assert_eq!(bare.subnet, None, "no operand means this PC's own LAN");

        let scoped = args(&["--scan", "192.168.32"]);
        assert!(scoped.scan);
        assert_eq!(scoped.subnet.as_deref(), Some("192.168.32"));

        let followed = args(&["--scan", "--vcam"]);
        assert!(followed.scan && followed.vcam);
        assert_eq!(followed.subnet, None);
    }

    #[test]
    fn unknown_arguments_are_ignored_rather_than_fatal() {
        let a = args(&["--nonsense", "--vcam"]);
        assert!(a.vcam);
    }

    /// The MSI uninstalls by invoking the machine-only flag. If it is not
    /// parsed, the flag falls through to the generic unknown-argument path and
    /// the custom action exits having done nothing — silently, because the MSI
    /// sets `Return="ignore"`. The ring file with its NULL DACL then survives
    /// every uninstall.
    #[test]
    fn the_machine_only_uninstall_flag_is_recognised() {
        let a = args(&["--uninstall-vcam-machine"]);
        assert!(a.uninstall_vcam_machine, "flag was swallowed");
        // It must not be mistaken for the full uninstall: that one deletes
        // per-user state, which under SYSTEM is the wrong user's.
        assert!(!a.uninstall_vcam);
    }

    #[test]
    fn the_three_camera_jobs_are_distinct_flags() {
        let a = args(&["--install-vcam"]);
        assert!(a.install_vcam && !a.uninstall_vcam && !a.uninstall_vcam_machine);
        let b = args(&["--uninstall-vcam"]);
        assert!(b.uninstall_vcam && !b.install_vcam && !b.uninstall_vcam_machine);
    }
}
