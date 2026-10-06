//! Status lines: the console's `[TAG] 鈥 line and the tray menu's
//! pill-language line, in both languages.

use rc_net::State;

use crate::i18n;

/// Compare what the phone says it is sending against what is actually arriving.
///
/// Returns `None` when the two agree, and a line naming the shortfall when they
/// do not. Kept pure and separate from the event loop because the loop is where
/// this was impossible to test — the numbers arrive over a socket and the
/// warning is only interesting when it is *absent*, which no integration test
/// can distinguish from "the code never ran".
///
/// The thresholds are deliberately loose (80% of the claimed rate, 50% of the
/// claimed bitrate). This is a "something is wrong" flag, not a quality
/// judgement: the only thing it must not do is cry wolf, because a warning that
/// appears when nothing is wrong is one people learn to ignore.
///
/// Why it exists: on iOS the advertised bitrate is *computed* from a property
/// that `Quality` overrides, so it does not describe the stream. Measured on a
/// real iPhone: claimed 30 fps / 9331 kbps, delivered 3.5 fps / 1878 kbps, while
/// the status line read "streaming @ 30fps". A receiver that only prints the
/// claim reports success for a stream delivering an eighth of it.
pub fn stream_shortfall(
    claimed_fps: f64,
    claimed_kbps: f64,
    got_fps: f64,
    got_kbps: f64,
) -> Option<String> {
    let fps_short = got_fps < claimed_fps * 0.8;
    let kbps_short = got_kbps < claimed_kbps * 0.5;
    if !fps_short && !kbps_short {
        return None;
    }
    Some(format!(
        "MEASURED {got_fps:.1} fps / {got_kbps:.0} kbps against a claim of {claimed_fps:.0} fps / {claimed_kbps:.0} kbps"
    ))
}

/// Human, localized copy for a failure. `State::Error` carries a
/// developer-facing English literal; a user should never see one
/// (AGENTS.md lesson 13).
fn error_text(reason: &str) -> String {
    match reason {
        "The iPhone denied the connection" => {
            i18n::t("iPhone 拒绝了连接", "The iPhone declined the connection").to_string()
        }
        // Not the same thing as a denial, and the difference is the user's
        // intent: they turned *this* computer off from the phone's computer
        // list. The remedy is a tap on the phone, not a fix on this machine.
        "The iPhone disconnected this computer" => i18n::t(
            "这台电脑已在 iPhone 上被断开。在 iPhone 的「选择电脑」里重新点一下这台，\
             或在托盘里点「重新连接」。",
            "This computer was disconnected on the iPhone. Pick it again under \
             \"Choose a computer\" on the phone, or hit Reconnect in the tray.",
        )
        .to_string(),
        "" => i18n::t("连接失败", "the connection failed").to_string(),
        // Anything unmatched is a developer-facing English literal from `rc-net`,
        // and this function exists precisely so a user never reads one — the
        // `other => other.to_string()` that used to be here was the very thing
        // the doc comment above warned about. The literal is still worth having,
        // so it goes to the log, which since the console was detached is a real
        // surface rather than a place nobody looks.
        other => {
            eprintln!("[status] unmapped failure reason: {other}");
            i18n::t(
                "连接失败（详情见日志）",
                "the connection failed — see the log for details",
            )
            .to_string()
        }
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
        State::Streaming {
            name, authenticated, ..
        } => {
            format!(
                "[LIVE]  {}{name}{}",
                i18n::t("正在投屏 ", "streaming from "),
                if *authenticated {
                    ""
                } else if i18n::is_chinese() {
                    "（未验证身份）"
                } else {
                    " (unverified)"
                }
            )
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

    /// Appended to a live session's line when the phone did not prove it holds
    /// the pairing token.
    ///
    /// Nothing at all when it did — which is the point. Any phone whose app
    /// predates the identity exchange still connects, because refusing it would
    /// turn a security improvement into an outage on the day it shipped, and this
    /// receiver has no way to update the phone. So the session is *allowed* and
    /// *labelled*: anyone on this network could have been the other end, and that
    /// is not something a status line should keep to itself.
    fn unverified_unless(authenticated: bool, zh: bool) -> &'static str {
        if authenticated {
            return "";
        }
        if zh {
            "（未验证身份）"
        } else {
            " (unverified)"
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
            format!(
                "{}{name} {dash} {waiting}",
                t(zh, "正在投屏 ", "Streaming from ")
            )
        }
        State::Streaming {
            name,
            latency_ms,
            authenticated,
        } if *latency_ms > 0 => {
            format!(
                "{}{name} · {latency_ms} ms{}",
                t(zh, "正在投屏 ", "Streaming from "),
                unverified_unless(*authenticated, zh)
            )
        }
        State::Streaming {
            name, authenticated, ..
        } => {
            format!(
                "{}{name}{}",
                t(zh, "正在投屏 ", "Streaming from "),
                unverified_unless(*authenticated, zh)
            )
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
mod stream_shortfall_tests {
    use super::stream_shortfall;

    /// The real capture: a phone that claimed 30 fps and 9331 kbps while
    /// delivering 3.5 fps and 1878 kbps, and the status line said
    /// "streaming @ 30fps". This is the line that should have been printed then.
    #[test]
    fn a_phone_sending_an_eighth_of_its_claim_is_called_out() {
        let line = stream_shortfall(30.0, 9331.0, 3.5, 1878.0).expect("should warn");
        assert!(line.contains("30 fps"), "the claim must be in the line: {line}");
        assert!(line.contains("9331"), "the claimed rate must be in it: {line}");
        assert!(line.contains("3.5"), "and what actually arrived: {line}");
        assert!(line.contains("1878"), "both figures, so the reader can compare: {line}");
    }

    /// A stream that matches its claim must say nothing. A warning that appears
    /// when nothing is wrong is one people learn to ignore, and this one has to
    /// survive a whole session of real use to be worth having.
    #[test]
    fn a_stream_that_matches_its_claim_is_silent() {
        assert_eq!(stream_shortfall(30.0, 9331.0, 29.8, 9100.0), None);
    }

    /// Just inside the tolerance. 30 fps claimed and 25 delivered is 83%, which
    /// is normal for a phone sharing a network, and warning there would be crying
    /// wolf on every single session.
    #[test]
    fn being_inside_the_tolerance_is_silent() {
        assert_eq!(stream_shortfall(30.0, 9331.0, 25.0, 4800.0), None);
    }

    /// Each dimension is judged on its own: a stream can hold its frame rate
    /// while collapsing in bitrate, or the reverse, and both are real faults.
    #[test]
    fn each_dimension_is_judged_independently() {
        assert!(
            stream_shortfall(30.0, 9331.0, 29.0, 900.0).is_some(),
            "bitrate collapsed, frame rate held"
        );
        assert!(
            stream_shortfall(30.0, 9331.0, 4.0, 9200.0).is_some(),
            "frame rate collapsed, bitrate held"
        );
    }

    /// A phone that claims nothing must not produce a warning. Metadata always
    /// arrives before video in practice, but a missing claim is not evidence of
    /// a fault.
    #[test]
    fn zero_claimed_produces_no_false_alarm() {
        assert_eq!(stream_shortfall(0.0, 0.0, 4.0, 900.0), None);
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
            authenticated: true,
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

    /// A session the phone did not prove must say so, in both languages, on both
    /// surfaces. Without this the flag rides through the state and reaches
    /// nobody, which is the same as not having it.
    #[test]
    fn an_unverified_session_says_so_and_a_verified_one_does_not() {
        let verified = State::Streaming {
            name: "iPhone".into(),
            latency_ms: 0,
            authenticated: true,
        };
        let unverified = State::Streaming {
            name: "iPhone".into(),
            latency_ms: 12,
            authenticated: false,
        };

        for zh in [true, false] {
            let marker = if zh { "未验证身份" } else { "unverified" };
            let quiet = tray_status(&verified, true, zh);
            let loud = tray_status(&unverified, true, zh);
            assert!(
                !quiet.contains(marker),
                "a proved session must not carry the warning (zh={zh}): {quiet}"
            );
            assert!(
                loud.contains(marker),
                "an unproved session must say so (zh={zh}): {loud}"
            );
        }

        // The console line reaches the same decision through a different
        // function, and it is the one a bug report quotes.
        let zh = crate::i18n::is_chinese();
        let marker = if zh { "未验证身份" } else { "unverified" };
        assert!(!state_line(&verified, true).contains(marker));
        assert!(state_line(&unverified, true).contains(marker));
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
            authenticated: true,
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
#[cfg(test)]
mod reply_copy_tests {
    use super::error_text;

    /// "The phone disconnected this computer" and "the phone denied the
    /// connection" are different events and must not share a sentence.
    ///
    /// The first is a user turning *this* PC off from the phone's computer list,
    /// and the remedy is a tap on the phone. The second is a refusal, and the
    /// remedy is on this machine. The receiver shipped the denial copy for both
    /// (`SessionReplyResult::Off` returned `ConnEndKind::Denied`), which tells
    /// the user they did something wrong when they did something deliberate.
    #[test]
    fn a_disconnect_does_not_read_like_a_refusal() {
        let denied = error_text("The iPhone denied the connection");
        let off = error_text("The iPhone disconnected this computer");
        assert_ne!(denied, off, "one sentence for two different events");
        assert!(off.contains("断开"), "says what happened: {off}");
        assert!(off.contains("选择电脑"), "and what to do about it: {off}");
    }

    /// And an unrecognised reason still reaches the user in their language,
    /// with the developer literal going to the log instead.
    #[test]
    fn an_unmapped_reason_is_not_shown_verbatim() {
        let line = error_text("Some internal English literal");
        assert!(!line.contains("Some internal English literal"), "{line}");
        assert!(!line.is_empty());
    }
}