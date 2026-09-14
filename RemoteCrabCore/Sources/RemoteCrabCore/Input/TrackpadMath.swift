import CoreGraphics
import Foundation

/// Pure pointer/scroll math for the iPhone-as-trackpad surface.
/// Kept in RemoteCrabCore (no UIKit) so the curves are unit-testable.
public enum TrackpadMath {

    /// Pointer acceleration: slow drags stay precise, fast flicks
    /// travel further. `sensitivity` is the 1...5 settings value.
    /// `maxBoost` caps the speed multiplier — pass 0 for a constant
    /// gain (precision work such as text selection).
    /// Input/output are normalized screen units (0...1 per axis).
    public static func accelerate(dx: Float, dy: Float, sensitivity: Int,
                                  maxBoost: Float = 2.0) -> (dx: Float, dy: Float) {
        let s = Float(max(1, min(5, sensitivity)))
        let baseGain: Float = 0.6 + 0.35 * (s - 1)   // 0.6 … 2.0
        let speed = sqrtf(dx * dx + dy * dy)
        let boost: Float = 1 + min(speed * 6, max(0, maxBoost))
        let gain = baseGain * boost
        return (dx * gain, dy * gain)
    }

    /// Selection-drag curve (double-tap-hold text selection): a fixed,
    /// low, boost-free gain. Selecting needs pixel-level control at
    /// low speed — acceleration and momentum only overshoot the
    /// selection boundary.
    public static func selectionAccelerate(dx: Float, dy: Float) -> (dx: Float, dy: Float) {
        let gain: Float = 0.55
        return (dx * gain, dy * gain)
    }

    /// One momentum-scroll step after the fingers lift.
    /// `velocity` is in points/second (UIKit's pan velocity).
    /// Returns the normalized scroll delta for this frame and the
    /// decayed velocity, or nil once the glide is imperceptible.
    public static func momentumStep(
        velocity: CGPoint,
        elapsedSeconds: Double
    ) -> (delta: CGPoint, newVelocity: CGPoint)? {
        let speed = hypot(velocity.x, velocity.y)
        guard speed >= 40 else { return nil }        // pt/s cutoff

        let dt = CGFloat(elapsedSeconds)
        let delta = CGPoint(x: velocity.x * dt, y: velocity.y * dt)
        let decay = pow(0.94, dt * 60)               // per-60fps-frame decay
        let newVelocity = CGPoint(x: velocity.x * decay, y: velocity.y * decay)
        return (delta, newVelocity)
    }
}
