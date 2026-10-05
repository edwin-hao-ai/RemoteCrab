//! Wire-compatibility guard: asserts the EXACT JSON keys and enum raw values
//! the Rust port emits/accepts, matching the Swift sources one-for-one.
//!
//! Why this exists: an early port used `#[serde(rename_all = "camelCase")]`
//! everywhere, which turns `icon_png` into `iconPng` — but Swift's property
//! is `iconPNG`, so the iPhone would silently receive no app icons. This
//! test makes that class of mismatch impossible to reintroduce.
//!
//! Ground truth: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift`
//! and `IBProtocol.swift`. Field names below are copied from there verbatim.

use rc_protocol::*;
use serde_json::Value;

fn keys<T: serde::Serialize>(v: &T) -> Vec<String> {
    let Value::Object(map) = serde_json::to_value(v).unwrap() else {
        panic!("expected a JSON object");
    };
    let mut k: Vec<String> = map.keys().cloned().collect();
    k.sort();
    k
}

fn assert_keys<T: serde::Serialize>(v: &T, expected: &[&str]) {
    let mut want: Vec<String> = expected.iter().map(|s| s.to_string()).collect();
    want.sort();
    assert_eq!(keys(v), want);
}

#[test]
fn touch_event_keys() {
    let t = TouchEvent {
        phase: TouchPhase::Move,
        x: 0.0,
        y: 0.0,
        dx: 0.0,
        dy: 0.0,
        modifiers: 0,
        momentum: Some(false),
        timestamp_micros: 0,
    };
    assert_keys(&t, &["phase", "x", "y", "dx", "dy", "modifiers", "momentum", "timestampMicros"]);
}

#[test]
fn key_event_keys() {
    let k = KeyEvent {
        action: KeyAction::Down,
        keycode: Some(1),
        text: None,
        modifiers: 0,
        timestamp_micros: 0,
    };
    assert_keys(&k, &["action", "keycode", "modifiers", "timestampMicros"]);
}

#[test]
fn stream_metadata_keys() {
    let m = StreamMetadata {
        version: 1,
        device_name: "d".into(),
        width: 1,
        height: 1,
        fps: 1,
        bitrate_bps: 1,
        codec: "h264".into(),
        sps: Some(vec![1]),
        pps: None,
    };
    assert_keys(&m, &["version", "deviceName", "width", "height", "fps", "bitrateBps", "codec", "sps"]);
}

#[test]
fn audio_packet_keys() {
    let a = AudioPacket {
        opus_data: vec![1],
        sample_rate: 48_000,
        channels: 1,
        timestamp_micros: 0,
        codec: AUDIO_CODEC_OPUS.into(),
    };
    assert_keys(&a, &["opusData", "sampleRate", "channels", "timestampMicros", "codec"]);
}

#[test]
fn feature_state_keys() {
    let s = FeatureStateSnapshot {
        camera_on: true,
        mic_on: true,
        voice_on: true,
        trackpad_on: true,
        keyboard_on: true,
        active_surface: Surface::Trackpad,
        camera_position: CameraPosition::Back,
        screen_on: true,
        speaker_on: true,
        timestamp_micros: 0,
    };
    assert_keys(
        &s,
        &[
            "cameraOn", "micOn", "voiceOn", "trackpadOn", "keyboardOn",
            "activeSurface", "cameraPosition", "screenOn", "speakerOn",
            "timestampMicros",
        ],
    );
}

#[test]
fn feature_state_decodes_without_screen_on() {
    // Older iOS builds don't send `screenOn`; it must default to false
    // rather than fail the whole snapshot decode.
    let json = r#"{"cameraOn":true,"micOn":false,"voiceOn":false,"trackpadOn":true,
        "keyboardOn":true,"activeSurface":"trackpad","cameraPosition":"back","timestampMicros":1}"#;
    let snap: FeatureStateSnapshot = serde_json::from_str(json).unwrap();
    assert!(!snap.screen_on);
}

/// The same obligation for `speakerOn`, and it is the one field whose absence
/// has a consequence rather than just a default: `speakerOn` is the ONLY thing
/// that starts the loopback capture, so a phone build that predates the feature
/// must read as "not asking" instead of failing the decode and taking camera,
/// mic and mirror control down with it (rule 2).
#[test]
fn feature_state_decodes_without_speaker_on() {
    let json = r#"{"cameraOn":true,"micOn":false,"voiceOn":false,"trackpadOn":true,
        "keyboardOn":true,"activeSurface":"trackpad","cameraPosition":"back","timestampMicros":1}"#;
    let snap: FeatureStateSnapshot = serde_json::from_str(json).unwrap();
    assert!(!snap.speaker_on);
}

/// The previous on-the-wire shape must load with NOTHING lost — not just with
/// the new key defaulted. `assert_keys` above pins what we send; this pins that
/// a phone which never heard of the speaker still controls everything else.
#[test]
fn a_snapshot_from_before_the_speaker_keeps_every_field_it_had() {
    let json = r#"{"cameraOn":true,"micOn":true,"voiceOn":false,"trackpadOn":true,
        "keyboardOn":false,"activeSurface":"keyboard","cameraPosition":"front",
        "screenOn":true,"timestampMicros":4242}"#;
    let snap: FeatureStateSnapshot = serde_json::from_str(json).unwrap();
    assert!(snap.camera_on && snap.mic_on && snap.trackpad_on && snap.screen_on);
    assert!(!snap.voice_on && !snap.keyboard_on && !snap.speaker_on);
    assert_eq!(snap.active_surface, Surface::Keyboard);
    assert_eq!(snap.camera_position, CameraPosition::Front);
    assert_eq!(snap.timestamp_micros, 4242);
}

#[test]
fn client_hello_keys() {
    let h = ClientHello {
        name: "n".into(),
        id: "i".into(),
        token: Some("t".into()),
        app_version: "v".into(),
        platform: Some("windows".into()),
    };
    // `platform` is the additive field this port introduced; it must serialize
    // as exactly "platform" so iOS (which now reads it) sees it.
    assert_keys(&h, &["name", "id", "token", "appVersion", "platform"]);
}

#[test]
fn session_reply_keys() {
    let r = SessionReply {
        result: SessionReplyResult::Busy,
        owner_name: Some("o".into()),
        token: None,
    };
    assert_keys(&r, &["result", "ownerName"]);
}

#[test]
fn app_info_keys_use_capital_acronyms() {
    // THE regression this test exists for: Swift sends `iconPNG`, not `iconPng`.
    let a = AppInfo {
        id: "pid:1".into(),
        name: "App".into(),
        pid: 1,
        is_active: true,
        icon_png: Some(vec![1, 2, 3]),
    };
    assert_keys(&a, &["id", "name", "pid", "isActive", "iconPNG"]);
    let json = serde_json::to_string(&a).unwrap();
    assert!(json.contains("\"iconPNG\""), "json = {json}");
    assert!(!json.contains("iconPng"), "json = {json}");
}

#[test]
fn window_info_keys_use_capital_acronyms() {
    // Swift sends `snapshotJPEG`, not `snapshotJpeg`.
    let w = WindowInfo {
        id: "1:2".into(),
        app_id: "pid:1".into(),
        app_name: "App".into(),
        title: "T".into(),
        is_active: false,
        width: 1.0,
        height: 2.0,
        snapshot_jpeg: Some(vec![9]),
    };
    assert_keys(
        &w,
        &["id", "appId", "appName", "title", "isActive", "width", "height", "snapshotJPEG"],
    );
    let json = serde_json::to_string(&w).unwrap();
    assert!(json.contains("\"snapshotJPEG\""), "json = {json}");
    assert!(!json.contains("snapshotJpeg"), "json = {json}");
}

#[test]
fn window_list_keys() {
    let w = WindowList {
        windows: vec![],
        can_capture: false,
    };
    assert_keys(&w, &["windows", "canCapture"]);
}

#[test]
fn file_keys() {
    assert_keys(
        &FileOffer { id: "f".into(), name: "n".into(), size: 1 },
        &["id", "name", "size"],
    );
    assert_keys(&FileComplete { id: "f".into() }, &["id"]);
    assert_keys(
        &FileAck {
            id: "f".into(),
            status: FileAckStatus::Saved,
            received_bytes: 3,
            path: Some("p".into()),
        },
        &["id", "status", "receivedBytes", "path"],
    );
}

#[test]
fn misc_command_keys() {
    assert_keys(&ActivateApp { id: "i".into(), window_title: Some("t".into()) }, &["id", "windowTitle"]);
    assert_keys(&QuitApp { id: "i".into(), force: true }, &["id", "force"]);
    assert_keys(&Clipboard { text: "x".into() }, &["text"]);
    assert_keys(&CameraCommand { position: CameraPosition::Front }, &["position"]);
    assert_keys(&TextCommandMessage { command: TextCommand::Uppercase }, &["command"]);
    assert_keys(&SystemCommand { command: SystemCommandKind::VolumeUp, argument: None }, &["command"]);
    assert_keys(&FeatureControl { feature: Feature::Camera, enabled: true }, &["feature", "enabled"]);
}

/// Enum raw values, exactly as the Swift `String` raw values declare them.
#[test]
fn enum_raw_values() {
    let pairs: &[(&str, &str)] = &[
        ("openURL", "system command OpenUrl"),
    ];
    for (wire, what) in pairs {
        let json = serde_json::to_string(&SystemCommand {
            command: SystemCommandKind::OpenUrl,
            argument: None,
        })
        .unwrap();
        assert!(json.contains(&format!("\"{wire}\"")), "{what}: {json}");
    }

    // A few more that are easy to get wrong.
    assert!(serde_json::to_string(&Surface::CameraPreview).unwrap().contains("cameraPreview"));
    assert!(serde_json::to_string(&TextCommand::TrimWhitespace).unwrap().contains("trimWhitespace"));
    assert!(serde_json::to_string(&TextCommand::StripNewlines).unwrap().contains("stripNewlines"));
    assert!(serde_json::to_string(&SessionReplyResult::Accepted).unwrap().contains("accepted"));
    // The phone sends this when its user taps Disconnect; a typo here means the
    // receiver fails to decode the frame and silently keeps reconnecting.
    assert!(serde_json::to_string(&SessionReplyResult::Off).unwrap().contains("off"));
    assert_eq!(
        serde_json::from_str::<SessionReplyResult>("\"off\"").unwrap(),
        SessionReplyResult::Off
    );
    assert!(serde_json::to_string(&TouchPhase::ThreeFingerSwipe).unwrap().contains("threeFingerSwipe"));
    assert!(serde_json::to_string(&TouchPhase::ForceClick).unwrap().contains("forceClick"));
    assert!(serde_json::to_string(&Feature::Microphone).unwrap().contains("microphone"));
    assert!(serde_json::to_string(&CameraPosition::Back).unwrap().contains("back"));
    assert!(serde_json::to_string(&FileAckStatus::Progress).unwrap().contains("progress"));
    assert!(serde_json::to_string(&KeyAction::Text).unwrap().contains("text"));
}

#[test]
fn installed_app_keys_use_capital_acronyms() {
    // Swift `IBInstalledApp` also declares `iconPNG`.
    let a = InstalledApp {
        id: "x".into(),
        name: "App".into(),
        icon_png: Some(vec![1]),
    };
    assert_keys(&a, &["id", "name", "iconPNG"]);
    assert!(serde_json::to_string(&a).unwrap().contains("\"iconPNG\""));
}

#[test]
fn screen_control_keys() {
    let c = ScreenControl {
        command: ScreenControlCommand::Select,
        window_id: Some("1:2".into()),
        max_pixel: Some(2560),
    };
    assert_keys(&c, &["command", "windowId", "maxPixel"]);
}

#[test]
fn screen_input_keys() {
    let i = ScreenInput {
        action: ScreenInputAction::Click,
        u: 0.5,
        v: 0.5,
        dx: 0.0,
        dy: 0.0,
        modifiers: 0,
        click_count: 2,
        timestamp_micros: 7,
    };
    assert_keys(
        &i,
        &["action", "u", "v", "dx", "dy", "modifiers", "clickCount", "timestampMicros"],
    );
}

#[test]
fn screen_info_keys() {
    let s = ScreenInfo {
        status: ScreenStatus::Ok,
        window_id: Some("1:2".into()),
        app_id: Some("pid:1".into()),
        app_name: Some("App".into()),
        title: Some("T".into()),
        origin_x: 1.0,
        origin_y: 2.0,
        width: 3.0,
        height: 4.0,
        pixel_width: 100,
        pixel_height: 200,
        shows_cursor: true,
    };
    assert_keys(
        &s,
        &[
            "status", "windowId", "appId", "appName", "title", "originX", "originY",
            "width", "height", "pixelWidth", "pixelHeight", "showsCursor",
        ],
    );
}

#[test]
fn feature_and_surface_accept_the_screen_variant() {
    // iOS gained `IBFeature.screen` and `Surface.screen` for the mirror.
    // Without these variants the whole featureState/featureControl frame
    // failed to decode the moment the user opened the mirror.
    assert!(serde_json::to_string(&Feature::Screen).unwrap().contains("\"screen\""));
    assert!(serde_json::to_string(&Surface::Screen).unwrap().contains("\"screen\""));

    // Decode a snapshot exactly as the iPhone sends it while mirroring.
    let json = r#"{"cameraOn":false,"micOn":false,"voiceOn":false,"trackpadOn":false,
        "keyboardOn":false,"activeSurface":"screen","cameraPosition":"back",
        "screenOn":true,"timestampMicros":9}"#;
    let snap: FeatureStateSnapshot = serde_json::from_str(json).unwrap();
    assert_eq!(snap.active_surface, Surface::Screen);
    assert!(snap.screen_on);

    let ctrl: FeatureControl = serde_json::from_str(r#"{"feature":"screen","enabled":true}"#).unwrap();
    assert_eq!(ctrl.feature, Feature::Screen);
}

#[test]
fn screen_enum_raw_values() {
    assert!(serde_json::to_string(&ScreenStatus::Ok).unwrap().contains("\"ok\""));
    assert!(serde_json::to_string(&ScreenStatus::PermissionDenied)
        .unwrap()
        .contains("\"permissionDenied\""));
    assert!(serde_json::to_string(&ScreenStatus::NoWindow).unwrap().contains("\"noWindow\""));
    assert!(serde_json::to_string(&ScreenControlCommand::Start).unwrap().contains("\"start\""));
    assert!(serde_json::to_string(&ScreenControlCommand::Extend).unwrap().contains("\"extend\""));
    assert!(serde_json::to_string(&ScreenInputAction::RightClick)
        .unwrap()
        .contains("\"rightClick\""));
    assert!(serde_json::to_string(&ScreenInputAction::DragStart)
        .unwrap()
        .contains("\"dragStart\""));
}

/// Decode a JSON document shaped exactly like Swift would emit it.
#[test]
fn decodes_swift_shaped_app_info() {
    let json = r#"{"id":"pid:42","name":"Safari","pid":42,"isActive":true,"iconPNG":"AQID"}"#;
    let app: AppInfo = serde_json::from_str(json).unwrap();
    assert_eq!(app.name, "Safari");
    assert_eq!(app.icon_png, Some(vec![1, 2, 3]));
}

#[test]
fn decodes_swift_shaped_window_info() {
    let json = r#"{"id":"1:2","appId":"pid:1","appName":"App","title":"T","isActive":false,"width":10.5,"height":20.5,"snapshotJPEG":"BAUG"}"#;
    let w: WindowInfo = serde_json::from_str(json).unwrap();
    assert_eq!(w.width, 10.5);
    assert_eq!(w.snapshot_jpeg, Some(vec![4, 5, 6]));
}
