import CoreGraphics
import Foundation

/// Coalesces two-finger scroll deltas into at most one event per display
/// frame.
///
/// A ProMotion iPhone delivers pan callbacks at up to 120 Hz; forwarding
/// every one puts twice the frames the Mac can consume onto the TCP
/// socket, which shows up as jitter on Wi-Fi. Deltas that arrive inside
/// the same interval are summed and sent together — the total travel is
/// identical, the event count halves.
public struct ScrollCoalescer {

    /// Minimum time between emitted events.
    public var minInterval: TimeInterval

    private var pending: CGPoint = .zero
    private var lastEmit: TimeInterval?

    public init(minInterval: TimeInterval = 1.0 / 60.0) {
        self.minInterval = minInterval
    }

    public var hasPending: Bool { pending != .zero }

    /// Add a delta at `time` (seconds, monotonic). Returns the delta to
    /// emit now — the first delta always emits immediately (no added
    /// latency), later ones once the interval has elapsed.
    public mutating func add(_ delta: CGPoint, at time: TimeInterval) -> CGPoint? {
        pending.x += delta.x
        pending.y += delta.y
        guard let last = lastEmit else {
            return emit(at: time)
        }
        guard time - last >= minInterval else { return nil }
        return emit(at: time)
    }

    /// Emit whatever is pending regardless of the interval (gesture end).
    public mutating func flush() -> CGPoint? {
        guard hasPending else { return nil }
        return emit(at: lastEmit ?? 0)
    }

    private mutating func emit(at time: TimeInterval) -> CGPoint? {
        guard hasPending else { return nil }
        let out = pending
        pending = .zero
        lastEmit = time
        return out
    }
}
