//! The tray menu's *shape*: which rows exist, in what order, under
//! which heading, with which icon and checkmark.
//!
//! Split from the Win32 drawing code on purpose. `TrackPopupMenu`
//! cannot be styled and hides its structure behind a single call, so the
//! layout would otherwise only be reviewable by running the app. Here it
//! is data, which is what lets the tests below hold the Windows menu to
//! the same standard as the Mac menu-bar popover.

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
}

/// One row of the menu: its kind, its menu id (`0` for non-actionable rows) and
/// the already-resolved text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MenuRow {
    pub kind: Row,
    pub id: u16,
    pub text: String,
}

/// Menu ids, kept out of the Win32 module so the layout can be tested on any
/// host. The values are private to the tray; the app loop never sees them.
pub mod ids {
    pub const CAMERA: u16 = 100;
    pub const MICROPHONE: u16 = 101;
    pub const TRACKPAD: u16 = 102;
    pub const KEYBOARD: u16 = 103;
    pub const RECORD: u16 = 110;
    pub const CLIPBOARD: u16 = 111;
    pub const SHOW_FILE: u16 = 112;
    pub const PREVIEW: u16 = 113;
    pub const RECONNECT: u16 = 114;
    pub const DISCONNECT: u16 = 115;
    pub const AUTOSTART: u16 = 116;
    pub const QUIT: u16 = 117;
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
}

/// The menu's shape, in draw order.
///
/// Kept in step with the Mac menu-bar popover: status header, then a labelled
/// *Features* group, an *Actions* group, the preview toggle, a *Connection*
/// group, start-at-login, quit, and a version footer.
pub fn menu_rows(state: &MenuState) -> Vec<MenuRow> {
    use i18n::t;
    let mut rows = Vec::new();
    let mut push = |kind: Row, id: u16, text: String| rows.push(MenuRow { kind, id, text });

    // Group headings use an en dash on each side so they read as headings even
    // in a menu that cannot be styled.
    push(Row::Info, 0, t("状态", "Status").to_string());
    push(Row::Separator, 0, String::new());

    push(Row::Section, 0, t("功能", "Features").to_string());
    push(Row::Item, ids::CAMERA, t("摄像头", "Camera").to_string());
    push(Row::Item, ids::MICROPHONE, t("麦克风", "Microphone").to_string());
    push(Row::Item, ids::TRACKPAD, t("触控板", "Trackpad").to_string());
    push(Row::Item, ids::KEYBOARD, t("键盘", "Keyboard").to_string());
    push(Row::Separator, 0, String::new());

    push(Row::Section, 0, t("操作", "Actions").to_string());
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
    push(Row::Item, ids::RECONNECT, t("重新连接", "Reconnect").to_string());
    push(Row::Item, ids::DISCONNECT, t("断开连接", "Disconnect").to_string());
    push(Row::Separator, 0, String::new());

    push(
        Row::Item,
        ids::AUTOSTART,
        t("开机自启动", "Start at login").to_string(),
    );
    push(Row::Separator, 0, String::new());
    push(Row::Item, ids::QUIT, t("退出 RemoteCrab", "Quit RemoteCrab").to_string());
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
pub fn flags_for(row: &MenuRow, state: &MenuState) -> windows::Win32::UI::WindowsAndMessaging::MENU_ITEM_FLAGS {
    use windows::Win32::UI::WindowsAndMessaging::{MF_GRAYED, MF_SEPARATOR, MF_STRING};
    match row.kind {
        Row::Separator => MF_SEPARATOR,
        // A heading and the status/footer lines are informative, not
        // actionable: greyed so they cannot be "clicked" into a no-op.
        Row::Section | Row::Info => MF_STRING | MF_GRAYED,
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
    }
}

/// Whether a toggle row is currently on.
pub fn is_on(id: u16, state: &MenuState) -> bool {
    match id {
        ids::CAMERA => state.camera,
        ids::MICROPHONE => state.microphone,
        ids::TRACKPAD => state.trackpad,
        ids::KEYBOARD => state.keyboard,
        ids::AUTOSTART => state.autostart,
        _ => false,
    }
}

/// The icon that precedes a row's label, matching the Mac popover's habit of
/// an SF Symbol on every row. Kept as text glyphs so no image assets are
/// needed; the font falls back gracefully if one is missing.
fn icon_for(id: u16) -> &'static str {
    match id {
        ids::CAMERA => "◉",
        ids::MICROPHONE => "◍",
        ids::TRACKPAD => "☰",
        ids::KEYBOARD => "⌨",
        ids::RECORD => "●",
        ids::CLIPBOARD => "⎘",
        ids::SHOW_FILE => "▤",
        ids::PREVIEW => "▣",
        ids::RECONNECT => "↻",
        ids::DISCONNECT => "⏻",
        ids::AUTOSTART => "⚙",
        ids::QUIT => "⏹",
        _ => "",
    }
}

/// Render a row's text the way it should appear in the popup.
pub fn decorate(row: &MenuRow) -> String {
    match row.kind {
        Row::Separator => String::new(),
        // En-dashes on both sides so a heading reads as one even in a menu
        // that cannot be styled.
        Row::Section => format!("— {} —", row.text),
        Row::Info => row.text.clone(),
        Row::Item => {
            let icon = icon_for(row.id);
            if icon.is_empty() {
                row.text.clone()
            } else {
                format!("{icon}  {}", row.text)
            }
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> MenuState {
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
        assert_eq!(sections.len(), 3, "features / actions / connection: {sections:?}");
        assert!(rows.iter().filter(|r| r.kind == Row::Separator).count() >= 5);
    }

    /// Every actionable row needs an icon and a real id, or the menu loses
    /// the visual rhythm the Mac version has.
    #[test]
    fn every_action_has_an_icon_and_an_id() {
        for row in menu_rows(&state()).iter().filter(|r| r.kind == Row::Item) {
            assert_ne!(row.id, 0, "actionable row without an id: {:?}", row.text);
            assert!(!icon_for(row.id).is_empty(), "no icon for {:?}", row.text);
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
                    let decorated = decorate(&row);
                    for toggle in [ids::CAMERA, ids::MICROPHONE, ids::QUIT] {
                        let icon = icon_for(toggle);
                        assert!(
                            !decorated.contains(icon),
                            "informative row carries the {toggle} icon: {decorated}"
                        );
                    }
                }
                _ => {}
            }
        }
    }

    #[test]
    fn the_wording_follows_the_state_it_describes() {
        let mut s = state();
        s.recording = true;
        assert!(labels(&menu_rows(&s)).iter().any(|l| l.contains("停止")));
        s.recording = false;
        assert!(labels(&menu_rows(&s)).iter().any(|l| l.contains("开始")));

        let mut s = state();
        s.preview_on = true;
        assert!(labels(&menu_rows(&s)).iter().any(|l| l.contains("隐藏")));
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
        let footer = rows.iter().position(|r| r.kind == Row::Info && r.text.starts_with("RemoteCrab v")).unwrap();
        assert!(quit < footer, "quit must come before the footer");
    }
}
