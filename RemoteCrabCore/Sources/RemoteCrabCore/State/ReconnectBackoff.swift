import Foundation

/// Geometric backoff for the receiver's automatic reconnect loop (B8).
///
/// The loop used a fixed 3 s delay, so a Mac whose phone was off — or on a
/// different network — kept dialing every 3 s for as long as the app ran. A
/// backoff eases off to a 30 s ceiling and resets the moment a dial lands.
public enum ReconnectBackoff {

    public static let base: Double = 3
    public static let ceiling: Double = 30

    /// Seconds to wait before auto-reconnect attempt `attempt` (0-based:
    /// 3, 6, 12, 24, then capped at 30).
    public static func delay(attempt: Int) -> Double {
        min(ceiling, base * pow(2.0, Double(max(0, attempt))))
    }
}
