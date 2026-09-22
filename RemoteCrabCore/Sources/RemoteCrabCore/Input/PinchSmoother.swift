import CoreGraphics
import Foundation

/// Smooths noisy `UIPinchGestureRecognizer` scale deltas.
///
/// The raw per-callback scale delta jitters by a few thousandths even
/// when the fingers are nearly still, so zoom would creep on its own.
/// A dead-zone kills that jitter and an exponential moving average damps
/// single-callback spikes, while a sustained pinch still comes through.
public struct PinchSmoother {

    /// Deltas below this magnitude are treated as jitter and dropped.
    public var deadZone: CGFloat
    /// EMA weight for a new sample (0 = ignore, 1 = no smoothing).
    public var smoothing: CGFloat

    private var filtered: CGFloat = 0

    public init(deadZone: CGFloat = 0.004, smoothing: CGFloat = 0.45) {
        self.deadZone = deadZone
        self.smoothing = smoothing
    }

    /// Smoothed delta for the raw scale change since the last call, or
    /// nil when the result is inside the dead-zone.
    public mutating func delta(forScaleDelta raw: CGFloat) -> CGFloat? {
        filtered = smoothing * raw + (1 - smoothing) * filtered
        guard abs(filtered) >= deadZone else { return nil }
        return filtered
    }

    /// Forget the moving average (call on pinch begin/end).
    public mutating func reset() {
        filtered = 0
    }
}
