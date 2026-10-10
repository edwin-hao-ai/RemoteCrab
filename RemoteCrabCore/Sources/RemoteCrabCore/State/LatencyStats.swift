import Foundation

/// A small rolling window of latency samples with a median.
///
/// The control panel showed only the ping RTT and called it "latency". This is
/// the *measured* device-side pipeline: the wall-clock time from a video frame
/// arriving at the receiver to the decoder emitting it — all on one machine's
/// clock, so it is exact (no cross-device skew), and the median is a scene-
/// independent baseline (a spike is "N× this stream's own median", not a magic
/// constant).
public struct LatencyStats {

    private var samples: [Double] = []
    private let capacity: Int

    public init(capacity: Int = 120) {
        self.capacity = max(1, capacity)
    }

    public mutating func add(_ milliseconds: Double) {
        samples.append(milliseconds)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public var median: Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    /// How many times the current sample exceeds the median (0 when there is
    /// no baseline yet) — a scene-independent "this frame was slow" signal.
    public func spikeRatio(latest: Double) -> Double {
        let m = median
        return m > 0 ? latest / m : 0
    }

    public var count: Int { samples.count }
}
