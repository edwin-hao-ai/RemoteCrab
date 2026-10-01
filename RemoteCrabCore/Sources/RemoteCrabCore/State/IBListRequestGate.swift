import Foundation

/// Tracks one "send me your list" round trip to the receiver.
///
/// The launcher sheet used to decide the list was empty on a fixed 500 ms
/// `Task.sleep`, while the Mac needs ~2.4 s on a cold run to enumerate
/// `/Applications` and rasterise an icon per app (measured: 113 apps →
/// 2356 ms; a warm icon cache is 1 ms). So the sheet said "No apps listed
/// yet" while the real answer was still in flight and then popped the grid
/// in underneath the sentence. **Only the arrival of the `installedApps`
/// frame (0x21) may end a wait** — a timer cannot, because the receiver's
/// cost is the machine's, not ours.
///
/// Three outcomes are genuinely different, so they are three cases and not
/// a boolean:
///
/// - `awaiting` — the receiver is working on it; spinner.
/// - `answered` — the receiver really has nothing (`installedApps` empty).
/// - `unanswered` — nobody replied. The receiver only sends 0x21 in answer
///   to `installedAppsRequest` (0x20), so silence means a dead link or a
///   receiver too old to know the frame, which is a different sentence and
///   a different action than "this computer has no apps".
public struct IBListRequestGate: Equatable, Sendable {

    public enum Phase: Equatable, Sendable {
        case idle
        case awaiting
        case answered
        case unanswered
    }

    /// Generous next to the measured ~2.4 s cold round trip: a slow disk or
    /// a bigger `/Applications` must still land as a *list*, not as a
    /// failure. Past it the user is told the truth about why nothing came.
    public static let replyTimeout: TimeInterval = 8

    public let timeout: TimeInterval
    private var phase: Phase
    private var askedAt: Date?

    public init(timeout: TimeInterval = IBListRequestGate.replyTimeout) {
        self.timeout = timeout
        self.phase = .idle
    }

    public var current: Phase { phase }

    /// No wait is outstanding, so a repeating expiry tick can stop.
    public var isSettled: Bool { phase == .answered || phase == .unanswered }

    /// Ask, or re-ask. Re-arming from `answered` puts the gate back to
    /// `awaiting` so a refresh shows that something is in flight.
    public mutating func begin(now: Date) {
        phase = .awaiting
        askedAt = now
    }

    /// The receiver's list arrived. Accepted from `awaiting` **and**
    /// `unanswered`: a late answer is still the answer, so a slow receiver
    /// heals on its own instead of demanding a manual retry.
    public mutating func answer() {
        phase = .answered
        askedAt = nil
    }

    /// Flip to `unanswered` once the deadline passes. Returns whether it
    /// did, so the caller surfaces it exactly once. Never disturbs
    /// `answered` — a list that already arrived cannot be un-arrived.
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        guard case .awaiting = phase, let askedAt else { return false }
        guard now.timeIntervalSince(askedAt) >= timeout else { return false }
        phase = .unanswered
        self.askedAt = nil
        return true
    }

    /// Nothing is outstanding — the link went away before an answer.
    public mutating func reset() {
        phase = .idle
        askedAt = nil
    }
}