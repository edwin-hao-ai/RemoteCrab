import XCTest
@testable import RemoteCrabCore

final class SystemCommandWireTests: XCTestCase {

    func testRoundTripVolumeUp() throws {
        let encoded = try IBWire.encode(systemCommand: IBSystemCommand(command: .volumeUp))
        let frames = IBWire.Parser().append(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .systemCommand)
        let decoded = try IBWire.decodeSystemCommand(frames[0])
        XCTAssertEqual(decoded.command, .volumeUp)
        XCTAssertNil(decoded.argument)
    }

    func testRoundTripLaunchAppWithArgument() throws {
        let encoded = try IBWire.encode(systemCommand: IBSystemCommand(command: .launchApp, argument: "com.apple.Safari"))
        let frames = IBWire.Parser().append(encoded)
        XCTAssertEqual(frames.count, 1)
        let decoded = try IBWire.decodeSystemCommand(frames[0])
        XCTAssertEqual(decoded.command, .launchApp)
        XCTAssertEqual(decoded.argument, "com.apple.Safari")
    }

    func testRoundTripOpenURL() throws {
        let encoded = try IBWire.encode(systemCommand: IBSystemCommand(command: .openURL, argument: "https://vgoapp.com/remotecrab/"))
        let decoded = try IBWire.decodeSystemCommand(try XCTUnwrap(IBWire.Parser().append(encoded).first))
        XCTAssertEqual(decoded.command, .openURL)
        XCTAssertEqual(decoded.argument, "https://vgoapp.com/remotecrab/")
    }
}
