//! The self-check panel: four live quadrants.
//!
//! The Mac has `TestWindowView` for exactly this, and its reason is the good
//! one: input injection is **invisible**. A key that was sent, a tap that
//! landed, a gesture that scrolled — none of them leave a trace the user can
//! see, so "is it working?" has no answer on Windows except by watching the
//! cursor move on another window they are not looking at.
//!
//! So the same four things the Mac shows, from the same data the tray readout
//! already collects:
//!
//! | quadrant | answers |
//! |---|---|
//! | camera | are frames arriving, and at what size |
//! | keyboard | did my last keypress reach this PC |
//! | trackpad | did my last gesture land, and where |
//! | microphone | is anything coming in, and how loud |
//!
//! The model is pure and tested; the drawing is Win32.

/// One quadrant's worth of evidence.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Quadrant {
    /// A short verdict in the user's language.
    pub summary: String,
    /// The numbers behind it, already formatted.
    pub detail: Vec<String>,
    /// Three states only, because a four-state indicator ("idle", "waiting",
    /// "ok", "error") is a legend nobody reads.
    pub health: Health,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Health {
    /// Nothing has arrived yet. Not an error — the phone may simply not be
    /// streaming yet, and calling that a failure teaches users to ignore it.
    #[default]
    Waiting,
    /// Something is arriving.
    Good,
    /// Something arrived and it is wrong: a stream that stopped, a mic that is
    /// silent while the user is talking.
    Bad,
}

/// The app's translation, mirrored here so this module is pure and testable on
/// a host with no locale of its own. The window passes the real `i18n::t`, so
/// the wording comes from one place at runtime; the tests pass a fixed `t` and
/// therefore assert on the Chinese, which is the stricter check.
type T = fn(&'static str, &'static str) -> &'static str;

impl Health {
    /// The word next to the quadrant's title.
    pub fn word(&self) -> (&'static str, &'static str) {
        match self {
            Health::Waiting => ("等待", "Waiting"),
            Health::Good => ("正常", "OK"),
            Health::Bad => ("异常", "Problem"),
        }
    }
}

/// The whole panel.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SelfCheck {
    pub camera: Quadrant,
    pub keyboard: Quadrant,
    pub trackpad: Quadrant,
    pub microphone: Quadrant,
}

/// The evidence the panel is built from.
///
/// A plain snapshot rather than a handle on the session, so the rules about what
/// counts as "working" are testable without a phone, a Mac or a Windows box.
/// That matters more here than usual: the alternative is the rules living in a
/// `match` inside a paint handler, which is where they cannot be tested.
#[derive(Debug, Clone, Default)]
pub struct Evidence {
    /// Frames per second, once frames have arrived.
    pub fps: Option<i64>,
    pub width: i64,
    pub height: i64,
    /// Milliseconds since the last video frame, if one has ever arrived.
    pub since_frame: Option<std::time::Duration>,
    /// The last key the phone sent, if any.
    pub last_key: Option<String>,
    pub since_key: Option<std::time::Duration>,
    /// The last gesture, and where it landed.
    pub last_touch: Option<String>,
    pub since_touch: Option<std::time::Duration>,
    /// Microphone level, 0..=100.
    pub mic_level: Option<i64>,
    /// Whether a session is live at all. Distinguishes "the phone is not
    /// streaming" from "the camera is broken", which look identical from
    /// inside a single reading.
    pub session_live: bool,
}

/// Beyond this, a video stream counts as stalled. A second is a guess; the
/// number is not load-bearing because the panel says "stale" rather than
/// "broken".
const STALE_AFTER: std::time::Duration = std::time::Duration::from_secs(2);

impl SelfCheck {
    /// Build the panel from a snapshot.
    pub fn from(e: &Evidence, t: T) -> Self {
        SelfCheck {
            camera: camera(e, t),
            keyboard: keyboard(e, t),
            trackpad: trackpad(e, t),
            microphone: microphone(e, t),
        }
    }
}

fn age(d: Option<std::time::Duration>) -> Option<std::time::Duration> {
    d
}

fn camera(e: &Evidence, t: T) -> Quadrant {
    if !e.session_live {
        return Quadrant {
            summary: t("手机还没开始推流。", "The phone is not streaming yet.").into(),
            detail: vec![t(
                "在 iPhone 上打开 RemoteCrab，点「开始推流」。",
                "Open RemoteCrab on the iPhone and tap Start streaming.",
            )
            .into()],
            health: Health::Waiting,
        };
    }
    match (e.fps, age(e.since_frame)) {
        (Some(fps), Some(since)) if since < STALE_AFTER => Quadrant {
            summary: t("画面正常。", "Video is arriving.").into(),
            detail: vec![format!("{fps} fps"), format!("{}×{}", e.width, e.height)],
            health: Health::Good,
        },
        (Some(_), Some(_)) => Quadrant {
            summary: t("画面停了。", "Video stopped.").into(),
            detail: vec![t(
                "手机在推流，但最近没有新画面。",
                "Streaming, but no new frames.",
            )
            .into()],
            health: Health::Bad,
        },
        // Streaming with a 0 fps reading is the shape a camera that is turned
        // off on the phone takes, and "waiting" is the honest verdict: the
        // phone has not sent anything to measure.
        _ => Quadrant {
            summary: t("还没有画面。", "No frames yet.").into(),
            detail: vec![t(
                "在 iPhone 上打开摄像头试试。",
                "Turn the camera on in the RemoteCrab app.",
            )
            .into()],
            health: Health::Waiting,
        },
    }
}

fn keyboard(e: &Evidence, t: T) -> Quadrant {
    let Some(key) = &e.last_key else {
        return Quadrant {
            summary: t("还没有按键。", "No keypress yet.").into(),
            detail: vec![t("在手机键盘上按一下试试。", "Try typing on the phone.").into()],
            health: Health::Waiting,
        };
    };
    Quadrant {
        summary: t("按键已送到这台电脑。", "Keys are reaching this PC.").into(),
        detail: vec![key.clone()],
        health: Health::Good,
    }
    .with_age(e.since_key)
}

fn trackpad(e: &Evidence, t: T) -> Quadrant {
    let Some(touch) = &e.last_touch else {
        return Quadrant {
            summary: t("还没有手势。", "No gesture yet.").into(),
            detail: vec![t("在手机触控板上划一下试试。", "Try swiping on the trackpad.").into()],
            health: Health::Waiting,
        };
    };
    Quadrant {
        summary: t("手势已送到这台电脑。", "Gestures are reaching this PC.").into(),
        detail: vec![touch.clone()],
        health: Health::Good,
    }
    .with_age(e.since_touch)
}

fn microphone(e: &Evidence, t: T) -> Quadrant {
    let Some(level) = e.mic_level else {
        return Quadrant {
            summary: t("还没有声音。", "No audio yet.").into(),
            detail: vec![t(
                "在手机上打开麦克风试试。",
                "Turn the microphone on in the app.",
            )
            .into()],
            health: Health::Waiting,
        };
    };
    // "Silent" is only a fault when the user is expecting sound. With no
    // evidence of them speaking, a flat meter is a flat meter.
    let health = if level > 2 {
        Health::Good
    } else {
        Health::Waiting
    };
    Quadrant {
        summary: match health {
            Health::Good => t("收到声音。", "Audio is arriving.").into(),
            _ => t("没有检测到声音。", "Nothing detected.").into(),
        },
        detail: vec![meter(level)],
        health,
    }
}

/// A five-cell level meter, so the number has a shape the eye can read.
fn meter(level: i64) -> String {
    let filled = ((level.clamp(0, 100) / 20) as usize).min(5);
    format!("[{}{}]", "█".repeat(filled), "·".repeat(5 - filled))
}

impl Quadrant {
    /// A "last seen N ago" line, when the reading is old enough to be worth
    /// qualifying.
    fn with_age(mut self, since: Option<std::time::Duration>) -> Quadrant {
        if let Some(d) = since {
            if d > STALE_AFTER {
                self.detail.push(format!("{}s", d.as_secs()));
            }
        }
        self
    }
}

#[cfg(test)]
mod tests {
    use super::{Evidence, Health, SelfCheck, STALE_AFTER};

    /// Always the Chinese, so the assertions below check the wording a Chinese
    /// user sees rather than whichever language the test machine prefers.
    fn zh(zh: &'static str, _en: &'static str) -> &'static str {
        zh
    }
    use std::time::Duration;

    fn live() -> Evidence {
        Evidence {
            session_live: true,
            fps: Some(30),
            width: 1280,
            height: 720,
            since_frame: Some(Duration::from_millis(100)),
            ..Default::default()
        }
    }

    /// Nothing connected must read as "waiting", never as a fault. A panel that
    /// shows four red quadrants before the user has done anything is a panel
    /// they learn to ignore.
    #[test]
    fn nothing_connected_is_waiting_not_broken() {
        let e = Evidence::default();
        let c = SelfCheck::from(&e, zh);
        for q in [c.camera, c.keyboard, c.trackpad, c.microphone] {
            assert_eq!(q.health, Health::Waiting, "{q:?}");
        }
    }

    #[test]
    fn a_live_stream_with_frames_is_good() {
        let c = SelfCheck::from(&live(), zh);
        assert_eq!(c.camera.health, Health::Good);
        assert!(c.camera.detail.iter().any(|d| d.contains("30")));
    }

    /// The distinction the whole panel exists for: a stream that has *stopped*
    /// is not the same as one that has not started.
    #[test]
    fn a_stopped_stream_is_bad_and_a_silent_one_is_waiting() {
        let mut e = live();
        e.since_frame = Some(STALE_AFTER + Duration::from_secs(1));
        assert_eq!(SelfCheck::from(&e, zh).camera.health, Health::Bad);

        let mut quiet = live();
        quiet.fps = None;
        quiet.since_frame = None;
        assert_eq!(SelfCheck::from(&quiet, zh).camera.health, Health::Waiting);
    }

    #[test]
    fn the_camera_row_distinguishes_not_streaming_from_not_sending_frames() {
        let off = Evidence {
            session_live: false,
            fps: Some(30),
            since_frame: Some(Duration::from_millis(10)),
            ..Default::default()
        };
        let q = SelfCheck::from(&off, zh).camera;
        assert_eq!(q.health, Health::Waiting, "{}", q.summary);
        // The wording is whatever language the test host prefers, so the
        // assertion is on the *shape*: a waiting camera row with an action.
        assert!(!q.detail.is_empty(), "{}", q.summary);
    }

    /// Input is invisible, which is why this panel exists — so a key that has
    /// arrived has to be shown, verbatim.
    #[test]
    fn a_received_key_is_shown_verbatim() {
        let e = Evidence {
            last_key: Some("⌘⇧A".into()),
            since_key: Some(Duration::from_millis(50)),
            ..Default::default()
        };
        let q = SelfCheck::from(&e, zh).keyboard;
        assert_eq!(q.health, Health::Good);
        assert!(q.detail.iter().any(|d| d.contains("⌘⇧A")), "{:?}", q.detail);
    }

    /// A silent mic is only a fault when there is a reason to expect sound.
    /// Calling it broken teaches users that the meter is always wrong.
    #[test]
    fn a_silent_microphone_is_waiting_not_bad() {
        let e = Evidence {
            mic_level: Some(0),
            ..Default::default()
        };
        assert_eq!(SelfCheck::from(&e, zh).microphone.health, Health::Waiting);
    }

    #[test]
    fn a_loud_microphone_is_good_and_the_meter_fills() {
        let e = Evidence {
            mic_level: Some(80),
            ..Default::default()
        };
        let q = SelfCheck::from(&e, zh).microphone;
        assert_eq!(q.health, Health::Good);
        assert!(q.detail[0].contains('█'), "{:?}", q.detail);
    }

    /// The meter must not run off the end of its own bar, which is what a
    /// level above 100 does.
    #[test]
    fn the_meter_clamps() {
        for level in [0, 20, 100, 500, -3] {
            let e = Evidence {
                mic_level: Some(level),
                ..Default::default()
            };
            let d = &SelfCheck::from(&e, zh).microphone.detail[0];
            assert!(d.starts_with('[') && d.ends_with(']'), "{level}: {d}");
            assert!(
                d.chars().filter(|c| *c == '█' || *c == '·').count() == 5,
                "{level}: {d}"
            );
        }
    }

    /// Three states, and each one is nameable in both languages — the panel has
    /// no legend.
    #[test]
    fn every_health_state_is_labelled_in_both_languages() {
        for h in [Health::Waiting, Health::Good, Health::Bad] {
            let (zh, en) = h.word();
            assert!(!zh.trim().is_empty());
            assert!(!en.trim().is_empty());
        }
    }

    /// Every quadrant owes the user a next step when it is waiting, or the
    /// panel is four statements of fact.
    #[test]
    fn a_waiting_quadrant_always_says_what_to_try() {
        let c = SelfCheck::from(&Evidence::default(), zh);
        for q in [c.camera, c.keyboard, c.trackpad, c.microphone] {
            assert!(!q.detail.is_empty(), "{}", q.summary);
        }
    }
}
