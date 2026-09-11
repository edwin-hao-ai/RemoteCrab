import SwiftUI

@main
struct iBridgeCaptureApp: App {
    @StateObject private var engine = CaptureEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
            // No app-wide status-bar hide: the trackpad and full-screen
            // camera surfaces hide system overlays themselves; elsewhere
            // time/battery stay visible during long sessions.
        }
    }
}