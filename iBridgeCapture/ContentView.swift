import SwiftUI
import iBridgeCore

struct ContentView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @State private var showConnectionSheet = false
    @State private var showSettings = false
    @State private var micEnabled = false
    @State private var mode: Mode = .camera

    enum Mode: String, CaseIterable, Hashable {
        case camera = "Camera"
        case touch  = "Trackpad"
        case type   = "Keyboard"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            modeSurface

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(IBSpace.l.pt)
        }
        .sheet(isPresented: $showConnectionSheet) {
            ConnectionSheet(engine: engine)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSettings) {
            IOSSettingsView()
                .environmentObject(engine)
                .presentationDetents([.large])
        }
        .onChange(of: micEnabled) { _, new in
            engine.setMicrophoneEnabled(new)
        }
    }

    @ViewBuilder
    private var modeSurface: some View {
        switch mode {
        case .camera:
            CameraPreview(session: engine.captureSession)
                .ignoresSafeArea()
        case .touch:
            TouchpadScreen()
        case .type:
            KeyboardScreen()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            IBStatusPill(status: pillStatus)
            Spacer()
            modeSelector
            Button {
                showConnectionSheet = true
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(IBSpace.s.pt + 2)
                    .background {
                        IBMaterial.bar(in: Circle())
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection info")
            .accessibilityHint("Shows the Mac you're connected to, resolution, and bitrate")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(IBSpace.s.pt + 2)
                    .background {
                        IBMaterial.bar(in: Circle())
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityHint("Video resolution, frame rate, microphone, and trackpad settings")
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    withAnimation(IBAnimation.snappy) { mode = m }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: symbolName(for: m))
                            .font(.system(size: 11, weight: .medium))
                        Text(m.rawValue)
                            .font(IBFont.eyebrowMono)
                            .ibEyebrowTracking()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .foregroundStyle(mode == m ? .white : .white.opacity(0.6))
                    .background {
                        if mode == m {
                            Capsule()
                                .fill(Color.accentColor)
                        } else {
                            Capsule()
                                .fill(.white.opacity(0.08))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func symbolName(for mode: Mode) -> String {
        switch mode {
        case .camera: return "camera.fill"
        case .touch:  return "hand.point.up.left.fill"
        case .type:   return "keyboard"
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Spacer()
            VStack(spacing: IBSpace.s.pt) {
                Text(mode.rawValue.uppercased())
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.7))
                    .ibEyebrowTracking()
                IBPrimaryButton(style: engine.isStreaming ? .stop : .stream) {
                    Task { await engine.toggleStreaming() }
                }
                .accessibilityLabel(engine.isStreaming ? "Stop streaming" : "Start streaming")
                .accessibilityHint("Turns the iPhone camera feed on or off")
                if engine.isStreaming {
                    micToggle
                        .accessibilityLabel(micEnabled ? "Microphone is on. Tap to turn off." : "Microphone is off. Tap to turn on.")
                }
            }
            Spacer()
        }
    }

    private var micToggle: some View {
        Button {
            micEnabled.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: micEnabled ? "mic.fill" : "mic.slash")
                Text(micEnabled ? "Mic on" : "Mic off")
            }
            .font(IBFont.monoMedium)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                IBMaterial.bar(in: Capsule())
            }
        }
        .buttonStyle(.plain)
    }

    private var pillStatus: IBStatusPill.Status {
        switch engine.connectionState {
        case .idle, .starting:
            return .reconnecting
        case .connected:
            return .connected(latencyMs: engine.lastLatencyMs ?? 0)
        case .failed:
            return .disconnected(reason: "Error")
        }
    }
}

// MARK: - Connection sheet

private struct ConnectionSheet: View {
    @ObservedObject var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Bonjour Service") {
                    LabeledContent("Type", value: IBServiceType.tcp)
                    LabeledContent("Domain", value: IBServiceType.domain)
                    LabeledContent("Status") {
                        Text(connectionLabel)
                            .foregroundStyle(connectionColor)
                    }
                }
                Section("Stream") {
                    LabeledContent("Resolution",
                                   value: "\(engine.metadata.width)×\(engine.metadata.height)")
                    LabeledContent("FPS", value: "\(engine.metadata.fps)")
                    LabeledContent("Bitrate",
                                   value: "\(engine.metadata.bitrateBps / 1_000_000) Mbps")
                    LabeledContent("Codec", value: engine.metadata.codec.uppercased())
                }
                Section {
                    Button(engine.isStreaming ? "Stop Streaming" : "Start Streaming",
                           systemImage: engine.isStreaming ? "stop.circle" : "play.circle") {
                        Task {
                            await engine.toggleStreaming()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("iBridge")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var connectionLabel: String {
        switch engine.connectionState {
        case .idle:      return "Idle"
        case .starting:  return "Starting…"
        case .connected: return "Connected"
        case .failed:    return "Failed"
        }
    }

    private var connectionColor: Color {
        switch engine.connectionState {
        case .idle, .starting: return .secondary
        case .connected:       return IBColor.success
        case .failed:          return IBColor.error
        }
    }
}