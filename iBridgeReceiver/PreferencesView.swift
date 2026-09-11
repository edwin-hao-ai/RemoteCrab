import AppKit
import AVFoundation
import Combine
import SwiftUI
import iBridgeCore

/// Mac-side preferences window. Opened from the menu bar dropdown
/// → "Preferences…" (⌘,). Uses Apple's `Settings { … }` scene container
/// so the window is consistent with the system preferences aesthetic.
///
/// All controls are wired to `ReceiverSession` settings so changes
/// take effect immediately (without requiring a restart).
struct PreferencesView: View {
    @EnvironmentObject private var session: ReceiverSession
    @EnvironmentObject private var sysexManager: SystemExtensionManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ibridge.resolution")     private var resolution: String = "1080p"
    @AppStorage("ibridge.frameRate")       private var frameRate: Int = 30
    @AppStorage("ibridge.audioQuality")    private var audioQuality: String = "Standard (48 kHz)"
    @AppStorage("ibridge.cameraPosition")  private var cameraPosition: String = "Back"
    @AppStorage("ibridge.launchAtLogin")   private var launchAtLogin: Bool = false
    @AppStorage("ibridge.autoReconnect")   private var autoReconnect: Bool = true
    @AppStorage("ibridge.didFirstLaunch")  private var didFirstLaunch: Bool = false

    @State private var hasAccessibility: Bool = AXIsProcessTrusted()

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(IBLocale.Settings.general, systemImage: "gear") }

            streamingTab
                .tabItem { Label(IBLocale.Settings.streaming, systemImage: "antenna.radiowaves.left.and.right") }

            aboutTab
                .tabItem { Label(IBLocale.Settings.about, systemImage: "info.circle") }
        }
        .frame(width: 480, height: 380)
        .onAppear { hasAccessibility = AXIsProcessTrusted() }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Picker("Camera position", selection: $cameraPosition) {
                    ForEach(IBLocale.Settings.CameraPosition.allCases) { pos in
                        Text(pos.localizedLabel).tag(pos.rawValue)
                    }
                }
                .accessibilityLabel("Camera position")
                .accessibilityHint("Which iPhone camera to use as the live feed")

                Toggle(IBLocale.Settings.openAtLogin, isOn: $launchAtLogin)
                    .accessibilityHint(IBLocale.Settings.launchAtLoginDescription)

                Toggle("Auto-reconnect on connection loss", isOn: $autoReconnect)
            } header: {
                Text(IBLocale.Settings.general)
            }

            Section {
                HStack {
                    Image(systemName: hasAccessibility
                          ? "checkmark.shield.fill"
                          : "exclamationmark.shield.fill")
                        .foregroundStyle(hasAccessibility ? IBColor.success : IBColor.warning)
                    Text(hasAccessibility
                         ? IBLocale.Permission.accessibilityGranted
                         : IBLocale.Permission.accessibilityRequired)
                        .font(IBFont.bodySmall)
                    Spacer()
                    Button(IBLocale.Permission.openSystemSettings) {
                        openAccessibilitySettings()
                    }
                    .controlSize(.small)
                }

                Button(IBLocale.Settings.resetAccessibility) {
                    // Reset the flag so the root window shows the
                    // first-launch flow (which re-prompts) again.
                    didFirstLaunch = false
                    openWindow(id: "root")
                    NSApp.activate()
                }
                .controlSize(.small)
            } header: {
                Text(IBLocale.Settings.accessibility)
            }

            Section {
                HStack {
                    Image(systemName: sysexStatusIcon)
                        .foregroundStyle(sysexStatusColor)
                    Text(sysexStatusLabel)
                        .font(IBFont.bodySmall)
                    Spacer()
                    if case .awaitingApproval = sysexManager.activationState {
                        Button(IBLocale.Permission.openSystemSettings) {
                            openExtensionSettings()
                        }
                        .controlSize(.small)
                    }
                    Button(IBLocale.Settings.activate) {
                        sysexManager.activate()
                    }
                    .controlSize(.small)
                }
                if case .failed(let message) = sysexManager.activationState {
                    Text("\(IBLocale.Settings.sysexFailed): \(message)")
                        .font(IBFont.caption)
                        .foregroundStyle(IBColor.error)
                }
            } header: {
                Text(IBLocale.Settings.cameraExtension)
            } footer: {
                Text("Lets other apps use your iPhone as a webcam. Runs from /Applications only.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Streaming

    private var streamingTab: some View {
        Form {
            Section {
                Picker("Resolution", selection: $resolution) {
                    ForEach(IBLocale.Settings.Resolution.allCases) { r in
                        Text(r.localizedLabel).tag(r.rawValue)
                    }
                }
                .accessibilityLabel("Streaming resolution")
                .accessibilityHint("Higher resolutions use more WiFi bandwidth")

                Picker("Frame rate", selection: $frameRate) {
                    ForEach(IBLocale.Settings.FrameRate.allCases) { fps in
                        Text(fps.localizedLabel).tag(fps.rawValue)
                    }
                }
                .accessibilityLabel("Streaming frame rate")

                Picker("Audio quality", selection: $audioQuality) {
                    ForEach(IBLocale.Settings.AudioQuality.allCases) { q in
                        Text(q.localizedLabel).tag(q.rawValue)
                    }
                }
                .accessibilityLabel("Microphone audio quality")
            } header: {
                Text(IBLocale.Settings.streaming)
            } footer: {
                Text("These settings are sent to your iPhone on the next streaming session.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 96, height: 96)
                    .background {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    }

                VStack(spacing: 4) {
                    Text(IBLocale.App.name)
                        .font(IBFont.titleLarge)
                    Text(IBLocale.App.tagline)
                        .font(IBFont.caption)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    row(IBLocale.Settings.versionLabel,
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    row(IBLocale.Settings.buildLabel,
                        value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                    row(IBLocale.Settings.builtFor, value: "macOS 26+")
                }
                .frame(maxWidth: 320)
                .accessibilityElement(children: .combine)

                Text(IBLocale.Settings.copyrightLabel)
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(IBFont.bodySmall)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(IBFont.monoMedium)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Helpers

    private var sysexStatusLabel: String {
        switch sysexManager.activationState {
        case .notInstalled:     return IBLocale.Settings.sysexNotInstalled
        case .awaitingApproval: return IBLocale.Settings.sysexAwaitingApproval
        case .active:           return IBLocale.Settings.sysexActive
        case .failed:           return IBLocale.Settings.sysexFailed
        }
    }

    private var sysexStatusIcon: String {
        switch sysexManager.activationState {
        case .notInstalled:     return "circle"
        case .awaitingApproval: return "clock.badge.exclamationmark"
        case .active:           return "checkmark.circle.fill"
        case .failed:           return "exclamationmark.triangle.fill"
        }
    }

    private var sysexStatusColor: Color {
        switch sysexManager.activationState {
        case .notInstalled:     return .secondary
        case .awaitingApproval: return IBColor.warning
        case .active:           return IBColor.success
        case .failed:           return IBColor.error
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }
}
