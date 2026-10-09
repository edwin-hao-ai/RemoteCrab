import Foundation

/// How the phone reacts to heat and low power.
///
/// Nothing shipped before: the app streamed at full quality no matter how hot
/// the phone got or how low the battery was, so a long 4K session could throttle
/// or drain silently and the user had no idea why the picture got choppy. The
/// policy is deliberately gentle — drop the frame rate a notch before it would
/// ever stop the stream, because a degraded-but-alive session beats a dead one
/// when someone is on a call.
public enum ThermalPolicy {

    public enum Severity: Equatable, Sendable {
        case nominal
        case warm
        case hot
        case critical
    }

    /// Reduce a `ProcessInfo.ThermalState` (+ Low Power Mode) to a severity.
    /// Low Power Mode reads as `warm`: the user asked to save power, so back
    /// off even if the phone isn't hot yet.
    public static func severity(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> Severity {
        switch thermal {
        case .nominal:    return lowPower ? .warm : .nominal
        case .fair:       return .warm
        case .serious:    return .hot
        case .critical:   return .critical
        @unknown default: return lowPower ? .warm : .nominal
        }
    }

    /// The frame rate to actually stream at. Kept at the requested rate until
    /// the phone is genuinely hot, then halved (never below 15, so it stays
    /// watchable).
    public static func effectiveFrameRate(requested: Int, severity: Severity) -> Int {
        switch severity {
        case .nominal, .warm: return requested
        case .hot, .critical: return max(15, requested / 2)
        }
    }

    /// Whether the user should be told (the state is one worth explaining).
    public static func shouldWarn(_ severity: Severity) -> Bool {
        severity == .hot || severity == .critical
    }

    /// One short, honest sentence for the UI — a status line owes the user a
    /// reason whenever the state is not "working".
    public static func message(_ severity: Severity) -> String? {
        switch severity {
        case .nominal:  return nil
        case .warm:     return "Low Power Mode is on — the video may be a little less smooth."
        case .hot:      return "The phone is warm — lowering the video quality to stay smooth."
        case .critical: return "The phone is very hot — video quality is reduced. Let it cool."
        }
    }
}
