import XCTest
@testable import RemoteCrabCore

/// Unit tests for the length-prefixed wire protocol used between
/// RemoteCrabCapture (iOS) and RemoteCrabReceiver (macOS).
final class IBWireTests: XCTestCase {

    // MARK: - Frame encode/decode round-trip

    func testRoundTripMetadata() throws {
        let metadata = IBStreamMetadata(
            version: 1,
            deviceName: "iPhone Test",
            width: 1920,
            height: 1080,
            fps: 30,
            bitrateBps: 4_000_000
        )

        let encoded = try IBWire.encode(metadata: metadata)
        let parser = IBWire.Parser()
        let frames = parser.append(encoded)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .metadata)

        let decoded = try JSONDecoder().decode(IBStreamMetadata.self, from: frames[0].payload)
        XCTAssertEqual(decoded, metadata)
    }

    func testRoundTripVideoFrame() {
        let nalData = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xc0, 0x1e])
        let frame = IBNalFrame(kind: .video, data: nalData, timestampMicros: 123_456)

        let encoded = IBWire.encode(frame: frame)
        let parser = IBWire.Parser()
        let frames = parser.append(encoded)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .video)
        XCTAssertEqual(frames[0].payload, nalData)
    }

    func testRoundTripSPS() {
        let spsData = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xc0, 0x1e, 0xd9, 0x00, 0xa0, 0x47, 0xfe, 0xc8])
        let frame = IBNalFrame(kind: .sps, data: spsData, timestampMicros: 0)

        let encoded = IBWire.encode(frame: frame)
        let parser = IBWire.Parser()
        let frames = parser.append(encoded)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .sps)
        XCTAssertEqual(frames[0].payload, spsData)
    }

    func testRoundTripPPS() {
        let ppsData = Data([0x00, 0x00, 0x00, 0x01, 0x68, 0xce, 0x38, 0x80])
        let frame = IBNalFrame(kind: .pps, data: ppsData, timestampMicros: 0)

        let encoded = IBWire.encode(frame: frame)
        let parser = IBWire.Parser()
        let frames = parser.append(encoded)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .pps)
    }

    // MARK: - Streaming / partial frames

    func testStreamingMultipleFrames() throws {
        let parser = IBWire.Parser()
        var collected: [IBWire.Frame] = []

        // Simulate a stream: feed one byte at a time.
        let metadata = IBStreamMetadata(deviceName: "Stream", width: 1280, height: 720, fps: 30, bitrateBps: 2_000_000)
        var stream = try IBWire.encode(metadata: metadata)
        for _ in 0..<5 {
            stream.append(IBWire.encode(frame: IBNalFrame(kind: .video, data: Data(repeating: 0xAB, count: 100), timestampMicros: 0)))
        }

        for byte in stream {
            collected.append(contentsOf: parser.append(Data([byte])))
        }

        XCTAssertEqual(collected.count, 6)
        XCTAssertEqual(collected[0].kind, .metadata)
        XCTAssertEqual(collected[1...5].map(\.kind), [.video, .video, .video, .video, .video])
    }

    func testPartialHeader() {
        let parser = IBWire.Parser()
        // Feed only 2 bytes (less than 4-byte length header).
        let frames = parser.append(Data([0x00, 0x10]))
        XCTAssertEqual(frames.count, 0)
    }

    func testPartialPayload() throws {
        let parser = IBWire.Parser()
        let metadata = IBStreamMetadata(deviceName: "Partial", width: 1920, height: 1080, fps: 30, bitrateBps: 4_000_000)
        let encoded = try IBWire.encode(metadata: metadata)

        // Feed everything except the last 2 bytes.
        let head = encoded.prefix(encoded.count - 2)
        let frames = parser.append(head)
        XCTAssertEqual(frames.count, 0)

        // Now feed the rest.
        let tail = encoded.suffix(2)
        let frames2 = parser.append(tail)
        XCTAssertEqual(frames2.count, 1)
        XCTAssertEqual(frames2[0].kind, .metadata)
    }

    func testResetClearsBuffer() throws {
        let parser = IBWire.Parser()
        _ = parser.append(Data([0x00, 0x10, 0x00]))   // partial
        parser.reset()
        // After reset, even a valid frame should fail to parse
        // because the partial header state was cleared.
        let frames = parser.append(Data([0x10]))
        XCTAssertEqual(frames.count, 0)
    }

    // MARK: - Refusal of oversized frames

    func testRefusesOversizedFrameLength() throws {
        let parser = IBWire.Parser()
        // 0xFFFFFFFF would imply a > 4 GB frame — we cap at 64 MiB.
        var data = Data([0xFF, 0xFF, 0xFF, 0xFF])
        data.append(Data(repeating: 0x00, count: 8))
        let frames = parser.append(data)
        XCTAssertEqual(frames.count, 0)
    }

    // MARK: - Metadata helpers

    func testResolutionLabel() {
        XCTAssertEqual(IBStreamMetadata(deviceName: "x", width: 1920, height: 1080, fps: 30, bitrateBps: 0).resolutionLabel, "1080p")
        XCTAssertEqual(IBStreamMetadata(deviceName: "x", width: 3840, height: 2160, fps: 30, bitrateBps: 0).resolutionLabel, "4K")
        XCTAssertEqual(IBStreamMetadata(deviceName: "x", width: 2560, height: 1440, fps: 30, bitrateBps: 0).resolutionLabel, "1440p")
        XCTAssertEqual(IBStreamMetadata(deviceName: "x", width: 1280, height: 720, fps: 30, bitrateBps: 0).resolutionLabel, "720p")
        XCTAssertEqual(IBStreamMetadata(deviceName: "x", width: 640, height: 480, fps: 30, bitrateBps: 0).resolutionLabel, "480p")
        XCTAssertEqual(IBStreamMetadata(deviceName: "x", width: 800, height: 600, fps: 30, bitrateBps: 0).resolutionLabel, "800x600")
    }

    func testServiceTypeConstants() {
        XCTAssertEqual(IBServiceType.tcp, "_remotecrab._tcp")
        XCTAssertEqual(IBServiceType.domain, "local.")
    }

    // MARK: - FeatureControl / FeatureState / Ping round-trip

    func testRoundTripFeatureControl() throws {
        let control = FeatureControl(feature: .microphone, enabled: true)
        let data = try IBWire.encode(featureControl: control)
        let parser = IBWire.Parser()
        let frames = parser.append(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .featureControl)
        XCTAssertEqual(try IBWire.decodeFeatureControl(frames[0]), control)
    }

    func testRoundTripFeatureState() throws {
        let snap = FeatureStateSnapshot(
            cameraOn: false, micOn: true, voiceOn: false,
            trackpadOn: true, keyboardOn: false,
            activeSurface: .keyboard, timestampMicros: 42
        )
        let data = try IBWire.encode(featureState: snap)
        let parser = IBWire.Parser()
        let frames = parser.append(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .featureState)
        XCTAssertEqual(try IBWire.decodeFeatureState(frames[0]), snap)
    }

    func testRoundTripPing() throws {
        let data = IBWire.encodePing(sentMicros: 9_876_543)
        let parser = IBWire.Parser()
        let frames = parser.append(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .ping)
        XCTAssertEqual(IBWire.decodePing(frames[0]), 9_876_543)
    }
}