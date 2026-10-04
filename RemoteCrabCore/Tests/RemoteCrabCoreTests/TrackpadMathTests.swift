import XCTest
@testable import RemoteCrabCore

final class TrackpadMathTests: XCTestCase {

    func testAccelerateIdentityForSlowMoves() {
        let (dx, dy) = TrackpadMath.accelerate(dx: 0.001, dy: 0, sensitivity: 3)
        XCTAssertGreaterThan(dx, 0)
        XCTAssertEqual(dy, 0)
    }

    func testAccelerateFastMoveGainsMore() {
        // Acceleration is velocity-driven: same delta, higher finger speed
        // → higher gain.
        let slow = TrackpadMath.accelerate(dx: 0.002, dy: 0, sensitivity: 3, pointerSpeed: 0.1).dx / 0.002
        let fast = TrackpadMath.accelerate(dx: 0.002, dy: 0, sensitivity: 3, pointerSpeed: 1.8).dx / 0.002
        XCTAssertGreaterThan(fast, slow)
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

    // MARK: - Momentum

    private func glideDistance(initialSpeed: CGFloat) -> CGFloat {
        let retention = TrackpadMath.momentumRetention(initialSpeed: initialSpeed)
        var v = CGPoint(x: 0, y: initialSpeed)
        var total: CGFloat = 0
        while let step = TrackpadMath.momentumStep(
            velocity: v, elapsedSeconds: 1.0 / 60.0, retention: retention) {
            total += abs(step.delta.y)
            v = step.newVelocity
        }
        return total
    }

    func testMomentumDecaysAndStops() {
        let retention = TrackpadMath.momentumRetention(initialSpeed: 800)
        var v = CGPoint(x: 0, y: 800)   // 800 pt/s downward
        var steps = 0
        while let step = TrackpadMath.momentumStep(
            velocity: v, elapsedSeconds: 1.0 / 60.0, retention: retention) {
            v = step.newVelocity
            steps += 1
            XCTAssertLessThan(abs(v.y), 800.0 + 0.01)
            XCTAssertLessThan(steps, 600)  // must terminate
        }
        XCTAssertGreaterThan(steps, 10)    // but actually glide a while
    }

    func testMomentumBelowCutoffStopsImmediately() {
        XCTAssertNil(TrackpadMath.momentumStep(
            velocity: CGPoint(x: 0, y: 10), elapsedSeconds: 1.0 / 60.0, retention: 0.95))
    }

    func testMomentumRetentionIncreasesWithSpeed() {
        XCTAssertLessThan(TrackpadMath.momentumRetention(initialSpeed: 40),
                          TrackpadMath.momentumRetention(initialSpeed: 2000))
        XCTAssertEqual(TrackpadMath.momentumRetention(initialSpeed: 40), 0.90, accuracy: 0.001)
        XCTAssertEqual(TrackpadMath.momentumRetention(initialSpeed: 5000), 0.985, accuracy: 0.001)
    }

    func testFastFlickGlidesFartherThanSlow() {
        // The whole point of velocity-scaled momentum: a hard flick
        // travels much farther than a gentle one.
        XCTAssertGreaterThan(glideDistance(initialSpeed: 2000),
                             glideDistance(initialSpeed: 120) * 2)
    }

    // MARK: - Scroll acceleration

    func testScrollAccelerateSensitivityOrdering() {
        let s1 = TrackpadMath.accelerateScroll(dx: 0.01, dy: 0, sensitivity: 1).x
        let s5 = TrackpadMath.accelerateScroll(dx: 0.01, dy: 0, sensitivity: 5).x
        XCTAssertGreaterThan(s5, s1)
    }

    func testScrollAccelerateFastGainsMore() {
        let slow = TrackpadMath.accelerateScroll(dx: 0.002, dy: 0, sensitivity: 3).x / 0.002
        let fast = TrackpadMath.accelerateScroll(dx: 0.03, dy: 0, sensitivity: 3).x / 0.03
        XCTAssertGreaterThan(fast, slow)
    }

    func testScrollAccelerateKeepsDirection() {
        XCTAssertLessThan(TrackpadMath.accelerateScroll(dx: 0, dy: -0.02, sensitivity: 3).y, 0)
        XCTAssertGreaterThan(TrackpadMath.accelerateScroll(dx: 0.02, dy: 0, sensitivity: 3).x, 0)
    }

    // MARK: - Haptic tick spacing

    func testScrollTickDistanceGrowsWithSpeed() {
        XCTAssertEqual(TrackpadMath.scrollTickDistance(speedPointsPerSecond: 0), 24, accuracy: 0.001)
        XCTAssertEqual(TrackpadMath.scrollTickDistance(speedPointsPerSecond: 5000), 64, accuracy: 0.001)
        XCTAssertGreaterThan(TrackpadMath.scrollTickDistance(speedPointsPerSecond: 800),
                             TrackpadMath.scrollTickDistance(speedPointsPerSecond: 200))
    }

    // MARK: - Pointer

    func testSelectionAccelerateHasNoBoost() {
        // Fast and slow drags get the SAME gain — selecting text must
        // never overshoot because the finger flicked.
        let slow = TrackpadMath.selectionAccelerate(dx: 0.002, dy: 0).dx
        let fast = TrackpadMath.selectionAccelerate(dx: 0.02, dy: 0).dx
        XCTAssertEqual(fast / 0.02, slow / 0.002, accuracy: 0.0001)
    }

    func testSelectionAccelerateIsLowGain() {
        // Below the lowest pointer-curve gain (0.6 at sensitivity 1,
        // before boost) — selection is precision-first.
        let (dx, dy) = TrackpadMath.selectionAccelerate(dx: 0.01, dy: -0.02)
        XCTAssertLessThan(dx / 0.01, 0.6)
        XCTAssertGreaterThan(dx, 0)
        XCTAssertEqual(dy / -0.02, dx / 0.01, accuracy: 0.0001)  // same gain both axes
    }

    func testAccelerateMaxBoostCapsSpeedGain() {
        let boosted = TrackpadMath.accelerate(dx: 0.05, dy: 0, sensitivity: 3, pointerSpeed: 2.0).dx
        let capped = TrackpadMath.accelerate(dx: 0.05, dy: 0, sensitivity: 3, pointerSpeed: 2.0, maxBoost: 0).dx
        XCTAssertLessThan(capped, boosted)
        // maxBoost 0 = constant base gain at any speed.
        let slowCapped = TrackpadMath.accelerate(dx: 0.002, dy: 0, sensitivity: 3, pointerSpeed: 0, maxBoost: 0).dx
        XCTAssertEqual(capped / 0.05, slowCapped / 0.002, accuracy: 0.01)
        // Full boost is capped at 1 + maxBoost.
        let full = TrackpadMath.accelerate(dx: 0.05, dy: 0, sensitivity: 3, pointerSpeed: 99).dx / 0.05
        let base: Float = 0.6 + 0.35 * 2
        XCTAssertEqual(full, base * (1 + 2.5), accuracy: 0.01)
    }

    // MARK: - Direction is an invariant, not a detail
    //
    // A user reported the pointer going right when the finger went left, on
    // Windows only. Reading both receivers found them **identical** — no
    // negation anywhere, and `git log -S` shows the Windows move maths has
    // exactly one commit and never had a sign flip. So nothing in this repo
    // explains it, which is precisely why the property needs a test: it is
    // the thing that would be invisible if it ever broke again.
    //
    // The curve is a positive gain, so it must never flip a sign or reorder
    // axes — at any sensitivity, any speed, in either direction.

    func testAccelerationNeverFlipsTheDirectionOfTravel() {
        for sensitivity in 1...5 {
            for pointerSpeed in [Float(0), 0.3, 1.0, 2.0, 9.0] {
                for (dx, dy) in [(Float(-0.2), Float(-0.1)),
                                 (Float(-0.2), Float(0.1)),
                                 (Float(0.2), Float(-0.1)),
                                 (Float(0.2), Float(0.1))] {
                    let out = TrackpadMath.accelerate(dx: dx, dy: dy,
                                                      sensitivity: sensitivity,
                                                      pointerSpeed: pointerSpeed)
                    XCTAssertEqual(out.dx.sign == dx.sign, true,
                                   "s=\(sensitivity) v=\(pointerSpeed): dx \(dx) -> \(out.dx)")
                    XCTAssertEqual(out.dy.sign == dy.sign, true,
                                   "s=\(sensitivity) v=\(pointerSpeed): dy \(dy) -> \(out.dy)")
                }
            }
        }
    }

    /// Selection drags use a different curve (fixed low gain). It must not
    /// swap or flip the axes either — a reversed selection drag is the same
    /// class of bug as a reversed pointer.
    func testSelectionCurveKeepsTheAxesApart() {
        let out = TrackpadMath.selectionAccelerate(dx: -0.3, dy: 0.2)
        XCTAssertLessThan(out.dx, 0)
        XCTAssertGreaterThan(out.dy, 0)
    }

    /// The gain must be finite and bounded at extreme speeds. An unbounded
    /// or NaN gain is what makes a small drag overshoot the target, which a
    /// user can easily describe as "it went the other way".
    func testTheGainStaysBoundedAtExtremeSpeed() {
        for pointerSpeed in [Float(0), 1e3, 1e9, .greatestFiniteMagnitude] {
            let out = TrackpadMath.accelerate(dx: 0.01, dy: 0,
                                              sensitivity: 5, pointerSpeed: pointerSpeed)
            XCTAssertTrue(out.dx.isFinite, "gain went non-finite at v=\(pointerSpeed)")
            XCTAssertLessThan(out.dx, 1.0, "a 1% drag must not cross the whole screen")
        }
    }

    /// Scrolling is the other direction users report. Same invariant: the
    /// curve scales, it never reflects.
    func testScrollAccelerationNeverFlipsTheDirection() {
        for sensitivity in 1...5 {
            for (dx, dy) in [(CGFloat(-0.2), CGFloat(-0.1)),
                             (CGFloat(-0.2), CGFloat(0.1)),
                             (CGFloat(0.2), CGFloat(-0.1)),
                             (CGFloat(0.2), CGFloat(0.1))] {
                let out = TrackpadMath.accelerateScroll(dx: dx, dy: dy,
                                                        sensitivity: sensitivity)
                XCTAssertEqual(out.x.sign == dx.sign, true, "scroll x flipped")
                XCTAssertEqual(out.y.sign == dy.sign, true, "scroll y flipped")
            }
        }
    }
}
