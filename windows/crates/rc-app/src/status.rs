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

pub fn state_line(state: &State, seen_frame: bool) -> String {
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
        //
        // `seen_frame` is whether a decoded frame has arrived at all this
        // session, and it is the difference between "streaming" and "claiming to
        // stream".
        //
        // `rc-phone-sim --scenario silent` reproduces the case: the phone
        // completes the handshake and then sends nothing at all. Without this
        // distinction the tray said "正在投屏" — a positive claim — indefinitely,
        // while not one frame arrived. No error, no warning, and nothing for the
        // user to act on, because from the protocol's point of view the
        // connection was perfect.
        State::Streaming { name, .. } if !seen_frame => {
            format!(
                "[LIVE]  {}{name} \u{2014} {}",
                i18n::t("已连接，", "connected, "),
                i18n::t("等待画面\u{2026}", "waiting for video\u{2026}")
            )
        }
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
///
/// # Why `zh` is a parameter and not an `i18n::t` lookup
///
/// This function used to render through the global `i18n::t`, and its test
/// asserted a **Chinese literal** against that output. So the test passed on a
/// Chinese-locale machine and failed on every other one — and this suite is run
/// from both (the project tests on a Mac and on the Windows box), which is how
/// it reached `main` broken.
///
/// A global locale lookup is the right thing for *rendering* and the wrong thing
/// for a *function under test*: it makes the result a property of the machine
/// rather than of the input. `doctor.rs` already threads an explicit `zh: bool`
/// through `panel` / `panel_summary` for exactly this reason, and this is now
/// the same shape. `i18n::t` remains the single place that knows the real
/// answer — the caller passes `i18n::is_chinese()`.
pub fn tray_status(state: &State, seen_frame: bool, zh: bool) -> String {
    // A named function rather than a closure: a closure with two independent
    // `&str` parameters cannot return either one, because their lifetimes do not
    // unify. Every string here is a literal, so `'static` is the honest bound.
    fn t(zh: bool, a: &'static str, b: &'static str) -> &'static str {
        if zh {
            a
        } else {
            b
        }
    }
    match state {
        // Before the latency arm: a round-trip number with not one frame
        // decoded is a measurement of nothing, and printing it would dress the
        // "waiting" state up as a working one.
        State::Streaming { name, .. } if !seen_frame => {
            let dash = "\u{2014}";
            let waiting = if zh {
                "已连接，等待画面…"
            } else {
                "connected, waiting for video\u{2026}"
            };
            format!("{}{name} {dash} {waiting}", t(zh, "正在投屏 ", "Streaming from "))
        }
        State::Streaming { name, latency_ms } if *latency_ms > 0 => {
            format!("{}{name} · {latency_ms} ms", t(zh, "正在投屏 ", "Streaming from "))
        }
        State::Streaming { name, .. } => {
            format!("{}{name}", t(zh, "正在投屏 ", "Streaming from "))
        }
        // See the note in `state_line`: the tap is on the iPhone.
        State::AwaitingApproval { name } => {
            let (a, b) = if zh {
                (format!("请在 iPhone 上允许「{name}」"), String::new())
            } else {
                (String::new(), format!("Allow \"{name}\" on the iPhone"))
            };
            if zh {
                a
            } else {
                b
            }
        }
        State::Connecting { name } | State::Handshaking { name } => {
            format!("{}{name}…", t(zh, "正在连接 ", "Connecting to "))
        }
        State::Busy { owner } => {
            format!("{}{owner}{}", t(zh, "已被 ", "In use by "), t(zh, " 占用", ""))
        }
        State::Searching => t(zh, "等待 iPhone…", "Waiting for an iPhone…").to_string(),
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
        }, true);
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
        }, true);
        let mentions_switch = s.contains("选择电脑") || s.contains("Choose a computer");
        assert!(
            mentions_switch,
            "the phone-side switch is the only path that always works: {s}"
        );
    }
}
#[cfg(test)]
mod no_video_tests {
    use super::{state_line, tray_status};
    use rc_net::State;

    fn streaming() -> State {
        State::Streaming {
            name: "iPhone".into(),
            latency_ms: 0,
        }
    }

    /// The bug, as a test. `rc-phone-sim --scenario silent` handshakes and then
    /// sends nothing: no error, no event, no warning. Both surfaces used to
    /// answer with an unqualified "streaming", which is a positive claim about
    /// something that was not happening.
    ///
    /// The tray arm is checked over **both** languages, because `tray_status`
    /// used to read the global locale while this assertion hard-coded Chinese —
    /// so the test passed on a Chinese machine and failed everywhere else, which
    /// is how it reached `main` broken. `state_line` still reads the global
    /// locale (it is console output, and there is nothing to parameterise from
    /// here), so it is checked against the locale it will actually use.
    #[test]
    fn a_connected_phone_that_sends_nothing_does_not_say_streaming() {
        let console = state_line(&streaming(), false);
        let console_waiting = if crate::i18n::is_chinese() {
            "等待画面"
        } else {
            "waiting for video"
        };
        assert!(
            console.contains(console_waiting),
            "the console line does not say it is waiting: {console}"
        );

        for zh in [true, false] {
            let waiting = if zh { "等待画面" } else { "waiting for video" };
            let streaming_word = if zh { "正在投屏" } else { "Streaming from" };
            let line = tray_status(&streaming(), false, zh);
            assert!(
                !line.contains(streaming_word) || line.contains(waiting),
                "claims to be streaming with no frames (zh={zh}): {line}"
            );
            assert!(
                line.contains(waiting),
                "does not say it is waiting (zh={zh}): {line}"
            );
        }
    }

    /// And the converse must stay true, or the fix has simply swapped one lie
    /// for another.
    #[test]
    fn a_connected_phone_that_is_sending_says_so_plainly() {
        let console = state_line(&streaming(), true);
        let console_waiting = if crate::i18n::is_chinese() {
            "等待画面"
        } else {
            "waiting for video"
        };
        assert!(
            !console.contains(console_waiting),
            "the console says it is waiting while frames arrive: {console}"
        );
        for zh in [true, false] {
            let waiting = if zh { "等待画面" } else { "waiting for video" };
            let line = tray_status(&streaming(), true, zh);
            assert!(
                !line.contains(waiting),
                "says it is waiting while frames are arriving (zh={zh}): {line}"
            );
        }
    }

    /// Latency with zero decoded frames measures nothing, so it must not appear
    /// in place of the waiting notice.
    ///
    /// This is the assertion that failed on a non-Chinese machine and passed on a
    /// Chinese one — the whole test's verdict was a property of the locale, not
    /// of the code. Both languages are checked now, so neither machine can be the
    /// one that hides a regression.
    #[test]
    fn a_latency_reading_never_replaces_the_waiting_notice() {
        let with_ping = State::Streaming {
            name: "iPhone".into(),
            latency_ms: 12,
        };
        for zh in [true, false] {
            let waiting = if zh { "等待画面" } else { "waiting for video" };
            let line = tray_status(&with_ping, false, zh);
            assert!(line.contains(waiting), "zh={zh} {line}");
            assert!(!line.contains("12 ms"), "zh={zh} {line}");
            // With frames, the same reading is worth showing.
            assert!(
                tray_status(&with_ping, true, zh).contains("12 ms"),
                "zh={zh}: the reading vanished once frames arrived"
            );
        }
    }

    /// The tray row is the whole product on Windows — there is no main window —
    /// so it has to render in the language it claims to. Asserting a Chinese
    /// literal against an English render is how the test above was passing on the
    /// wrong machine.
    #[test]
    fn the_tray_row_renders_in_the_language_it_is_asked_for() {
        let zh = tray_status(&streaming(), false, true);
        let en = tray_status(&streaming(), false, false);
        assert!(zh.contains("等待画面"), "{zh}");
        assert!(en.contains("waiting for video"), "{en}");
        assert!(!en.contains("等待画面"), "English row leaked Chinese: {en}");
        assert!(!zh.contains("waiting for video"), "Chinese row leaked English: {zh}");
    }
}