import AVFoundation
import SwiftUI
import UIKit
import RemoteCrabCore

/// iOS-side settings sheet, shown from the top-bar antenna icon.
/// Uses standard SwiftUI Form styling (iOS Settings aesthetic) with
/// grouped sections, footers, and the system color picker.
struct IOSSettingsView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("remotecrab.ios.resolution")    private var resolution: String = "1080p"
    @AppStorage("remotecrab.ios.frameRate")    private var frameRate: Int = 30
    @AppStorage("remotecrab.ios.trackpadSens")  private var trackpadSens: Int = 3
    @AppStorage("remotecrab.ios.keepScreenOn") private var keepScreenOn: Bool = true
    @AppStorage("remotecrab.ios.labAirMouse")   private var labAirMouse = false
    @AppStorage("remotecrab.ios.labWheelScroll") private var labWheelScroll = false
    @AppStorage("remotecrab.ios.demoMode") private var demoMode = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                pairedMacsSection
                videoSection
                inputSection
                labsSection
                demoSection
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

    /// Offline demo content for exploring / App Review without a Mac.
    private var demoSection: some View {
        Section {
            Toggle(IBLocale.Demo.title, isOn: $demoMode)
        } footer: {
            Text(IBLocale.Demo.footer)
        }
    }


    private var connectionSection: some View {
        Section {
            HStack {
                Text(connectionLabel)
                    .font(IBFont.bodyMedium)
                Spacer()
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text(IBLocale.Connection.info)
        } footer: {
            Text(IBLocale.Settings.connectionFooter)
        }
    }

    /// The Mac currently owning the session + the persisted allow-list.
    private var pairedMacsSection: some View {
        Section {
            if let connected = engine.connectedMacName {
                HStack {
                    Label(connected, systemImage: "laptopcomputer")
                    Spacer()
                    Button(IBLocale.Pairing.disconnect, role: .destructive) {
                        engine.disconnectCurrentMac()
                    }
                    .buttonStyle(.borderless)
                }
            }
            if engine.pairedMacs.isEmpty {
                Text(IBLocale.Pairing.nonePaired)
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.pairedMacs) { mac in
                    HStack {
                        Image(systemName: "laptopcomputer")
                            .foregroundStyle(.secondary)
                        Text(mac.name)
                        Spacer()
                        Button(role: .destructive) {
                            engine.forgetPairedMac(id: mac.id)
                        } label: {
                            Text(IBLocale.Pairing.forget)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text(IBLocale.Pairing.pairedMacs)
        }
    }

    private var connectionLabel: String {
        switch engine.connectionState {
        case .connected: return IBLocale.Status.live
        case .starting: return IBLocale.Status.waiting
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
            .accessibilityLabel(IBLocale.A11y.frameRate)
            .onChange(of: frameRate) { _, new in
                Task { await engine.applyVideoConfig(resolution: resolution, fps: new) }
            }
        } header: {
            Text(IBLocale.Connection.streamSection)
        } footer: {
            Text(IBLocale.Settings.streamFooter)
        }
    }

    private var inputSection: some View {
        Section {
            Toggle(engine.features.micOn ? IBLocale.Mic.on : IBLocale.Mic.off, isOn: Binding(
                get: { engine.features.micOn },
                set: { engine.features.set(feature: .microphone, enabled: $0) }
            ))
                .accessibilityLabel(engine.features.micOn ? IBLocale.Mic.on : IBLocale.Mic.off)
                .accessibilityHint(IBLocale.A11y.streamMicHint)

            Picker(IBLocale.Mode.trackpad, selection: $trackpadSens) {
                ForEach(1...5, id: \.self) { i in
                    Text(IBLocale.Settings.sensitivity(i)).tag(i)
                }
            }
            .accessibilityLabel(IBLocale.A11y.trackpadSensitivity)

            Toggle(IBLocale.Settings.keepScreenOn, isOn: $keepScreenOn)
                .accessibilityHint(IBLocale.A11y.keepScreenOnHint)
                .onChange(of: keepScreenOn) { _, new in
                    if engine.isStreaming {
                        UIApplication.shared.isIdleTimerDisabled = new
                    }
                }
        } header: {
            Text(IBLocale.Settings.input)
        } footer: {
            Text(IBLocale.Settings.inputFooter)
        }
    }

    private var labsSection: some View {
        Section {
            Toggle(IBLocale.Labs.airMouse, isOn: $labAirMouse)
                .accessibilityHint(IBLocale.A11y.airMouseHint)
            Toggle(IBLocale.Labs.wheelScroll, isOn: $labWheelScroll)
                .accessibilityHint(IBLocale.A11y.wheelScrollHint)
        } header: {
            Text(IBLocale.Labs.title)
        } footer: {
            Text(IBLocale.Labs.footer)
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

            Link(destination: URL(string: RemoteCrabLinks.productPage)!) {
                Label(IBLocale.Settings.downloadMac, systemImage: "arrow.down.circle")
            }
            .accessibilityLabel(IBLocale.Settings.downloadMac)

            Link(destination: URL(string: RemoteCrabLinks.privacyPolicy)!) {
                Label(IBLocale.Settings.privacyPolicy, systemImage: "hand.raised.fill")
            }
            .accessibilityLabel(IBLocale.A11y.privacyPolicySafari)

            Button {
                UserDefaults.standard.set(false, forKey: "remotecrab.didOnboard")
                UserDefaults.standard.set(true, forKey: "remotecrab.replayOnboarding")
                dismiss()
            } label: {
                Label(IBLocale.Settings.replayOnboarding, systemImage: "play.rectangle")
            }
            .accessibilityLabel(IBLocale.Settings.replayOnboarding)
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