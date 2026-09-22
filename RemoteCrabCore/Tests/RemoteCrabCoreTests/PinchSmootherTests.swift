import XCTest
@testable import RemoteCrabCore

final class PinchSmootherTests: XCTestCase {

    func testDeadZoneSuppressesJitter() {
        var s = PinchSmoother(deadZone: 0.01, smoothing: 0.5)
        XCTAssertNil(s.delta(forScaleDelta: 0.001))
        XCTAssertNil(s.delta(forScaleDelta: -0.002))
    }

    func testSustainedPinchEmits() {
        var s = PinchSmoother(deadZone: 0.005, smoothing: 0.5)
        var out: CGFloat?
        for _ in 0..<20 { out = s.delta(forScaleDelta: 0.05) ?? out }
        XCTAssertNotNil(out)
        XCTAssertGreaterThan(out ?? 0, 0)
    }

    func testSmoothingDampsFirstSpike() {
        var s = PinchSmoother(deadZone: 0, smoothing: 0.5)
        let first = s.delta(forScaleDelta: 0.1)
        XCTAssertEqual(first ?? 0, 0.05, accuracy: 0.0001)
    }

    func testResetClearsState() {
        var s = PinchSmoother(deadZone: 0, smoothing: 0.5)
        _ = s.delta(forScaleDelta: 0.1)
        s.reset()
        XCTAssertEqual(s.delta(forScaleDelta: 0.1) ?? 0, 0.05, accuracy: 0.0001)
    }
}
