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
    /// Decode the H.264 stream and report frame counts, with no window.
    ///
    /// Exists because decoding and displaying were welded together: `main`
    /// built the pipeline `if args.preview || args.vcam`, so there was no way
    /// to run the media path on a machine that cannot open a window. That is
    /// the macOS-hosted parity run — `minifb` cannot create a Cocoa window
    /// there and aborts the whole process with "Rust cannot catch foreign
    /// exceptions", which is exactly what it does.
    pub decode_only: bool,
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
    /// One-shot: undo **only** the per-user bits, exit. Needs no rights, and
    /// must be run *impersonated* — the MSI's uninstall runs elevated, where
    /// `%APPDATA%` and `HKCU` are the system profile's, and cleaning those leaves
    /// the real user's tokens and autostart entry behind.
    pub uninstall_vcam_user: bool,
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
            "--decode-only" => args.decode_only = true,
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
            "--uninstall-vcam-user" => args.uninstall_vcam_user = true,
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
// `--decode-only` is an opt-out too, and that is the whole point of it: a
// mode called "decode only" that also opens a window is not decode-only, and
// on a machine with no display the window is the thing that kills the
// process. Passing `--decode-only --preview` explicitly still opens it —
// an explicit request wins over a default.
if !args.no_preview && !args.decode_only {
        args.preview = true;
    }
    args
}

impl Args {
    /// Whether the H.264 decode pipeline should run.
    ///
    /// Deliberately separate from `preview`. Two consumers want decoded
    /// frames — the preview window and the virtual camera — and now a third:
    /// a headless run that only needs to know the frames decode. Deriving
    /// this from `preview` is what made `--no-preview` also mean "do not
    /// decode", which silently removed the media path from every
    /// machine without a display.
    pub fn decode_pipeline_needed(&self) -> bool {
        self.preview || self.vcam || self.decode_only
    }
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

    /// `--decode-only` exists because the decode pipeline and the preview
    /// window were welded together: `main` built the pipeline
    /// `if args.preview || args.vcam`, so there was no way to run the media
    /// path on a machine that cannot open a window. That is exactly the
    /// macOS-hosted parity run — `minifb` cannot create a Cocoa window
    /// there and aborts the process with "Rust cannot catch foreign
    /// exceptions", taking the whole receiver with it.
    ///
    /// The invariant these two tests carry: **decoding and displaying are
    /// separate decisions.** A caller can verify frames decode without a
    /// display, and asking for no display must not silently stop decoding.
    #[test]
    fn decode_only_decodes_without_opening_a_window() {
        let a = args(&["--decode-only"]);
        assert!(a.decode_only, "the flag is parsed");
        assert!(!a.preview, "and it must NOT imply a window");
        assert!(
            Args::decode_pipeline_needed(&a),
            "the decode pipeline is exactly what this mode is for"
        );
    }

    /// The inverse must hold too, or `--decode-only` would be a
    /// `--no-preview` in disguise and the two flags would be
    /// indistinguishable at the call site.
    #[test]
    fn decode_only_is_not_the_same_thing_as_no_preview() {
        let quiet = args(&["--no-preview"]);
        assert!(!Args::decode_pipeline_needed(&quiet));
        assert!(!quiet.decode_only);
    }

    #[test]
    fn vcam_still_decodes_even_with_no_window() {
        // Pre-existing behaviour, pinned: the virtual camera is the second
        // consumer of decoded frames.
        let a = args(&["--vcam", "--no-preview"]);
        assert!(Args::decode_pipeline_needed(&a));
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

    /// Same argument for the user-side flag. Measured failure: an MSI uninstall
    /// left `%APPDATA%\RemoteCrab\tokens.json` — the saved pairing token — on
    /// disk, because nothing invoked the app's per-user cleanup.
    #[test]
    fn the_user_only_uninstall_flag_is_recognised() {
        let a = args(&["--uninstall-vcam-user"]);
        assert!(a.uninstall_vcam_user, "flag was swallowed");
        assert!(!a.uninstall_vcam, "must not trigger the machine-wide half");
        assert!(!a.uninstall_vcam_machine);
    }

    /// The four jobs are four distinct states. Collapsing any two of them is how
    /// the wrong user's data gets deleted, or how the ring file survives.
    #[test]
    fn the_four_camera_jobs_are_distinct_flags() {
        for (argv, pick) in [
            (&["--install-vcam"][..], 0usize),
            (&["--uninstall-vcam"][..], 1),
            (&["--uninstall-vcam-machine"][..], 2),
            (&["--uninstall-vcam-user"][..], 3),
        ] {
            let a = args(argv);
            let flags = [
                a.install_vcam,
                a.uninstall_vcam,
                a.uninstall_vcam_machine,
                a.uninstall_vcam_user,
            ];
            assert!(flags[pick], "{argv:?} did not set its own flag");
            assert_eq!(
                flags.iter().filter(|f| **f).count(),
                1,
                "{argv:?} set more than one: {flags:?}"
            );
        }
    }
}
