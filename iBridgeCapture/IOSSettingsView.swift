import AVFoundation
import SwiftUI
import UIKit
import iBridgeCore

/// iOS-side settings sheet, shown from the top-bar antenna icon.
/// Uses standard SwiftUI Form styling (iOS Settings aesthetic) with
/// grouped sections, footers, and the system color picker.
struct IOSSettingsView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ibridge.ios.resolution")    private var resolution: String = "1080p"
    @AppStorage("ibridge.ios.frameRate")    private var frameRate: Int = 30
    @AppStorage("ibridge.ios.trackpadSens")  private var trackpadSens: Int = 3
    @AppStorage("ibridge.ios.keepScreenOn") private var keepScreenOn: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                videoSection
                inputSection
                aboutSection
            }
            .navigationTitle(IBLocale.Settings.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IBLocale.Onboarding.nextBtn) { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            HStack {
                Text(connectionLabel)
                    .font(IBFont.bodyMedium)
                Spacer()
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(connectionLabel)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Connection")
        } footer: {
            Text("iBridge streams over your local WiFi using Bonjour. No data ever leaves your network.")
        }
    }

    private var connectionLabel: String {
        switch engine.connectionState {
        case .connected: return IBLocale.Status.live
        case .starting: return IBLocale.Status.connecting
        case .failed: return IBLocale.Status.offline
        case .idle: return "Idle"
        }
    }

    private var connectionColor: Color {
        switch engine.connectionState {
        case .connected: return .green
        case .failed: return .red
        default: return .gray
        }
    }

    private var videoSection: some View {
        Section {
            Picker(IBLocale.Settings.video, selection: $resolution) {
                ForEach(IBLocale.Settings.Resolution.allCases) { r in
                    Text(r.localizedLabel).tag(r.rawValue)
                }
            }
            .accessibilityLabel(IBLocale.Settings.video)
            .onChange(of: resolution) { _, new in
                Task { await engine.applyVideoConfig(resolution: new, fps: frameRate) }
            }

            Picker(IBLocale.Settings.streaming, selection: $frameRate) {
                ForEach(IBLocale.Settings.FrameRate.allCases) { fps in
                    Text(fps.localizedLabel).tag(fps.rawValue)
                }
            }
            .accessibilityLabel("Frame rate")
            .onChange(of: frameRate) { _, new in
                Task { await engine.applyVideoConfig(resolution: resolution, fps: new) }
            }
        } header: {
            Text("Stream")
        } footer: {
            Text("Higher resolutions and frame rates use more WiFi bandwidth. 1080p / 30 fps is the recommended balance.")
        }
    }

    private var inputSection: some View {
        Section {
            Toggle(IBLocale.Mic.on, isOn: Binding(
                get: { engine.features.micOn },
                set: { engine.features.set(feature: .microphone, enabled: $0) }
            ))
                .accessibilityLabel(IBLocale.Mic.on)
                .accessibilityHint("Stream the iPhone microphone to your Mac")

            Picker(IBLocale.Mode.trackpad, selection: $trackpadSens) {
                ForEach(1...5, id: \.self) { i in
                    Text("Sensitivity \(i)").tag(i)
                }
            }
            .accessibilityLabel("Trackpad sensitivity")

            Toggle("Keep screen on while streaming", isOn: $keepScreenOn)
                .accessibilityHint("Prevents the iPhone from auto-locking during a streaming session")
                .onChange(of: keepScreenOn) { _, new in
                    UIApplication.shared.isIdleTimerDisabled = new
                }
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = keepScreenOn
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        } header: {
            Text("Input")
        } footer: {
            Text("Trackpad sensitivity: 1 = slowest, 5 = fastest. Default is 3.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text(IBLocale.Settings.versionLabel)
                Spacer()
                Text("0.2 (1)")
                    .font(IBFont.monoMedium)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(IBLocale.Settings.builtFor)
                Spacer()
                Text("iOS 26+")
                    .font(IBFont.monoMedium)
                    .foregroundStyle(.secondary)
            }

            Link(destination: URL(string: "https://ibridge.app/privacy")!) {
                Label("Privacy Policy", systemImage: "hand.raised.fill")
            }
            .accessibilityLabel("Privacy Policy (opens in Safari)")
        } header: {
            Text(IBLocale.Settings.about)
        } footer: {
            Text(IBLocale.Settings.copyrightLabel)
        }
    }
}

// MARK: - Convenience used by iOS Info.plist

enum SettingsBuildInfo {
    static let shortVersion = "0.2"
    static let buildNumber = 1
}