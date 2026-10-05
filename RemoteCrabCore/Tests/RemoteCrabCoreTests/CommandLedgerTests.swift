import XCTest
@testable import RemoteCrabCore

/// The rule that matters most here: **do not retry.** These tests exist so
/// that stays true, and so a future change that adds one has to fight them.
final class CommandLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Confirm / expire

    func testConfirmedRequestSucceeds() {
        var l = IBCommandLedger()
        l.open("r1", now: t0)
        let outcome = l.resolve("r1")
        XCTAssertEqual(outcome?.state, .ok)
        XCTAssertEqual(outcome?.succeeded, true)
        XCTAssertEqual(l.pendingCount, 0)
    }

    func testUnconfirmedRequestExpiresAfterTheTimeout() {
        var l = IBCommandLedger()
        l.open("r1", now: t0)
        XCTAssertTrue(l.expire(t0.addingTimeInterval(1.0)).isEmpty, "not yet due")
        let expired = l.expire(t0.addingTimeInterval(1.6))
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired[0].state, .unconfirmed)
        XCTAssertEqual(expired[0].requestId, "r1")
        XCTAssertEqual(l.pendingCount, 0)
    }

    /// A confirmed request must never also come back as expired — that is
    /// the difference between "done" and "your Mac is too old".
    func testResolvedRequestDoesNotAlsoExpire() {
        var l = IBCommandLedger()
        l.open("r1", now: t0)
        l.resolve("r1")
        XCTAssertTrue(l.expire(t0.addingTimeInterval(99)).isEmpty)
    }

    func testSeveralRequestsExpireIndependently() {
        var l = IBCommandLedger()
        l.open("a", now: t0)
        l.open("b", now: t0.addingTimeInterval(1.0))
        let expired = l.expire(t0.addingTimeInterval(1.7))
        XCTAssertEqual(expired.map(\.requestId), ["a"], "only 'a' is past the window")
        XCTAssertEqual(l.pendingCount, 1)
    }

    /// A late/duplicate reply for something already settled is dropped, not
    /// turned into a second outcome.
    func testResolvingTwiceYieldsNothingTheSecondTime() {
        var l = IBCommandLedger()
        l.open("r1", now: t0)
        XCTAssertNotNil(l.resolve("r1"))
        XCTAssertNil(l.resolve("r1"))
    }

    func testResolvingAnUnknownIdIsHarmless() {
        var l = IBCommandLedger()
        XCTAssertNil(l.resolve("never-opened"))
    }

    // MARK: - Messages

    func testSuccessSaysNothing() {
        // The screen visibly changes; a toast on top of it is noise.
        XCTAssertNil(IBCommandOutcome(requestId: "r", state: .ok).message())
    }

    func testEachFailureHasItsOwnSentence() {
        let cases: [(IBCommandResult.Status, String)] = [
            (.noPermission, "Your Mac needs Accessibility permission to control apps."),
            (.noWindow, "That window isn't open on your computer anymore."),
            (.failed, "Your computer refused that request."),
        ]
        for (status, expected) in cases {
            let m = IBCommandOutcome(requestId: "r", state: .failed(status: status)).message()
            XCTAssertEqual(m, expected, "status \(status)")
        }
    }

    /// The name the user just tapped has to survive into the sentence —
    /// "it is no longer running" is much weaker than "Safari is no longer
    /// running".
    func testAppNotRunningNamesTheApp() {
        let m = IBCommandOutcome(requestId: "r", state: .failed(status: .appNotRunning),
                                 appName: "Safari").message()
        XCTAssertEqual(m, "“Safari” is no longer running.")
    }

    /// The four reasons must not collapse into one generic sentence — that is
    /// exactly the bug this whole feature exists to fix.
    func testFailureMessagesAreDistinct() {
        let messages = [IBCommandResult.Status.appNotRunning, .noPermission, .noWindow, .failed]
            .map { IBCommandOutcome(requestId: "r", state: .failed(status: $0), appName: "X").message() }
        XCTAssertEqual(Set(messages).count, 4, "got \(messages)")
    }

    func testSilenceIsReportedAsTooOldNotAsFailure() {
        // The distinction the phone cannot make for itself, spelled out: an
        // old receiver and a dropped frame look identical, and we say so
        // rather than accusing the user of a failure that may not exist.
        let m = IBCommandOutcome(requestId: "r", state: .unconfirmed).message()
        XCTAssertNotNil(m)
        XCTAssertTrue(m!.lowercased().contains("out of date"), "got \(m!)")
    }

    /// There is deliberately no retry path: one attempt per request.
    func testThereIsNoRetryEntryPoint() {
        var l = IBCommandLedger()
        l.open("r", now: t0)
        // After expiry the ledger is empty and offers nothing to re-send.
        _ = l.expire(t0.addingTimeInterval(2))
        XCTAssertEqual(l.pendingCount, 0)
    }
}
