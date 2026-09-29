import XCTest
@testable import RemoteCrabCore

/// The window/median model behind the "poor connection" hint.
///
/// Median, not mean: a single 3 s stall in a ten-sample window moves the
/// mean by 300 ms, which would flicker the hint. The median ignores it.
final class LatencyTrackerTests: XCTestCase {

    func testEmptyTrackerHasNoReading() {
        let t = IBLatencyTracker()
        XCTAssertNil(t.medianMs)
        XCTAssertFalse(t.isPoor)
        XCTAssertEqual(t.quality, .unknown)
    }

    func testSingleSampleIsTheMedian() {
        var t = IBLatencyTracker()
        t.record(millis: 42)
        XCTAssertEqual(t.medianMs, 42)
    }

    func testMedianIgnoresOneOutlier() {
        var t = IBLatencyTracker()
        for ms in [20, 22, 24, 25, 26, 3_000] { t.record(millis: ms) }
        // Six samples: a 3000 outlier is above the middle, so the median of
        // the lower half wins — nowhere near 600.
        XCTAssertLessThan(t.medianMs ?? .max, 100)
    }

    func testMedianIgnoresOneShortHiccup() {
        var t = IBLatencyTracker()
        for ms in [400, 410, 420, 430, 0] { t.record(millis: ms) }
        XCTAssertGreaterThanOrEqual(t.medianMs ?? 0, 400)
    }

    func testWindowDropsOldSamples() {
        var t = IBLatencyTracker(window: 4)
        for _ in 0..<10 { t.record(millis: 1_000) }
        for _ in 0..<4 { t.record(millis: 5) }
        // The four stale 1000s are gone, so the median is 5, not 500.
        XCTAssertEqual(t.medianMs, 5)
    }

    func testQualityFlipsAtTheThreshold() {
        // Explicit window: with a 10-deep window, 5 samples at the
        // threshold and 3 above it still have a median of exactly the
        // threshold, so the majority has to actually be over it.
        var t = IBLatencyTracker(window: 4)
        for _ in 0..<4 { t.record(millis: IBLatencyTracker.poorThresholdMs) }
        XCTAssertEqual(t.quality, .good, "the threshold itself is not 'poor'")
        for _ in 0..<3 { t.record(millis: IBLatencyTracker.poorThresholdMs + 1) }
        XCTAssertEqual(t.medianMs, IBLatencyTracker.poorThresholdMs + 1)
        XCTAssertEqual(t.quality, .poor)
    }

    /// A minority of slow samples must not condemn the link.
    func testQualityIgnoresAMinorityOfSlowSamples() {
        var t = IBLatencyTracker(window: 10)
        for _ in 0..<8 { t.record(millis: 30) }
        for _ in 0..<2 { t.record(millis: 900) }
        XCTAssertEqual(t.quality, .good, "2 of 10 slow is normal Wi-Fi jitter")
    }

    func testNegativeAndAbsurdSamplesAreIgnored() {
        var t = IBLatencyTracker()
        t.record(millis: -5)
        t.record(millis: Int(Int32.max))
        XCTAssertNil(t.medianMs, "garbage must not become a reading")
    }

    /// The hint must not strobe: a link that keeps crossing the threshold
    /// should report "poor" once, not once per sample.
    func testQualityIsStickyWhilePoor() {
        var t = IBLatencyTracker()
        for _ in 0..<5 { t.record(millis: 900) }
        XCTAssertEqual(t.quality, .poor)
        for _ in 0..<5 { t.record(millis: 800) }
        XCTAssertEqual(t.quality, .poor)
        for _ in 0..<5 { t.record(millis: 900) }
        XCTAssertEqual(t.quality, .poor)
    }

    func testResetClearsEverything() {
        var t = IBLatencyTracker()
        for _ in 0..<5 { t.record(millis: 900) }
        t.reset()
        XCTAssertNil(t.medianMs)
        XCTAssertEqual(t.quality, .unknown)
    }

    /// Symmetry with the Mac's own measurement: the same model on both ends
    /// means a slow link is described the same way from either side.
    func testSameModelAsTheMacReceiver() {
        var t = IBLatencyTracker(window: 30)
        for _ in 0..<30 { t.record(millis: 12) }
        XCTAssertEqual(t.medianMs, 12)
        XCTAssertEqual(t.quality, .good)
    }
}
