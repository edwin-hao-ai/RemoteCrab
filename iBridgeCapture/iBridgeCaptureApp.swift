import SwiftUI

@main
struct iBridgeCaptureApp: App {
    @StateObject private var engine = CaptureEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .task { await engine.startIfNeeded() }
        }
    }
}