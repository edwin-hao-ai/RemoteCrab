import Foundation
import os
import RemoteCrabCore
import UserNotifications

/// Posts the one desktop notification this app raises: *"the iPhone is waiting
/// for you to tap Allow."*
///
/// Deliberately tiny and deliberately not a general notification layer. Two
/// constraints shape it:
///
/// * **One identifier, reused.** `UNUserNotificationCenter` *replaces* a
///   delivered notification that has the same identifier, so the reconnect
///   loop cannot build a pile the user clears instead of acting on. The
///   identifier and the decision to post both live in
///   `ApprovalNotificationPolicy`, so the "why once" is testable without a
///   notification centre.
/// * **Never blocks and never throws.** `add` is asynchronous and the centre
///   can refuse (unauthorised, notifications off). A missing alert is a small
///   annoyance; crashing the receiver because it could not post one is not a
///   trade worth making, so every failure is logged at info and swallowed.
enum ApprovalNotifier {

    /// `UNUserNotificationCenter` is not `Sendable`, so a stored static is a
    /// Swift 6 concurrency error. Computing it per call sidesteps that without
    /// an `unsafe` annotation: the centre is a process-wide singleton the
    /// framework hands back, and this type has no state of its own to protect.
    private static var center: UNUserNotificationCenter { .current() }

    /// Ask once, lazily. Requesting authorisation is cheap after the first
    /// call, and prompting on every launch would be noise.
    static func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        Self.log.info("notification authorization failed: \(error.localizedDescription)")
                    } else {
                        Self.log.info("notification authorization granted: \(granted)")
                    }
                }
            case .denied:
                // Nothing to do, and nothing worth interrupting the user about:
                // the menu-bar row already says what is happening.
                Self.log.info("notifications denied — the awaiting-approval alert will not appear")
            default:
                break
            }
        }
    }

    /// Post the alert. `body` is already localized by the caller, which knows
    /// which phone is involved.
    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // No sound: the receiver is usually in the user's peripheral vision
        // already, and a sound on every reconnect attempt is how a notification
        // gets muted within a day.
        center.add(UNNotificationRequest(
            identifier: ApprovalNotificationPolicy.identifier,
            content: content,
            trigger: nil)) { error in
            if let error {
                Self.log.info("could not post the approval notification: \(error.localizedDescription)")
            }
        }
    }

    /// Dismiss it once the wait resolves, so a resolved problem does not leave
    /// an alert behind.
    static func clear() {
        center.removeDeliveredNotifications(
            withIdentifiers: [ApprovalNotificationPolicy.identifier])
    }

    private static let log = Logger(subsystem: "com.remotecrab", category: "approval-notifier")
}