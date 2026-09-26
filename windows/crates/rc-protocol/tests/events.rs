//! Ports of `IBEventsTests.swift` + `TextTransformTests.swift` and a few
//! wire-level compatibility checks.

use rc_protocol::*;

#[test]
fn touch_event_round_trip() {
    let event = TouchEvent {
        phase: TouchPhase::Move,
        x: 0.42,
        y: 0.73,
        dx: 0.01,
        dy: 0.02,
        modifiers: 9, // shift + command
        momentum: None,
        timestamp_micros: 1_234_567,
    };

    let data = encode_touch(&event).unwrap();
    let mut parser = Parser::new();
    let frames = parser.append(&data);

    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::Touch);
    assert_eq!(decode_touch(&frames[0]).unwrap(), event);
}

#[test]
fn touch_event_modifier_flags() {
    let plain = TouchEvent {
        phase: TouchPhase::Down,
        x: 0.0,
        y: 0.0,
        dx: 0.0,
        dy: 0.0,
        modifiers: 0,
        momentum: None,
        timestamp_micros: 0,
    };
    assert!(!plain.has_command());

    let cmd = TouchEvent {
        modifiers: Modifier::COMMAND,
        ..plain.clone()
    };
    assert!(cmd.has_command());
    assert!(!cmd.has_shift());

    let combined = TouchEvent {
        phase: TouchPhase::Move,
        modifiers: Modifier::SHIFT | Modifier::COMMAND | Modifier::OPTION,
        ..plain.clone()
    };
    assert!(combined.has_shift());
    assert!(combined.has_command());
    assert!(combined.has_option());
    assert!(!combined.has_control());
}

#[test]
fn all_touch_phases_round_trip() {
    for phase in [
        TouchPhase::Down,
        TouchPhase::Move,
        TouchPhase::Up,
        TouchPhase::RightDown,
        TouchPhase::RightUp,
        TouchPhase::Scroll,
        TouchPhase::Click,
    ] {
        let event = TouchEvent {
            phase,
            x: 0.0,
            y: 0.0,
            dx: 0.0,
            dy: 0.0,
            modifiers: 0,
            momentum: None,
            timestamp_micros: 0,
        };
        let encoded = encode_touch(&event).unwrap();
        let mut parser = Parser::new();
        let frames = parser.append(&encoded);
        assert_eq!(frames.len(), 1);
        assert_eq!(decode_touch(&frames[0]).unwrap().phase, phase);
    }
}

#[test]
fn key_event_down_round_trip() {
    let event = KeyEvent {
        action: KeyAction::Down,
        keycode: Some(0x04),
        text: None,
        modifiers: Modifier::SHIFT,
        timestamp_micros: 999,
    };
    let encoded = encode_key(&event).unwrap();
    let mut parser = Parser::new();
    let frames = parser.append(&encoded);
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::Key);
    let decoded = decode_key(&frames[0]).unwrap();
    assert_eq!(decoded, event);
    assert_eq!(decoded.action, KeyAction::Down);
    assert_eq!(decoded.keycode, Some(0x04));
    assert!(decoded.text.is_none());
}

#[test]
fn key_event_text_round_trip() {
    let event = KeyEvent {
        action: KeyAction::Text,
        keycode: None,
        text: Some("Hello, 世界".to_string()),
        modifiers: 0,
        timestamp_micros: 1_000_000,
    };
    let encoded = encode_key(&event).unwrap();
    let mut parser = Parser::new();
    let frames = parser.append(&encoded);
    assert_eq!(frames.len(), 1);
    let decoded = decode_key(&frames[0]).unwrap();
    assert_eq!(decoded.action, KeyAction::Text);
    assert_eq!(decoded.text.as_deref(), Some("Hello, 世界"));
    assert!(decoded.keycode.is_none());
}

#[test]
fn camera_command_round_trip() {
    for position in [CameraPosition::Front, CameraPosition::Back] {
        let encoded = encode_camera_command(&CameraCommand { position }).unwrap();
        let mut parser = Parser::new();
        let frames = parser.append(&encoded);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].kind, Kind::CameraCommand);
        assert_eq!(decode_camera_command(&frames[0]).unwrap().position, position);
    }
    assert_eq!(CameraPosition::Back.toggled(), CameraPosition::Front);
    assert_eq!(CameraPosition::Front.toggled(), CameraPosition::Back);
}

#[test]
fn audio_packet_round_trip() {
    let opus: Vec<u8> = (0..100u32).map(|i| (i * 7 % 256) as u8).collect();
    let packet = AudioPacket {
        opus_data: opus.clone(),
        sample_rate: 48_000,
        channels: 1,
        timestamp_micros: 50_000,
        codec: AUDIO_CODEC_PCM.to_string(),
    };

    let encoded = encode_audio(&packet).unwrap();
    let mut parser = Parser::new();
    let frames = parser.append(&encoded);
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::Audio);
    let decoded = decode_audio(&frames[0]).unwrap();
    assert_eq!(decoded, packet);
    assert_eq!(decoded.opus_data, opus);
    assert_eq!(decoded.sample_rate, 48_000);
    assert_eq!(decoded.channels, 1);
}

#[test]
fn audio_packet_large_opus_frame() {
    let opus: Vec<u8> = (0..4096u32).map(|i| (i * 13 % 256) as u8).collect();
    let packet = AudioPacket {
        opus_data: opus.clone(),
        sample_rate: 48_000,
        channels: 1,
        timestamp_micros: 0,
        codec: AUDIO_CODEC_OPUS.to_string(),
    };
    let encoded = encode_audio(&packet).unwrap();
    let mut parser = Parser::new();
    let frames = parser.append(&encoded);
    assert_eq!(frames.len(), 1);
    assert_eq!(decode_audio(&frames[0]).unwrap().opus_data, opus);
}

#[test]
fn legacy_audio_packet_without_codec_decodes_as_pcm() {
    // Pre-Opus builds send no `codec` key at all.
    let json = r#"{"opusData":"AQID","sampleRate":48000,"channels":1,"timestampMicros":12345}"#;
    let packet: AudioPacket = serde_json::from_str(json).unwrap();
    assert_eq!(packet.codec, AUDIO_CODEC_PCM);
    assert_eq!(packet.opus_data, vec![0x01, 0x02, 0x03]);
    assert_eq!(packet.sample_rate, 48_000);
}

#[test]
fn mixed_video_and_events_over_same_connection() {
    let mut parser = Parser::new();

    let mut stream = encode_metadata(&StreamMetadata {
        version: 1,
        device_name: "Mixed".to_string(),
        width: 1920,
        height: 1080,
        fps: 30,
        bitrate_bps: 4_000_000,
        codec: "h264".to_string(),
        sps: None,
        pps: None,
    })
    .unwrap();
    stream.extend_from_slice(&encode_nal(&NalFrame {
        kind: NalKind::Sps,
        data: vec![0x00, 0x00, 0x00, 0x01, 0x67],
        timestamp_micros: 0,
    }));
    stream.extend_from_slice(&encode_nal(&NalFrame {
        kind: NalKind::Pps,
        data: vec![0x00, 0x00, 0x00, 0x01, 0x68],
        timestamp_micros: 0,
    }));
    stream.extend_from_slice(
        &encode_touch(&TouchEvent {
            phase: TouchPhase::Down,
            x: 0.1,
            y: 0.1,
            dx: 0.0,
            dy: 0.0,
            modifiers: 0,
            momentum: None,
            timestamp_micros: 0,
        })
        .unwrap(),
    );
    stream.extend_from_slice(
        &encode_key(&KeyEvent {
            action: KeyAction::Text,
            keycode: None,
            text: Some("a".to_string()),
            modifiers: 0,
            timestamp_micros: 0,
        })
        .unwrap(),
    );
    stream.extend_from_slice(&encode_nal(&NalFrame {
        kind: NalKind::Video,
        data: vec![0x00, 0x00, 0x00, 0x01, 0x41],
        timestamp_micros: 33_000,
    }));
    stream.extend_from_slice(
        &encode_audio(&AudioPacket {
            opus_data: vec![0xAA, 0xBB, 0xCC],
            sample_rate: 48_000,
            channels: 1,
            timestamp_micros: 0,
            codec: AUDIO_CODEC_PCM.to_string(),
        })
        .unwrap(),
    );

    let frames = parser.append(&stream);
    assert_eq!(frames.len(), 7);
    assert_eq!(
        frames.iter().map(|f| f.kind).collect::<Vec<_>>(),
        vec![
            Kind::Metadata,
            Kind::Sps,
            Kind::Pps,
            Kind::Touch,
            Kind::Key,
            Kind::Video,
            Kind::Audio,
        ]
    );

    assert_eq!(decode_touch(&frames[3]).unwrap().phase, TouchPhase::Down);
    assert_eq!(decode_key(&frames[4]).unwrap().text.as_deref(), Some("a"));
    assert_eq!(decode_audio(&frames[6]).unwrap().opus_data, vec![0xAA, 0xBB, 0xCC]);
}

#[test]
fn feature_control_json_round_trip() {
    let control = FeatureControl {
        feature: Feature::Camera,
        enabled: false,
    };
    let data = serde_json::to_string(&control).unwrap();
    let decoded: FeatureControl = serde_json::from_str(&data).unwrap();
    assert_eq!(decoded, control);
    // Wire value check: the enum is a lowercase string.
    assert!(data.contains("\"camera\""));
}

#[test]
fn feature_state_snapshot_json_round_trip() {
    let snap = FeatureStateSnapshot {
        camera_on: true,
        mic_on: false,
        voice_on: false,
        trackpad_on: true,
        keyboard_on: true,
        active_surface: Surface::Trackpad,
        camera_position: CameraPosition::Front,
        timestamp_micros: 123_456,
    };
    let data = serde_json::to_string(&snap).unwrap();
    let decoded: FeatureStateSnapshot = serde_json::from_str(&data).unwrap();
    assert_eq!(decoded, snap);
}

#[test]
fn feature_state_defaults_camera_position_to_back() {
    // Older iOS builds omit `cameraPosition`.
    let json = r#"{"cameraOn":true,"micOn":false,"voiceOn":false,"trackpadOn":true,
        "keyboardOn":true,"activeSurface":"trackpad","timestampMicros":1}"#;
    let snap: FeatureStateSnapshot = serde_json::from_str(json).unwrap();
    assert_eq!(snap.camera_position, CameraPosition::Back);
}

#[test]
fn touch_event_new_phases_round_trip() {
    for phase in [
        TouchPhase::DragStart,
        TouchPhase::Pinch,
        TouchPhase::ThreeFingerSwipe,
        TouchPhase::ThreeFingerTap,
        TouchPhase::ForceClick,
    ] {
        let event = TouchEvent {
            phase,
            x: 0.5,
            y: 0.5,
            dx: 0.02,
            dy: 1.0,
            modifiers: 0,
            momentum: None,
            timestamp_micros: 0,
        };
        let data = serde_json::to_string(&event).unwrap();
        let decoded: TouchEvent = serde_json::from_str(&data).unwrap();
        assert_eq!(decoded, event);
    }
}

#[test]
fn touch_event_momentum_optional_round_trip() {
    let with_momentum = TouchEvent {
        phase: TouchPhase::Scroll,
        x: 0.0,
        y: 0.0,
        dx: 0.1,
        dy: -0.2,
        modifiers: 0,
        momentum: Some(true),
        timestamp_micros: 7,
    };
    let json = serde_json::to_string(&with_momentum).unwrap();
    assert!(json.contains("\"momentum\":true"));
    assert_eq!(
        serde_json::from_str::<TouchEvent>(&json).unwrap(),
        with_momentum
    );

    // Absent momentum decodes to None.
    let without: TouchEvent =
        serde_json::from_str(r#"{"phase":"move","x":0,"y":0,"dx":0,"dy":0,"modifiers":0,"timestampMicros":0}"#)
            .unwrap();
    assert_eq!(without.momentum, None);
}

#[test]
fn client_hello_round_trip_with_optional_platform() {
    let hello = ClientHello {
        name: "DESKTOP-ABC".to_string(),
        id: "uuid-1".to_string(),
        token: Some("tok".to_string()),
        app_version: "0.1.0".to_string(),
        platform: Some("windows".to_string()),
    };
    let json = serde_json::to_string(&hello).unwrap();
    assert!(json.contains("\"platform\":\"windows\""));
    assert_eq!(serde_json::from_str::<ClientHello>(&json).unwrap(), hello);

    // A Mac client (no platform key) still decodes.
    let mac_json = r#"{"name":"Mac","id":"uuid-2","token":null,"appVersion":"1.0"}"#;
    let mac: ClientHello = serde_json::from_str(mac_json).unwrap();
    assert_eq!(mac.platform, None);
}

#[test]
fn text_transform_matches_swift() {
    assert_eq!(TextCommand::Uppercase.apply("Hello World"), "HELLO WORLD");
    assert_eq!(TextCommand::Lowercase.apply("Hello World"), "hello world");
    assert_eq!(TextCommand::Capitalize.apply("hello world"), "Hello World");
    assert_eq!(TextCommand::TrimWhitespace.apply("  hi  \n"), "hi");
    assert_eq!(
        TextCommand::StripNewlines.apply("  a  \n\n  b  \n"),
        "a b"
    );
    assert_eq!(
        TextCommand::BulletList.apply("a\n\n  b  \n"),
        "• a\n• b"
    );
}

#[test]
fn system_command_open_url_wire_value() {
    let cmd = SystemCommand {
        command: SystemCommandKind::OpenUrl,
        argument: Some("https://example.com".to_string()),
    };
    let json = serde_json::to_string(&cmd).unwrap();
    // Swift's raw value is "openURL" (not camelCase "openUrl").
    assert!(json.contains("\"openURL\""));
    assert_eq!(serde_json::from_str::<SystemCommand>(&json).unwrap(), cmd);

    let vol = SystemCommand {
        command: SystemCommandKind::VolumeUp,
        argument: None,
    };
    assert!(serde_json::to_string(&vol).unwrap().contains("\"volumeUp\""));
}

#[test]
fn empty_request_structs_serialize_as_object() {
    assert_eq!(serde_json::to_string(&AppListRequest {}).unwrap(), "{}");
    assert_eq!(serde_json::to_string(&WindowListRequest {}).unwrap(), "{}");
}

// --- App screen mirror (kinds 0x1A–0x1F) -----------------------------------

#[test]
fn screen_control_round_trip() {
    for command in [
        ScreenControlCommand::Start,
        ScreenControlCommand::Stop,
        ScreenControlCommand::Select,
        ScreenControlCommand::Follow,
    ] {
        let control = ScreenControl {
            command,
            window_id: Some("4242:131072".to_string()),
            max_pixel: Some(1920),
        };
        let data = encode_screen_control(&control).unwrap();
        let mut parser = Parser::new();
        let frames = parser.append(&data);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].kind, Kind::ScreenControl);
        assert_eq!(decode_screen_control(&frames[0]).unwrap(), control);
    }
}

#[test]
fn screen_input_round_trip() {
    for action in [
        ScreenInputAction::Click,
        ScreenInputAction::DragStart,
        ScreenInputAction::DragMove,
        ScreenInputAction::DragEnd,
        ScreenInputAction::RightClick,
        ScreenInputAction::Scroll,
    ] {
        let input = ScreenInput {
            action,
            u: 0.25,
            v: 0.75,
            dx: -0.01,
            dy: 0.02,
            modifiers: 9,
            click_count: 2,
            timestamp_micros: 42,
        };
        let data = encode_screen_input(&input).unwrap();
        let mut parser = Parser::new();
        let frames = parser.append(&data);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].kind, Kind::ScreenInput);
        assert_eq!(decode_screen_input(&frames[0]).unwrap(), input);
    }
}

#[test]
fn screen_info_round_trip() {
    for status in [
        ScreenStatus::Ok,
        ScreenStatus::PermissionDenied,
        ScreenStatus::NoWindow,
    ] {
        let info = ScreenInfo {
            status,
            window_id: Some("4242:131072".to_string()),
            app_id: Some("pid:4242".to_string()),
            app_name: Some("Editor".to_string()),
            title: Some("notes.txt".to_string()),
            origin_x: 100.0,
            origin_y: 50.0,
            width: 800.0,
            height: 600.0,
            pixel_width: 1600,
            pixel_height: 1200,
            shows_cursor: true,
        };
        let data = encode_screen_info(&info).unwrap();
        let mut parser = Parser::new();
        let frames = parser.append(&data);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].kind, Kind::ScreenInfo);
        assert_eq!(decode_screen_info(&frames[0]).unwrap(), info);
    }
}

#[test]
fn screen_json_field_names_match_swift() {
    // The iOS `IB*` structs use Swift's synthesized Codable keys (verbatim
    // property names). If these drift, the iPhone silently gets nothing.
    let info = ScreenInfo {
        status: ScreenStatus::PermissionDenied,
        window_id: None,
        app_id: None,
        app_name: None,
        title: None,
        origin_x: 1.0,
        origin_y: 2.0,
        width: 3.0,
        height: 4.0,
        pixel_width: 5,
        pixel_height: 6,
        shows_cursor: true,
    };
    let value = serde_json::to_value(&info).unwrap();
    assert_eq!(value["status"], "permissionDenied");
    assert_eq!(value["originX"], 1.0);
    assert_eq!(value["originY"], 2.0);
    assert_eq!(value["pixelWidth"], 5);
    assert_eq!(value["pixelHeight"], 6);
    assert_eq!(value["showsCursor"], true);

    let control = ScreenControl {
        command: ScreenControlCommand::Select,
        window_id: Some("1:2".to_string()),
        max_pixel: Some(2560),
    };
    let value = serde_json::to_value(&control).unwrap();
    assert_eq!(value["command"], "select");
    assert_eq!(value["windowId"], "1:2");
    assert_eq!(value["maxPixel"], 2560);

    let input = ScreenInput {
        action: ScreenInputAction::DragStart,
        u: 0.0,
        v: 0.0,
        dx: 0.0,
        dy: 0.0,
        modifiers: 0,
        click_count: 1,
        timestamp_micros: 7,
    };
    let value = serde_json::to_value(&input).unwrap();
    assert_eq!(value["action"], "dragStart");
    assert_eq!(value["clickCount"], 1);
    assert_eq!(value["timestampMicros"], 7);
}

#[test]
fn screen_nal_frames_use_screen_kinds() {
    let sps = NalFrame {
        kind: NalKind::Sps,
        data: vec![0x67, 0x64],
        timestamp_micros: 0,
    };
    let frames = Parser::new().append(&encode_screen_nal(&sps));
    assert_eq!(frames[0].kind, Kind::ScreenSps);

    let video = NalFrame {
        kind: NalKind::Video,
        data: vec![0x41, 0x9a],
        timestamp_micros: 0,
    };
    let frames = Parser::new().append(&encode_screen_nal(&video));
    assert_eq!(frames[0].kind, Kind::ScreenVideo);
}

#[test]
fn system_command_show_desktop_wire_value() {
    // The iOS encoder emits the Swift enum raw value verbatim.
    let value = serde_json::to_value(SystemCommand {
        command: SystemCommandKind::ShowDesktop,
        argument: None,
    })
    .unwrap();
    assert_eq!(value["command"], "showDesktop");
    assert_eq!(value, serde_json::json!({"command": "showDesktop"}));
}
