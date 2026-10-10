import XCTest
@testable import RemoteCrabCore

final class SpeakerRingTests: XCTestCase {

    func testDropCountCountsOnlyTheLap() {
        let cap: UInt64 = 24_000
        XCTAssertEqual(SpeakerRing.dropCount(writeIndex: 100, readIndex: 0, capacity: cap), 0)
        XCTAssertEqual(SpeakerRing.dropCount(writeIndex: cap, readIndex: 0, capacity: cap), 0)
        XCTAssertEqual(SpeakerRing.dropCount(writeIndex: cap + 1000, readIndex: 0, capacity: cap), 1000)
    }

    /// The regression (2026-10-11): a wrapped difference — the consumer briefly
    /// ahead of the producer — used to yield a value near `UInt64.max`. That
    /// value flowed into `pendingDrops += dropped`, a **non-wrapping** add on
    /// CoreAudio's IO thread, which trapped ("arithmetic overflow") and killed
    /// the entire receiver. It must yield 0, and adding it must not overflow.
    func testWrappedDifferenceIsZeroAndNeverOverflows() {
        let cap: UInt64 = 24_000
        XCTAssertEqual(SpeakerRing.dropCount(writeIndex: 5, readIndex: 100, capacity: cap), 0)
        XCTAssertEqual(SpeakerRing.dropCount(writeIndex: 0, readIndex: UInt64.max - 3, capacity: cap), 0)

        var pending: UInt64 = 0
        pending &+= SpeakerRing.dropCount(writeIndex: 5, readIndex: 100, capacity: cap)
        XCTAssertEqual(pending, 0)
    }
}
