import AppKit
import AVFoundation
import Combine
import SwiftUI
import RemoteCrabCore

/// Mac-side preferences window. Opened from the menu bar dropdown
/// → "Preferences…" (⌘,). Uses Apple's `Settings { … }` scene container
/// so the window is consistent with the system preferences aesthetic.
///
/// All controls are wired to `ReceiverSession` settings so changes
/// take effect immediately (without requiring a restart).
struct PreferencesView: View {
    @EnvironmentObject private var session: ReceiverSession
    @EnvironmentObject private var sysexManager: SystemExtensionManager
    @EnvironmentObject private var setupStatus: SetupStatus
    @Environment(\.openWindow) private var openWindow
    @AppStorage("remotecrab.resolution")     private var resolution: String = "1080p"
    @AppStorage("remotecrab.frameRate")       private var frameRate: Int = 30
    @AppStorage("remotecrab.audioQuality")    private var audioQuality: String = "Standard (48 kHz)"
    @AppStorage("remotecrab.cameraPosition")  private var cameraPosition: String = "Back"
    @AppStorage("remotecrab.launchAtLogin")   private var launchAtLogin: Bool = false
    @AppStorage("remotecrab.autoReconnect")   private var autoReconnect: Bool = true
    @AppStorage("remotecrab.didFirstLaunch")  private var didFirstLaunch: Bool = false

    /// Local mirrors so this window reflects a permission the user
    /// granted while it was already open (SetupStatus only polls while
    /// the setup assistant is on screen).
    @State private var hasAccessibility: Bool = AXIsProcessTrusted()
    @State private var micDriverInstalled = false
    @State private var showMicPkgMissing = false

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
        .onAppear {
            hasAccessibility = AXIsProcessTrusted()
            refreshMicDriverState()
        }
        .alert(IBLocale.MicDriver.install, isPresented: $showMicPkgMissing) {
            Button(IBLocale.Settings.done, role: .cancel) {}
        } message: {
            Text("The installer package isn't bundled in this build. Build it with scripts/build-mic-driver-pkg.sh and embed it for distribution.")
        }
    }

    /// Is the HAL device present? (More reliable than checking the file
    /// path, which the sandbox may hide.) Detection itself lives in
    /// SetupStatus.swift so the setup assistant shares the same query.
    private func refreshMicDriverState() {
        micDriverInstalled = halMicDriverInstalled()
    }

    /// One-click install: open the signed pkg shipped inside the app.
    private func installMicDriver() {
        if let pkg = Bundle.main.url(forResource: "RemoteCrabMicrophone", withExtension: "pkg") {
            NSWorkspace.shared.open(pkg)
        } else {
            showMicPkgMissing = true
        }
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
                .accessibilityLabel(Text(verbatim: IBLocale.A11y.cameraPosition))
                .accessibilityHint(Text(verbatim: IBLocale.A11y.cameraPositionHint))

                Toggle(IBLocale.Settings.openAtLogin, isOn: $launchAtLogin)
                    .accessibilityHint(IBLocale.Settings.launchAtLoginDescription)

                Toggle("Auto-reconnect on connection loss", isOn: $autoReconnect)
            } header: {
                Text(IBLocale.Settings.general)
            }

            Section {
                if session.pairedPhones.isEmpty {
                    Text(IBLocale.Connection.noPairedPhones)
                        .font(IBFont.bodySmall)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.pairedPhones, id: \.self) { name in
                        HStack {
                            Image(systemName: "iphone.gen3")
                                .foregroundStyle(.secondary)
                            Text(name)
                                .font(IBFont.bodySmall)
                            Spacer()
                            if session.state.phoneName == name {
                                Button(IBLocale.Connection.disconnect) {
                                    session.disconnect()
                                }
                                .controlSize(.small)
                            }
                            Button(IBLocale.Connection.forget) {
                                session.forgetPhone(named: name)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text(IBLocale.Connection.pairedPhones)
            } footer: {
                Text(IBLocale.Connection.pairedPhonesFooter)
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Image(systemName: micDriverInstalled
                          ? "checkmark.circle.fill"
                          : "circle.dashed")
                        .foregroundStyle(micDriverInstalled ? IBColor.success : IBColor.textTertiary)
                    Text(micDriverInstalled ? IBLocale.MicDriver.installed : IBLocale.MicDriver.notInstalled)
                        .font(IBFont.bodySmall)
                    Spacer()
                    if !micDriverInstalled {
                        Button(IBLocale.MicDriver.install) { installMicDriver() }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text(IBLocale.MicDriver.title)
            } footer: {
                Text(IBLocale.MicDriver.footer)
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
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

                Button(IBLocale.Setup.reopenWizard) {
                    // Reset the flag so the root window shows the setup
                    // assistant (which re-detects everything) again.
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
                    Button(IBLocale.Settings.reRegister) {
                        sysexManager.repair()
                    }
                    .controlSize(.small)
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
                Text("Lets other apps use your iPhone as a webcam. Runs from /Applications only. Re-register after moving or updating the app.")
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
                .accessibilityLabel(Text(verbatim: IBLocale.A11y.streamingResolution))
                .accessibilityHint(Text(verbatim: IBLocale.A11y.streamingResolutionHint))

                Picker("Frame rate", selection: $frameRate) {
                    ForEach(IBLocale.Settings.FrameRate.allCases) { fps in
                        Text(fps.localizedLabel).tag(fps.rawValue)
                    }
                }
                .accessibilityLabel(Text(verbatim: IBLocale.A11y.streamingFrameRate))

                Picker("Audio quality", selection: $audioQuality) {
                    ForEach(IBLocale.Settings.AudioQuality.allCases) { q in
                        Text(q.localizedLabel).tag(q.rawValue)
                    }
                }
                .accessibilityLabel(Text(verbatim: IBLocale.A11y.micAudioQuality))
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
        case .unknown:          return IBLocale.Settings.sysexNotInstalled
        case .notInstalled:     return IBLocale.Settings.sysexNotInstalled
        case .awaitingApproval: return IBLocale.Settings.sysexAwaitingApproval
        case .active:           return IBLocale.Settings.sysexActive
        case .repairing:        return IBLocale.Settings.sysexRepairing
        case .failed:           return IBLocale.Settings.sysexFailed
        }
    }

    private var sysexStatusIcon: String {
        switch sysexManager.activationState {
        case .unknown:          return "circle"
        case .notInstalled:     return "circle"
        case .awaitingApproval: return "clock.badge.exclamationmark"
        case .active:           return "checkmark.circle.fill"
        case .repairing:        return "arrow.triangle.2.circlepath"
        case .failed:           return "exclamationmark.triangle.fill"
        }
    }

    private var sysexStatusColor: Color {
        switch sysexManager.activationState {
        case .unknown:          return .secondary
        case .notInstalled:     return .secondary
        case .awaitingApproval: return IBColor.warning
        case .active:           return IBColor.success
        case .repairing:        return IBColor.accent
        case .failed:           return IBColor.error
        }
    }

    private func openAccessibilitySettings() {
        SetupStatus.openAccessibilitySettings()
    }

    private func openExtensionSettings() {
        SetupStatus.openExtensionSettings()
    }
}
