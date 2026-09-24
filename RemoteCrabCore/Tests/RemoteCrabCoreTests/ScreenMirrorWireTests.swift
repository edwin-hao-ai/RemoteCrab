import XCTest
import CoreGraphics
@testable import RemoteCrabCore

final class ScreenMirrorWireTests: XCTestCase {

    func testScreenControlRoundTrip() throws {
        let original = IBScreenControl(command: .select, windowId: "123:45")
        let data = try IBWire.encode(screenControl: original)
        let frames = IBWire.Parser().append(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .screenControl)
        XCTAssertEqual(try IBWire.decodeScreenControl(frames[0]), original)
    }

    func testScreenInputRoundTrip() throws {
        let original = IBScreenInput(action: .scroll, u: 0.25, v: 0.75,
                                     dx: 0.1, dy: -0.2, modifiers: 8,
                                     timestampMicros: 42)
        let data = try IBWire.encode(screenInput: original)
        let frames = IBWire.Parser().append(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .screenInput)
        XCTAssertEqual(try IBWire.decodeScreenInput(frames[0]), original)
    }

    func testScreenInfoRoundTrip() throws {
        let original = IBScreenInfo(status: .ok, windowId: "9:7", appId: "com.apple.Safari",
                                    appName: "Safari", title: "Start Page",
                                    originX: 12, originY: 34, width: 1440, height: 900,
                                    pixelWidth: 2880, pixelHeight: 1800, showsCursor: true)
        let data = try IBWire.encode(screenInfo: original)
        let frames = IBWire.Parser().append(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .screenInfo)
        XCTAssertEqual(try IBWire.decodeScreenInfo(frames[0]), original)
    }

    func testNoPermissionStatusRoundTrips() throws {
        let original = IBScreenInfo(status: .permissionDenied)
        let data = try IBWire.encode(screenInfo: original)
        let decoded = try IBWire.decodeScreenInfo(IBWire.Parser().append(data)[0])
        XCTAssertEqual(decoded.status, .permissionDenied)
        XCTAssertNil(decoded.windowId)
    }

    /// The mirror reuses `IBNalFrame` but must land on the screen-specific
    /// kinds so the two video directions can never be confused.
    func testScreenNalFramesUseDedicatedKinds() {
        let cases: [(IBNalFrame.Kind, IBWire.Kind)] = [
            (.video, .screenVideo), (.sps, .screenSPS), (.pps, .screenPPS),
        ]
        for (input, expected) in cases {
            let data = IBWire.encodeScreen(frame: IBNalFrame(kind: input,
                                                             data: Data([0xAA, 0xBB]),
                                                             timestampMicros: 0))
            let frames = IBWire.Parser().append(data)
            XCTAssertEqual(frames.count, 1)
            XCTAssertEqual(frames[0].kind, expected)
            XCTAssertEqual(frames[0].payload, Data([0xAA, 0xBB]))
        }
    }

    func testFeatureStateScreenOnRoundTripsAndDefaultsFalse() throws {
        let snapshot = FeatureStateSnapshot(
            cameraOn: false, micOn: true, voiceOn: false,
            trackpadOn: true, keyboardOn: true,
            activeSurface: .screen, screenOn: true, timestampMicros: 7)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(FeatureStateSnapshot.self, from: data), snapshot)

        // A snapshot from an older build (no screenOn key) decodes to false.
        let legacy = """
        {"cameraOn":false,"micOn":false,"voiceOn":false,"trackpadOn":true,
         "keyboardOn":true,"activeSurface":"trackpad","timestampMicros":1}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FeatureStateSnapshot.self, from: legacy)
        XCTAssertFalse(decoded.screenOn)
    }

    /// The normalized→global mapping contract shared with the Mac injector.
    func testRecordingInjectorMapsNormalizedInputToGlobalCursor() {
        let injector = RecordingInputInjector()
        injector.inject(screenInput: IBScreenInput(action: .click, u: 0.5, v: 0.25),
                        windowOrigin: CGPoint(x: 100, y: 50),
                        windowSize: CGSize(width: 800, height: 400))
        XCTAssertEqual(injector.lastCursor.x, 500, accuracy: 0.001)
        XCTAssertEqual(injector.lastCursor.y, 150, accuracy: 0.001)
        XCTAssertEqual(injector.screens.count, 1)
        XCTAssertEqual(injector.screens.first?.action, .click)
    }
}
