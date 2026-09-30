import Foundation

/// How a pending command ends, and what the user is told.
///
/// Two decisions are encoded here, and both are deliberate:
///
/// 1. **Silence is not failure.** A receiver that predates `commandResult`
///    never answers, and the phone has no way to tell that apart from a
///    dropped frame. It says "too old to confirm" and *stops* — it does not
///    retry, because a retry is useless against a missing Accessibility
///    grant, a quit app or a vanished window (all three survive a second
///    attempt identically) and would only delay the same sentence by three
///    seconds.
/// 2. **The reason is named.** "Nothing happened" is what every one of these
///    used to look like from the phone.
public struct IBCommandOutcome: Equatable, Sendable {

    public enum State: Equatable, Sendable {
        /// The receiver confirmed.
        case ok
        /// The receiver answered with a specific reason.
        case failed(status: IBCommandResult.Status)
        /// No answer inside the window.
        case unconfirmed
    }

    /// How long to wait. Generous enough for a busy Mac, short enough that a
    /// genuine failure is not mistaken for a hang.
    public static let confirmTimeout: TimeInterval = 1.5

    public let requestId: String
    public let state: State
    /// What the user tapped, so `appNotRunning` can name it.
    public let appName: String

    public init(requestId: String, state: State, appName: String = "") {
        self.requestId = requestId
        self.state = state
        self.appName = appName
    }

    /// `true` when the receiver confirmed the command ran.
    public var succeeded: Bool { state == .ok }

    /// A phone-facing message, or `nil` when there is nothing to say (success
    /// is its own feedback — the screen visibly changes).
    public func message() -> String? {
        switch state {
        case .ok:
            return nil
        case .unconfirmed:
            return IBLocale.Command.unconfirmed
        case .failed(let status):
            switch status {
            case .ok:
                return nil
            case .appNotRunning:
                // The app's own display name, which the user just tapped.
                return IBLocale.Command.appNotRunning(appName)
            case .noPermission:
                return IBLocale.Command.noPermission
            case .noWindow:
                return IBLocale.Command.noWindow
            case .failed:
                return IBLocale.Command.refused
            }
        }
    }
}

/// Tracks commands awaiting a `commandResult`.
public struct IBCommandLedger: Equatable, Sendable {

    private var pending: [String: Date] = [:]
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = IBCommandOutcome.confirmTimeout) {
        self.timeout = timeout
    }

    public var pendingCount: Int { pending.count }

    public mutating func open(_ requestId: String, now: Date) {
        pending[requestId] = now
    }

    /// Resolve a request. `nil` for an id we never opened, which is the
    /// normal case for a duplicate or late reply — and must not crash.
    @discardableResult
    public mutating func resolve(_ requestId: String) -> IBCommandOutcome? {
        guard pending.removeValue(forKey: requestId) != nil else { return nil }
        return IBCommandOutcome(requestId: requestId, state: .ok)
    }

    /// Drop everything still unconfirmed. Returns one outcome per expired
    /// request so the caller can raise a hint for each.
    public mutating func expire(_ now: Date) -> [IBCommandOutcome] {
        let stale = pending.filter { now.timeIntervalSince($0.value) > timeout }
        for id in stale.keys { pending.removeValue(forKey: id) }
        return stale.keys.sorted().map {
            IBCommandOutcome(requestId: $0, state: .unconfirmed)
        }
    }

    public mutating func clear() { pending.removeAll() }
}
