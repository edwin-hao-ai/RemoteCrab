import Foundation

/// A small sliding-window RTT model, shared by both ends of the link.
///
/// **Why the phone needs its own.** The wire's `ping` frame carries a
/// *sender's* timestamp and is echoed back verbatim, so whoever **echoes**
/// can measure nothing — the two clocks belong to different machines. Until
/// now the phone only echoed, which is why `lastLatencyMs` was declared and
/// never assigned. With the receiver now echoing probes it didn't originate
/// (see `IBPingProbe`), the phone initiates too and this tracks the result.
///
/// **Why a median.** A single 3 s stall inside a ten-sample window shifts the
/// mean by 300 ms, which would make a "poor connection" hint flicker on and
/// off during ordinary Wi-Fi jitter. The median ignores it entirely, and
/// `quality` only reports a change when the evidence is unambiguous.
public struct IBLatencyTracker: Equatable, Sendable {

    /// Round trips above this (after the median) make the link "poor".
    /// High enough that a busy home Wi-Fi never trips it, low enough that a
    /// user notices video stutter *before* they notice the video stutter.
    public static let poorThresholdMs = 400

    /// Samples kept. ~30 s of history at the phone's 3 s cadence — long
    /// enough to ignore a burst, short enough to notice a real change.
    public static let defaultWindow = 10

    public enum Quality: Equatable, Sendable {
        /// No measurement yet (a receiver too old to echo probes, or the
        /// link dropped). Never surfaced as "bad" — absence of data is not
        /// evidence of a problem.
        case unknown
        case good
        case poor
    }

    public let window: Int
    private var samples: [Int] = []

    public init(window: Int = defaultWindow) {
        self.window = max(1, window)
    }

    /// Record one round trip. Out-of-range values are dropped rather than
    /// clamped — a negative or `Int32.max` reading means the clocks or the
    /// framing are broken, and storing it would poison the median.
    @discardableResult
    public mutating func record(millis: Int) -> Int {
        guard millis >= 0, millis <= 60_000 else { return millis }
        samples.append(millis)
        if samples.count > window { samples.removeFirst(samples.count - window) }
        return millis
    }

    public var medianMs: Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    public var quality: Quality {
        guard let medianMs else { return .unknown }
        return medianMs > Self.poorThresholdMs ? .poor : .good
    }

    public var isPoor: Bool { quality == .poor }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}

/// Sends `ping` probes and recognises their echoes.
///
/// Both sides need the same discrimination, and getting it wrong is not a
/// cosmetic bug: a receiver that mistakes the *phone's* timestamp for its
/// own computes a round trip equal to the **clock offset between the two
/// machines** — which can be hours — and paints that in the menu bar. So the
/// rule is "a probe is mine only if its timestamp is byte-identical to the
/// last one I sent", and anything else is somebody else's probe to echo.
public struct IBPingProbe: Sendable {

    /// Microseconds, matching `IBWire.encodePing`.
    public private(set) var lastSentMicros: UInt64?

    public init() {}

    /// Stamp and remember an outgoing probe. Returns the payload to send.
    public mutating func makeProbe(now: Date) -> UInt64 {
        let micros = UInt64(now.timeIntervalSince1970 * 1_000_000)
        lastSentMicros = micros
        return micros
    }

    /// `true` when `micros` is the echo of a probe we sent (so it is a
    /// measurement), `false` when it is the peer's own probe (so it must be
    /// echoed back).
    public func isOwnEcho(_ micros: UInt64) -> Bool {
        micros == lastSentMicros
    }

    /// Round trip for an own echo, in whole milliseconds.
    public func roundTripMs(ofEcho micros: UInt64, now: Date) -> Int? {
        guard let sent = lastSentMicros, micros == sent else { return nil }
        let nowMicros = UInt64(now.timeIntervalSince1970 * 1_000_000)
        return Int((nowMicros &- sent) / 1_000)
    }

    public mutating func reset() {
        lastSentMicros = nil
    }
}
