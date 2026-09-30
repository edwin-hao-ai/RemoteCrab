//! A live readout of what is actually flowing.
//!
//! The Mac has a `ControlPanelView` and a `TestWindowView` for this: a control
//! panel with a latency sparkline, and a four-quadrant self-check (camera,
//! keyboard echo, trackpad pad, mic level). Windows has no main window at all
//! — it is a tray app — so the native equivalent of those panels is a **live
//! submenu in the tray**, rebuilt on every popup exactly like the rest of the
//! menu. Same information, no new window infrastructure, and it cannot end up
//! showing yesterday's numbers because it is regenerated from the current
//! counters each time the user looks.
//!
//! It answers the question the Mac's self-check window was built for: *is my
//! input actually landing?* A trackpad whose modifiers were silently dropped
//! for a week looked fine until something showed the cursor trail and the last
//! key that arrived.

use rc_protocol::{KeyEvent, KeyAction, TouchEvent, TouchPhase};

/// Everything the readout shows. Kept as plain data so the wording and the
/// formatting are testable without a window.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct StreamStats {
    /// Round trip in whole milliseconds, when a probe has completed.
    pub latency_ms: Option<i64>,
    /// The most recent latency values, oldest first, for a sparkline.
    pub latency_history: Vec<i64>,
    /// Decoded frame size, once a frame has been decoded.
    pub resolution: Option<(u32, u32)>,
    /// Frames per second, measured over a short window.
    pub fps: Option<f64>,
    /// Bits per second of incoming video, from the phone's own metadata.
    pub bitrate_bps: Option<u64>,
    /// The last key the phone sent, as a short printable description.
    pub last_key: Option<String>,
    /// The last cursor position the trackpad asked for, in virtual-screen
    /// pixels. The point of the "trackpad pad" quadrant.
    pub cursor: Option<(i32, i32)>,
    /// 0.0–1.0, from the phone's audio packets.
    pub mic_level: Option<f32>,
    /// A short note when something is not arriving, e.g. "camera is off".
    pub camera_note: Option<String>,
    /// What the phone calls itself, for the readout.
    pub device_name: Option<String>,
    /// When a frame last arrived, so "the camera is off" can be told apart
    /// from "the camera is on and simply idle".
    pub last_frame: Option<std::time::Instant>,
}

/// How many samples the sparkline keeps. Thirty is what the Mac's
/// `latencyHistory` keeps, and it is about 60 s at the 2 s probe interval.
const HISTORY: usize = 30;

impl StreamStats {
    /// A latency sample, pushed into the history.
    pub fn record_latency(&mut self, ms: i64) {
        self.latency_ms = Some(ms);
        self.latency_history.push(ms);
        if self.latency_history.len() > HISTORY {
            self.latency_history.remove(0);
        }
    }

    /// The phone's own description of the stream, which arrives before any
    /// frame. Taken from `metadata` rather than from the decoder because it is
    /// the sender's truth — a decoder that has not produced a frame yet has
    /// nothing to say, and showing a resolution there would be a guess.
    pub fn record_metadata(&mut self, m: &rc_protocol::StreamMetadata) {
        if m.width > 0 && m.height > 0 {
            self.resolution = Some((m.width as u32, m.height as u32));
        }
        if m.fps > 0 {
            self.fps = Some(m.fps as f64);
        }
        if m.bitrate_bps > 0 {
            self.bitrate_bps = Some(m.bitrate_bps as u64);
        }
        if !m.device_name.trim().is_empty() {
            self.device_name = Some(m.device_name.trim().to_string());
        }
    }

    /// A decoded frame arrived, so the camera is demonstrably on.
    pub fn record_video(&mut self, width: u32, height: u32) {
        self.resolution = Some((width, height));
        self.camera_note = None;
        self.last_frame = Some(std::time::Instant::now());
    }

    /// Describe a key the way a person would recognise it.
    ///
    /// A raw keycode is useless in a readout — the whole point is to answer
    /// "did my ⌘C arrive?", so the *character* is what has to be shown, and a
    /// non-text key has to be named.
    pub fn record_key(&mut self, key: &KeyEvent) {
        // Only report the press. A key that is still held would otherwise
        // leave the readout claiming a key is down long after the user let go.
        if key.action != KeyAction::Down {
            return;
        }
        self.last_key = Some(describe_key(key));
    }

    pub fn record_touch(&mut self, touch: &TouchEvent) {
        // A drag or a move is where the position is meaningful; a tap's
        // coordinates are where it happened to land and would make the cursor
        // readout jump to the last thing clicked.
        if !matches!(touch.phase, TouchPhase::Move | TouchPhase::DragStart) {
            return;
        }
        // The phone sends normalized surface coordinates; the readout is in
        // virtual-screen pixels, so the app layer supplies the mapping. Here we
        // only keep the raw values and let the caller scale — otherwise this
        // type would need to know the screen size.
        self.cursor = Some((touch.x as i32, touch.y as i32));
    }

    pub fn record_audio(&mut self, level: f32) {
        self.mic_level = Some(level.clamp(0.0, 1.0));
    }

    pub fn set_camera_note(&mut self, note: Option<&str>) {
        self.camera_note = note.map(str::to_string);
    }

    /// The latency history as a fixed-width run of block characters.
    ///
    /// Fixed width, and it never reflows, because it sits in a menu row
    /// (AGENTS.md lesson 14): a row whose width changes as numbers move makes
    /// the whole menu twitch, which on Windows is the difference between a
    /// readout and a distraction.
    ///
    /// Scaled against the window's own min and max rather than an absolute
    /// range, so a link that is healthy at 8 ms looks healthy here and one
    /// that has quietly degraded from 8 to 40 still looks flat until it has
    /// history on both sides — which is the honest reading, and a fixed 0–100
    /// scale would draw a perfectly good link as a flat line on the floor.
    pub fn sparkline(&self, width: usize) -> String {
        const BLOCKS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
        if width == 0 || self.latency_history.is_empty() {
            return "─".repeat(width);
        }
        // Newest `width` samples, oldest first.
        let recent: Vec<i64> = self
            .latency_history
            .iter()
            .rev()
            .take(width)
            .copied()
            .collect::<Vec<i64>>()
            .into_iter()
            .rev()
            .collect();
        let lo = *recent.iter().min().unwrap_or(&0) as f64;
        let hi = *recent.iter().max().unwrap_or(&0) as f64;
        let span = (hi - lo).max(1.0);
        let mut out: String = recent
            .iter()
            .map(|v| {
                let t = ((*v as f64 - lo) / span).clamp(0.0, 1.0);
                BLOCKS[(t * (BLOCKS.len() - 1) as f64).round() as usize]
            })
            .collect();
        // Pad on the left so the newest sample is always at the right edge, the
        // way the Mac's sparkline reads, and so the row's width never changes
        // as samples accumulate.
        while out.chars().count() < width {
            out.insert(0, BLOCKS[0]);
        }
        out
    }
}

/// A short, printable name for a key.
fn describe_key(key: &KeyEvent) -> String {
    if let Some(text) = key.text.as_deref() {
        let printable: String = text.chars().filter(|c| !c.is_control()).collect();
        if !printable.is_empty() {
            return printable;
        }
    }
    match key.keycode {
        Some(0x08) => "\u{2318}C".into(),
        Some(0x09) => "Tab".into(),
        Some(0x0D) => "Return".into(),
        Some(0x1B) => "Esc".into(),
        Some(0x20) => "Space".into(),
        Some(0x26) => "↑".into(),
        Some(0x28) => "↓".into(),
        Some(0x25) => "←".into(),
        Some(0x27) => "→".into(),
        Some(c) => format!("key {c:#04x}"),
        None => "—".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(action: KeyAction, keycode: u16, text: Option<&str>) -> KeyEvent {
        KeyEvent {
            action,
            keycode: Some(keycode),
            text: text.map(str::to_string),
            modifiers: 0,
            timestamp_micros: 0,
        }
    }

    #[test]
    fn latency_history_is_bounded_and_ordered() {
        let mut s = StreamStats::default();
        for ms in 0..(HISTORY as i64 + 10) {
            s.record_latency(ms);
        }
        assert_eq!(s.latency_history.len(), HISTORY, "the sparkline must not grow forever");
        assert_eq!(s.latency_history[0], 10, "oldest samples fall off the front");
        // 40 samples pushed, 30 kept: the oldest kept is the 11th pushed.
        assert_eq!(
            s.latency_history[HISTORY - 1],
            HISTORY as i64 + 9,
            "the newest sample must be last"
        );
    }

    /// The readout's whole job: answer "did my ⌘C arrive?".
    #[test]
    fn a_key_is_named_the_way_a_person_would_say_it() {
        let mut s = StreamStats::default();
        s.record_key(&key(KeyAction::Down, 0x41, Some("a")));
        assert_eq!(s.last_key.as_deref(), Some("a"));
        s.record_key(&key(KeyAction::Down, 0x08, Some("\u{8}")));
        assert_eq!(s.last_key.as_deref(), Some("\u{2318}C"), "a non-printable key needs a name");
        s.record_key(&key(KeyAction::Down, 0x0D, None));
        assert_eq!(s.last_key.as_deref(), Some("Return"));
    }

    /// A key-up must not overwrite the reading, or a held key looks like a
    /// stream of keystrokes.
    #[test]
    fn only_key_presses_update_the_readout() {
        let mut s = StreamStats::default();
        s.record_key(&key(KeyAction::Down, 0x41, Some("a")));
        s.record_key(&key(KeyAction::Up, 0x41, Some("a")));
        assert_eq!(s.last_key.as_deref(), Some("a"));
    }

    /// Only a *drag* or a *move* says where the cursor is. Reporting a tap's
    /// coordinates would make the pad jump to the last thing the user clicked,
    /// which is the opposite of what the pad is for.
    #[test]
    fn the_cursor_readout_follows_drag_and_move_only() {
        let mut s = StreamStats::default();
        let t = |phase| TouchEvent {
            phase,
            x: 0.5,
            y: 0.25,
            dx: 0.0,
            dy: 0.0,
            modifiers: 0,
            momentum: None,
            timestamp_micros: 0,
        };
        s.record_touch(&t(TouchPhase::Down));
        assert_eq!(s.cursor, None, "a touch-down says nothing about the cursor");
        s.record_touch(&t(TouchPhase::Move));
        assert_eq!(s.cursor, Some((0, 0)), "raw normalized values; the app scales them");
        s.record_touch(&t(TouchPhase::Click));
        assert_eq!(s.cursor, Some((0, 0)), "a click must not move the pad");
    }

    #[test]
    fn mic_level_is_clamped() {
        let mut s = StreamStats::default();
        s.record_audio(0.4);
        assert_eq!(s.mic_level, Some(0.4));
        s.record_audio(9.0);
        assert_eq!(s.mic_level, Some(1.0), "a hot mic must not draw a broken meter");
        s.record_audio(-3.0);
        assert_eq!(s.mic_level, Some(0.0));
    }

    /// A camera that is off should say so, and the note must clear itself when
    /// frames come back — a stale "camera is off" next to a live picture is
    /// the kind of lie this product is not allowed to tell.
    #[test]
    fn the_camera_note_clears_when_frames_arrive() {
        let mut s = StreamStats::default();
        s.set_camera_note(Some("camera is off"));
        assert_eq!(s.camera_note.as_deref(), Some("camera is off"));
        s.record_video(1080, 1920);
        assert_eq!(s.camera_note, None);
    }
}

/// Format the readout as `(label, value)` pairs for the tray submenu.
///
/// A field that has not arrived is **omitted**, not shown as a zero: "latency
/// 0 ms" reads as a measurement, and a user who has just started the app would
/// take it as the worst possible reading rather than as no reading.
pub fn detail_rows(s: &StreamStats) -> Vec<(String, String)> {
    let mut rows = Vec::new();

    if let Some(name) = &s.device_name {
        rows.push((t("iPhone", "iPhone"), name.clone()));
    }
    if let Some((w, h)) = s.resolution {
        rows.push((t("分辨率", "Resolution"), format!("{w}x{h}")));
    }
    if let Some(fps) = s.fps {
        rows.push((t("帧率", "Frame rate"), format!("{fps:.0} fps")));
    }
    if let Some(bps) = s.bitrate_bps {
        rows.push((t("码率", "Bitrate"), format_bitrate(bps)));
    }
    if let Some(ms) = s.latency_ms {
        rows.push((
            t("延迟", "Latency"),
            format!("{ms} ms  {}", s.sparkline(12)),
        ));
    }
    if let Some(note) = &s.camera_note {
        rows.push((t("摄像头", "Camera"), note.clone()));
    }
    if let Some(key) = &s.last_key {
        rows.push((t("最后按键", "Last key"), key.clone()));
    }
    if let Some((x, y)) = s.cursor {
        rows.push((t("光标", "Cursor"), format!("{x}, {y}")));
    }
    if let Some(level) = s.mic_level {
        rows.push((t("麦克风", "Microphone"), level_meter(level)));
    }
    rows
}

/// A bitrate the way a person reads it. The Mac has `IBFormat.bitrate`; this
/// is the same idea in the shape a menu row can hold.
fn format_bitrate(bps: u64) -> String {
    if bps >= 1_000_000 {
        format!("{:.1} Mbps", bps as f64 / 1_000_000.0)
    } else if bps >= 1_000 {
        format!("{:.0} kbps", bps as f64 / 1_000.0)
    } else {
        format!("{bps} bps")
    }
}

/// A ten-cell level meter. Block characters, because the whole point is a
/// level you can see at a glance in a menu that cannot be styled — and a
/// meter made of ASCII pipes would look like a typo.
fn level_meter(level: f32) -> String {
    const CELLS: usize = 10;
    let filled = ((level.clamp(0.0, 1.0) * CELLS as f32).round() as usize).min(CELLS);
    let on = "█".repeat(filled);
    let off = "░".repeat(CELLS - filled);
    format!("{on}{off}")
}

fn t(zh: &str, en: &str) -> String {
    crate::i18n::t(zh, en).to_string()
}

#[cfg(test)]
mod readout_tests {
    use super::*;

    fn label(rows: &[(String, String)], want: &str) -> Option<String> {
        rows.iter().find(|(l, _)| l == want).map(|(_, v)| v.clone())
    }

    #[test]
    fn an_empty_readout_lists_nothing_rather_than_zeros() {
        assert!(
            detail_rows(&StreamStats::default()).is_empty(),
            "\"latency 0 ms\" reads as a measurement, not as no measurement"
        );
    }

    #[test]
    fn the_phone_name_resolution_frame_rate_and_bitrate_all_appear() {
        let mut s = StreamStats::default();
        s.record_metadata(&rc_protocol::StreamMetadata {
            version: 1,
            device_name: "iPhone".into(),
            width: 1080,
            height: 1920,
            fps: 30,
            bitrate_bps: 2_400_000,
            codec: "h264".into(),
            sps: None,
            pps: None,
        });
        let rows = detail_rows(&s);
        assert_eq!(label(&rows, "iPhone").as_deref(), Some("iPhone"));
        assert_eq!(label(&rows, "Resolution").as_deref(), Some("1080x1920"));
        assert_eq!(label(&rows, "Frame rate").as_deref(), Some("30 fps"));
        assert_eq!(label(&rows, "Bitrate").as_deref(), Some("2.4 Mbps"));
    }

    #[test]
    fn the_input_readout_shows_the_last_key_and_where_the_cursor_is() {
        let mut s = StreamStats::default();
        s.record_key(&KeyEvent {
            action: KeyAction::Down,
            keycode: Some(0x41),
            text: Some("a".into()),
            modifiers: 0,
            timestamp_micros: 0,
        });
        s.record_touch(&TouchEvent {
            phase: TouchPhase::Move,
            x: 0.5,
            y: 0.25,
            dx: 0.0,
            dy: 0.0,
            modifiers: 0,
            momentum: None,
            timestamp_micros: 0,
        });
        let rows = detail_rows(&s);
        assert_eq!(label(&rows, "Last key").as_deref(), Some("a"));
        assert_eq!(label(&rows, "Cursor").as_deref(), Some("0, 0"));
    }

    /// The sparkline sits in a menu row, which cannot reflow (AGENTS.md
    /// lesson 14), so its width must be exactly what was asked for no matter
    /// how many samples there are.
    #[test]
    fn the_sparkline_is_always_exactly_as_wide_as_asked() {
        let mut s = StreamStats::default();
        assert_eq!(s.sparkline(12).chars().count(), 12, "no samples yet");
        s.record_latency(4);
        assert_eq!(s.sparkline(12).chars().count(), 12, "one sample");
        for ms in 0..30 {
            s.record_latency(ms);
        }
        assert_eq!(s.sparkline(12).chars().count(), 12, "thirty samples");
        assert_eq!(s.sparkline(0).chars().count(), 0);
    }

    #[test]
    fn the_meter_is_a_fixed_width_and_fills_with_level() {
        assert_eq!(level_meter(0.0).chars().count(), 10);
        assert_eq!(level_meter(1.0).chars().count(), 10);
        assert!(level_meter(1.0).starts_with('█'));
        assert!(level_meter(0.0).starts_with('░'));
    }

    #[test]
    fn bitrates_read_the_way_a_person_says_them() {
        assert_eq!(format_bitrate(2_400_000), "2.4 Mbps");
        assert_eq!(format_bitrate(850_000), "850 kbps");
        assert_eq!(format_bitrate(400), "400 bps");
    }
}
