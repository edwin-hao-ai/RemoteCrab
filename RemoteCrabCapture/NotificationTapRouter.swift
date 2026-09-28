import Foundation
import UserNotifications

/// Receives taps on a relayed notification's system banner and routes them to
/// the engine, so tapping behaves like a normal iOS notification: the app
/// opens and the Mac switches to the app (and window) that sent it.
///
/// **The delegate must be installed from
/// `application(_:didFinishLaunchingWithOptions:)`** — a tap that *launched*
/// the app is delivered to the delegate immediately after launch, so
/// installing it later (a view's `.task`, a `@StateObject` init) silently
/// drops that first tap. Same too-early/too-late trap as the camera
/// extension and Sparkle lessons.
///
/// The engine may not exist yet when a cold-launch tap arrives, so taps are
/// held until a handler is registered.
final class NotificationTapRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    static let shared = NotificationTapRouter()

    /// `userInfo` keys set by `LocalNotifier`.
    static let appKey = "remotecrab.app"
    static let windowTitleKey = "remotecrab.windowTitle"

    private let lock = NSLock()
    private var handler: ((String, String?) -> Void)?
    private var pending: [(String, String?)] = []

    private override init() { super.init() }

    /// Install as the notification-center delegate. Idempotent.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Registered by `CaptureEngine`. Any tap that arrived first is delivered
    /// immediately, in order.
    func setHandler(_ handler: @escaping (String, String?) -> Void) {
        lock.lock()
        self.handler = handler
        let queued = pending
        pending.removeAll()
        lock.unlock()
        for (app, window) in queued { handler(app, window) }
    }

    private func deliver(app: String, windowTitle: String?) {
        lock.lock()
        let handler = self.handler
        if handler == nil { pending.append((app, windowTitle)) }
        lock.unlock()
        handler?(app, windowTitle)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// A tapped banner (or an action on it).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let app = info[Self.appKey] as? String, !app.isEmpty else { return }
        let window = (info[Self.windowTitleKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        deliver(app: app, windowTitle: window)
    }

    /// Show the banner even while the app is frontmost. Without this iOS
    /// suppresses it (and the tap) whenever the user happens to be in
    /// RemoteCrab — which read as "the relay stopped working".
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
