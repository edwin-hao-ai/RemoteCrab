import XCTest
@testable import RemoteCrabCore

/// Capability negotiation — the thing that makes 1.1 safe to ship to
/// anyone whose Mac app has not been updated yet.
///
/// The problem it solves, concretely: 1.1's phone sends latency probes, and
/// a Mac app built before that treats *every* inbound ping as the echo of its
/// own probe. It therefore subtracts the phone's clock from its own and
/// reports the **clock offset between the two machines** in the menu bar —
/// hours, on a LAN. The phone cannot fix that from its side, so it must not
/// send the probe in the first place unless the receiver has said it can
/// handle one. `clientHello` is the first frame in each direction, and it
/// already exists, so this adds one optional array and nothing else.
final class CapabilityNegotiationTests: XCTestCase {

    // MARK: - The contract

    func testCapabilitiesAreOmittedWhenEmpty() throws {
        // A Mac with no special abilities must not grow a `"capabilities":[]`
        // in its hello — smallest possible frame for older phones.
        let hello = IBClientHello(name: "Mac", id: "u", token: nil,
                                  appVersion: "1.0", platform: "macos")
        let json = String(decoding: try IBWire.encode(clientHello: hello), as: UTF8.self)
        XCTAssertFalse(json.contains("capabilities"), "got \(json)")
    }

    func testOlderMacDecodesToNoCapabilities() throws {
        // This is the whole point: what a pre-1.1 Mac actually sends.
        let legacy = Data("""
        {"name":"Mac","id":"ECBDD7BA","token":null,"appVersion":"1.0"}
        """.utf8)
        let hello = try IBWire.decodeClientHello(
            IBWire.Frame(kind: .clientHello, payload: legacy))
        XCTAssertEqual(hello.name, "Mac")
        XCTAssertFalse(hello.supports(.latencyProbe),
                       "a Mac that never heard of probes must not claim them")
        XCTAssertFalse(hello.supports(.commandResult))
    }

    func testNewerMacDecodesCapabilities() throws {
        let modern = Data("""
        {"name":"Mac","id":"E","token":null,"appVersion":"1.0",\
        "capabilities":["latencyProbe","commandResult"]}
        """.utf8)
        let hello = try IBWire.decodeClientHello(
            IBWire.Frame(kind: .clientHello, payload: modern))
        XCTAssertTrue(hello.supports(.latencyProbe))
        XCTAssertTrue(hello.supports(.commandResult))
    }

    func testUnknownCapabilitiesAreIgnoredNotFatal() throws {
        // A future Mac that advertises things this phone has never heard of
        // must still connect — unknown entries are simply not understood.
        let future = Data("""
        {"name":"Mac","id":"E","token":null,"appVersion":"9.9",\
        "capabilities":["latencyProbe","holographicDock"]}
        """.utf8)
        let hello = try IBWire.decodeClientHello(
            IBWire.Frame(kind: .clientHello, payload: future))
        XCTAssertTrue(hello.supports(.latencyProbe))
        XCTAssertFalse(hello.supports(.commandResult))
        // The unknown one is dropped, not remembered and not fatal.
        XCTAssertEqual(hello.capabilities, [.latencyProbe])
    }

    func testRoundTripPreservesTheList() throws {
        let hello = IBClientHello(name: "Mac", id: "u", token: "t", appVersion: "1.0",
                                  platform: "windows",
                                  capabilities: [.latencyProbe, .commandResult])
        let parser = IBWire.Parser()
        let frames = parser.append(try IBWire.encode(clientHello: hello))
        XCTAssertEqual(frames.count, 1)
        let back = try IBWire.decodeClientHello(frames[0])
        XCTAssertEqual(back.capabilities, [.latencyProbe, .commandResult])
    }

    // MARK: - The behaviour each capability gates

    /// The scenario the whole mechanism exists for.
    func testAPhoneOnlyProbesWhenTheReceiverAdvertisedIt() {
        var p = IBPingProbe()
        let legacy = IBClientHello(name: "Mac", id: "u", token: nil, appVersion: "1.0")
        if legacy.supports(.latencyProbe) { p.makeProbe(now: Date()) }
        XCTAssertNil(p.lastSentMicros,
                     "probing an old receiver is what poisons its latency display")
    }

    func testCommandsAreNotAwaitedFromAReceiverThatCannotAnswer() {
        // With no `commandResult` capability there is no point in a 1.5 s
        // wait or a "your Mac app is too old" hint: the phone already knows.
        let legacy = IBClientHello(name: "Mac", id: "u", token: nil, appVersion: "1.0")
        var l = IBCommandLedger()
        l.open("r", now: Date())
        if legacy.supports(.commandResult) {
            // would wait for a reply
        } else {
            l.clear()
        }
        XCTAssertEqual(l.pendingCount, 0, "nothing to confirm, nothing pending")
    }
}
