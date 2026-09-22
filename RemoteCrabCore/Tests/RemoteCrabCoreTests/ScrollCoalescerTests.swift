import XCTest
@testable import RemoteCrabCore

final class ScrollCoalescerTests: XCTestCase {

    func testFirstDeltaEmitsImmediately() {
        var c = ScrollCoalescer(minInterval: 1.0 / 60.0)
        XCTAssertEqual(c.add(CGPoint(x: 1, y: 0), at: 0), CGPoint(x: 1, y: 0))
    }

    func testDeltasWithinIntervalAccumulate() {
        var c = ScrollCoalescer(minInterval: 0.02)
        _ = c.add(CGPoint(x: 1, y: 0), at: 0)              // emits, starts the clock
        XCTAssertNil(c.add(CGPoint(x: 2, y: 0), at: 0.005)) // too soon
        XCTAssertEqual(c.add(CGPoint(x: 3, y: 0), at: 0.021), CGPoint(x: 5, y: 0))
    }

    func testFlushReturnsPendingAndClears() {
        var c = ScrollCoalescer(minInterval: 0.02)
        _ = c.add(CGPoint(x: 1, y: 0), at: 0)
        _ = c.add(CGPoint(x: 2, y: 0), at: 0.005)
        XCTAssertEqual(c.flush(), CGPoint(x: 2, y: 0))
        XCTAssertNil(c.flush())
    }

    func testNothingPendingEmitsNothing() {
        var c = ScrollCoalescer(minInterval: 0.02)
        _ = c.add(CGPoint(x: 1, y: 0), at: 0)
        XCTAssertNil(c.add(.zero, at: 1.0))
    }

    func testHasPending() {
        var c = ScrollCoalescer(minInterval: 0.02)
        _ = c.add(CGPoint(x: 1, y: 0), at: 0)
        XCTAssertFalse(c.hasPending)
        _ = c.add(CGPoint(x: 2, y: 0), at: 0.005)
        XCTAssertTrue(c.hasPending)
    }
}
