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
    ///
    /// **Must NOT be declared `async`, and must not touch the
    /// `UNNotification*` objects off the main thread.** Two separate traps,
    /// both of which abort the app (an ObjC `NSException` is uncatchable in
    /// Swift), and only on a *tap* — `willPresent` never dereferences its
    /// argument, which is why receiving a banner always looked fine:
    ///
    /// 1. `UNUserNotificationCenter` delivers its callbacks on a background
    ///    thread (measured: `willPresent` runs with `pthread_main_np() == 0`),
    ///    and the notification object graph is main-thread-only.
    /// 2. Declaring the method `async` makes it *worse*: the Swift runtime
    ///    bridges it through `_runTaskForBridgedAsyncMethod`, which runs the
    ///    body on a cooperative-pool thread **and finishes the bridge there
    ///    too**. That trailing step is where
    ///    `NSInternalInconsistencyException: Call must be made on main
    ///    thread` came from — instrumenting every line of the body showed it
    ///    completing successfully first, then aborting.
    ///
    /// So: the completion-handler form (no Swift bridging) plus an explicit
    /// main-actor hop for the object read, and `completionHandler()` on the
    /// main actor, which is where the framework requires it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completionHandler: @escaping () -> Void) {
        let box = UncheckedBox(response)
        let done = UncheckedBox(completionHandler)
        Task { @MainActor in
            Forensic.log("[notify] banner tapped (delegate path)")
            let info = box.value.notification.request.content.userInfo
            if let app = info[Self.appKey] as? String, !app.isEmpty {
                let window = (info[Self.windowTitleKey] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
                deliver(app: app, windowTitle: window)
            }
            done.value()
        }
    }

    /// Show the banner even while the app is frontmost. Without this iOS
    /// suppresses it (and the tap) whenever the user happens to be in
    /// RemoteCrab — which read as "the relay stopped working".
    ///
    /// Completion-handler form for the same reason as `didReceive`: never
    /// declare a `UNUserNotificationCenterDelegate` method `async`. The
    /// framework requires the handler on the main thread, and the callback
    /// arrives off it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        let done = UncheckedBox(completionHandler)
        Task { @MainActor in
            done.value([.banner, .list, .sound])
        }
    }
}

/// Carries a non-`Sendable` value across an isolation boundary, for the one
/// case where the transfer is safe by construction: the enclosing method
/// keeps the only strong reference alive in its local `let`, the `Task`
/// closure captures that same local, and the receiving isolation (the main
/// actor) is the one the value requires anyway. Without it, Swift 6 rejects
/// passing `UNNotificationResponse` / the completion handler into
/// `Task { @MainActor }`.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
