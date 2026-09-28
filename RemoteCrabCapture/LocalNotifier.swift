import Foundation
import RemoteCrabCore
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` for notifications relayed
/// from the Mac. The in-app `NotificationStore` is always updated; this only
/// adds the system banner so it is visible in the background / on the lock
/// screen.
/// Stateless wrapper (each call goes through `UNUserNotificationCenter.current()`),
/// so it is safe to pass across isolation boundaries.
final class LocalNotifier: @unchecked Sendable {
    /// Request (once) permission to show alerts. Idempotent: after the user
    /// has answered, this returns the stored decision without prompting.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    /// Post one notification immediately. Silently dropped when the user
    /// has not granted permission (the in-app list still shows it).
    func post(_ n: IBNotification) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            default:
                Forensic.log("[notify] system banner skipped (notifications not authorized)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = n.app
            content.body = [n.title, n.subtitle, n.body]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            content.sound = .default
            // Carried so a tap can switch the Mac to that app (and window):
            // the banner itself is not routable.
            content.userInfo = [NotificationTapRouter.appKey: n.app,
                                NotificationTapRouter.windowTitleKey: n.windowTitle ?? ""]
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
            center.add(request) { error in
                Forensic.log("[notify] system banner \(error == nil ? "posted" : "failed: \(error!.localizedDescription)")")
            }
        }
    }
}
