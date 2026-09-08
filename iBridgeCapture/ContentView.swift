import SwiftUI
import iBridgeCore

struct ContentView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @State private var showConnectionSheet = false
    @State private var micEnabled = false
    @State private var keyboardText = ""
    @State private var mode: Mode = .camera

    enum Mode { case camera, touch, type }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Mode surface (camera preview / touchpad / keyboard).
            modeSurface
                .ignoresSafeArea(edges: mode == .camera ? .all : .bottom)

            VStack {
                topBar
                Spacer()
                modeBar
            }
            .padding(IBSpace.l.pt)
        }
        .sheet(isPresented: $showConnectionSheet) {
            ConnectionSheet(engine: engine)
                .presentationDetents([.medium])
        }
        .onChange(of: micEnabled) { _, newValue in
            engine.setMicrophoneEnabled(newValue)
        }
    }

    @ViewBuilder
    private var modeSurface: some View {
        switch mode {
        case .camera:
            CameraPreview(session: engine.captureSession)
        case .touch:
            TouchpadView { event in
                engine.sendTouch(event)
            }
        case .type:
            VStack(spacing: 0) {
                Spacer()
                KeyboardView(onEvent: { event in
                    engine.sendKey(event)
                }, text: $keyboardText)
                .frame(height: 60)
                .padding(.horizontal)
                .padding(.bottom, 80)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            IBStatusPill(status: pillStatus)
            Spacer()
            modeTabs
            Button {
                showConnectionSheet = true
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(IBSpace.s.pt + 2)
                    .background {
                        IBMaterial.bar(in: Circle())
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 6) {
            ForEach([Mode.camera, .touch, .type], id: \.self) { m in
                Button {
                    mode = m
                } label: {
                    Image(systemName: iconName(for: m))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(mode == m ? .white : .white.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .background {
                            if mode == m {
                                IBMaterial.bar(in: Circle())
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func iconName(for m: Mode) -> String {
        switch m {
        case .camera: return "camera.fill"
        case .touch:  return "hand.point.up.left.fill"
        case .type:   return "keyboard"
        }
    }

    // MARK: - Bottom bar

    private var modeBar: some View {
        HStack {
            Spacer()
            VStack(spacing: IBSpace.s.pt) {
                Text(modeLabel)
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.75))
                    .ibEyebrowTracking()
                IBPrimaryButton(style: engine.isStreaming ? .stop : .stream) {
                    Task { await engine.toggleStreaming() }
                }
                if engine.isStreaming {
                    micToggle
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                IBMaterial.bar(in: Capsule())
            }
        }
        .buttonStyle(.plain)
    }

    private var modeLabel: String {
        switch mode {
        case .camera: return "CAMERA"
        case .touch:  return "TRACKPAD"
        case .type:   return "KEYBOARD"
        }
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