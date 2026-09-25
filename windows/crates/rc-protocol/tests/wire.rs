//! Ports of `RemoteCrabCore/Tests/RemoteCrabCoreTests/IBWireTests.swift`.
//! Behaviour must match the Swift tests one-for-one so the Windows receiver
//! is provably compatible with the existing iOS sender / Mac receiver.

use rc_protocol::*;

fn metadata(device_name: &str, width: i64, height: i64, fps: i64, bitrate: i64) -> StreamMetadata {
    StreamMetadata {
        version: 1,
        device_name: device_name.to_string(),
        width,
        height,
        fps,
        bitrate_bps: bitrate,
        codec: "h264".to_string(),
        sps: None,
        pps: None,
    }
}

#[test]
fn round_trip_metadata() {
    let md = metadata("iPhone Test", 1920, 1080, 30, 4_000_000);

    let encoded = encode_metadata(&md).unwrap();
    let mut parser = Parser::new();
    let frames = parser.append(&encoded);

    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::Metadata);

    let decoded = decode_metadata(&frames[0]).unwrap();
    assert_eq!(decoded, md);
}

#[test]
fn round_trip_video_frame() {
    let nal = vec![0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xc0, 0x1e];
    let frame = NalFrame {
        kind: NalKind::Video,
        data: nal.clone(),
        timestamp_micros: 123_456,
    };

    let encoded = encode_nal(&frame);
    let mut parser = Parser::new();
    let frames = parser.append(&encoded);

    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::Video);
    assert_eq!(frames[0].payload, nal);
}

#[test]
fn round_trip_sps() {
    let sps = vec![0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xc0, 0x1e, 0xd9, 0x00, 0xa0, 0x47, 0xfe, 0xc8];
    let frame = NalFrame {
        kind: NalKind::Sps,
        data: sps.clone(),
        timestamp_micros: 0,
    };

    let encoded = encode_nal(&frame);
    let mut parser = Parser::new();
    let frames = parser.append(&encoded);

    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::Sps);
    assert_eq!(frames[0].payload, sps);
}

#[test]
fn round_trip_pps() {
    let pps = vec![0x00, 0x00, 0x00, 0x01, 0x68, 0xce, 0x38, 0x80];
    let frame = NalFrame {
        kind: NalKind::Pps,
        data: pps,
        timestamp_micros: 0,
    };

    let encoded = encode_nal(&frame);
    let mut parser = Parser::new();
    let frames = parser.append(&encoded);

    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::Pps);
}

#[test]
fn streaming_multiple_frames_one_byte_at_a_time() {
    let mut parser = Parser::new();
    let mut collected: Vec<Frame> = Vec::new();

    let md = metadata("Stream", 1280, 720, 30, 2_000_000);
    let mut stream = encode_metadata(&md).unwrap();
    for _ in 0..5 {
        stream.extend_from_slice(&encode_nal(&NalFrame {
            kind: NalKind::Video,
            data: vec![0xAB; 100],
            timestamp_micros: 0,
        }));
    }

    for byte in stream {
        collected.extend(parser.append(&[byte]));
    }

    assert_eq!(collected.len(), 6);
    assert_eq!(collected[0].kind, Kind::Metadata);
    assert_eq!(
        collected[1..6].iter().map(|f| f.kind).collect::<Vec<_>>(),
        vec![Kind::Video, Kind::Video, Kind::Video, Kind::Video, Kind::Video]
    );
}

#[test]
fn partial_header_yields_nothing() {
    let mut parser = Parser::new();
    let frames = parser.append(&[0x00, 0x10]);
    assert_eq!(frames.len(), 0);
}

#[test]
fn partial_payload_reassembles() {
    let mut parser = Parser::new();
    let md = metadata("Partial", 1920, 1080, 30, 4_000_000);
    let encoded = encode_metadata(&md).unwrap();

    let head = &encoded[..encoded.len() - 2];
    assert_eq!(parser.append(head).len(), 0);

    let tail = &encoded[encoded.len() - 2..];
    let frames = parser.append(tail);
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::Metadata);
}

#[test]
fn reset_clears_buffer() {
    let mut parser = Parser::new();
    let _ = parser.append(&[0x00, 0x10, 0x00]); // partial
    parser.reset();
    let frames = parser.append(&[0x10]);
    assert_eq!(frames.len(), 0);
}

#[test]
fn refuses_oversized_frame_length() {
    let mut parser = Parser::new();
    // 0xFFFFFFFF would imply a > 4 GB frame — capped at 64 MiB.
    let mut data = vec![0xFF, 0xFF, 0xFF, 0xFF];
    data.extend_from_slice(&[0x00; 8]);
    let frames = parser.append(&data);
    assert_eq!(frames.len(), 0);
}

#[test]
fn resolution_label() {
    assert_eq!(metadata("x", 1920, 1080, 30, 0).resolution_label(), "1080p");
    assert_eq!(metadata("x", 3840, 2160, 30, 0).resolution_label(), "4K");
    assert_eq!(metadata("x", 2560, 1440, 30, 0).resolution_label(), "1440p");
    assert_eq!(metadata("x", 1280, 720, 30, 0).resolution_label(), "720p");
    assert_eq!(metadata("x", 640, 480, 30, 0).resolution_label(), "480p");
    assert_eq!(metadata("x", 800, 600, 30, 0).resolution_label(), "800x600");
}

#[test]
fn service_type_constants() {
    assert_eq!(ServiceType::TCP, "_remotecrab._tcp");
    assert_eq!(ServiceType::DOMAIN, "local.");
}

#[test]
fn round_trip_feature_control() {
    let control = FeatureControl {
        feature: Feature::Microphone,
        enabled: true,
    };
    let data = encode_feature_control(&control).unwrap();
    let mut parser = Parser::new();
    let frames = parser.append(&data);
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::FeatureControl);
    assert_eq!(decode_feature_control(&frames[0]).unwrap(), control);
}

#[test]
fn round_trip_feature_state() {
    let snap = FeatureStateSnapshot {
        camera_on: false,
        mic_on: true,
        voice_on: false,
        trackpad_on: true,
        keyboard_on: false,
        active_surface: Surface::Keyboard,
        camera_position: CameraPosition::Back,
        timestamp_micros: 42,
    };
    let data = encode_feature_state(&snap).unwrap();
    let mut parser = Parser::new();
    let frames = parser.append(&data);
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::FeatureState);
    assert_eq!(decode_feature_state(&frames[0]).unwrap(), snap);
}

#[test]
fn round_trip_ping() {
    let data = encode_ping(9_876_543);
    let mut parser = Parser::new();
    let frames = parser.append(&data);
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].kind, Kind::Ping);
    assert_eq!(decode_ping(&frames[0]), 9_876_543);
}

#[test]
fn screen_mirror_kinds_are_recognised_not_video() {
    // The iOS/Mac app-window mirror uses 0x1A–0x1F. Windows must decode the
    // kind byte correctly (never fall through to Video) and report it as a
    // mirror kind so the session loop can ignore it safely.
    let cases = [
        (0x1Au8, Kind::ScreenVideo),
        (0x1B, Kind::ScreenSps),
        (0x1C, Kind::ScreenPps),
        (0x1D, Kind::ScreenControl),
        (0x1E, Kind::ScreenInput),
        (0x1F, Kind::ScreenInfo),
    ];
    for (byte, expected) in cases {
        let kind = Kind::from_u8_or_video(byte);
        assert_eq!(kind, expected, "byte {byte:#x}");
        assert!(kind.is_screen_mirror(), "byte {byte:#x} should be a mirror kind");
        assert_ne!(kind, Kind::Video);
    }
    // A genuinely unknown byte still falls back to Video (unchanged).
    assert_eq!(Kind::from_u8_or_video(0x99), Kind::Video);
}
