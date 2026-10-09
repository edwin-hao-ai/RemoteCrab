import Foundation

/// Achieved stream numbers, computed from raw counters.
///
/// Both receivers only ever reported the *requested* rate, and on iOS that
/// number was inert (`Quality` overrides `AverageBitRate`), so nobody could say
/// what the stream actually did. This turns byte/frame counts into the two
/// numbers a human can check — real fps and real kbps — so "the picture is
/// choppy" has a measurement behind it instead of a guess.
public enum StreamTelemetry {

    public struct Sample: Equatable, Sendable {
        public let fps: Double
        public let kbps: Double
        public init(fps: Double, kbps: Double) {
            self.fps = fps
            self.kbps = kbps
        }

        /// One compact line; SF Mono, locale-neutral.
        public var summary: String {
            String(format: "%.0f fps, %.0f kbps", fps, kbps)
        }
    }

    /// - Parameters:
    ///   - bytes: bytes observed since the previous sample
    ///   - frames: frames observed since the previous sample
    ///   - interval: seconds since the previous sample
    public static func sample(bytes: Int, frames: Int, interval: Double) -> Sample {
        guard interval > 0 else { return Sample(fps: 0, kbps: 0) }
        return Sample(
            fps: Double(max(0, frames)) / interval,
            kbps: Double(max(0, bytes)) * 8.0 / 1000.0 / interval
        )
    }
}
