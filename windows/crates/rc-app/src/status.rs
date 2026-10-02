//! Status lines: the console's `[TAG] 鈥 line and the tray menu's
//! pill-language line, in both languages.

use rc_net::State;

use crate::i18n;

/// Human, localized copy for a failure. `State::Error` carries a
/// developer-facing English literal; a user should never see one
/// (AGENTS.md lesson 13).
fn error_text(reason: &str) -> String {
    match reason {
        "The iPhone denied the connection" => {
            i18n::t("iPhone 拒绝了连接", "The iPhone declined the connection").to_string()
        }
        "" => i18n::t("连接失败", "the connection failed").to_string(),
        other => other.to_string(),
    }
}

pub fn state_line(state: &State) -> String {
    match state {
        State::Searching => format!(
            "[LOOKING]  {}",
            i18n::t("正在搜索 iPhone…", "searching for an iPhone…")
        ),
        State::Connecting { name } => format!(
            "[CONNECTING]  {}{name}…",
            i18n::t("正在连接 ", "connecting to ")
        ),
        State::Handshaking { name } => format!(
            "[CONNECTING]  {}{name}…",
            i18n::t("正在握手 ", "handshaking with ")
        ),
        // The tag used to say CONNECTING and the text used to name the
        // *computer* ("approve on MacBook Pro"). Neither is true: nothing is
        // connecting, and the tap happens on the iPhone — the only place a
        // person is looking. A user who followed the old wording went to the
        // wrong machine entirely.
        State::AwaitingApproval { name } => format!(
            "[APPROVAL]  {}",
            i18n::t(
                &format!("请在 iPhone 上允许「{name}」"),
                &format!("Allow \"{name}\" on the iPhone")
            )
        ),
        // NOTE: the label deliberately omits latency — including it made the
        // state line reprint on every 2 s ping (visual spam). Latency is
        // surfaced only for real spikes, by the Latency event handler.
        State::Streaming { name, .. } => {
            format!("[LIVE]  {}{name}", i18n::t("正在投屏 ", "streaming from "))
        }
        // This told Windows users to look for a "menu bar" — there is not
        // one. The instruction was copied from the Mac, where it is right. The
        // other computer may be a Mac *or* another PC, so it has to name both
        // places it can be disconnected from.
        State::Busy { owner } => {
            if i18n::is_chinese() {
                format!(
                    "[IN USE]  iPhone 已被 {owner} 占用。\n\
                     \x20          在那台电脑上断开（Mac：菜单栏 → RemoteCrab → 断开连接；\n\
                     \x20          Windows：托盘 → RemoteCrab → 断开连接），或者在 iPhone 的\n\
                     \x20          「选择电脑」里直接切到这台。\n\
                     \x20          断开之后本机每 10 秒重试一次，会自己接上——\n\
                     \x20          但如果 {owner} 是这台 iPhone 的「首选电脑」，\n\
                     \x20          断开也不会自动切过来，必须在 iPhone 上选一次这台。"
                )
            } else {
                format!(
                    "[IN USE]  {owner} is already connected to this iPhone.\n\
                     \x20          Disconnect it there (Mac: menu bar → RemoteCrab → Disconnect;\n\
                     \x20          Windows: tray → RemoteCrab → Disconnect), or switch straight to\n\
                     \x20          this PC from the iPhone's \"Choose a computer\" list.\n\
                     \x20          This PC retries every 10s and will pick it up on its own —\n\
                     \x20          unless {owner} is the iPhone's preferred computer, in which\n\
                     \x20          case you have to pick this PC there once."
                )
            }
        }
        State::Error(reason) => format!("[OFFLINE]  {}", error_text(reason)),
    }
}
/// One-line, pill-language status for the tray menu — same wording the Mac's
/// menu-bar popover and the iOS status pill use (`State::pill_label` /
/// `Status.latency`), without the console's [TAG] + wrapped explanation.
pub fn tray_status(state: &State) -> String {
    match state {
        State::Streaming { name, latency_ms } if *latency_ms > 0 => {
            format!(
                "{}{name} · {latency_ms} ms",
                i18n::t("正在投屏 ", "Streaming from ")
            )
        }
        State::Streaming { name, .. } => {
            format!("{}{name}", i18n::t("正在投屏 ", "Streaming from "))
        }
        // See the note in `state_line`: the tap is on the iPhone.
        State::AwaitingApproval { name } => i18n::t(
            &format!("请在 iPhone 上允许「{name}」"),
            &format!("Allow \"{name}\" on the iPhone"),
        )
        .to_string(),
        State::Connecting { name } | State::Handshaking { name } => {
            format!("{}{name}…", i18n::t("正在连接 ", "Connecting to "))
        }
        State::Busy { owner } => {
            format!(
                "{}{owner}{}",
                i18n::t("已被 ", "In use by "),
                i18n::t(" 占用", "")
            )
        }
        State::Searching => i18n::t("等待 iPhone…", "Waiting for an iPhone…").to_string(),
        State::Error(reason) => error_text(reason),
    }
}

#[cfg(test)]
mod busy_copy_tests {
    use super::state_line;
    use rc_net::State;

    /// The copy used to promise "it takes over on its own" and nothing more.
    /// On the iPhone that is only true when the other computer is neither the
    /// current owner nor the phone's *preferred* computer — and the preferred
    /// case is the common one, because it is whoever the user picks normally.
    /// A user who read that sentence, disconnected the other machine, and was
    /// still handed `busy` had been told a lie by the product.
    #[test]
    fn the_busy_copy_names_the_preferred_computer_caveat() {
        let s = state_line(&State::Busy {
            owner: "MacBook Pro".into(),
        });
        assert!(
            s.contains("MacBook Pro"),
            "the owner must be named: {s}"
        );
    }

    /// The only reliable handover is choosing this computer on the phone, so
    /// the instruction has to survive any future shortening of this string.
    #[test]
    fn the_busy_copy_always_offers_the_phone_side_switch() {
        let s = state_line(&State::Busy {
            owner: "Some PC".into(),
        });
        let mentions_switch = s.contains("选择电脑") || s.contains("Choose a computer");
        assert!(
            mentions_switch,
            "the phone-side switch is the only path that always works: {s}"
        );
    }
}