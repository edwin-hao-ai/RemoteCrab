import Foundation

/// Whether entering this state should raise a desktop notification.
///
/// Extracted from the receiver because "should we notify" is a product
/// decision and the state machine is where it is easiest to get wrong: the
/// same state is entered on every reconnect, so a naive notification fires
/// every few seconds while the phone is unreachable.
///
/// ## Why a notification at all
///
/// The phone shows an approval card and the Mac shows a menu-bar row. Both
/// are invisible if you are looking at the phone rather than the Mac, and the
/// phone is a small screen you may not be holding. The run then sits in
/// `awaitingApproval` until something times out, and the visible symptom is
/// "it didn't connect" with no indication that a tap was the missing step.
///
/// So: notify **once per entry into the waiting state**, never while already
/// waiting, and never for a state the user did not have to act on.
public enum ApprovalNotificationPolicy {

    /// The notification's identity. Reusing one identifier replaces the
    /// delivered notification instead of stacking, so repeated entries cannot
    /// build a pile.
    public static let identifier = "com.remotecrab.awaiting-approval"

    /// Whether to notify on a transition from `previous` to `next`.
    ///
    /// - Parameters:
    ///   - isFirstEntryThisSession: false once the user has already approved a
    ///     computer in this run. Approvals are rare and deliberate; being asked
    ///     again for the same machine later is not news.
    ///   - alreadyNotifiedForThisWait: guards the reconnect loop, which re-enters
    ///     the same state every few seconds.
    public static func shouldNotify(previous: ReceiverStateKind,
                                    next: ReceiverStateKind,
                                    isFirstEntryThisSession: Bool,
                                    alreadyNotifiedForThisWait: Bool) -> Bool {
        // Only on entry. Staying in the waiting state is not news.
        guard next == .awaitingApproval, previous != .awaitingApproval else { return false }
        // One per run is the point: the user has demonstrably seen the screen.
        guard isFirstEntryThisSession else { return false }
        // Belt and braces against the reconnect loop re-entering.
        guard !alreadyNotifiedForThisWait else { return false }
        return true
    }

    /// Reset when the wait resolves, so the *next* distinct wait can notify.
    public static func shouldResetAfterExit(previous: ReceiverStateKind,
                                            next: ReceiverStateKind) -> Bool {
        previous == .awaitingApproval && next != .awaitingApproval
    }
}

/// A mirror of `ReceiverSession.State`, so the policy is testable without the
/// app target. Deliberately not the receiver's own enum: `ReceiverSession` is
/// macOS-only and cannot be imported from the package, and this is the
/// project's usual answer — the decision goes in Core, the wiring stays put.
///
/// Kept in sync by `ReceiverSession`'s mapping; a new case there must be added
/// here or the switch will not compile, which is the intended alarm.
public enum ReceiverStateKind: Equatable, Sendable {
    case searching
    case connecting
    case handshaking
    case awaitingApproval
    case streaming
    case error
}