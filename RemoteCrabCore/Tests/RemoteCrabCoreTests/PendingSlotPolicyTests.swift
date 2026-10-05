import XCTest
@testable import RemoteCrabCore

/// The "waiting for approval" slot must never outlive the connection holding it.
///
/// A pending slot that outlives its connection answers `busy` to every computer
/// from then on, naming a machine that is no longer running — the phone is
/// locked until the app restarts, with no control anywhere that unlocks it.
final class PendingSlotPolicyTests: XCTestCase {

    // MARK: - Timeout

    func test_a_waiting_request_is_not_expired_before_the_timeout() {
        XCTAssertFalse(PendingSlotPolicy.isExpired(waited: 0))
        XCTAssertFalse(PendingSlotPolicy.isExpired(waited: PendingSlotPolicy.timeout - 0.001))
    }

    /// The boundary is the load-bearing half: "not yet" must not include the
    /// instant the timeout is reached, or a live approval gets stolen.
    func test_a_waiting_request_is_expired_once_the_timeout_is_reached() {
        XCTAssertTrue(PendingSlotPolicy.isExpired(waited: PendingSlotPolicy.timeout))
        XCTAssertTrue(PendingSlotPolicy.isExpired(waited: PendingSlotPolicy.timeout + 1))
    }

    /// A stale preference once refused every computer for ten minutes
    /// (lesson 132). The pending slot fails the same way, so the number is
    /// pinned against that outcome rather than left to taste.
    func test_the_timeout_is_far_below_the_ten_minute_lock_it_replaced() {
        XCTAssertLessThan(PendingSlotPolicy.timeout, 10 * 60)
        // …but long enough that a human who walked away is not raced.
        XCTAssertGreaterThanOrEqual(PendingSlotPolicy.timeout, 60)
    }

    // MARK: - Identity

    func test_the_dying_connection_is_recognised_as_the_slot_holder() {
        XCTAssertTrue(PendingSlotPolicy.isHeld(byDying: 7, pending: 7))
    }

    /// A newcomer dying must not release the incumbent's approval card —
    /// otherwise one computer can cancel another's request.
    func test_a_different_connection_does_not_release_the_slot() {
        XCTAssertFalse(PendingSlotPolicy.isHeld(byDying: 7, pending: 9))
    }

    /// Exactly the shape the old code produced: it cleared `candidate` first and
    /// then asked whether the dead connection was the one holding the slot, so
    /// the dying identity it compared was already `nil`.
    func test_nothing_is_held_when_either_side_is_unknown() {
        XCTAssertFalse(PendingSlotPolicy.isHeld(byDying: nil as Int?, pending: 7))
        XCTAssertFalse(PendingSlotPolicy.isHeld(byDying: 7, pending: nil as Int?))
        XCTAssertFalse(PendingSlotPolicy.isHeld(byDying: nil as Int?, pending: nil as Int?))
    }
}
