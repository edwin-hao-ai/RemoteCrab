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
    /// `retention` is the per-60fps-frame velocity retention for this
    /// glide (see `momentumRetention`). Returns the normalized scroll
    /// delta for this frame and the decayed velocity, or nil once the
    /// glide is imperceptible.
    public static func momentumStep(
        velocity: CGPoint,
        elapsedSeconds: Double,
        retention: CGFloat
    ) -> (delta: CGPoint, newVelocity: CGPoint)? {
        let speed = hypot(velocity.x, velocity.y)
        guard speed >= momentumCutoff else { return nil }   // pt/s cutoff

        let dt = CGFloat(elapsedSeconds)
        let delta = CGPoint(x: velocity.x * dt, y: velocity.y * dt)
        let decay = pow(retention, dt * 60)               // per-60fps-frame decay
        let newVelocity = CGPoint(x: velocity.x * decay, y: velocity.y * decay)
        return (delta, newVelocity)
    }

    /// Velocity below which a glide is considered finished (pt/s).
    public static let momentumCutoff: CGFloat = 40

    /// Per-frame (60 fps) velocity retention for a momentum glide,
    /// scaled by how hard the user flicked. A gentle flick barely above
    /// the cutoff decays quickly (0.90/frame); a hard flick keeps more
    /// speed (0.985/frame) and therefore glides much farther — the
    /// Magic Trackpad's "hard flick travels far" feel, instead of the
    /// old fixed-rate decay where every flick stopped at the same time.
    public static func momentumRetention(initialSpeed: CGFloat) -> CGFloat {
        let slow: CGFloat = 40, fast: CGFloat = 2000
        let t = min(max((initialSpeed - slow) / (fast - slow), 0), 1)
        return 0.90 + 0.085 * t
    }

    /// Two-finger scroll gain. A mild acceleration (much gentler than the
    /// pointer curve) so fast scrolls travel a little farther, like a real
    /// trackpad. `sensitivity` is the 1...5 settings value.
    /// Input/output are normalized finger deltas (fraction of the surface).
    public static func accelerateScroll(dx: CGFloat, dy: CGFloat,
                                        sensitivity: Int) -> CGPoint {
        let s = CGFloat(max(1, min(5, sensitivity)))
        let baseGain: CGFloat = 0.7 + 0.3 * (s - 1)   // 0.7 … 1.9
        let speed = (dx * dx + dy * dy).squareRoot()
        let boost: CGFloat = 1 + min(speed * 4, 0.8)  // up to +80%
        let gain = baseGain * boost
        return CGPoint(x: dx * gain, y: dy * gain)
    }

    /// Haptic tick spacing for finger-driven scroll, in points of travel.
    /// A fast flick scrolls farther between ticks (so it doesn't buzz);
    /// slow scrubbing ticks tightly for precision.
    public static func scrollTickDistance(speedPointsPerSecond: CGFloat) -> CGFloat {
        let t = min(max(speedPointsPerSecond / 2000, 0), 1)
        return 24 + 40 * t   // 24 … 64 pt
    }
}
