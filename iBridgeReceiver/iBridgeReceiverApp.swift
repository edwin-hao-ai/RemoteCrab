import SwiftUI
import ApplicationServices
import iBridgeCore

@main
struct iBridgeReceiverApp: App {

    @AppStorage("ibridge.didFirstLaunch") private var didFirstLaunch: Bool = false
    @StateObject private var session = ReceiverSession()

    /// Kept alive for the whole app lifetime: OSSystemExtensionRequest's
    /// delegate is weak, so a local manager would deallocate before the
    /// activation callbacks fire. Also published into the environment so
    /// Preferences can show the camera extension's activation state.
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
        // Prompt for Accessibility only as part of the first-launch
        // flow (so the app appears in the user's Accessibility list).
        // On later launches FirstLaunchView / Preferences check with
        // AXIsProcessTrusted() without re-prompting.
        if !UserDefaults.standard.bool(forKey: "ibridge.didFirstLaunch") {
            let opts: NSDictionary = [
                "AXTrustedCheckOptionPrompt" as NSString: kCFBooleanTrue
            ]
            _ = AXIsProcessTrustedWithOptions(opts)
        }

        // Auto-activate the embedded CMIO camera extension once; after
        // that the user controls it from Preferences → Camera Extension.
        // Requires running from /Applications; the user may need to
        // approve in System Settings → General → Login Items &
        // Extensions → Camera Extensions.
        if !UserDefaults.standard.bool(forKey: "ibridge.sysexAutoActivated") {
            UserDefaults.standard.set(true, forKey: "ibridge.sysexAutoActivated")
            sysexManager.activate()
        }
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
        .keyboardShortcut(KeyboardShortcut("p", modifiers: [.command, .shift]))

        // Floating control panel. The 380×620 size is the single source
        // of truth — ControlPanelView fills whatever it is given.
        Window("iBridge Control Panel", id: "controls") {
            ControlPanelView()
                .environmentObject(session)
                .frame(width: 380, height: 620)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.bottomTrailing)
        .windowStyle(.hiddenTitleBar)
        .keyboardShortcut(KeyboardShortcut("p"))

        // Connection test window — four-quadrant live verification
        // of camera / keyboard / trackpad / mic channels.
        Window("Connection Test", id: "test") {
            TestWindowView()
                .environmentObject(session)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 640)
        .defaultPosition(.center)
        .keyboardShortcut(KeyboardShortcut("t"))

        // Standard macOS Settings scene (⌘,) — General / Streaming / About
        Settings {
            PreferencesView()
                .environmentObject(session)
                .environmentObject(sysexManager)
        }

        // Menu bar popover. The 320pt width is single-sourced inside
        // MenuBarMenu itself.
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(session)
        } label: {
            // SF Symbol renders as a proper menu bar template image
            // (visible in light + dark). A custom Canvas label renders
            // as a solid blob — do not bring it back here.
            // No session.start() here — ReceiverSession.init already
            // starts Bonjour browsing, and start() is idempotent.
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu bar icon mirrors the connection state so status is
    /// glanceable without opening the popover: radiowaves while live,
    /// an antenna while looking/connecting, a plain iPhone when the
    /// connection dropped. Plain SF Symbols only — template rendering
    /// keeps them legible in light and dark menu bars.
    private var menuBarSymbol: String {
        switch session.state {
        case .streaming:            return "iphone.gen3.radiowaves.left.and.right"
        case .searching, .connecting: return "antenna.radiowaves.left.and.right"
        case .error:                return "iphone.gen3"
        }
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
            IBGradient.brand
        }
    }
}