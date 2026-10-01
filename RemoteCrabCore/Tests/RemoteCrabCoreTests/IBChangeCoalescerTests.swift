import XCTest
@testable import RemoteCrabCore

/// A launch arrives as a pair — `didLaunchApplication` then
/// `didActivateApplication` — and each one costs a full window capture with
/// a JPEG per window. Refreshing on both doubled that; refreshing on the
/// first alone listed an app with no card. These pin "one refresh, after
/// the burst goes quiet".
final class IBChangeCoalescerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let delay = IBChangeCoalescer.settleDelay

    func testFreshCoalescerHasNothingPending() {
        XCTAssertFalse(IBChangeCoalescer().isPending)
        XCTAssertFalse(IBChangeCoalescer().isDue(now: t0.addingTimeInterval(60)))
    }

    func testSignalSchedulesARefresh() {
        var c = IBChangeCoalescer(delay: delay)
        XCTAssertTrue(c.signal(now: t0))
        XCTAssertTrue(c.isPending)
    }

    /// The launch→activate pair collapses to one refresh, and the refresh
    /// waits for the *last* signal — a card is not built from a half-launched
    /// app.
    func testTwoSignalsInOneWindowProduceOneRefresh() {
        var c = IBChangeCoalescer(delay: delay)
        c.signal(now: t0)
        // activate lands 120 ms later — absorbed, and the wait restarts
        c.signal(now: t0.addingTimeInterval(0.12))
        XCTAssertFalse(c.isDue(now: t0.addingTimeInterval(delay + 0.001)))
        XCTAssertTrue(c.isDue(now: t0.addingTimeInterval(0.12 + delay + 0.001)))
    }

    /// A signal after the window restarts the wait, so an app that takes
    /// longer than `delay` to reach the front still gets picked up.
    func testLateSignalRestartsTheWait() {
        var c = IBChangeCoalescer(delay: delay)
        c.signal(now: t0)
        c.consume()
        c.signal(now: t0.addingTimeInterval(3))
        XCTAssertFalse(c.isDue(now: t0.addingTimeInterval(delay)))
        XCTAssertTrue(c.isDue(now: t0.addingTimeInterval(3 + delay + 0.001)))
    }

    /// Two signals at the same instant are one burst, not two.
    func testIdenticalSignalDoesNotMoveTheDueDate() {
        var c = IBChangeCoalescer(delay: delay)
        XCTAssertTrue(c.signal(now: t0))
        XCTAssertFalse(c.signal(now: t0))
        XCTAssertEqual(c.dueAt, t0.addingTimeInterval(delay))
    }

    func testNotDueBeforeTheDelay() {
        var c = IBChangeCoalescer(delay: delay)
        c.signal(now: t0)
        XCTAssertFalse(c.isDue(now: t0.addingTimeInterval(delay - 0.01)))
    }

    /// Consuming is what lets the next burst schedule its own refresh.
    func testConsumeClearsThePendingRefresh() {
        var c = IBChangeCoalescer(delay: delay)
        c.signal(now: t0)
        c.consume()
        XCTAssertFalse(c.isPending)
        XCTAssertFalse(c.isDue(now: t0.addingTimeInterval(60)))
    }

    func testCancelDropsThePendingRefresh() {
        var c = IBChangeCoalescer(delay: delay)
        c.signal(now: t0)
        c.cancel()
        XCTAssertFalse(c.isPending)
    }

    /// The delay has to outlast the launch→activate gap it exists for.
    func testSettleDelayCoversTheLaunchActivateGap() {
        XCTAssertGreaterThan(IBChangeCoalescer.settleDelay, 0.5)
    }
}