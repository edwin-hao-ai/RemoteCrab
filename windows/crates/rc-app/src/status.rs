//! Status lines: the console's `[TAG] 鈥 line and the tray menu's
//! pill-language line, in both languages.

use rc_net::State;

use crate::i18n;

pub fn state_line(state: &State) -> String {
    match state {
        State::Searching => format!("[LOOKING]  {}", i18n::t("正在搜索 iPhone…", "searching for an iPhone…")),
        State::Connecting { name } => format!("[CONNECTING]  {}{name}…", i18n::t("正在连接 ", "connecting to ")),
        State::Handshaking { name } => format!("[CONNECTING]  {}{name}…", i18n::t("正在握手 ", "handshaking with ")),
        State::AwaitingApproval { name } => format!(
            "[CONNECTING]  {}{name}{}",
            i18n::t("请在 ", "waiting for you to approve on "),
            i18n::t(" 上确认…", "…")
        ),
        // NOTE: the label deliberately omits latency — including it made the
        // state line reprint on every 2 s ping (visual spam). Latency is
        // surfaced only for real spikes, by the Latency event handler.
        State::Streaming { name, .. } => format!("[LIVE]  {}{name}", i18n::t("正在投屏 ", "streaming from ")),
        State::Busy { owner } => {
            if i18n::is_chinese() {
                format!(
                    "[IN USE]  iPhone 已被 {owner} 占用。\n\
                     \x20          请在那边断开连接（菜单栏 → RemoteCrab → 断开连接，或 iPhone → 选择电脑），本机将自动连接。"
                )
            } else {
                format!(
                    "[IN USE]  {owner} is already connected to this iPhone.\n\
                     \x20          Disconnect there (menu bar → RemoteCrab → Disconnect, or iPhone → Choose a Mac)\n\
                     \x20          and this PC will connect automatically."
                )
            }
        }
        State::Error(reason) => format!("[OFFLINE]  {reason}"),
    }
}
/// One-line, pill-language status for the tray menu — same wording the Mac's
/// menu-bar popover and the iOS status pill use (`State::pill_label` /
/// `Status.latency`), without the console's [TAG] + wrapped explanation.
pub fn tray_status(state: &State) -> String {
    match state {
        State::Streaming { name, latency_ms } if *latency_ms > 0 => {
            format!("{}{name} · {latency_ms} ms", i18n::t("正在投屏 ", "Streaming from "))
        }
        State::Streaming { name, .. } => {
            format!("{}{name}", i18n::t("正在投屏 ", "Streaming from "))
        }
        State::AwaitingApproval { name } => {
            format!("{}{name}{}", i18n::t("请在 ", "Approve on "), i18n::t(" 上确认", ""))
        }
        State::Connecting { name } | State::Handshaking { name } => {
            format!("{}{name}…", i18n::t("正在连接 ", "Connecting to "))
        }
        State::Busy { owner } => {
            format!("{}{owner}{}", i18n::t("已被 ", "In use by "), i18n::t(" 占用", ""))
        }
        State::Searching => i18n::t("等待 iPhone…", "Waiting for an iPhone…").to_string(),
        State::Error(reason) => reason.clone(),
    }
}

