import SwiftUI
import UIKit
import UserNotifications

/// Exists so the notification-tap delegate is installed before the system
/// delivers a tap that *launched* the app (see `NotificationTapRouter`).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationTapRouter.shared.install()
        return true
    }
}

@main
struct RemoteCrabCaptureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = CaptureEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
            // No app-wide status-bar hide: the trackpad and full-screen
            // camera surfaces hide system overlays themselves; elsewhere
            // time/battery stay visible during long sessions.
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                engine.handleDidBecomeActive()
            } else if phase == .inactive {
                engine.handleDidBecomeInactive()
            }
        }
    }
}