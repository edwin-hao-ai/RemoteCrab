//! Frame decoding: bytes in, `Event`s out.
//!
//! Split out of `lib.rs` because it is a different job: the supervisor
//! decides *when* to connect and what to do when a link drops; this
//! decides what an incoming frame *means*. `dispatch_frame`鈥檚 arms are
//! the complete list of the kinds the receiver acts on.

use std::collections::VecDeque;

use rc_protocol::{
    decode_activate_app, decode_audio, decode_clipboard, decode_feature_state,
    decode_file_complete, decode_file_offer, decode_key, decode_metadata, decode_quit_app,
    decode_screen_control, decode_screen_input, decode_system_command, decode_text_command,
    decode_touch, Frame, Kind, NalFrame, NalKind,
};
use tokio::io::AsyncReadExt;
use tokio::sync::broadcast;


use super::{emit, Event, Parser};

pub(crate) async fn next_frame(
    read_half: &mut tokio::net::tcp::OwnedReadHalf,
    parser: &mut Parser,
    queue: &mut VecDeque<Frame>,
    buf: &mut [u8],
) -> Option<Frame> {
    loop {
        if let Some(f) = queue.pop_front() {
            return Some(f);
        }
        let n = read_half.read(buf).await.ok()?;
        if n == 0 {
            return None;
        }
        for f in parser.append(&buf[..n]) {
            queue.push_back(f);
        }
    }
}

pub(crate) fn dispatch_frame(frame: &Frame, events_tx: &broadcast::Sender<Event>) {
    match frame.kind {
        Kind::Metadata => {
            if let Ok(m) = decode_metadata(frame) {
                emit(events_tx, Event::Metadata(m));
            }
        }
        // App-window mirror: the iPhone drives it with `screenControl` /
        // `screenInput` (kinds 0x1D/0x1E); the receiver answers with
        // `screenSps`/`screenPps`/`screenVideo`/`screenInfo` (0x1A–0x1C/0x1F)
        // via `send_frame`. The video kinds are decoded here.
        Kind::ScreenControl => {
            if let Ok(c) = decode_screen_control(frame) {
                emit(events_tx, Event::ScreenControl(c));
            }
        }
        Kind::ScreenInput => {
            if let Ok(i) = decode_screen_input(frame) {
                emit(events_tx, Event::ScreenInput(i));
            }
        }
        k if k.is_screen_mirror() => {}
        Kind::Video | Kind::Sps | Kind::Pps => {
            let kind = match frame.kind {
                Kind::Sps => NalKind::Sps,
                Kind::Pps => NalKind::Pps,
                _ => NalKind::Video,
            };
            emit(
                events_tx,
                Event::Video(NalFrame {
                    kind,
                    data: frame.payload.clone(),
                    timestamp_micros: 0,
                }),
            );
        }
        Kind::Touch => {
            if let Ok(t) = decode_touch(frame) {
                emit(events_tx, Event::Touch(t));
            }
        }
        Kind::Key => {
            if let Ok(k) = decode_key(frame) {
                emit(events_tx, Event::Key(k));
            }
        }
        Kind::Audio => {
            if let Ok(a) = decode_audio(frame) {
                emit(events_tx, Event::Audio(a));
            }
        }
        Kind::FeatureState => {
            if let Ok(s) = decode_feature_state(frame) {
                emit(events_tx, Event::FeatureState(s));
            }
        }
        Kind::ClipboardSet => {
            if let Ok(c) = decode_clipboard(frame) {
                emit(events_tx, Event::Clipboard(c));
            }
        }
        Kind::TextCommand => {
            if let Ok(c) = decode_text_command(frame) {
                emit(events_tx, Event::TextCommand(c));
            }
        }
        Kind::SystemCommand => {
            if let Ok(c) = decode_system_command(frame) {
                emit(events_tx, Event::SystemCommand(c));
            }
        }
        Kind::ActivateApp => {
            if let Ok(a) = decode_activate_app(frame) {
                emit(events_tx, Event::ActivateApp(a));
            }
        }
        Kind::QuitApp => {
            if let Ok(q) = decode_quit_app(frame) {
                emit(events_tx, Event::QuitApp(q));
            }
        }
        Kind::AppListRequest => {
            // The iPhone wants a fresh app list; the app layer answers.
            emit(events_tx, Event::AppListRequested);
        }
        Kind::WindowListRequest => {
            emit(events_tx, Event::WindowListRequested);
        }
        Kind::InstalledAppsRequest => {
            emit(events_tx, Event::InstalledAppsRequested);
        }
        Kind::AppList => {
            if let Ok(list) = rc_protocol::decode_app_list(frame) {
                emit(events_tx, Event::AppList(list));
            }
        }
        Kind::WindowList => {
            if let Ok(list) = rc_protocol::decode_window_list(frame) {
                emit(events_tx, Event::WindowList(list));
            }
        }
        Kind::FileOffer => {
            if let Ok(o) = decode_file_offer(frame) {
                emit(events_tx, Event::FileOffer(o));
            }
        }
        Kind::FileChunk => emit(events_tx, Event::FileChunk(frame.payload.clone())),
        Kind::FileComplete => {
            if let Ok(c) = decode_file_complete(frame) {
                emit(events_tx, Event::FileComplete(c));
            }
        }
        // A relayed desktop notification. Windows *sends* these rather than
        // receiving them, so this arm exists for symmetry and for the case
        // where a peer sends one — recognised on purpose either way: without
        // the kind it would decode as `Video` and the JSON payload would reach
        // the H.264 decoder.
        // A command outcome from a peer. Recognised rather than dropped,
        // because a dropped `0x23` is a button on the phone that does nothing
        // with no explanation anywhere.
        Kind::CommandResult => {
            if let Ok(r) = rc_protocol::decode_command_result(frame) {
                emit(events_tx, Event::CommandResult(r));
            }
        }
        Kind::Notification => {
            if let Ok(n) = rc_protocol::decode_notification(frame) {
                emit(events_tx, Event::Notification(n));
            }
        }
        _ => {}
    }
}





#[cfg(test)]
mod dispatch_tests {
    //! Regression: `activateApp` (0x0E) and `quitApp` (0x16) used to fall
    //! through `dispatch_frame`'s catch-all, so the iPhone's app switcher
    //! silently did nothing on Windows.
    use super::*;
    use rc_protocol::{encode_activate_app, encode_quit_app, ActivateApp, QuitApp};

    fn parse_one(bytes: Vec<u8>) -> Frame {
        let mut parser = Parser::new();
        let mut frames = parser.append(&bytes);
        assert_eq!(frames.len(), 1, "expected exactly one frame");
        frames.remove(0)
    }

    #[test]
    fn activate_app_is_dispatched_not_dropped() {
        let bytes = encode_activate_app(&ActivateApp {
            id: "pid:42".to_string(),
            window_title: None,
        })
        .unwrap();
        let (tx, mut rx) = broadcast::channel(16);
        dispatch_frame(&parse_one(bytes), &tx);
        match rx.try_recv() {
            Ok(Event::ActivateApp(a)) => assert_eq!(a.id, "pid:42"),
            other => panic!("expected ActivateApp, got {other:?}"),
        }
    }

    #[test]
    fn quit_app_is_dispatched_not_dropped() {
        let bytes = encode_quit_app(&QuitApp {
            id: "pid:7".to_string(),
            force: true,
        })
        .unwrap();
        let (tx, mut rx) = broadcast::channel(16);
        dispatch_frame(&parse_one(bytes), &tx);
        match rx.try_recv() {
            Ok(Event::QuitApp(q)) => {
                assert_eq!(q.id, "pid:7");
                assert!(q.force);
            }
            other => panic!("expected QuitApp, got {other:?}"),
        }
    }
}
#[cfg(test)]
mod screen_dispatch_tests {
    //! `screenControl`/`screenInput` used to fall through the mirror
    //! catch-all, so the iPhone's mirror did nothing on Windows.
    use super::*;
    use rc_protocol::{
        encode_screen_control, encode_screen_input, ScreenControl, ScreenControlCommand,
        ScreenInput, ScreenInputAction,
    };

    fn parse_one(bytes: Vec<u8>) -> Frame {
        let mut parser = Parser::new();
        let mut frames = parser.append(&bytes);
        assert_eq!(frames.len(), 1);
        frames.remove(0)
    }

    #[test]
    fn screen_control_and_input_are_dispatched() {
        let control = ScreenControl {
            command: ScreenControlCommand::Select,
            window_id: Some("42:7".to_string()),
            max_pixel: Some(1920),
        };
        let input = ScreenInput {
            action: ScreenInputAction::DragMove,
            u: 0.5,
            v: 0.25,
            dx: -0.1,
            dy: 0.1,
            modifiers: 8,
            click_count: 2,
            timestamp_micros: 99,
        };
        let (tx, mut rx) = broadcast::channel(16);
        dispatch_frame(&parse_one(encode_screen_control(&control).unwrap()), &tx);
        dispatch_frame(&parse_one(encode_screen_input(&input).unwrap()), &tx);
        match rx.try_recv() {
            Ok(Event::ScreenControl(c)) => assert_eq!(c, control),
            other => panic!("expected ScreenControl, got {other:?}"),
        }
        match rx.try_recv() {
            Ok(Event::ScreenInput(i)) => assert_eq!(i, input),
            other => panic!("expected ScreenInput, got {other:?}"),
        }
    }
}

