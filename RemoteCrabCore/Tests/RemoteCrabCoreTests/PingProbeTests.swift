import XCTest
@testable import RemoteCrabCore

/// The discrimination that keeps the two clocks apart.
///
/// This is the highest-consequence little function in the latency path: if
/// an end mistakes the peer's timestamp for its own, it computes a "round
/// trip" equal to the clock offset between the two machines — hours — and
/// shows that as latency.
final class PingProbeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstProbeIsNotAnEcho() {
        var p = IBPingProbe()
        XCTAssertNil(p.lastSentMicros)
        XCTAssertFalse(p.isOwnEcho(12345), "with nothing sent, nothing is an echo")
    }

    func testOurOwnTimestampIsRecognised() {
        var p = IBPingProbe()
        let sent = p.makeProbe(now: t0)
        XCTAssertTrue(p.isOwnEcho(sent))
    }

    func testAPeerTimestampIsNotAnEcho() {
        var p = IBPingProbe()
        _ = p.makeProbe(now: t0)
        // The peer's clock is somewhere else entirely.
        XCTAssertFalse(p.isOwnEcho(999_999_999))
    }

    func testOnlyTheMostRecentProbeCanBeAnEcho() {
        var p = IBPingProbe()
        let first = p.makeProbe(now: t0)
        let second = p.makeProbe(now: t0.addingTimeInterval(3))
        XCTAssertTrue(p.isOwnEcho(second))
        XCTAssertFalse(p.isOwnEcho(first),
                       "a superseded probe's echo is too late to measure")
    }

    func testRoundTripIsComputedInMilliseconds() {
        var p = IBPingProbe()
        let sent = p.makeProbe(now: t0)
        let rtt = p.roundTripMs(ofEcho: sent, now: t0.addingTimeInterval(0.042))
        XCTAssertEqual(rtt, 42)
    }

    /// Sub-millisecond probes round to 0, not to a negative number: the
    /// `&-` wrapping subtraction would otherwise hand back a huge unsigned
    /// value truncated into a nonsense "milliseconds" reading.
    func testSubMillisecondRoundTripIsZero() {
        var p = IBPingProbe()
        let sent = p.makeProbe(now: t0)
        XCTAssertEqual(p.roundTripMs(ofEcho: sent, now: t0.addingTimeInterval(0.0002)), 0)
    }

    func testRoundTripIsNilForAPeerProbe() {
        var p = IBPingProbe()
        _ = p.makeProbe(now: t0)
        XCTAssertNil(p.roundTripMs(ofEcho: 42, now: t0))
    }

    /// The failure this whole type exists to prevent, stated as a test.
    func testTwoIndependentProbesNeverCollide() {
        // 20 probes one second apart, on two machines whose clocks are three
        // hours apart. No overlap, so no false echo.
        var a = IBPingProbe()
        var b = IBPingProbe()
        let threeHours = 3 * 3600.0
        for i in 0..<20 {
            let aMicros = a.makeProbe(now: t0.addingTimeInterval(Double(i)))
            let bMicros = b.makeProbe(now: t0.addingTimeInterval(Double(i) + threeHours))
            XCTAssertFalse(a.isOwnEcho(bMicros))
            XCTAssertFalse(b.isOwnEcho(aMicros))
            XCTAssertTrue(a.isOwnEcho(aMicros))
            XCTAssertTrue(b.isOwnEcho(bMicros))
        }
    }

    func testResetForgetsEverything() {
        var p = IBPingProbe()
        let sent = p.makeProbe(now: t0)
        p.reset()
        XCTAssertNil(p.lastSentMicros)
        XCTAssertFalse(p.isOwnEcho(sent))
    }
}
