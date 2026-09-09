import SwiftUI
import iBridgeCore

@main
struct iBridgeReceiverApp: App {

    @AppStorage("ibridge.didFirstLaunch") private var didFirstLaunch: Bool = false
    @StateObject private var session = ReceiverSession()

    var body: some Scene {
        // First-launch / minimal "running" view.
        Window("iBridge", id: "root") {
            if didFirstLaunch {
                MainWindowView()
                    .environmentObject(session)
            } else {
                FirstLaunchView(didComplete: $didFirstLaunch)
                    .environmentObject(session)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 600)
        .defaultPosition(.center)

        // Preview window.
        Window("iBridge Preview", id: "preview") {
            PreviewWindow()
                .environmentObject(session)
                .frame(minWidth: 640, minHeight: 400)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 800, height: 600)

        // Floating control panel.
        Window("iBridge Control Panel", id: "controls") {
            ControlPanelView()
                .environmentObject(session)
                .frame(width: 380, height: 580)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)
        .windowStyle(.hiddenTitleBar)

        // Menu bar popover.
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(session)
                .frame(width: 320)
        } label: {
            MenuBarIcon()
                .environmentObject(session)
                .frame(width: 22, height: 18)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Minimal "iBridge is running" view shown in the root window after
/// the first-launch flow completes. Most of the actual UI lives in
/// the menu bar popover and the control panel window.
private struct MainWindowView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text("iBridge is running")
                .font(IBFont.titleMedium)
                .foregroundStyle(.white)
            Text("Open the control panel from the menu bar icon.")
                .font(IBFont.caption)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(width: 360, height: 220)
        .background {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.10, blue: 0.22),
                    Color(red: 0.20, green: 0.06, blue: 0.32)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}