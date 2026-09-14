import XCTest
@testable import iBridgeCore

/// Unit tests for TouchEvent / KeyEvent / AudioPacket — the V0.2 input
/// + audio events sent from iPhone to Mac.
final class IBEventsTests: XCTestCase {

    // MARK: - TouchEvent round-trip

    func testTouchEventRoundTrip() throws {
        let event = TouchEvent(
            phase: .move,
            x: 0.42,
            y: 0.73,
            dx: 0.01,
            dy: 0.02,
            modifiers: 9,    // shift + command
            timestampMicros: 1_234_567
        )

        let data = try IBWire.encode(touch: event)
        let parser = IBWire.Parser()
        let frames = parser.append(data)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .touch)
        let decoded = try IBWire.decodeTouch(frames[0])
        XCTAssertEqual(decoded, event)
    }

    func testTouchEventModifierFlags() {
        var event = TouchEvent(phase: .down)
        XCTAssertFalse(event.hasCommand)

        event = TouchEvent(phase: .down, modifiers: TouchEvent.Modifier.command.rawValue)
        XCTAssertTrue(event.hasCommand)
        XCTAssertFalse(event.hasShift)

        let combined = TouchEvent.Modifier.shift.rawValue
                    | TouchEvent.Modifier.command.rawValue
                    | TouchEvent.Modifier.option.rawValue
        event = TouchEvent(phase: .move, modifiers: combined)
        XCTAssertTrue(event.hasShift)
        XCTAssertTrue(event.hasCommand)
        XCTAssertTrue(event.hasOption)
        XCTAssertFalse(event.hasControl)
    }

    func testAllTouchPhasesRoundTrip() throws {
        for phase: TouchEvent.Phase in [.down, .move, .up, .rightDown, .rightUp, .scroll, .click] {
            let event = TouchEvent(phase: phase)
            let encoded = try IBWire.encode(touch: event)
            let parser = IBWire.Parser()
            let frames = parser.append(encoded)
            XCTAssertEqual(frames.count, 1)
            let decoded = try IBWire.decodeTouch(frames[0])
            XCTAssertEqual(decoded.phase, phase)
        }
    }

    // MARK: - KeyEvent round-trip

    func testKeyEventDownRoundTrip() throws {
        let event = KeyEvent(
            action: .down,
            keycode: 0x04,           // USB HID 'a'
            modifiers: TouchEvent.Modifier.shift.rawValue,
            timestampMicros: 999
        )
        let encoded = try IBWire.encode(key: event)
        let parser = IBWire.Parser()
        let frames = parser.append(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .key)
        let decoded = try IBWire.decodeKey(frames[0])
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.action, .down)
        XCTAssertEqual(decoded.keycode, 0x04)
        XCTAssertNil(decoded.text)
    }

    func testKeyEventTextRoundTrip() throws {
        let event = KeyEvent(
            action: .text,
            text: "Hello, 世界",
            timestampMicros: 1_000_000
        )
        let encoded = try IBWire.encode(key: event)
        let parser = IBWire.Parser()
        let frames = parser.append(encoded)
        XCTAssertEqual(frames.count, 1)
        let decoded = try IBWire.decodeKey(frames[0])
        XCTAssertEqual(decoded.action, .text)
        XCTAssertEqual(decoded.text, "Hello, 世界")
        XCTAssertNil(decoded.keycode)
    }

    // MARK: - Camera command round-trip

    func testCameraCommandRoundTrip() throws {
        for position in IBCameraPosition.allCases {
            let encoded = try IBWire.encode(cameraCommand: IBCameraCommand(position: position))
            let parser = IBWire.Parser()
            let frames = parser.append(encoded)
            XCTAssertEqual(frames.count, 1)
            XCTAssertEqual(frames[0].kind, .cameraCommand)
            let decoded = try IBWire.decodeCameraCommand(frames[0])
            XCTAssertEqual(decoded.position, position)
        }
        XCTAssertEqual(IBCameraPosition.back.toggled, .front)
        XCTAssertEqual(IBCameraPosition.front.toggled, .back)
    }

    // MARK: - AudioPacket round-trip

    func testAudioPacketRoundTrip() throws {
        // Simulated Opus frame: 100 bytes of pseudo-random data.
        let opusBytes = (0..<100).map { _ in UInt8.random(in: 0...255) }
        let packet = AudioPacket(
            opusData: Data(opusBytes),
            sampleRate: 48_000,
            channels: 1,
            timestampMicros: 50_000
        )

        let encoded = try IBWire.encode(audio: packet)
        let parser = IBWire.Parser()
        let frames = parser.append(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .audio)
        let decoded = try IBWire.decodeAudio(frames[0])
        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(decoded.opusData, packet.opusData)
        XCTAssertEqual(decoded.sampleRate, 48_000)
        XCTAssertEqual(decoded.channels, 1)
    }

    func testAudioPacketWithLargeOpusFrame() throws {
        // 4 KB Opus frame — typical for high-bitrate speech.
        let opus = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        let packet = AudioPacket(opusData: opus, sampleRate: 48_000)
        let encoded = try IBWire.encode(audio: packet)
        let parser = IBWire.Parser()
        let frames = parser.append(encoded)
        XCTAssertEqual(frames.count, 1)
        let decoded = try IBWire.decodeAudio(frames[0])
        XCTAssertEqual(decoded.opusData, opus)
    }

    // MARK: - Mixed traffic

    func testMixedVideoAndEventsOverSameConnection() throws {
        // Simulates a real session: metadata, then SPS+PPS, then a video
        // frame, then interleaved touch/key events, then more video.
        let parser = IBWire.Parser()

        var stream = try IBWire.encode(metadata: IBStreamMetadata(
            deviceName: "Mixed", width: 1920, height: 1080, fps: 30, bitrateBps: 4_000_000
        ))
        stream.append(try IBWire.encode(frame: IBNalFrame(kind: .sps,
            data: Data([0x00, 0x00, 0x00, 0x01, 0x67]), timestampMicros: 0)))
        stream.append(try IBWire.encode(frame: IBNalFrame(kind: .pps,
            data: Data([0x00, 0x00, 0x00, 0x01, 0x68]), timestampMicros: 0)))
        stream.append(try IBWire.encode(touch: TouchEvent(phase: .down, x: 0.1, y: 0.1)))
        stream.append(try IBWire.encode(key: KeyEvent(action: .text, text: "a")))
        stream.append(try IBWire.encode(frame: IBNalFrame(kind: .video,
            data: Data([0x00, 0x00, 0x00, 0x01, 0x41]), timestampMicros: 33_000)))
        stream.append(try IBWire.encode(audio: AudioPacket(
            opusData: Data([0xAA, 0xBB, 0xCC]), sampleRate: 48_000
        )))

        let frames = parser.append(stream)
        XCTAssertEqual(frames.count, 7)
        XCTAssertEqual(frames.map(\.kind),
            [.metadata, .sps, .pps, .touch, .key, .video, .audio])

        let touch = try IBWire.decodeTouch(frames[3])
        XCTAssertEqual(touch.phase, .down)

        let key = try IBWire.decodeKey(frames[4])
        XCTAssertEqual(key.text, "a")

        let audio = try IBWire.decodeAudio(frames[6])
        XCTAssertEqual(audio.opusData, Data([0xAA, 0xBB, 0xCC]))
    }

    // MARK: - FeatureControl / FeatureStateSnapshot / new touch phases

    func testFeatureControlRoundTrip() throws {
        let control = FeatureControl(feature: .camera, enabled: false)
        let data = try JSONEncoder().encode(control)
        let decoded = try JSONDecoder().decode(FeatureControl.self, from: data)
        XCTAssertEqual(decoded, control)
    }

    func testFeatureStateSnapshotRoundTrip() throws {
        let snap = FeatureStateSnapshot(
            cameraOn: true, micOn: false, voiceOn: false,
            trackpadOn: true, keyboardOn: true,
            activeSurface: .trackpad, timestampMicros: 123_456
        )
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(FeatureStateSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testTouchEventNewPhasesRoundTrip() throws {
        for phase: TouchEvent.Phase in [.dragStart, .pinch, .threeFingerSwipe, .threeFingerTap, .forceClick] {
            let event = TouchEvent(phase: phase, x: 0.5, y: 0.5, dx: 0.02, dy: 1)
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(TouchEvent.self, from: data)
            XCTAssertEqual(decoded, event)
        }
    }
}