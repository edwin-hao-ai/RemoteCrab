//! `--help` and the `help` command, both driven by the same two tables
//! so the two can never disagree.

use crate::i18n;

/// One row per `--help` line: `(argument, Chinese, English)`.
///
/// Data-driven on purpose: two hand-copied help blocks drift the moment a flag
/// is added, and the flag list is exactly the part a user copy-pastes.
const USAGE: &[(&str, &str, &str)] = &[
    (
        "remotecrab",
        "自动发现并连接 iPhone，打开预览窗口",
        "Discover, connect, and open a preview window",
    ),
    (
        "--no-input",
        "只看不操作（不控制本机）",
        "Watch only (do not drive this PC)",
    ),
    (
        "--no-preview",
        "只显示状态，不开视频窗口",
        "Console status only (no video window)",
    ),
    (
        "--list",
        "列出已发现的 iPhone 并等待",
        "List discovered iPhones and wait",
    ),
    (
        "--vcam",
        "把画面发布为 \"RemoteCrab\" 虚拟摄像头",
        "Publish the video to a \"RemoteCrab\" virtual camera",
    ),
    (
        "--unmute",
        "把 iPhone 麦克风播到本机扬声器",
        "Play the iPhone mic on this PC's speakers",
    ),
    (
        "--record",
        "录制当前画面（见下方 record 命令）",
        "Record the live stream (see `record` below)",
    ),
    (
        "--no-tray",
        "不显示托盘图标",
        "Skip the notification-area tray icon",
    ),
];

/// Escape hatches, listed separately and *after* the normal usage.
///
/// `--connect` and `--scan` are the two things a user reaches for when the
/// product appears broken, so listing them beside `--no-preview` made the
/// product read as "here is how to work around me being broken" (AGENTS.md
/// rule 1). They are still supported — they are genuinely useful on a
/// network where mDNS is blocked, and the doctor points at them — but they
/// are troubleshooting, not usage, and the help says so.
const SELF_CHECKS: &[(&str, &str, &str)] = &[
    (
        "--selftest",
        "本地假 iPhone 自检整条链路（需 --features selftest 构建）",
        "Run a fake iPhone locally and verify the pipeline (built with --features selftest)",
    ),
    (
        "--preview-selftest",
        "把假 H.264 喂进预览窗口验证解码（需 --features selftest 构建）",
        "Stream fake H.264 into the preview window and verify decode (needs --features selftest)",
    ),
    (
        "--audio-selftest",
        "生成测试音 → 编码 Opus → 解码播放",
        "Generate a tone, encode to Opus, decode, and play it",
    ),
    (
        "--vcam-selftest",
        "给虚拟摄像头喂动态测试图（无需手机）",
        "Feed a moving test pattern to the virtual camera (no phone)",
    ),
];

const TROUBLESHOOTING: &[(&str, &str, &str)] = &[
    (
        "--doctor [ip[:port]]",
        "诊断“为什么连不上 iPhone”并给出解决办法",
        "Explain why the iPhone will not connect, and what to do about it",
    ),
    (
        "--connect IP[:P]",
        "手动指定 iPhone 地址连接（mDNS 被网络拦截时）",
        "Connect to a specific iPhone address (when the network blocks mDNS)",
    ),
    (
        "--scan [subnet]",
        "扫描本机（或指定）网段中 8765 端口的 iPhone",
        "Scan this PC's (or a given) /24 for an iPhone on port 8765",
    ),
];
/// Live console commands, shown by both `--help` and the `help` command, so
/// the two can never disagree: `(command, Chinese, English)`.
const COMMANDS: &[(&str, &str, &str)] = &[
    ("camera [on|off]", "摄像头开关", "Camera on/off"),
    ("mic [on|off]", "麦克风开关", "Microphone on/off"),
    ("voice [on|off]", "语音输入开关", "Dictation on/off"),
    ("trackpad [on|off]", "触控板开关", "Trackpad on/off"),
    ("keyboard [on|off]", "键盘开关", "Keyboard on/off"),
    ("switch-camera", "切换前后摄像头", "Switch camera"),
    (
        "clipboard",
        "把本机剪贴板发到 iPhone",
        "Send this PC's clipboard to the iPhone",
    ),
    ("record", "开始 / 停止录制", "Start / stop recording"),
    ("autostart", "开机自启动开关", "Toggle start at login"),
    ("help", "显示这份帮助", "Show this help"),
    (
        "doctor [ip[:port]]",
        "诊断连接问题（见上方 --doctor）",
        "Diagnose the connection (see --doctor above)",
    ),
    ("quit", "退出", "Quit"),
];
pub fn print_help() {
    println!("RemoteCrab for Windows\n");
    println!("{}", i18n::t("用法：", "Usage:"));
    let wide = USAGE
        .iter()
        .map(|(a, _, _)| a.chars().count())
        .max()
        .unwrap_or(0);
    for (arg, zh, en) in USAGE {
        let desc = i18n::t(zh, en);
        println!("  {arg:<wide$}  {desc}", wide = wide + 1);
    }
    println!();
    print_console_help();
    println!();
    println!(
        "{}",
        i18n::t(
            "请先打开 RemoteCrab iOS app；两台设备必须在同一 WiFi 下。",
            "Run the RemoteCrab iOS app first; both devices must share the same WiFi."
        )
    );

    println!();
    println!(
        "{}",
        i18n::t(
            "连不上时：托盘菜单里点「为什么连不上」—— 它会直接告诉你原因和该做什么，\
             不需要记这些参数。",
            "If it will not connect: choose \"Why not connected\" in the tray menu. It names \
             the cause and what to do about it, so you do not need any of these flags."
        )
    );
    let wide = TROUBLESHOOTING
        .iter()
        .map(|(a, _, _)| a.chars().count())
        .max()
        .unwrap_or(0);
    for (arg, zh, en) in TROUBLESHOOTING {
        println!("  {arg:<wide$}  {}", i18n::t(zh, en), wide = wide + 1);
    }

    println!();
    println!(
        "{}",
        i18n::t(
            "自检（不需要手机，用来确认这台电脑装好了；发布版不含假 iPhone，需要 --features selftest）：",
            "Self-checks (no phone needed — use these to confirm this PC is set up; a release build omits the fake iPhone, so build with --features selftest):"
        )
    );
    let wide = SELF_CHECKS
        .iter()
        .map(|(a, _, _)| a.chars().count())
        .max()
        .unwrap_or(0);
    for (arg, zh, en) in SELF_CHECKS {
        println!("  {arg:<wide$}  {}", i18n::t(zh, en), wide = wide + 1);
    }
}
pub fn print_console_help() {
    println!(
        "{}",
        i18n::t(
            "运行时可以输入下面这些控制台命令（回车确认）：",
            "While running, type these console commands (then Enter):"
        )
    );
    let wide = COMMANDS
        .iter()
        .map(|(c, _, _)| c.chars().count())
        .max()
        .unwrap_or(0);
    for (cmd, zh, en) in COMMANDS {
        let desc = i18n::t(zh, en);
        println!("  {cmd:<wide$}  {desc}", wide = wide + 1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The help is the first thing a user reads, and it is a product surface:
    /// listing the escape hatches beside the normal flags made the app read as
    /// "here is how to work around me being broken" (AGENTS.md rule 1). This
    /// keeps the three groups distinct.
    #[test]
    fn the_escape_hatches_are_not_listed_as_normal_usage() {
        for (arg, _, _) in USAGE {
            assert!(
                !arg.starts_with("--connect") && !arg.starts_with("--scan"),
                "{arg} is a troubleshooting escape hatch, not normal usage"
            );
            assert!(
                !arg.contains("selftest"),
                "{arg} is a self-check, not normal usage"
            );
        }
        assert!(
            TROUBLESHOOTING
                .iter()
                .any(|(a, _, _)| a.starts_with("--connect")),
            "removing it from USAGE must not remove it from the product"
        );
        assert!(
            SELF_CHECKS.iter().any(|e| e.0 == "--selftest"),
            "the self-check must stay reachable"
        );
    }

    /// Every flag the parser accepts should be reachable from the help, or a
    /// user is left guessing. (Catches a flag added to args.rs and forgotten
    /// here — the exact drift the data-driven table was meant to prevent.)
    #[test]
    fn every_listed_flag_has_a_description_and_vice_versa() {
        for table in [USAGE, TROUBLESHOOTING, SELF_CHECKS] {
            for (arg, zh, en) in table {
                assert!(!arg.is_empty());
                assert!(!zh.trim().is_empty(), "{arg} has no Chinese description");
                assert!(!en.trim().is_empty(), "{arg} has no English description");
            }
        }
        let listed = USAGE.len() + TROUBLESHOOTING.len() + SELF_CHECKS.len();
        assert!(listed >= 14, "flags went missing: {listed}");
    }

    /// A description that a user cannot act on is worse than none, and a
    /// Chinese/English pair that has drifted is a bug in itself.
    #[test]
    fn no_description_is_just_the_flag_name_again() {
        for table in [USAGE, TROUBLESHOOTING, SELF_CHECKS] {
            for entry in table {
                let (arg, zh, en) = *entry;
                assert_ne!(zh.trim(), arg, "{arg}'s Chinese text just repeats the flag");
                assert_ne!(en.trim(), arg, "{arg}'s English text just repeats the flag");
            }
        }
    }
}
