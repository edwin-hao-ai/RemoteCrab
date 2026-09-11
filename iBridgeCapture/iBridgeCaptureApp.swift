import SwiftUI

@main
struct iBridgeCaptureApp: App {
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
            }
        }
    }
}