import XCTest
@testable import RemoteCrabCore

/// The launcher sheet used to declare "the list is empty" after a fixed
/// 500 ms sleep while the Mac needed ~2.4 s to answer, so it told the user
/// "No apps listed yet" and then popped the grid in underneath. These tests
/// pin the replacement contract: only the receiver's frame may end a wait,
/// and silence is its own outcome rather than an empty list.
final class IBListRequestGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFreshGateIsIdle() {
        XCTAssertEqual(IBListRequestGate().current, .idle)
        XCTAssertFalse(IBListRequestGate().isSettled)
    }

    func testBeginWaitsForTheReply() {
        var gate = IBListRequestGate()
        gate.begin(now: t0)
        XCTAssertEqual(gate.current, .awaiting)
        XCTAssertFalse(gate.isSettled)
    }

    func testAnswerSettles() {
        var gate = IBListRequestGate()
        gate.begin(now: t0)
        gate.answer()
        XCTAssertEqual(gate.current, .answered)
        XCTAssertTrue(gate.isSettled)
    }

    /// The regression itself: an empty view must not be reachable while the
    /// reply is merely late.
    func testNoAnswerBeforeTheDeadlineIsNotAnEmptyList() {
        var gate = IBListRequestGate(timeout: 8)
        gate.begin(now: t0)
        // 2.5 s — past the measured cold round trip, well short of the
        // deadline. A timer-based decision would have shown "no apps" here.
        XCTAssertFalse(gate.expire(now: t0.addingTimeInterval(2.5)))
        XCTAssertEqual(gate.current, .awaiting)
    }

    func testDeadlineProducesAnUnansweredOutcome() {
        var gate = IBListRequestGate(timeout: 8)
        gate.begin(now: t0)
        XCTAssertTrue(gate.expire(now: t0.addingTimeInterval(8)))
        XCTAssertEqual(gate.current, .unanswered)
        XCTAssertTrue(gate.isSettled)
    }

    /// Reports the flip exactly once, so the caller can log it once.
    func testExpiryIsReportedOnce() {
        var gate = IBListRequestGate(timeout: 8)
        gate.begin(now: t0)
        XCTAssertTrue(gate.expire(now: t0.addingTimeInterval(8)))
        XCTAssertFalse(gate.expire(now: t0.addingTimeInterval(9)))
    }

    func testAnsweredIsNeverUnanswered() {
        var gate = IBListRequestGate(timeout: 8)
        gate.begin(now: t0)
        gate.answer()
        XCTAssertFalse(gate.expire(now: t0.addingTimeInterval(600)))
        XCTAssertEqual(gate.current, .answered)
    }

    func testIdleIsNeverExpired() {
        var gate = IBListRequestGate(timeout: 8)
        XCTAssertFalse(gate.expire(now: t0.addingTimeInterval(600)))
        XCTAssertEqual(gate.current, .idle)
    }

    /// A late answer is still the answer — the gate heals rather than
    /// making the user pull to refresh a list that was already on its way.
    func testLateAnswerAfterTheDeadlineStillSettles() {
        var gate = IBListRequestGate(timeout: 8)
        gate.begin(now: t0)
        XCTAssertTrue(gate.expire(now: t0.addingTimeInterval(8)))
        gate.answer()
        XCTAssertEqual(gate.current, .answered)
    }

    /// Pull-to-refresh re-arms the wait, so the sheet shows that the new
    /// request is in flight.
    func testBeginAfterAnswerWaitsAgain() {
        var gate = IBListRequestGate()
        gate.begin(now: t0)
        gate.answer()
        gate.begin(now: t0.addingTimeInterval(30))
        XCTAssertEqual(gate.current, .awaiting)
        XCTAssertFalse(gate.isSettled)
    }

    /// A duplicate or unsolicited frame must not crash or stall the gate.
    func testAnswerWithoutABeginSettles() {
        var gate = IBListRequestGate()
        gate.answer()
        XCTAssertEqual(gate.current, .answered)
    }

    func testResetReturnsToIdle() {
        var gate = IBListRequestGate(timeout: 8)
        gate.begin(now: t0)
        gate.reset()
        XCTAssertEqual(gate.current, .idle)
        XCTAssertFalse(gate.expire(now: t0.addingTimeInterval(600)))
    }

    /// The deadline has to clear the *measured* cold cost of the real thing:
    /// 113 apps with an icon rasterised each took 2356 ms on the dev Mac,
    /// and a busier `/Applications` is worse. Keep this the first thing that
    /// breaks if someone tunes the timeout down for a "snappier" feel.
    func testDefaultDeadlineClearsTheMeasuredColdRoundTrip() {
        XCTAssertGreaterThan(IBListRequestGate.replyTimeout, 2.5)
    }
}