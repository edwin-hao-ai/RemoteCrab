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
    @AppStorage("ibridge.ios.labAirMouse")   private var labAirMouse = false
    @AppStorage("ibridge.ios.labWheelScroll") private var labWheelScroll = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                videoSection
                inputSection
                labsSection
                aboutSection
            }
            .navigationTitle(IBLocale.Settings.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IBLocale.Settings.done) { dismiss() }
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
        case .idle: return IBLocale.Status.ready
        }
    }

    private var connectionColor: Color {
        switch engine.connectionState {
        case .connected: return IBColor.success
        case .failed: return IBColor.error
        default: return IBColor.textTertiary
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
            Toggle(engine.features.micOn ? IBLocale.Mic.on : IBLocale.Mic.off, isOn: Binding(
                get: { engine.features.micOn },
                set: { engine.features.set(feature: .microphone, enabled: $0) }
            ))
                .accessibilityLabel(engine.features.micOn ? IBLocale.Mic.on : IBLocale.Mic.off)
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
                    if engine.isStreaming {
                        UIApplication.shared.isIdleTimerDisabled = new
                    }
                }
        } header: {
            Text("Input")
        } footer: {
            Text("Trackpad sensitivity: 1 = slowest, 5 = fastest. Default is 3.")
        }
    }

    private var labsSection: some View {
        Section {
            Toggle("Air mouse", isOn: $labAirMouse)
                .accessibilityHint("Hold the floating button on the trackpad and tilt your iPhone to move the cursor")
            Toggle("Wheel scrolling", isOn: $labWheelScroll)
                .accessibilityHint("Hold the edge button on the trackpad and draw circles to scroll")
        } header: {
            Text("Labs")
        } footer: {
            Text("Experimental gestures. Air mouse: hold the floating button on the trackpad and tilt your iPhone to move the cursor. Wheel scrolling: hold the edge button and draw circles to scroll.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text(IBLocale.Settings.versionLabel)
                Spacer()
                Text(Self.versionString)
                    .font(IBFont.monoMedium)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(IBLocale.Settings.builtFor)
                Spacer()
                Text(Self.builtForString)
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

    // MARK: - Build info (read from the bundle, never hardcoded)

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private static var builtForString: String {
        let min = Bundle.main.infoDictionary?["MinimumOSVersion"] as? String ?? "26.0"
        return "iOS \(min)+"
    }
}