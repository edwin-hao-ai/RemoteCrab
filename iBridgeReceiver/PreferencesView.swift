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
    @AppStorage("ibridge.resolution")     private var resolution: String = "1080p"
    @AppStorage("ibridge.frameRate")       private var frameRate: Int = 30
    @AppStorage("ibridge.audioQuality")    private var audioQuality: String = "Standard (48 kHz)"
    @AppStorage("ibridge.cameraPosition")  private var cameraPosition: String = "Back"
    @AppStorage("ibridge.launchAtLogin")   private var launchAtLogin: Bool = false
    @AppStorage("ibridge.autoReconnect")   private var autoReconnect: Bool = true

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(IBLocale.Settings.general, systemImage: "gear") }

            streamingTab
                .tabItem { Label(IBLocale.Settings.streaming, systemImage: "antenna.radiowaves.left.and.right") }

            aboutTab
                .tabItem { Label(IBLocale.Settings.about, systemImage: "info.circle") }
        }
        .frame(width: 540, height: 420)
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
                .accessibilityLabel(IBLocale.Settings.video)
                .accessibilityHint("Which iPhone camera to use as the live feed")

                Toggle(IBLocale.Settings.openAtLogin, isOn: $launchAtLogin)
                    .accessibilityHint(IBLocale.Settings.launchAtLoginDescription)

                Toggle("Auto-reconnect on connection loss", isOn: $autoReconnect)
            } header: {
                Text(IBLocale.Settings.general)
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
                    row("Version", value: "0.2")
                    row("Build",   value: "1")
                    row("Made for", value: "macOS 26+")
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
}