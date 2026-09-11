import Foundation

/// Shared formatters for technical readouts shown in the Mac UI.
enum IBFormat {
    /// Human-readable bitrate: one-decimal Mbps at/above 1 Mbps,
    /// whole kbps below it (integer Mbps division used to render
    /// "0 Mbps" for anything under a megabit).
    static func bitrate(bps: Int) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000)
        }
        return String(format: "%.0f kbps", Double(bps) / 1_000)
    }
}
