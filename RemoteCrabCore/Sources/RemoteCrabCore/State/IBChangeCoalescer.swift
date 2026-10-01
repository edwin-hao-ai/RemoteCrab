import Foundation

/// Turns a burst of "something changed on this computer" signals into one
/// refresh, and delays it just long enough for the change to settle.
///
/// The window picker needed this because the workspace notifications that
/// mean "the app the user just opened has arrived" arrive as a *pair*:
/// `didLaunchApplication` when the process appears (usually before it has
/// a window) and `didActivateApplication` when it comes to the front (by
/// then it does). Refreshing on both cost two full window captures — a
/// JPEG per window — per launch, and refreshing on the first alone listed
/// an app with no card, which is the complaint that started this.
///
/// So: leading signal is deferred by `delay`, everything inside the window
/// is absorbed, and one refresh runs after the burst goes quiet. A signal
/// arriving after the window restarts the wait, so a slow launch still
/// lands.
public struct IBChangeCoalescer: Equatable, Sendable {

    /// Long enough to cover launch → activate, short enough that a card
    /// appears while the user is still looking at the sheet.
    public static let settleDelay: TimeInterval = 0.7

    public let delay: TimeInterval
    /// When the pending refresh is due, or `nil` with nothing pending.
    public private(set) var dueAt: Date?

    public init(delay: TimeInterval = IBChangeCoalescer.settleDelay) {
        self.delay = delay
        self.dueAt = nil
    }

    public var isPending: Bool { dueAt != nil }

    /// Record a signal. Returns whether the pending refresh moved.
    @discardableResult
    public mutating func signal(now: Date) -> Bool {
        let due = now.addingTimeInterval(delay)
        if dueAt == due { return false }
        dueAt = due
        return true
    }

    /// Whether a refresh is due — the caller performs it and calls
    /// `consume()` so the next signal starts a fresh window.
    public func isDue(now: Date) -> Bool {
        guard let dueAt else { return false }
        return now >= dueAt
    }

    public mutating func consume() { dueAt = nil }

    public mutating func cancel() { dueAt = nil }
}