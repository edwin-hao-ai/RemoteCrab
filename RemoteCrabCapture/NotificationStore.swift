import Foundation
import Observation
import RemoteCrabCore

/// In-app inbox for notifications relayed from the Mac.
///
/// Newest first, capped at 100 so a long session can't grow unbounded.
/// The wire payload carries no id or timestamp, so each entry gets a
/// phone-side `UUID` (stable SwiftUI identity — a prepend must not reuse
/// another row's identity) and a receipt time.
/// `@Observable` so SwiftUI tracks the reads directly, even though the
/// engine that owns it is an `ObservableObject`.
@Observable
final class NotificationStore {
    /// One relayed notification plus the phone-side metadata the wire
    /// frame omits.
    struct Entry: Identifiable {
        let id: UUID
        let notification: IBNotification
        let receivedAt: Date
    }

    private(set) var entries: [Entry] = []
    private(set) var unread: Int = 0

    private let cap = 100

    /// Prepend a freshly received notification and bump the unread count.
    func append(_ n: IBNotification) {
        entries.insert(Entry(id: UUID(), notification: n, receivedAt: Date()), at: 0)
        if entries.count > cap {
            entries.removeSubrange(cap...)
        }
        // Cap unread the same as the list: the badge must never exceed
        // the number of rows the user can actually see.
        unread = min(unread + 1, cap)
    }

    /// Called when the inbox is opened — the user has now seen everything.
    func markAllRead() {
        unread = 0
    }

    /// Empty the inbox.
    func clear() {
        entries.removeAll()
        unread = 0
    }
}
