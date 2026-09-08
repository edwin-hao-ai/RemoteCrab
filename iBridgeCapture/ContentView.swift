import SwiftUI
import iBridgeCore

struct ContentView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @State private var showConnectionSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Live camera preview behind everything else.
            CameraPreview(session: engine.captureSession)
                .ignoresSafeArea()

            // Top: status pill + connection indicator.
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
    }

    private var topBar: some View {
        HStack {
            IBStatusPill(status: pillStatus)
            Spacer()
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

    private var bottomBar: some View {
        HStack {
            Spacer()
            VStack(spacing: IBSpace.s.pt) {
                Text(engine.metadata.resolutionLabel)
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.75))
                    .ibEyebrowTracking()
                IBPrimaryButton(style: engine.isStreaming ? .stop : .stream) {
                    Task { await engine.toggleStreaming() }
                }
            }
            Spacer()
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