import Foundation
import Observation
import RemoteCrabCore

/// In-app inbox for notifications relayed from the Mac.
///
/// Newest first, capped at 100 so a long session can't grow unbounded.
/// `receivedAt` is maintained in parallel with `items` (the wire payload
/// carries no timestamp — the list shows when the phone received it).
/// `@Observable` so SwiftUI tracks the reads directly, even though the
/// engine that owns it is an `ObservableObject`.
@Observable
final class NotificationStore {
    private(set) var items: [IBNotification] = []
    private(set) var receivedAt: [Date] = []
    private(set) var unread: Int = 0

    private let cap = 100

    /// Prepend a freshly received notification and bump the unread count.
    func append(_ n: IBNotification) {
        items.insert(n, at: 0)
        receivedAt.insert(Date(), at: 0)
        if items.count > cap {
            items.removeSubrange(cap...)
            receivedAt.removeSubrange(cap...)
        }
        unread += 1
    }

    /// Called when the inbox is opened — the user has now seen everything.
    func markAllRead() {
        unread = 0
    }

    /// Empty the inbox.
    func clear() {
        items.removeAll()
        receivedAt.removeAll()
        unread = 0
    }

    /// Receipt time for the item at `index`, defaulting to "now" if the
    /// parallel arrays are somehow out of step (they are always mutated
    /// together, so this is only defensive).
    func date(for index: Int) -> Date {
        receivedAt.indices.contains(index) ? receivedAt[index] : Date()
    }
}
