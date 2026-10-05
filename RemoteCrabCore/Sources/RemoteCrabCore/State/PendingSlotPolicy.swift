import Foundation

/// The rules for the "waiting for approval" slot on the phone.
///
/// The slot exists so a computer that has never been paired can ask the user
/// once. It is also the easiest way to lock the phone out of every computer,
/// because a slot that outlives its connection answers `busy` to all of them
/// and names a machine that is no longer running. Two independent rules keep
/// that from happening, and neither is enforced by the compiler alone:
///
/// - **Identity**: only the connection that is actually dying may release the
///   slot, compared *before* anything is cleared. Clearing first and comparing
///   after leaves the comparison asking "is `nil` the slot holder?", which is
///   never true — so the cleanup silently never runs.
/// - **Timeout**: `NWConnection` does not deliver `.cancelled` on every exit
///   path, so identity alone is not enough. The slot expires like the owner's
///   silence does.
public enum PendingSlotPolicy {

    /// Seconds a connection may hold the approval slot before the phone
    /// releases it.
    ///
    /// Long enough that a person who put the phone down and came back is not
    /// raced, and far below the ten minutes a stale preference once refused
    /// every computer for.
    public static let timeout: TimeInterval = 120

    /// Whether a request that has been waiting `waited` seconds is stale.
    ///
    /// `>=` and not `>`: the timeout is the instant the slot is released, and
    /// the alternative is a request that survives one tick past its own limit.
    public static func isExpired(waited: TimeInterval,
                                 timeout: TimeInterval = PendingSlotPolicy.timeout) -> Bool {
        waited >= timeout
    }

    /// Whether the connection that just went away is the one holding the slot.
    ///
    /// Generic over the identity so the caller passes whatever it already has
    /// (`ObjectIdentifier` for a live connection) instead of this type
    /// inventing a token scheme. Both arguments are read by the caller *before*
    /// it clears anything — that call order is the bug this function documents.
    public static func isHeld<T: Hashable>(byDying dying: T?, pending: T?) -> Bool {
        guard let dying, let pending else { return false }
        return dying == pending
    }
}
