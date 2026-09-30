import XCTest
@testable import RemoteCrabCore

/// `commandResult` (0x23) and the `requestId` correlation it rides on.
///
/// The framing rule that shapes this whole file: **an older peer must keep
/// working.** A receiver built before 0x23 exists decodes a request without
/// the field and never answers; a phone that learned the field must treat
/// that silence as "too old to confirm", not as a failure. So every addition
/// here is optional on the wire and additive in memory.
final class CommandResultWireTests: XCTestCase {

    /// Encoders take the value and return a whole frame; decoders take a
    /// frame. The kind is asserted separately so a round trip cannot pass by
    /// accidentally using the wrong one.
    private func roundTrip<T: Codable & Equatable>(
        _ value: T,
        _ kind: IBWire.Kind,
        _ encode: (T) throws -> Data,
        _ decode: (IBWire.Frame) throws -> T
    ) throws -> T {
        let data = try encode(value)
        let parser = IBWire.Parser()
        let frames = parser.append(data)
        guard frames.count == 1, frames[0].kind == kind else {
            throw NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected 1 \(kind) frame, got \(frames.map(\.kind))",
            ])
        }
        return try decode(frames[0])
    }

    // MARK: - The result frame itself

    func testCommandResultRoundTrips() throws {
        let r = IBCommandResult(requestId: "req-42", status: .ok)
        let back = try roundTrip(r, .commandResult, IBWire.encode(commandResult:), IBWire.decodeCommandResult)
        XCTAssertEqual(back, r)
    }

    func testEveryStatusRoundTrips() throws {
        for status in [IBCommandResult.Status.ok, .appNotRunning, .noPermission,
                       .noWindow, .failed] {
            let r = IBCommandResult(requestId: "x", status: status, detail: "d")
            let back = try roundTrip(r, .commandResult, IBWire.encode(commandResult:), IBWire.decodeCommandResult)
            XCTAssertEqual(back.status, status)
        }
    }

    func testOptionalDetailIsOmittedFromTheWire() throws {
        // A `nil` detail must not appear as `"detail": null` — peers that
        // were built before it existed should see the smallest possible frame.
        let json = String(decoding: try IBWire.encode(commandResult:
            IBCommandResult(requestId: "r", status: .ok)), as: UTF8.self)
        XCTAssertFalse(json.contains("detail"), "got \(json)")
    }

    func testCommandResultKindIs0x23() {
        XCTAssertEqual(IBWire.Kind.commandResult.rawValue, 0x23)
    }

    // MARK: - Requests carry a correlation id

    func testActivateAppCarriesItsRequestId() throws {
        let a = IBActivateApp(id: "com.apple.Safari", windowTitle: "Doc", requestId: "req-1")
        let back = try roundTrip(a, .activateApp, IBWire.encode(activateApp:), IBWire.decodeActivateApp)
        XCTAssertEqual(back.requestId, "req-1")
        XCTAssertEqual(back.id, "com.apple.Safari")
        XCTAssertEqual(back.windowTitle, "Doc")
    }

    func testActivateAppWithoutARequestIdOmitsIt() throws {
        let a = IBActivateApp(id: "x")
        XCTAssertNil(a.requestId)
        let json = String(decoding: try IBWire.encode(activateApp: a), as: UTF8.self)
        XCTAssertFalse(json.contains("requestId"), "got \(json)")
    }

    /// An old phone sends a request with no `requestId`. A new receiver must
    /// decode it and must NOT answer, because there is nothing to correlate
    /// the answer with.
    func testOldPhoneRequestDecodesAndCarriesNoId() throws {
        let legacy = Data(#"{"id":"com.apple.Safari","windowTitle":null}"#.utf8)
        let decoded = try IBWire.decodeActivateApp(IBWire.Frame(kind: .activateApp,
                                                                 payload: legacy))
        XCTAssertEqual(decoded.id, "com.apple.Safari")
        XCTAssertNil(decoded.requestId)
    }

    func testQuitAppCarriesItsRequestId() throws {
        let q = IBQuitApp(id: "x", force: true, requestId: "req-2")
        let back = try roundTrip(q, .quitApp, IBWire.encode(quitApp:), IBWire.decodeQuitApp)
        XCTAssertEqual(back.requestId, "req-2")
        XCTAssertTrue(back.force)
    }

    func testSystemCommandCarriesItsRequestId() throws {
        let c = IBSystemCommand(command: .launchApp, argument: "com.apple.Safari",
                                requestId: "req-3")
        let back = try roundTrip(c, .systemCommand, IBWire.encode(systemCommand:), IBWire.decodeSystemCommand)
        XCTAssertEqual(back.requestId, "req-3")
        XCTAssertEqual(back.command, .launchApp)
    }
}
