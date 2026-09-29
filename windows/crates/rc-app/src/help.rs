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
    ("--connect IP[:P]", "直接连接（mDNS 被拦截时）", "Connect directly (when mDNS is blocked)"),
    ("--no-input", "只看不操作（不控制本机）", "Watch only (do not drive this PC)"),
    ("--no-preview", "只显示状态，不开视频窗口", "Console status only (no video window)"),
    ("--list", "列出已发现的 iPhone 并等待", "List discovered iPhones and wait"),
    ("--selftest", "本地假 iPhone 自检整条链路", "Run a fake iPhone locally and verify the pipeline"),
    ("--preview-selftest", "把假 H.264 喂进预览窗口验证解码", "Stream fake H.264 into the preview window and verify decode"),
    ("--scan [subnet]", "扫描本机（或指定）网段中 8765 端口的 iPhone", "Scan this PC's (or a given) /24 for an iPhone on port 8765"),
    ("--audio-selftest", "生成测试音 → 编码 Opus → 解码播放", "Generate a tone, encode to Opus, decode, and play it"),
    ("--vcam", "把画面发布为 \"RemoteCrab\" 虚拟摄像头", "Publish the video to a \"RemoteCrab\" virtual camera"),
    ("--vcam-selftest", "给虚拟摄像头喂动态测试图（无需手机）", "Feed a moving test pattern to the virtual camera (no phone)"),
    ("--unmute", "把 iPhone 麦克风播到本机扬声器", "Play the iPhone mic on this PC's speakers"),
    ("--record", "录制当前画面（见下方 record 命令）", "Record the live stream (see `record` below)"),
    ("--doctor [ip[:port]]", "诊断“为什么连不上 iPhone”并给出解决办法", "Explain why the iPhone will not connect, and what to do about it"),
    ("--no-tray", "不显示托盘图标", "Skip the notification-area tray icon"),
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
    ("clipboard", "把本机剪贴板发到 iPhone", "Send this PC's clipboard to the iPhone"),
    ("record", "开始 / 停止录制", "Start / stop recording"),
    ("autostart", "开机自启动开关", "Toggle start at login"),
    ("help", "显示这份帮助", "Show this help"),
    ("doctor [ip[:port]]", "诊断连接问题（见上方 --doctor）", "Diagnose the connection (see --doctor above)"),
    ("quit", "退出", "Quit"),
];
pub fn print_help() {
    println!("RemoteCrab for Windows\n");
    println!("{}", i18n::t("用法：", "Usage:"));
    let wide = USAGE.iter().map(|(a, _, _)| a.chars().count()).max().unwrap_or(0);
    for (arg, zh, en) in USAGE {
        let desc = i18n::t(zh, en);
        println!("  {arg:<wide$}  {desc}", wide = wide + 1);
    }
    println!();
    println!(
        "{}",
        i18n::t(
            "运行时可以输入下面这些控制台命令（回车确认）：",
            "While running, type these console commands (then Enter):"
        )
    );
    print_console_help();
    println!();
    println!(
        "{}",
        i18n::t(
            "请先打开 RemoteCrab iOS app；两台设备必须在同一 WiFi 下。",
            "Run the RemoteCrab iOS app first; both devices must share the same WiFi."
        )
    );
}
pub fn print_console_help() {
    println!(
        "  {}",
        i18n::t("命令：", "commands:")
    );
    let wide = COMMANDS.iter().map(|(c, _, _)| c.chars().count()).max().unwrap_or(0);
    for (cmd, zh, en) in COMMANDS {
        let desc = i18n::t(zh, en);
        println!("  {cmd:<wide$}  {desc}", wide = wide + 1);
    }
}

