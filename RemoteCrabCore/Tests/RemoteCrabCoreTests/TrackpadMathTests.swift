import XCTest
@testable import RemoteCrabCore

final class TrackpadMathTests: XCTestCase {

    func testAccelerateIdentityForSlowMoves() {
        let (dx, dy) = TrackpadMath.accelerate(dx: 0.001, dy: 0, sensitivity: 3)
        XCTAssertGreaterThan(dx, 0)
        XCTAssertEqual(dy, 0)
    }

    func testAccelerateFastMoveGainsMore() {
        let slow = TrackpadMath.accelerate(dx: 0.002, dy: 0, sensitivity: 3).dx
        let fast = TrackpadMath.accelerate(dx: 0.02, dy: 0, sensitivity: 3).dx
        // Fast flicks gain proportionally more than slow drags.
        XCTAssertGreaterThan(fast / 0.02, slow / 0.002)
    }

    func testSensitivityOrdering() {
        let s1 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 1).dx
        let s5 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 5).dx
        XCTAssertGreaterThan(s5, s1)
    }

    func testSensitivityClamped() {
        let s0 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 0).dx
        let s1 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 1).dx
        let s9 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 9).dx
        let s5 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 5).dx
        XCTAssertEqual(s0, s1, accuracy: 0.0001)
        XCTAssertEqual(s9, s5, accuracy: 0.0001)
    }

    func testMomentumDecaysAndStops() {
        var v = CGPoint(x: 0, y: 800)   // 800 pt/s downward
        var steps = 0
        while let step = TrackpadMath.momentumStep(velocity: v, elapsedSeconds: 1.0 / 60.0) {
            v = step.newVelocity
            steps += 1
            XCTAssertLessThan(abs(v.y), 800.0 + 0.01)
            XCTAssertLessThan(steps, 600)  // must terminate
        }
        XCTAssertGreaterThan(steps, 10)    // but actually glide a while
    }

    func testMomentumBelowCutoffStopsImmediately() {
        XCTAssertNil(TrackpadMath.momentumStep(velocity: CGPoint(x: 0, y: 10), elapsedSeconds: 1.0 / 60.0))
    }
}
