import XCTest
@testable import RemoteCrabCore

final class ReconnectBackoffTests: XCTestCase {
    func testDelayGrowsGeometricallyThenCaps() {
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 0), 3)
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 1), 6)
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 2), 12)
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 3), 24)
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 4), 30)
    }

    func testDelayNeverExceedsTheCeiling() {
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 20), 30)
    }

    func testNegativeAttemptIsTreatedAsFirst() {
        XCTAssertEqual(ReconnectBackoff.delay(attempt: -1), 3)
    }
}
