import SwiftUI

@main
struct iBridgeCaptureApp: App {
    @StateObject private var engine = CaptureEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}