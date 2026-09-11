import SwiftUI
import iBridgeCore

struct ContentView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @State private var showConnectionSheet = false
    @State private var showSettings = false
    @State private var voice = VoiceRecognizer()

    /// Brief "Sent" confirmation shown on the voice card after the
    /// finalized text has been dispatched to the Mac.
    @State private var voiceSentFlash = false

    // PiP drag state: committed offset + in-flight gesture translation.
    @State private var pipOffset: CGSize = .zero
    @GestureState private var pipTranslation: CGSize = .zero

    private let pipSize = CGSize(width: 120, height: 160)
    private let pipTopPad: CGFloat = 76

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                surface

                VStack {
                    topBar
                    Spacer()
                    FeatureDock(features: engine.features, voice: voice)
                }
                .padding(IBSpace.l.pt)

                if showsPiP {
                    pip(in: geo.size)
                }

                if voice.isRunning || voiceSentFlash {
                    voiceCard
                }
            }
            .animation(IBAnimation.snappy, value: voice.isRunning || voiceSentFlash)
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
        .onAppear {
            // Finalized dictation is typed into the Mac as a `.text`
            // KeyEvent — the same channel the keyboard surface uses,
            // but via `sendVoiceText` so it isn't gated on keyboardOn.
            voice.onFinal = { text in
                engine.sendVoiceText(text)
                voiceSentFlash = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    voiceSentFlash = false
                }
            }

            // E2E test mode: when IBRIDGE_AUTO_START=1 is set, skip
            // onboarding and surface a "Tap to start streaming" affordance.
            //
            // We deliberately do NOT auto-start streaming on appear:
            //   1. The iOS Local Network permission dialog is a system
            //      modal that the user must respond to manually.
            //   2. Auto-starting behind the dialog leaves the user
            //      unable to tell which app the prompt belongs to,
            //      and on iPhone-with-Dynamic-Island the modal can
            //      visually overlap our UI in confusing ways.
            //   3. The user explicitly tapping the stream button in the
            //      connection sheet makes the cause-and-effect obvious:
            //      tap → permission prompt → streaming starts.
            //
            // The env var is only used to bypass onboarding so the
            // user lands directly on the home screen.
            if ProcessInfo.processInfo.environment["IBRIDGE_AUTO_START"] == "1" {
                UserDefaults.standard.set(true, forKey: "ibridge.didOnboard")
                // No auto-toggle — user must tap to start.
            }
        }
        .task {
            await engine.startIfNeeded()
            // E2E test mode: IBRIDGE_AUTOSTREAM=1 starts streaming
            // (Bonjour publish + listener) without a manual tap.
            // Only usable once Local Network permission is granted.
            if ProcessInfo.processInfo.environment["IBRIDGE_AUTOSTREAM"] == "1" {
                await engine.startStreaming()
            }
        }
    }

    // MARK: - Surfaces

    @ViewBuilder
    private var surface: some View {
        switch engine.features.activeSurface {
        case .cameraPreview:
            if engine.features.cameraOn {
                CameraPreview(session: engine.captureSession)
                    .ignoresSafeArea()
            } else {
                cameraOffPlaceholder
            }
        case .trackpad:
            TouchpadScreen()
        case .keyboard:
            KeyboardScreen()
        }
    }

    private var cameraOffPlaceholder: some View {
        VStack(spacing: IBSpace.l.pt) {
            Image(systemName: "video.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text("Camera is off")
                .font(IBFont.eyebrowMono)
                .ibEyebrowTracking()
                .foregroundStyle(.white.opacity(0.7))
            Button {
                engine.features.set(feature: .camera, enabled: true)
            } label: {
                Text("Turn on")
                    .font(IBFont.eyebrowMono)
                    .ibEyebrowTracking()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background {
                        Capsule().fill(Color.accentColor)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn camera on")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            IBStatusPill(status: pillStatus)
            Spacer()

            if engine.features.activeSurface == .cameraPreview {
                Button {
                    withAnimation(IBAnimation.snappy) {
                        engine.features.activeSurface = .trackpad
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(IBSpace.s.pt + 2)
                        .background {
                            IBMaterial.bar(in: Circle())
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done")
                .accessibilityHint("Returns to the trackpad")
            }

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

    // MARK: - Voice recognition card

    /// Floating hold-to-talk card, hovers above the dock on every
    /// surface. Shows the live interim transcription while the
    /// recognizer runs, then a brief "Sent" confirmation (~0.8 s)
    /// after the final text is dispatched.
    private var voiceCard: some View {
        HStack(spacing: IBSpace.m.pt - 2) {
            Image(systemName: voiceSentFlash ? "checkmark" : "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(voiceSentFlash ? IBColor.success : .red)
                .symbolEffect(.pulse, isActive: voice.isRunning)
            Text(voiceSentFlash
                 ? "Sent"
                 : (voice.partialText.isEmpty ? "Listening…" : voice.partialText))
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, IBSpace.l.pt)
        .padding(.vertical, IBSpace.m.pt - 2)
        .background {
            IBMaterial.bar(in: RoundedRectangle(cornerRadius: IBRadius.continuous.pt, style: .continuous))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        // Clear the dock (~64pt tall + l padding) below.
        .padding(.bottom, IBSpace.huge.pt * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceSentFlash
                            ? "Dictation sent"
                            : "Voice input. \(voice.partialText.isEmpty ? "Listening" : voice.partialText)")
    }

    // MARK: - PiP camera preview

    private var showsPiP: Bool {
        engine.features.cameraOn && engine.features.activeSurface != .cameraPreview
    }

    private func pip(in size: CGSize) -> some View {
        let liveOffset = clampedPiPOffset(
            CGSize(
                width: pipOffset.width + pipTranslation.width,
                height: pipOffset.height + pipTranslation.height
            ),
            in: size
        )
        return CameraPreview(session: engine.captureSession)
            .frame(width: pipSize.width, height: pipSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .padding(.top, pipTopPad)
            .padding(.trailing, IBSpace.l.pt)
            .offset(liveOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .gesture(pipDrag(in: size))
            .simultaneousGesture(
                TapGesture().onEnded {
                    withAnimation(IBAnimation.snappy) {
                        engine.features.activeSurface = .cameraPreview
                    }
                }
            )
            .accessibilityLabel("Camera preview")
            .accessibilityHint("Tap to show the camera full screen, drag to move")
    }

    private func pipDrag(in size: CGSize) -> some Gesture {
        DragGesture()
            .updating($pipTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let proposed = CGSize(
                    width: pipOffset.width + value.translation.width,
                    height: pipOffset.height + value.translation.height
                )
                pipOffset = clampedPiPOffset(proposed, in: size)
            }
    }

    private func clampedPiPOffset(_ offset: CGSize, in size: CGSize) -> CGSize {
        let margin = IBSpace.l.pt
        let minX = -(size.width - pipSize.width - 2 * margin)
        let maxY = size.height - pipSize.height - pipTopPad - margin
        return CGSize(
            width: min(max(offset.width, minX), 0),
            height: min(max(offset.height, 0), maxY)
        )
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
