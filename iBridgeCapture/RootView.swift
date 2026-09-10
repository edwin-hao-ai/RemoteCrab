import SwiftUI
import iBridgeCore

/// Top-level root that decides between:
///   • OnboardingFlow  (first launch only)
///   • PermissionFlow   (right after onboarding completes)
///   • ContentView      (main app, only after permissions are handled)
///
/// Persists "has seen onboarding" with @AppStorage so users only see
/// it once.
struct RootView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @AppStorage("ibridge.didOnboard") private var didOnboard: Bool = false
    @State private var stage: Stage = .onboarding

    enum Stage {
        case onboarding
        case permissions
        case main
    }

    var body: some View {
        Group {
            switch stage {
            case .onboarding:
                OnboardingFlow(hasSeenOnboarding: $didOnboard)
                    .onChange(of: didOnboard) { _, on in
                        if on { advance(to: .permissions) }
                    }
            case .permissions:
                PermissionFlow(onComplete: { didOnboard = true; advance(to: .main) })
            case .main:
                ContentView()
            }
        }
        .onAppear {
            // If the user previously completed onboarding, skip straight
            // to the main UI. Otherwise, show the onboarding hero.
            // Auto-start: when IBRIDGE_AUTO_START=1 is set in the env
            // (e.g. via xcrun simctl launch --setenv or Xcode scheme),
            // skip onboarding + permissions and go straight to main.
            if didOnboard ||
                ProcessInfo.processInfo.environment["IBRIDGE_AUTO_START"] == "1" {
                stage = .main
            } else {
                stage = .onboarding
            }
        }
    }

    private func advance(to next: Stage) {
        withAnimation(IBAnimation.gentle) {
            stage = next
        }
    }
}
