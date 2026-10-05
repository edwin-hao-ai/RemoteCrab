import XCTest
@testable import RemoteCrabCore

/// The WiFi-only retry is once per attempt, not once per process.
///
/// ## The bug this replaces
///
/// The latch was a `String?` with a comment claiming it was "cleared when a
/// different phone is dialled". Nothing cleared it. So after one wedge and one
/// retry, the watchdog cancelled and gave up for the rest of the process's life
/// — the retry existed but could only ever fire once, for any phone.
///
/// That is the "comment describes the intent, code does something else" shape,
/// and it is invisible to a reader who trusts the comment.
///
/// ## The two halves, both required
///
/// * a **normal dial clears** the latch — otherwise a later attempt inherits a
///   spent retry and the feature silently stops working;
/// * the **retry sets** it — otherwise cancel → retry → cancel → retry is an
///   unbounded loop, which is what the latch was for.
///
/// Neither half is interesting alone. Together they are the whole rule, and the
/// reason it is a type with tests rather than a line in a comment.
final class PeerToPeerRetryLatchTests: XCTestCase {

    func testAFreshLatchHasSpentNothing() {
        let latch = PeerToPeerRetryLatch()
        XCTAssertFalse(latch.hasRetried("phone-A"))
    }

    /// The half that was missing. Without it the retry is once-per-process.
    func testANormalDialClearsASpentRetry() {
        var latch = PeerToPeerRetryLatch()
        latch.retryingWithoutPeerToPeer("phone-A")
        XCTAssertTrue(latch.hasRetried("phone-A"), "precondition: the retry was spent")

        latch.diallingNormally("phone-A")

        XCTAssertFalse(latch.hasRetried("phone-A"),
                       "a new attempt must earn its own retry, or the feature works exactly once per launch")
    }

    /// The half that stops the loop.
    func testTheRetryCannotRetryItselfForever() {
        var latch = PeerToPeerRetryLatch()
        latch.retryingWithoutPeerToPeer("phone-A")
        XCTAssertTrue(latch.hasRetried("phone-A"),
                      "a cancel → retry → cancel → retry loop is what the latch exists to prevent")
    }

    /// Per phone, so one phone's spent retry does not silence another's.
    func testOnePhonesSpentRetryDoesNotAffectAnother() {
        var latch = PeerToPeerRetryLatch()
        latch.retryingWithoutPeerToPeer("phone-A")
        XCTAssertFalse(latch.hasRetried("phone-B"))
    }

    /// The sequence the watchdog actually performs, start to finish: wedge,
    /// retry, fail, back off, try again, and get the retry again.
    func testTheWholeCycleGetsARetryEachTime() {
        var latch = PeerToPeerRetryLatch()
        for attempt in 1...3 {
            latch.diallingNormally("phone-A")
            XCTAssertFalse(latch.hasRetried("phone-A"), "attempt \(attempt) must be allowed to retry")
            latch.retryingWithoutPeerToPeer("phone-A")
            XCTAssertTrue(latch.hasRetried("phone-A"), "attempt \(attempt) must not retry twice")
        }
    }
}
