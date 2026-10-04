//! The tray menu's *shape*: which rows exist, in what order, under
//! which heading, with which icon and checkmark.
//!
//! Split from the Win32 drawing code on purpose. `TrackPopupMenu`
//! cannot be styled and hides its structure behind a single call, so the
//! layout would otherwise only be reviewable by running the app. Here it
//! is data, which is what lets the tests below hold the Windows menu to
//! the same standard as the Mac menu-bar popover.

//! On non-Windows builds the menu model has no renderer, so the
//! compiler cannot see its consumers. It is still exercised — the
//! layout and wording tests run everywhere, and the Win32 renderer on
//! Windows uses every type.
#![cfg_attr(not(windows), allow(dead_code, unused_imports))]
use crate::i18n;

/// What a menu row is, independent of how it gets drawn.
///
/// The Win32 popup is opaque, so the *shape* of the menu — which rows exist,
/// in what order, grouped under which heading, with which icon — is expressed
/// here as data and rendered by the platform layer. That makes the layout
/// testable (and therefore reviewable against the Mac popover) instead of
/// being buried in a `TrackPopupMenu` call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Row {
    /// A greyed-out heading that starts a group.
    Section,
    /// A divider.
    Separator,
    /// A greyed-out, non-clickable line (the status header, the version).
    Info,
    /// A clickable action.
    Item,
    /// A collapsible group: its `rows` are the submenu's contents.
    Sub,
    /// One non-clickable line inside a submenu. Carries no icon — a submenu is
    /// already a second level, and a column of glyphs inside it is noise.
    Detail,
}

/// One row of the menu: its kind, its menu id (`0` for non-actionable rows) and
/// the already-resolved text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MenuRow {
    pub kind: Row,
    pub id: usize,
    pub text: String,
}

/// Menu ids, kept out of the Win32 module so the layout can be tested on any
/// host. The values are private to the tray; the app loop never sees them.
pub mod ids {
    pub const CAMERA: usize = 100;
    pub const MICROPHONE: usize = 101;
    pub const TRACKPAD: usize = 102;
    pub const KEYBOARD: usize = 103;
    pub const RECORD: usize = 110;
    pub const CLIPBOARD: usize = 111;
    pub const SHOW_FILE: usize = 112;
    pub const PREVIEW: usize = 113;
    pub const RECONNECT: usize = 114;
    pub const DISCONNECT: usize = 115;
    pub const AUTOSTART: usize = 116;
    pub const QUIT: usize = 117;
    pub const DIAGNOSIS: usize = 118;
    pub const SWITCH_CAMERA: usize = 119;
    pub const DETAILS: usize = 120;
    /// Only present when the virtual camera is not registered. The row *is* the
    /// instruction: its absence is what says "nothing to do".
    pub const INSTALL_VCAM: usize = 121;
    /// Forward desktop notifications to the phone (kind `0x22`). Off by
    /// default — see `rc_net::notify` for why that is not negotiable.
    pub const NOTIFY: usize = 122;
    /// Reopen the setup wizard. Present always: the state it checks can change
    /// after first run (a declined camera install, a moved exe), and a wizard
    /// reachable only once is a wizard that cannot help the user who needs it
    /// a second time.
    pub const SETUP: usize = 123;
    /// The settings window: the notification denylist, the paired phones, the
    /// video quality. Present always, for the same reason the wizard row is.
    pub const SETTINGS: usize = 124;
    /// The four-quadrant self-check. The Mac has had this since V0.1, and it
    /// is worth *more* on Windows: input injection leaves no visible trace, so
    /// without it "did my tap land?" has no answer anywhere.
    pub const SELF_CHECK: usize = 125;
    /// Mute this PC's audio while the phone plays the computer's sound (kind
    /// `0x24`).
    ///
    /// **Reserved and deliberately unused**, so it carries no icon cell today.
    /// The row belongs here — the tray is where a user looks for this — but
    /// `scripts/generate-windows-menu-icons.py` needs Python + PIL, and no cell
    /// exists for a speaker glyph yet. Assigning an existing cell would collide,
    /// and `no_two_rows_share_a_glyph` is right to refuse that: two rows with the
    /// same picture is worse than one row absent. Until the sheet can be
    /// regenerated, the preference lives on the console as `speaker-mute` (like
    /// `autostart`), and the safe default means nobody has to set it for the
    /// feature to work.
    ///
    /// To finish this: add the glyph as cell 20 in the generator's `ROWS`, bump
    /// `ICON_CELLS_FOR_THE_SHEET` to 21, regenerate the PNG, then map
    /// `SPEAKER_MUTE => 20` in `icon_cell`, add it to `known_ids` and
    /// `is_on`, and push the row in `menu_rows`.
    ///
    /// `allow(dead_code)` is targeted rather than blanket, and only because a
    /// reservation is by definition not referenced yet — `the_speaker_row_is_
    /// reserved_and_deliberately_not_wired` is what keeps that honest.
    #[allow(dead_code)]
    pub const SPEAKER_MUTE: usize = 126;
}

/// What the menu shows right now, as far as the layout is concerned.
#[derive(Debug, Clone, Default)]
pub struct MenuState {
    pub camera: bool,
    pub microphone: bool,
    pub trackpad: bool,
    pub keyboard: bool,
    pub recording: bool,
    pub has_last_file: bool,
    pub preview_on: bool,
    pub autostart: bool,
    /// The one-line reason the session is not live, already localized by the
    /// app. Rendered *into* the Diagnosis row so the menu answers "why not?"
    /// without the user having to click anything (AGENTS.md rule 1: the line
    /// that says what is happening must also say what to do).
    pub diagnosis: String,
    /// Live readouts for the "connection details" submenu: `(label, value)`.
    ///
    /// The Windows counterpart of the Mac's `ControlPanelView` +
    /// `TestWindowView`. Those are windows; this app has no main window, it is a
    /// tray app, so the native equivalent is a submenu rebuilt on each popup.
    /// Empty rows are dropped, so a field that has not arrived yet simply does
    /// not appear rather than showing a zero that reads like a measurement.
    pub details: Vec<(String, String)>,
    /// Whether desktop notifications are forwarded to the phone. `false` until
    /// the user asks, because the alternative is a product that ships reading
    /// your notifications before you have agreed to it.
    pub notify_relay: bool,
    /// Whether the phone's feature state has arrived at all — which is this
    /// receiver's definition of "connected" for the speaker row.
    pub connected: bool,
    /// Whether the phone is currently sending us its system audio (kind `0x24`).
    pub speaker_on: bool,
    /// Whether the virtual camera's COM source is registered. `false` is the
    /// only state in which the user has something to do about it, so it is the
    /// only state that shows the install row.
    pub vcam_installed: bool,
}

/// The install row's label, as a pair rather than a resolved string.
///
/// A test that asserts on the *rendered* label can only assert on one
/// language — whichever `t()` picks for the machine running it — so such a
/// test silently stops checking anything on the other locale. Naming both
/// lets a test state the rule ("both languages must name the consequence")
/// without depending on the environment.
/// The relay row's two labels, as pairs rather than resolved strings, so a
/// test can state the rule for both languages instead of whichever one the
/// machine running it happens to use. See `INSTALL_VCAM_LABEL` for the same
/// reason.
pub const NOTIFY_LABEL_ON: (&str, &str) = (
    "通知中继：开（转发到手机）",
    "Notification relay: on (forwarding to the phone)",
);
pub const NOTIFY_LABEL_OFF: (&str, &str) = ("通知中继：关", "Notification relay: off");

pub const INSTALL_VCAM_LABEL: (&str, &str) = (
    "安装虚拟摄像头（需要允许管理员提示）",
    "Install virtual camera (allow the admin prompt)",
);

/// The menu's shape, in draw order.
///
/// Kept in step with the Mac menu-bar popover: status header, then a labelled
/// *Features* group, an *Actions* group, the preview toggle, a *Connection*
/// group, start-at-login, quit, and a version footer.
pub fn menu_rows(state: &MenuState) -> Vec<MenuRow> {
    use i18n::t;
    let mut rows = Vec::new();
    let mut push = |kind: Row, id: usize, text: String| rows.push(MenuRow { kind, id, text });

    // Group headings use an en dash on each side so they read as headings even
    // in a menu that cannot be styled.
    push(Row::Info, 0, t("状态", "Status").to_string());
    push(Row::Separator, 0, String::new());

    // The live readout, first, so a user checking "is this thing actually
    // working?" reads numbers rather than hunting through toggles.
    if !state.details.is_empty() {
        push(
            Row::Sub,
            ids::DETAILS,
            t("连接详情", "Connection Details").to_string(),
        );
        push(Row::Separator, 0, String::new());
    }

    push(Row::Section, 0, t("功能", "Features").to_string());
    push(Row::Item, ids::CAMERA, t("摄像头", "Camera").to_string());
    // A missing virtual camera with no way to install it was the one gap that
    // made the feature unusable on a fresh machine: registering it needs
    // administrator rights, and the only instruction a user could be given was
    // "run the other binary as admin" — not something a person who installed a
    // program can act on. This row exists only while it is missing, and
    // clicking it is the whole fix, so it sits directly under the camera it is
    // about rather than in a diagnostics corner.
    if !state.vcam_installed {
        push(
            Row::Item,
            ids::INSTALL_VCAM,
            t(INSTALL_VCAM_LABEL.0, INSTALL_VCAM_LABEL.1).to_string(),
        );
    }
    push(
        Row::Item,
        ids::MICROPHONE,
        t("麦克风", "Microphone").to_string(),
    );
    // "Play computer sound" is a STATUS row, not a toggle, mirroring the Mac's
    // `FeatureStatusRow` (`MenuBarMenu.swift`). The phone owns the decision — it
    // plays the computer's audio out of itself — so a switch here would be a
    // second place to look for the same decision, which is what made the feature
    // read as "the Mac has to be set up first". The line names the state AND the
    // place that changes it, because a row that only points elsewhere has not
    // told the user anything about now.
    //
    // A `Row::Info` renders greyed and unclickable, which is exactly the Mac's
    // `FeatureStatusRow`: a state word rather than a switch.
    push(
        Row::Info,
        0,
        format!(
            "{}: {}",
            t(crate::speaker::TITLE.0, crate::speaker::TITLE.1),
            crate::speaker::status_line(state.connected, state.speaker_on)
        ),
    );
    push(
        Row::Item,
        ids::TRACKPAD,
        t("触控板", "Trackpad").to_string(),
    );
    push(Row::Item, ids::KEYBOARD, t("键盘", "Keyboard").to_string());
    push(Row::Separator, 0, String::new());

    push(Row::Section, 0, t("操作", "Actions").to_string());
    // The Mac has had this row since the switcher shipped; on Windows it was
    // console-only, which made flipping a phone that is facing the wrong way a
    // two-terminal operation.
    push(
        Row::Item,
        ids::SWITCH_CAMERA,
        t("切换前后摄像头", "Switch Camera").to_string(),
    );
    push(
        Row::Item,
        ids::RECORD,
        t("开始录制", "Start Recording").to_string(),
    );
    push(
        Row::Item,
        ids::CLIPBOARD,
        t("发送剪贴板", "Send Clipboard").to_string(),
    );
    push(
        Row::Item,
        ids::SHOW_FILE,
        t("显示最后接收的文件", "Show Last Received File").to_string(),
    );
    push(
        Row::Item,
        ids::PREVIEW,
        t("显示预览窗口", "Show Preview Window").to_string(),
    );
    push(Row::Separator, 0, String::new());

    push(Row::Section, 0, t("连接", "Connection").to_string());
    // Position is fixed so the menu never changes height as the state moves
    // (AGENTS.md lesson 14). The wording does change, because a menu that says
    // "LOOKING" and nothing else is what made this undiagnosable.
    push(
        Row::Item,
        ids::DIAGNOSIS,
        if state.diagnosis.is_empty() {
            t("连接状态…", "Connection status…").to_string()
        } else {
            format!(
                "{}: {}",
                t("为什么连不上", "Why not connected"),
                state.diagnosis
            )
        },
    );
    push(
        Row::Item,
        ids::RECONNECT,
        t("重新连接", "Reconnect").to_string(),
    );
    push(
        Row::Item,
        ids::DISCONNECT,
        t("断开连接", "Disconnect").to_string(),
    );
    push(Row::Separator, 0, String::new());

    // The notification relay sits with the other machine-level switches. It is
    // always present, because it is the switch that turns it off — a row that
    // disappeared when the feature was on would leave no way to turn it back
    // off from the menu.
    push(
        Row::Item,
        ids::NOTIFY,
        if state.notify_relay {
            t(NOTIFY_LABEL_ON.0, NOTIFY_LABEL_ON.1).to_string()
        } else {
            t(NOTIFY_LABEL_OFF.0, NOTIFY_LABEL_OFF.1).to_string()
        },
    );
    // The speaker-mute preference is NOT here yet; see `ids::SPEAKER_MUTE` for
    // why and for the exact steps to finish it. It lives on the console as
    // `speaker-mute` until then, and the default (`keep this PC playing`) means
    // the feature works without anyone opening it.
    push(
        Row::Item,
        ids::AUTOSTART,
        t("开机自启动", "Start at login").to_string(),
    );
    push(Row::Separator, 0, String::new());
    push(
        Row::Item,
        ids::QUIT,
        t("退出 RemoteCrab", "Quit RemoteCrab").to_string(),
    );
    push(Row::Separator, 0, String::new());
    push(
        Row::Info,
        0,
        format!("RemoteCrab v{}", env!("CARGO_PKG_VERSION")),
    );

    // Reflect the live state in the wording, so a row never claims the
    // opposite of what it will do.
    for row in &mut rows {
        match row.id {
            ids::RECORD => {
                row.text = if state.recording {
                    t("停止录制", "Stop Recording").to_string()
                } else {
                    t("开始录制", "Start Recording").to_string()
                }
            }
            ids::PREVIEW => {
                row.text = if state.preview_on {
                    t("隐藏预览窗口", "Hide Preview Window").to_string()
                } else {
                    t("显示预览窗口", "Show Preview Window").to_string()
                }
            }
            _ => {}
        }
    }
    rows
}

#[cfg(windows)]
/// Win32 menu flags for a row. Split out from the drawing code so the
/// checked/greyed logic is testable off-Windows.
pub fn flags_for(
    row: &MenuRow,
    state: &MenuState,
) -> windows::Win32::UI::WindowsAndMessaging::MENU_ITEM_FLAGS {
    use windows::Win32::UI::WindowsAndMessaging::{MF_GRAYED, MF_SEPARATOR, MF_STRING};
    match row.kind {
        Row::Separator => MF_SEPARATOR,
        // A heading and the status/footer lines are informative, not
        // actionable: greyed so they cannot be "clicked" into a no-op.
        Row::Section | Row::Info => MF_STRING | MF_GRAYED,
        // Readout lines: same reasoning, inside the submenu.
        Row::Detail => MF_STRING | MF_GRAYED,
        Row::Item => {
            let mut f = MF_STRING;
            if is_on(row.id, state) {
                f |= windows::Win32::UI::WindowsAndMessaging::MF_CHECKED;
            }
            if row.id == ids::SHOW_FILE && !state.has_last_file {
                f |= MF_GRAYED;
            }
            f
        }
        // `MF_POPUP` is added by the tray, which owns the submenu's `HMENU` —
        // the flag and the handle have to be combined at the one call site that
        // created it.
        Row::Sub => MF_STRING,
    }
}

/// The submenu's rows, built from the live readouts.
///
/// Deliberately not clickable and deliberately not icon-bearing: a second
/// level of menu with a column of glyphs in it is noise, and these are
/// readings, not actions. An absent field is **omitted** rather than shown as
/// a zero, because "latency 0 ms" reads as a measurement and "no sample yet"
/// does not.
pub fn detail_rows(state: &MenuState) -> Vec<MenuRow> {
    state
        .details
        .iter()
        .filter(|(_, v)| !v.trim().is_empty())
        .map(|(label, value)| MenuRow {
            kind: Row::Detail,
            id: 0,
            text: format!("{label}: {value}"),
        })
        .collect()
}

/// Every id the click handler in `tray.rs` acts on.
///
/// This exists because of a real outage. `tray.rs` used to keep a second,
/// private id table (1, 2, 3 …) while the rows carried these (100, 101, 102 …),
/// so every click fell through to `_ => None`: the tray opened, rendered
/// perfectly, and did nothing at all. Two tables compiled cleanly and the
/// unit tests (which only ever inspected the model) stayed green.
///
/// Keep this list and the `match` in `tray.rs` in step — [`all_rows_have_a_known_id`]
/// is the test that notices when they drift.
/// Every id a `WM_COMMAND` can deliver.
///
/// `DETAILS` is deliberately **not** here: it is a submenu *parent*, and
/// Win32 expands a submenu on its own without ever sending its id. Listing it
/// would invite someone to write a handler for a message that cannot arrive.
/// The one state-dependent id, `RECORD`, *is* here, because it is a real row.
pub fn known_ids() -> &'static [usize] {
    &[
        ids::CAMERA,
        ids::MICROPHONE,
        ids::TRACKPAD,
        ids::KEYBOARD,
        ids::RECORD,
        ids::CLIPBOARD,
        ids::SHOW_FILE,
        ids::PREVIEW,
        ids::RECONNECT,
        ids::DISCONNECT,
        ids::AUTOSTART,
        ids::SWITCH_CAMERA,
        ids::QUIT,
        ids::DIAGNOSIS,
        ids::INSTALL_VCAM,
        ids::NOTIFY,
        ids::SETUP,
        ids::SETTINGS,
        ids::SELF_CHECK,
    ]
}

/// Whether a toggle row is currently on.
pub fn is_on(id: usize, state: &MenuState) -> bool {
    match id {
        ids::CAMERA => state.camera,
        ids::MICROPHONE => state.microphone,
        ids::TRACKPAD => state.trackpad,
        ids::KEYBOARD => state.keyboard,
        ids::AUTOSTART => state.autostart,
        // Without this the relay row renders identically whether the feature
        // is on or off, so the user has no way to tell which state they are in
        // — and a privacy switch you cannot read is a privacy switch nobody
        // will trust to have been off.
        ids::NOTIFY => state.notify_relay,
        _ => false,
    }
}

/// The icon that precedes a row's label, matching the Mac popover's habit of
/// an SF Symbol on every row. Kept as text glyphs so no image assets are
/// needed; the font falls back gracefully if one is missing.
/// Which cell of `assets/menu-icons.png` a row's icon lives in.
///
/// The order **must** match `ROWS` in
/// `scripts/generate-windows-menu-icons.py`, which is the file that actually
/// draws them. They cannot be derived from each other — one is Python, one is
/// Rust — so [`ICON_CELLS_FOR_THE_SHEET`] pins the count and
/// `all_rows_have_an_icon` pins the coverage, and a reorder that forgets to
/// regenerate the sheet fails the test rather than shipping a menu where
/// "Quit" shows a folder.
pub fn icon_cell(id: usize) -> Option<usize> {
    Some(match id {
        ids::CAMERA => 0,
        ids::MICROPHONE => 1,
        ids::TRACKPAD => 2,
        ids::KEYBOARD => 3,
        ids::SWITCH_CAMERA => 4,
        ids::CLIPBOARD => 6,
        ids::SHOW_FILE => 7,
        ids::PREVIEW => 8,
        ids::DIAGNOSIS => 9,
        ids::RECONNECT => 10,
        ids::DISCONNECT => 11,
        ids::AUTOSTART => 12,
        ids::QUIT => 13,
        ids::INSTALL_VCAM => 15,
        ids::NOTIFY => 16,
        ids::SETUP => 17,
        ids::SETTINGS => 18,
        ids::SELF_CHECK => 19,
        // `SPEAKER_MUTE` is deliberately absent until the sheet has a speaker
        // glyph to give it; see the id's doc comment for the exact steps.
        // `RECORD` is deliberately absent: it is the one row whose glyph
        // depends on state, so it goes through [`record_icon_cell`] and not
        // through here. Letting both decide it is how they drift apart.
        _ => return None,
    })
}

/// The "stop recording" glyph is a different cell from "start recording", so
/// one id maps to one of two depending on state.
pub fn record_icon_cell(recording: bool) -> usize {
    if recording {
        14
    } else {
        5
    }
}

/// The cell a row draws, with its state.
///
/// This exists so that "which glyph does the Record row get" has **one**
/// answer. `icon_cell` cannot answer it (the glyph depends on whether we are
/// recording), so the tray used to answer the question itself — and the tests
/// answered it a third way, which is how the sheet and the bitmap disagreed
/// without anything failing. The tray now asks here, and so does every test.
pub fn row_icon_cell(id: usize, recording: bool) -> Option<usize> {
    if id == ids::RECORD {
        return Some(record_icon_cell(recording));
    }
    icon_cell(id)
}

/// How many cells `scripts/generate-windows-menu-icons.py` writes.
pub const ICON_CELLS_FOR_THE_SHEET: usize = 20;

/// Render a row's text the way it should appear in the popup.
///
/// No icon prefix: the icon is a real bitmap attached with
/// `SetMenuItemBitmaps`. This used to prepend an arbitrary Unicode glyph
/// (`◉`, `☰`, `⌨`…), which is not a set — those come from whatever font the
/// system happens to resolve each one through, so they render inconsistently
/// and fall back to tofu on a stripped install. A drawn sheet is one family by
/// construction and it always exists.
pub fn decorate(row: &MenuRow) -> String {
    match row.kind {
        Row::Separator => String::new(),
        // En-dashes on both sides so a heading reads as one even in a menu
        // that cannot be styled.
        Row::Section => format!("— {} —", row.text),
        Row::Info | Row::Detail => row.text.clone(),
        Row::Item | Row::Sub => row.text.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> MenuState {
        // Installed, so the tests below that count rows are counting the normal
        // menu. The missing-camera case has its own test.
        MenuState::default()
    }

    fn labels(rows: &[MenuRow]) -> Vec<&str> {
        rows.iter().map(|r| r.text.as_str()).collect()
    }

    /// The Mac popover is "heavily sectioned" — the Windows menu has to be
    /// too, or it reads as a flat grey list next to it.
    #[test]
    fn the_menu_is_grouped_into_labelled_sections() {
        let rows = menu_rows(&state());
        let sections: Vec<&str> = rows
            .iter()
            .filter(|r| r.kind == Row::Section)
            .map(|r| r.text.as_str())
            .collect();
        assert_eq!(
            sections.len(),
            3,
            "features / actions / connection: {sections:?}"
        );
        assert!(rows.iter().filter(|r| r.kind == Row::Separator).count() >= 5);
    }

    /// Every actionable row needs an icon and a real id, or the menu loses
    /// the visual rhythm the Mac version has.
    #[test]
    fn every_action_has_an_icon_and_an_id() {
        for row in menu_rows(&state()).iter().filter(|r| r.kind == Row::Item) {
            assert_ne!(row.id, 0, "actionable row without an id: {:?}", row.text);
            assert!(
                row_icon_cell(row.id, false).is_some(),
                "no icon cell for {:?} (id {})",
                row.text,
                row.id
            );
        }
    }

    /// A cell index outside the generated sheet is an invisible-at-best icon
    /// (it would read as another row's glyph) and a blank cell is worse. The
    /// count is the one thing tying this file to the Python generator, so it is
    /// pinned here rather than assumed.
    #[test]
    fn no_icon_cell_points_outside_the_sheet() {
        for id in 0..=200 {
            if let Some(cell) = icon_cell(id) {
                assert!(
                    cell < ICON_CELLS_FOR_THE_SHEET,
                    "id {id} maps to cell {cell}, but the sheet has \
                     {ICON_CELLS_FOR_THE_SHEET} cells — regenerate it with \
                     scripts/generate-windows-menu-icons.py"
                );
            }
        }
        assert_eq!(record_icon_cell(false), 5);
        assert_eq!(record_icon_cell(true), 14);
    }

    /// The recording row is the one row whose icon changes with state. If the
    /// two cells ever collide, "stop recording" would look like "start".
    #[test]
    fn the_two_record_glyphs_are_different_glyphs() {
        assert_ne!(record_icon_cell(true), record_icon_cell(false));
    }

    /// No label may carry a hand-picked icon character any more. This is the
    /// "casual icons" the sheet replaced, and putting one back would be a
    /// regression: a stray glyph from whatever font resolves it is not part of
    /// a set.
    #[test]
    fn no_label_carries_a_stray_glyph() {
        for row in menu_rows(&state()) {
            if !matches!(row.kind, Row::Item | Row::Section | Row::Info) {
                continue;
            }
            for (i, ch) in row.text.chars().enumerate() {
                let looks_like_a_glyph = matches!(ch,
                    '\u{25A0}'..='\u{25FF}' | '\u{2600}'..='\u{27BF}' |
                    '\u{2300}'..='\u{23FF}' | '\u{2B00}'..='\u{2BFF}');
                assert!(
                    !looks_like_a_glyph,
                    "row {:?} carries a bare symbol {ch:?} at {i}: {:?}",
                    row.text, row.text
                );
            }
        }
    }

    /// Informative rows must not be clickable — a clickable heading is a
    /// no-op the user has to discover by clicking it.
    #[test]
    fn headings_and_the_footer_are_not_clickable() {
        for row in menu_rows(&state()) {
            match row.kind {
                Row::Section | Row::Info => {
                    assert_eq!(row.id, 0, "clickable non-action: {:?}", row.text);
                    // Informative rows carry no bitmap at all: id 0 has no
                    // cell in `icon_cell`, which is how the tray knows to skip
                    // `SetMenuItemBitmaps` for them.
                    assert_eq!(
                        row_icon_cell(row.id, false),
                        None,
                        "informative row must not claim an icon cell: {:?}",
                        row.text
                    );
                }
                _ => {}
            }
        }
    }

    /// The regression test for the dead tray: a row whose id the click handler
    /// does not know is a silent no-op, which is invisible in every other test
    /// because the menu still looks perfect.
    #[test]
    fn all_rows_have_a_known_id() {
        let known = known_ids();
        for row in menu_rows(&state()) {
            if row.kind != Row::Item {
                continue;
            }
            assert!(
                known.contains(&row.id),
                "row {:?} carries id {} which no click handler matches — \
                 add it to known_ids() AND to the match in tray.rs",
                row.text,
                row.id
            );
        }
    }

    /// And the two lists must not silently shrink together, or a row could
    /// exist with no handler again.
    #[test]
    fn known_ids_has_no_duplicates() {
        let known = known_ids();
        let mut sorted = known.to_vec();
        sorted.sort_unstable();
        let before = sorted.len();
        sorted.dedup();
        assert_eq!(
            before,
            sorted.len(),
            "duplicate id in known_ids(): {sorted:?}"
        );
    }

    #[test]
    fn the_diagnosis_row_carries_the_reason_without_a_click() {
        // A menu row that only says "LOOKING" is the whole problem this
        // session set out to fix: the user cannot tell "not found yet" from
        // "found it and was refused" from "something is tunnelling my
        // traffic". The reason belongs on the row.
        let mut s = state();
        s.diagnosis = i18n::t(
            "被 VPN/代理接管（198.18.0.1）",
            "a VPN/proxy tunnel took the route (198.18.0.1)",
        )
        .to_string();
        let row = menu_rows(&s)
            .into_iter()
            .find(|r| r.id == ids::DIAGNOSIS)
            .expect("a diagnosis row must always exist");
        assert!(row.text.contains("198.18.0.1"), "{row:?}");
        assert!(!row.text.contains('\n'), "a menu row cannot wrap: {row:?}");

        // …and the row's position never moves, so the menu cannot jump.
        let before = menu_rows(&state())
            .iter()
            .position(|r| r.id == ids::DIAGNOSIS)
            .expect("row present even with nothing to say");
        let after = menu_rows(&s)
            .iter()
            .position(|r| r.id == ids::DIAGNOSIS)
            .expect("row present");
        assert_eq!(before, after, "the row must not move as the state changes");
    }

    #[test]
    fn the_diagnosis_row_stays_put_when_there_is_nothing_to_say() {
        let rows = menu_rows(&state());
        let row = rows.iter().find(|r| r.id == ids::DIAGNOSIS).expect("row");
        assert!(!row.text.trim().is_empty(), "a blank row reads as a bug");
    }

    #[test]
    fn the_wording_follows_the_state_it_describes() {
        // Compare against the same `t()` the rows are built with rather than
        // a hardcoded string: a Chinese-only assertion silently passes on a
        // Chinese dev box and fails on every CI runner (and vice versa), which
        // is how both languages ended up half-tested.
        let start = i18n::t("开始录制", "Start Recording").to_string();
        let stop_recording = i18n::t("停止录制", "Stop Recording").to_string();
        let show = i18n::t("显示预览窗口", "Show Preview Window").to_string();
        let hide = i18n::t("隐藏预览窗口", "Hide Preview Window").to_string();

        let mut s = state();
        s.recording = true;
        assert!(
            labels(&menu_rows(&s)).iter().any(|l| *l == stop_recording),
            "a recording session must offer to stop"
        );
        s.recording = false;
        assert!(
            labels(&menu_rows(&s)).iter().any(|l| *l == start),
            "an idle session must offer to start"
        );

        let mut s = state();
        s.preview_on = true;
        assert!(labels(&menu_rows(&s)).iter().any(|l| *l == hide));
        s.preview_on = false;
        assert!(labels(&menu_rows(&s)).iter().any(|l| *l == show));
    }

    /// A toggle that says "on" but draws unchecked (or vice versa) is the
    /// worst class of menu bug: the user cannot tell which one lied.
    #[test]
    fn checkmarks_match_the_state() {
        let mut s = state();
        s.camera = true;
        s.autostart = true;
        for row in menu_rows(&s) {
            if row.kind != Row::Item {
                continue;
            }
            let checked = is_on(row.id, &s);
            assert_eq!(checked, row.id == ids::CAMERA || row.id == ids::AUTOSTART);
        }
    }

    #[test]
    fn the_version_footer_is_present_and_last() {
        let rows = menu_rows(&state());
        let last = rows.last().expect("a footer");
        assert_eq!(last.kind, Row::Info);
        assert!(last.text.starts_with("RemoteCrab v"), "{}", last.text);
    }

    #[test]
    fn a_row_without_a_file_is_greyed_out() {
        let mut s = state();
        s.has_last_file = false;
        let row = menu_rows(&s)
            .into_iter()
            .find(|r| r.id == ids::SHOW_FILE)
            .unwrap();
        // MF_GRAYED is 0x1 on Windows; the test is cfg-gated to stay honest.
        #[cfg(windows)]
        {
            use windows::Win32::UI::WindowsAndMessaging::MF_GRAYED;
            assert_ne!(flags_for(&row, &s).0 & MF_GRAYED.0, 0);
        }
        #[cfg(not(windows))]
        assert_eq!(row.kind, Row::Item);
    }

    #[test]
    fn quit_is_the_last_thing_before_the_footer() {
        let rows = menu_rows(&state());
        let quit = rows.iter().position(|r| r.id == ids::QUIT).unwrap();
        let footer = rows
            .iter()
            .position(|r| r.kind == Row::Info && r.text.starts_with("RemoteCrab v"))
            .unwrap();
        assert!(quit < footer, "quit must come before the footer");
    }
}

#[cfg(test)]
mod sheet_order_tests {
    use super::{icon_cell, ids, record_icon_cell, row_icon_cell, ICON_CELLS_FOR_THE_SHEET};

    /// The sheet's order, spelled out here so a wrong glyph is a failed test
    /// rather than a screenshot the user has to notice.
    ///
    /// This mapping was wrong once already: the generator gained a cell in the
    /// middle and the Rust map did not, so from one row down **every** icon
    /// was shifted by one — the camera row wore the switch-camera glyph, the
    /// Quit row wore the stop square — and nothing failed. The old tests
    /// checked only that a cell was *in range*, which a shifted cell satisfies.
    /// A state with a readout in it, so the `连接详情` submenu row exists.
    ///
    /// The submenu row is only pushed when there is something to show, and
    /// `MenuState::default()` has no details — so a test built on the default
    /// silently never walks the `Sub` path. That is exactly how the submenu
    /// row's missing icon stayed invisible: no test ever built a state with
    /// details in it.
    fn state_with_details() -> super::MenuState {
        super::MenuState {
            camera: false,
            microphone: false,
            trackpad: false,
            keyboard: false,
            recording: false,
            has_last_file: false,
            preview_on: false,
            autostart: false,
            diagnosis: String::new(),
            details: vec![("延迟".to_string(), "5 ms".to_string())],
            notify_relay: false,
            connected: true,
            speaker_on: false,
            vcam_installed: true,
        }
    }

    #[test]
    fn the_speaker_row_is_reserved_and_deliberately_not_wired() {
        // Both halves of "deliberately", so a later change cannot half-enable it:
        // a row with an id nobody handles clicks into nothing, and an id with a
        // glyph but no row is a cell that can never be seen.
        assert!(!super::known_ids().contains(&ids::SPEAKER_MUTE), "the id is live but no row pushes it");
        assert!(
            super::icon_cell(ids::SPEAKER_MUTE).is_none(),
            "the id borrows another row's glyph"
        );
        assert!(
            !super::menu_rows(&state_with_details())
                .iter()
                .any(|r| r.id == ids::SPEAKER_MUTE),
            "the row exists without an icon"
        );
    }

    #[test]
    fn the_submenu_row_is_reachable_and_carries_no_icon_on_purpose() {
        let rows = super::menu_rows(&state_with_details());
        let sub = rows
            .iter()
            .find(|r| r.id == ids::DETAILS)
            .expect("a state with details must offer the details submenu");
        assert_eq!(sub.kind, super::Row::Sub);
        // A second level of menu with a column of 16x16 glyphs in it is noise,
        // so the submenu parent draws nothing. What matters is that asking
        // does not panic and does not hand back a cell it does not own.
        assert_eq!(row_icon_cell(ids::DETAILS, false), None);
        assert!(
            !super::known_ids().contains(&ids::DETAILS),
            "a submenu parent can never deliver WM_COMMAND"
        );
    }

    #[test]
    fn every_row_draws_the_glyph_its_name_promises() {
        // (menu id, the cell the generator's ROWS list puts that glyph in)
        let expected = [
            (ids::CAMERA, 0),
            (ids::MICROPHONE, 1),
            (ids::TRACKPAD, 2),
            (ids::KEYBOARD, 3),
            (ids::SWITCH_CAMERA, 4),
            (ids::CLIPBOARD, 6),
            (ids::SHOW_FILE, 7),
            (ids::PREVIEW, 8),
            (ids::DIAGNOSIS, 9),
            (ids::RECONNECT, 10),
            (ids::DISCONNECT, 11),
            (ids::AUTOSTART, 12),
            (ids::QUIT, 13),
            (ids::INSTALL_VCAM, 15),
            (ids::NOTIFY, 16),
            (ids::SETUP, 17),
            (ids::SETTINGS, 18),
            (ids::SELF_CHECK, 19),
        ];
        for (id, cell) in expected {
            assert_eq!(icon_cell(id), Some(cell), "id {id} draws the wrong cell");
        }
        // The two state-dependent cells, which the generator calls "record" and
        // "stop" — they are the only two nothing points at unconditionally.
        assert_eq!(row_icon_cell(ids::RECORD, false), Some(5));
        assert_eq!(row_icon_cell(ids::RECORD, true), Some(14));
    }

    /// The generator is the thing that actually paints the sheet, so its
    /// `ROWS` order is the definition. Checked here, from the file, so the two
    /// cannot drift without a red test.
    #[test]
    fn the_generator_and_the_rust_map_agree_cell_for_cell() {
        let gen = include_str!("../../../../scripts/generate-windows-menu-icons.py");
        let rows_block = gen
            .split_once("ROWS = [")
            .expect("generator has no ROWS list")
            .1
            .split_once("\n]")
            .expect("ROWS list is unterminated")
            .0;
        let mut cell = 0usize;
        for line in rows_block.lines() {
            let Some(name) = line.split('"').nth(1) else {
                continue;
            };
            let id = match name {
                "camera" => ids::CAMERA,
                "microphone" => ids::MICROPHONE,
                "trackpad" => ids::TRACKPAD,
                "keyboard" => ids::KEYBOARD,
                "switch_camera" => ids::SWITCH_CAMERA,
                "record" => ids::RECORD,
                "clipboard" => ids::CLIPBOARD,
                "folder" => ids::SHOW_FILE,
                "preview" => ids::PREVIEW,
                "diagnosis" => ids::DIAGNOSIS,
                "reconnect" => ids::RECONNECT,
                "disconnect" => ids::DISCONNECT,
                "autostart" => ids::AUTOSTART,
                "quit" => ids::QUIT,
                "stop" => ids::RECORD,
                "install_vcam" => ids::INSTALL_VCAM,
                "notify" => ids::NOTIFY,
                "setup" => ids::SETUP,
                "settings" => ids::SETTINGS,
                "self_check" => ids::SELF_CHECK,
                other => panic!("the generator draws {other:?}, which no menu row claims"),
            };
            assert_eq!(
                row_icon_cell(id, name == "stop"),
                Some(cell),
                "generator cell {cell} is {name:?}, but the tray draws something else there",
            );
            cell += 1;
        }
        assert_eq!(cell, ICON_CELLS_FOR_THE_SHEET, "the sheet changed size");
    }

    /// Each cell is used once. Two rows sharing a glyph is not a crash, but it
    /// is how two different actions end up indistinguishable in a menu of
    /// same-sized monochrome squares.
    #[test]
    fn no_two_rows_share_a_glyph() {
        let rows = super::menu_rows(&state_with_details());
        let mut seen = std::collections::BTreeMap::new();
        let items: Vec<_> = rows.iter().filter(|r| r.kind == super::Row::Item).collect();
        for r in &items {
            let cell = row_icon_cell(r.id, false).expect("row without an icon");
            if let Some(prev) = seen.insert(cell, r.text.clone()) {
                panic!("cell {cell} is drawn by both {prev:?} and {:?}", r.text);
            }
        }
        assert_eq!(seen.len(), items.len());
    }

    #[test]
    fn record_is_the_only_state_dependent_glyph() {
        let rows = super::menu_rows(&super::MenuState::default());
        for id in rows
            .iter()
            .filter(|r| matches!(r.kind, super::Row::Item | super::Row::Sub))
            .map(|r| r.id)
        {
            if id == ids::RECORD {
                continue;
            }
            assert_eq!(
                row_icon_cell(id, false),
                row_icon_cell(id, true),
                "id {id} changed glyph when the recording state flipped",
            );
        }
        assert_ne!(record_icon_cell(false), record_icon_cell(true));
    }
}

#[cfg(test)]
mod vcam_row_tests {
    use super::{ids, menu_rows, MenuState, Row};

    fn state_with(vcam_installed: bool) -> MenuState {
        MenuState {
            vcam_installed,
            ..MenuState::default()
        }
    }

    /// The row is the entire recovery path for a feature whose setup needs
    /// administrator rights, so it has to be there exactly when it is needed.
    #[test]
    fn the_install_row_appears_only_when_the_camera_is_missing() {
        let missing = menu_rows(&state_with(false));
        let row = missing
            .iter()
            .find(|r| r.id == ids::INSTALL_VCAM)
            .expect("a missing virtual camera must offer a way to install it");
        assert_eq!(row.kind, Row::Item, "it has to be clickable");
        // The label has to name the consequence, or the user is being asked to
        // approve a UAC prompt with no idea what it is for.
        // Checked against *both* languages, not the rendered one: a rule that
        // only holds in the test machine's locale is a rule that is untested in
        // the other one.
        for (lang, text) in [
            ("zh", super::INSTALL_VCAM_LABEL.0),
            ("en", super::INSTALL_VCAM_LABEL.1),
        ] {
            assert!(
                text.contains(if lang == "zh" {
                    "虚拟摄像头"
                } else {
                    "virtual camera"
                }),
                "{lang}: {text:?}"
            );
            assert!(
                text.contains(if lang == "zh" { "管理员" } else { "admin" }),
                "{lang}: {text:?}"
            );
        }

        // …and gone once there is nothing to do. A row that stays after the
        // camera is installed is a click that does nothing, which is worse
        // than no row: it teaches users that this menu is decorative.
        let installed = menu_rows(&state_with(true));
        assert!(
            !installed.iter().any(|r| r.id == ids::INSTALL_VCAM),
            "the install row must disappear once the camera is registered"
        );
    }

    /// It belongs with the features it is about, not in a diagnostics corner
    /// the user has no reason to open.
    #[test]
    fn the_install_row_sits_with_the_camera_toggle() {
        let rows = menu_rows(&state_with(false));
        let pos = |id: usize| {
            rows.iter()
                .position(|r| r.id == id)
                .unwrap_or_else(|| panic!("row {id} missing"))
        };
        assert!(
            pos(ids::INSTALL_VCAM) > pos(ids::CAMERA),
            "the install row should come after the camera it installs"
        );
        assert!(
            pos(ids::INSTALL_VCAM) < pos(ids::MICROPHONE),
            "and before the rows it has nothing to do with"
        );
    }
}

#[cfg(test)]
mod notify_row_tests {
    use super::{ids, is_on, menu_rows, MenuState, Row};

    /// The relay is a privacy switch, and a switch whose state cannot be read
    /// is one nobody will believe is off. The row's *label* carries it too, but
    /// a tick is the native signal and the Mac uses one.
    #[test]
    fn the_relay_row_shows_whether_it_is_on() {
        let off = MenuState {
            notify_relay: false,
            ..MenuState::default()
        };
        let on = MenuState {
            notify_relay: true,
            ..MenuState::default()
        };
        assert!(!is_on(ids::NOTIFY, &off));
        assert!(is_on(ids::NOTIFY, &on));
    }

    /// The label has to say which state it is in, because a tick alone does not
    /// tell a user what turning it *does*.
    ///
    /// Checked against the source strings, not the rendered one: a test that
    /// only ever sees the machine's own language is a test that has silently
    /// stopped checking the other one.
    #[test]
    fn the_relay_row_says_on_or_off_in_both_languages() {
        use super::{NOTIFY_LABEL_OFF, NOTIFY_LABEL_ON};
        for (on, needle_zh, needle_en) in [(true, "开", "on"), (false, "关", "off")] {
            let rows = menu_rows(&MenuState {
                notify_relay: on,
                ..MenuState::default()
            });
            let row = rows
                .iter()
                .find(|r| r.id == ids::NOTIFY)
                .expect("the relay row must always be present — it is the switch");
            assert_eq!(row.kind, Row::Item, "it has to be clickable");
            let (zh, en) = if on {
                NOTIFY_LABEL_ON
            } else {
                NOTIFY_LABEL_OFF
            };
            assert!(zh.contains(needle_zh), "zh on={on}: {zh:?}");
            assert!(en.contains(needle_en), "en on={on}: {en:?}");
        }
    }

    /// It is a toggle, so it is always there — unlike the virtual-camera row,
    /// which is only there when there is something to do. A control that
    /// deletes itself when turned off is unusable.
    #[test]
    fn the_relay_row_is_present_in_both_states() {
        for on in [true, false] {
            let rows = menu_rows(&MenuState {
                notify_relay: on,
                ..MenuState::default()
            });
            assert!(
                rows.iter().any(|r| r.id == ids::NOTIFY),
                "on={on}: the row vanished"
            );
        }
    }
}
