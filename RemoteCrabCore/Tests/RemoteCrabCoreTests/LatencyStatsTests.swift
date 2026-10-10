import XCTest
@testable import RemoteCrabCore

final class LatencyStatsTests: XCTestCase {

    func testMedianOfAnOddWindow() {
        var s = LatencyStats(capacity: 10)
        [10, 20, 30].forEach { s.add(Double($0)) }
        XCTAssertEqual(s.median, 20)
    }

    func testWindowKeepsOnlyTheCapacity() {
        var s = LatencyStats(capacity: 3)
        [1, 2, 3, 4, 5].forEach { s.add(Double($0)) }
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.median, 4)   // [3, 4, 5]
    }

    func testEmptyMedianIsZero() {
        XCTAssertEqual(LatencyStats().median, 0)
    }

    func testSpikeRatioAgainstTheStreamsOwnMedian() {
        var s = LatencyStats()
        [10, 10, 10, 10].forEach { s.add($0) }
        XCTAssertEqual(s.spikeRatio(latest: 30), 3, accuracy: 0.001)
        XCTAssertEqual(s.spikeRatio(latest: 10), 1, accuracy: 0.001)
        XCTAssertEqual(LatencyStats().spikeRatio(latest: 5), 0)
    }
}
