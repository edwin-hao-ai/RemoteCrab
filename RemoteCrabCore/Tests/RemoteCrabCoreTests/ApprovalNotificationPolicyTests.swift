import XCTest
@testable import RemoteCrabCore

/// A tap on the phone was the missing step, and nothing on the Mac said so.
///
/// ## Why this is a policy
///
/// The receiver re-enters `awaitingApproval` on every reconnect attempt, so a
/// notification attached to the *state* rather than to the *transition* fires
/// every few seconds while the phone is unreachable. That is the same shape as
/// the pending-slot bug in `PendingSlotPolicy`: a cleanup that reads as dead
/// code because the question is asked after the fact.
///
/// So the assertions are about transitions and counts, not about "the state is
/// awaiting approval".
final class ApprovalNotificationPolicyTests: XCTestCase {

    private func shouldNotify(_ from: ReceiverStateKind, _ to: ReceiverStateKind,
                              firstThisSession: Bool = true,
                              alreadyNotified: Bool = false) -> Bool {
        ApprovalNotificationPolicy.shouldNotify(
            previous: from, next: to,
            isFirstEntryThisSession: firstThisSession,
            alreadyNotifiedForThisWait: alreadyNotified)
    }

    // MARK: - The case that matters

    func testEnteringTheWaitingStateNotifies() {
        XCTAssertTrue(shouldNotify(.handshaking, .awaitingApproval),
                      "the phone is showing an approval card and the Mac is silent")
    }

    /// The reconnect loop is the reason this policy exists.
    func testStayingInTheWaitingStateDoesNotNotifyAgain() {
        for from: ReceiverStateKind in [.awaitingApproval, .awaitingApproval] {
            XCTAssertFalse(shouldNotify(from, .awaitingApproval),
                           "a state you are already in is not an event")
        }
    }

    func testTheReconnectLoopThatReEntersIsGuardedTwiceOver() {
        // `.searching → .awaitingApproval` is what a retry loop actually
        // produces once something else moved the state along in between.
        XCTAssertTrue(shouldNotify(.searching, .awaitingApproval),
                      "precondition: this IS a fresh entry")
        XCTAssertFalse(shouldNotify(.searching, .awaitingApproval, alreadyNotified: true),
                       "and the latch catches the loop that produces it")
    }

    // MARK: - Only the waiting state

    func testNoOtherTransitionNotifies() {
        let all: [ReceiverStateKind] = [.searching, .connecting, .handshaking,
                                        .awaitingApproval, .streaming, .error]
        for from in all {
            for to in all where !(from != .awaitingApproval && to == .awaitingApproval) {
                XCTAssertFalse(shouldNotify(from, to), "\(from) → \(to) must be silent")
            }
        }
    }

    /// Streaming and searching are states the user did not have to act on.
    func testTheStatesThatNeedNoTapAreSilent() {
        XCTAssertFalse(shouldNotify(.handshaking, .streaming))
        XCTAssertFalse(shouldNotify(.searching, .connecting))
        XCTAssertFalse(shouldNotify(.streaming, .error))
    }

    // MARK: - Once per run

    func testASecondWaitInTheSameRunIsSilent() {
        XCTAssertFalse(shouldNotify(.handshaking, .awaitingApproval,
                                   firstThisSession: false),
                       "the user has already approved a computer this run; asking again is noise")
    }

    func testTheLatchResetsWhenTheWaitResolves() {
        XCTAssertTrue(ApprovalNotificationPolicy.shouldResetAfterExit(
            previous: .awaitingApproval, next: .streaming))
        XCTAssertFalse(ApprovalNotificationPolicy.shouldResetAfterExit(
            previous: .awaitingApproval, next: .awaitingApproval),
            "still waiting — keep the latch")
        // Which is what lets a genuinely new wait notify again.
        XCTAssertTrue(shouldNotify(.handshaking, .awaitingApproval,
                                  firstThisSession: true, alreadyNotified: false))
    }

    /// A notification that stacks is worse than none: the user clears a pile
    /// instead of acting on the one that matters.
    func testTheIdentifierIsFixedSoRepeatedPostsReplaceRatherThanStack() {
        XCTAssertEqual(ApprovalNotificationPolicy.identifier,
                       "com.remotecrab.awaiting-approval")
    }
}