import XCTest
@testable import RemoteCrabCore

final class SpeakerSampleTests: XCTestCase {

    func testClampsAndSaturates() {
        XCTAssertEqual(SpeakerSample.clampToInt16(0), 0)
        XCTAssertEqual(SpeakerSample.clampToInt16(1), Int16.max)
        XCTAssertEqual(SpeakerSample.clampToInt16(-1), Int16.min)
        XCTAssertEqual(SpeakerSample.clampToInt16(2), Int16.max)
        XCTAssertEqual(SpeakerSample.clampToInt16(-2), Int16.min)
        XCTAssertEqual(SpeakerSample.clampToInt16(0.5), Int16(0.5 * 32_767))
    }

    /// The regression (2026-10-11): a non-finite sample reached `Int16(_:)`,
    /// which traps. On the Mac that trap runs on CoreAudio's IO thread, so the
    /// whole receiver died with SIGTRAP. It must never trap.
    func testNonFiniteNeverTraps() {
        XCTAssertEqual(SpeakerSample.clampToInt16(.nan), 0)
        XCTAssertEqual(SpeakerSample.clampToInt16(.infinity), Int16.max)
        XCTAssertEqual(SpeakerSample.clampToInt16(-.infinity), Int16.min)
    }
}
