import SwiftUI
import ApplicationServices
import iBridgeCore

@main
struct iBridgeReceiverApp: App {

    @AppStorage("ibridge.didFirstLaunch") private var didFirstLaunch: Bool = false
    @StateObject private var session = ReceiverSession()

    /// Kept alive for the whole app lifetime: OSSystemExtensionRequest's
    /// delegate is weak, so a local manager would deallocate before the
    /// activation callbacks fire.
    private let sysexManager = SystemExtensionManager()

    /// The single shared audio unit instance. Used by:
    ///   • `AudioReceiver` (which feeds it iPhone mic samples)
    ///   • `iBridgeAUInstanceProvider` (which the system extension
    ///     uses to vend the same instance into its own AUv3 instance)
    @State private var audioUnit: iBridgeAudioUnit? = {
        let unit = iBridgeAudioUnit()
        iBridgeAUInstanceProvider.makeInstance = unit
        return unit
    }()

    init() {
        // Trigger the system permission dialog for Accessibility so
        // iBridgeReceiver shows up in the user's Accessibility list.
        let opts: NSDictionary = [
            "AXTrustedCheckOptionPrompt" as NSString: kCFBooleanTrue
        ]
        _ = AXIsProcessTrustedWithOptions(opts)

        // Register the embedded CMIO camera extension with macOS.
        // Requires running from /Applications; the user may need to
        // approve in System Settings → General → Login Items &
        // Extensions → Camera Extensions.
        sysexManager.activate()
    }

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

        // Standard macOS Settings scene (⌘,) — General / Streaming / About
        Settings {
            PreferencesView()
                .environmentObject(session)
        }

        // Menu bar popover.
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(session)
                .frame(width: 320)
        } label: {
            // SF Symbol renders as a proper menu bar template image
            // (visible in light + dark). A custom Canvas label renders
            // as a solid blob — do not bring it back here.
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .onAppear { session.start() }
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