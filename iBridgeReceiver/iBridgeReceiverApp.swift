import SwiftUI
import ApplicationServices
import AppKit
import iBridgeCore

/// Runs the camera-extension registration once AppKit has finished
/// launching. Submitting an `OSSystemExtensionRequest` from `App.init()`
/// is too early — the app's connection to `sysextd` isn't up yet, so the
/// request is silently dropped.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the embedded CMIO camera extension's system registration
        // in sync with this app. The system records the host's origin
        // path at activation time, so renaming/moving the app (or
        // rebuilding the extension) silently orphans the record — it
        // stays "enabled" but never launches.
        let env = ProcessInfo.processInfo.environment
        if env["IBRIDGE_SYSEX_REPAIR"] == "1" {
            SystemExtensionManager.shared.repair()
        } else if env["IBRIDGE_SYSEX_ACTIVATE"] == "1" {
            SystemExtensionManager.shared.activate()
        } else {
            SystemExtensionManager.shared.ensureRegistered()
        }
    }
}

@main
struct iBridgeReceiverApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("ibridge.didFirstLaunch") private var didFirstLaunch: Bool = false
    @StateObject private var session = ReceiverSession()

    /// Shared setup-state detection (Accessibility / camera device /
    /// mic driver). Read by the setup assistant, the menu bar
    /// "Finish Setup…" row, and Preferences.
    @StateObject private var setupStatus = SetupStatus()

    /// Kept alive for the whole app lifetime: OSSystemExtensionRequest's
    /// delegate is weak, so a local manager would deallocate before the
    /// activation callbacks fire. Also published into the environment so
    /// Preferences can show the camera extension's activation state.
    private let sysexManager = SystemExtensionManager.shared

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
        // On later launches the setup assistant / Preferences check
        // with AXIsProcessTrusted() without re-prompting.
        if !UserDefaults.standard.bool(forKey: "ibridge.didFirstLaunch") {
            let opts: NSDictionary = [
                "AXTrustedCheckOptionPrompt" as NSString: kCFBooleanTrue
            ]
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }

    var body: some Scene {
        // First-launch setup assistant / minimal "running" view.
        Window("Familiar", id: "root") {
            if didFirstLaunch {
                MainWindowView()
                    .environmentObject(session)
                    .environmentObject(sysexManager)
            } else {
                SetupAssistantView(didComplete: $didFirstLaunch)
                    .environmentObject(session)
                    .environmentObject(sysexManager)
                    .environmentObject(setupStatus)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 600)
        .defaultPosition(.center)

        // Preview window.
        Window("Familiar Preview", id: "preview") {
            PreviewWindow()
                .environmentObject(session)
                .frame(minWidth: 640, minHeight: 400)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 800, height: 600)
        .keyboardShortcut(KeyboardShortcut("p", modifiers: [.command, .shift]))

        // Floating control panel. The 380×620 size is the single source
        // of truth — ControlPanelView fills whatever it is given.
        Window("Familiar Control Panel", id: "controls") {
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
                .environmentObject(setupStatus)
        }

        // Menu bar popover. The 320pt width is single-sourced inside
        // MenuBarMenu itself.
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(session)
                .environmentObject(setupStatus)
        } label: {
            // The app's "monitor buddy" logo, shipped as a monochrome
            // TEMPLATE image asset so macOS tints it for light/dark menu
            // bars (a custom Canvas label renders as a blob — don't).
            // Recording swaps to a filled record dot so "am I recording?"
            // is still answerable at a glance.
            // No session.start() here — ReceiverSession.init already
            // starts Bonjour browsing, and start() is idempotent.
            if session.isRecording {
                Image(systemName: "record.circle.fill")
            } else {
                Image("MenuBarIcon")
                    .renderingMode(.template)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Minimal "iBridge is running" view shown in the root window after
/// the first-launch flow completes. Most of the actual UI lives in
/// the menu bar popover and the control panel window.
private struct MainWindowView: View {
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Familiar is running")
                    .font(IBFont.titleMedium)
                    .foregroundStyle(.white)
                Text("Open the control panel from the menu bar icon.")
                    .font(IBFont.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 32)
            .background {
                IBGradient.brand
            }

            CameraExtensionCard()
                .padding(16)
        }
        .frame(width: 460)
        .background(IBColor.canvas)
    }
}