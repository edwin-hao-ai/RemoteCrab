import XCTest
@testable import RemoteCrabCore

final class ThermalPolicyTests: XCTestCase {

    func testLowPowerReadsAsWarmEvenWhenCool() {
        // The user asked to save power; back off even before the phone is hot.
        XCTAssertEqual(ThermalPolicy.severity(thermal: .nominal, lowPower: true), .warm)
    }

    func testThermalStatesMapToSeverity() {
        XCTAssertEqual(ThermalPolicy.severity(thermal: .nominal, lowPower: false), .nominal)
        XCTAssertEqual(ThermalPolicy.severity(thermal: .fair, lowPower: false), .warm)
        XCTAssertEqual(ThermalPolicy.severity(thermal: .serious, lowPower: false), .hot)
        XCTAssertEqual(ThermalPolicy.severity(thermal: .critical, lowPower: false), .critical)
    }

    func testFrameRateStaysUntilHotThenHalvesButNeverBelow15() {
        XCTAssertEqual(ThermalPolicy.effectiveFrameRate(requested: 30, severity: .nominal), 30)
        XCTAssertEqual(ThermalPolicy.effectiveFrameRate(requested: 30, severity: .warm), 30)
        XCTAssertEqual(ThermalPolicy.effectiveFrameRate(requested: 30, severity: .hot), 15)
        XCTAssertEqual(ThermalPolicy.effectiveFrameRate(requested: 24, severity: .critical), 15)
    }

    func testWarningIsOnlyRaisedWhenHotAndSaysWhy() {
        XCTAssertFalse(ThermalPolicy.shouldWarn(.nominal))
        XCTAssertFalse(ThermalPolicy.shouldWarn(.warm))
        XCTAssertTrue(ThermalPolicy.shouldWarn(.hot))
        // A status line owes the user a reason whenever it is not "working".
        XCTAssertNil(ThermalPolicy.message(.nominal))
        XCTAssertNotNil(ThermalPolicy.message(.hot))
        XCTAssertNotNil(ThermalPolicy.message(.critical))
    }
}

final class StreamTelemetryTests: XCTestCase {

    func testSampleComputesRealFpsAndKbps() {
        let s = StreamTelemetry.sample(bytes: 1_000_000, frames: 60, interval: 2.0)
        XCTAssertEqual(s.fps, 30, accuracy: 0.001)
        XCTAssertEqual(s.kbps, 4000, accuracy: 1)
    }

    func testZeroIntervalIsSafe() {
        XCTAssertEqual(StreamTelemetry.sample(bytes: 100, frames: 5, interval: 0),
                       StreamTelemetry.Sample(fps: 0, kbps: 0))
    }

    func testNegativeCountersAreClamped() {
        let s = StreamTelemetry.sample(bytes: -10, frames: -1, interval: 1)
        XCTAssertEqual(s.fps, 0)
        XCTAssertEqual(s.kbps, 0)
    }
}
