import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import RemoteCrabCore

struct ContentView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("remotecrab.ios.demoMode") private var demoMode = false
    @State private var backgroundPausePending = false
    @State private var showResumedHint = false
    @State private var showConnectionSheet = false
    @State private var showSettings = false
    @State private var showAppSwitcher = false
    @State private var showSendDialog = false
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var voice = VoiceRecognizer()

    /// Brief "Sent" confirmation shown on the voice card after the
    /// finalized text has been dispatched to the Mac.
    @State private var voiceSentFlash = false
    /// Brief error flash on the voice card when the recognition session
    /// dies mid-dictation (driven by `voice.lastError`).
    @State private var voiceErrorFlash = false

    // PiP drag state: committed offset + in-flight gesture translation.
    @State private var pipOffset: CGSize = .zero
    @GestureState private var pipTranslation: CGSize = .zero

    private let pipSize = CGSize(width: 120, height: 160)
    private let pipTopPad: CGFloat = 76

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                surface(topInset: geo.safeAreaInsets.top)

                VStack {
                    topBar
                    Spacer()
                    FeatureDock(features: engine.features, voice: voice)
                }
                .padding(IBSpace.l.pt)

                statusBanner

                // The PiP reparents the app's single shared preview view
                // (engine.previewView) — the full-screen camera surface
                // and the PiP never exist at the same time, so one
                // AVCaptureVideoPreviewLayer serves both. No second layer:
                // attaching one blocked the main thread ~9 s at cold start.
                if showsPiP && !demoMode, let previewView = engine.previewView {
                    pip(in: geo.size, view: previewView)
                }

                if voice.isRunning || voiceSentFlash || voiceErrorFlash {
                    voiceCard
                }

                if let pending = engine.pendingMacName {
                    pendingApprovalCard(pending)
                }

                if let progress = engine.fileTransferProgress {
                    transferBanner(progress)
                }

                if showResumedHint {
                    hintBanner(IBLocale.Error.resumedAfterBackground)
                }
            }
            .animation(IBAnimation.snappy, value: voice.isRunning || voiceSentFlash || voiceErrorFlash)
        }
        // The trackpad surface hides system overlays itself. The only
        // other immersive surface is the full-screen camera preview —
        // everywhere else the status bar stays visible (time/battery
        // matter during hours-long trackpad sessions).
        .persistentSystemOverlays(
            engine.features.activeSurface == .cameraPreview && engine.features.cameraOn
                ? .hidden
                : .automatic
        )
        .sheet(isPresented: $showConnectionSheet) {
            ConnectionSheet(engine: engine)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSettings) {
            IOSSettingsView()
                .environmentObject(engine)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showAppSwitcher) {
            AppSwitcherView()
                .environmentObject(engine)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(IBLocale.Transfer.sendTitle, isPresented: $showSendDialog, titleVisibility: .visible) {
            Button(IBLocale.Transfer.photo) { showPhotoPicker = true }
            Button(IBLocale.Transfer.file) { showFileImporter = true }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                engine.sendFile(at: url)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "dat"
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("remotecrab-\(UUID().uuidString).\(ext)")
                    try? data.write(to: tmp)
                    engine.sendFile(at: tmp)
                }
                photoItem = nil
            }
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

            // E2E test mode: when REMOTECRAB_AUTO_START=1 is set, skip
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
            if ProcessInfo.processInfo.environment["REMOTECRAB_AUTO_START"] == "1" {
                UserDefaults.standard.set(true, forKey: "remotecrab.didOnboard")
                // No auto-toggle — user must tap to start.
            }

            // E2E: exercise the voice pipeline headlessly. The tap
            // block used to trap on the audio realtime thread (actor
            // isolation) — a survived hold-and-release proves the fix.
            // The voice flag round-trips to the Mac so the run is
            // visible in the receiver log.
            if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_VOICE"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    engine.features.set(feature: .voice, enabled: true)
                    let started = await voice.start()
                    if !started {
                        engine.features.set(feature: .voice, enabled: false)
                    }
                    try? await Task.sleep(for: .seconds(5))
                    voice.stop()
                    engine.features.set(feature: .voice, enabled: false)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS hard-stops camera capture in the background; tell the
            // user why the Mac went dark and that it recovered.
            if phase != .active, engine.features.cameraOn {
                backgroundPausePending = true
            } else if phase == .active, backgroundPausePending {
                backgroundPausePending = false
                withAnimation(IBAnimation.snappy) { showResumedHint = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(IBAnimation.snappy) { showResumedHint = false }
                }
            }
        }
        .onChange(of: voice.lastError) { _, newError in
            // Mid-session failure: flash the error on the voice card
            // briefly, then dismiss. (The dock resets its own held
            // state via `voice.onInterrupted`.)
            guard newError != nil else { return }
            voiceErrorFlash = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                voiceErrorFlash = false
                voice.clearError()
            }
        }
        .task {
            await engine.startIfNeeded()
            // E2E test mode: REMOTECRAB_AUTOSTREAM=1 starts streaming
            // (Bonjour publish + listener) without a manual tap.
            // Only usable once Local Network permission is granted.
            if ProcessInfo.processInfo.environment["REMOTECRAB_AUTOSTREAM"] == "1" {
                await engine.startStreaming()
            }
            // E2E: preset the visible surface for UI screenshot runs.
            switch ProcessInfo.processInfo.environment["REMOTECRAB_E2E_SURFACE"] {
            case "trackpad": engine.features.activeSurface = .trackpad
            case "keyboard": engine.features.activeSurface = .keyboard
            case "camera":   engine.features.activeSurface = .cameraPreview
            default:         break
            }
        }
    }

    // MARK: - Pending Mac approval

    /// Shown while a new Mac waits on the iPhone's pairing decision.
    private func pendingApprovalCard(_ name: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white)
            Text(IBLocale.Pairing.requestTitle)
                .font(IBFont.bodyMedium.weight(.semibold))
                .foregroundStyle(.white)
            Text(IBLocale.Pairing.allowPrompt(name))
                .font(IBFont.caption)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(IBLocale.Pairing.deny) { engine.denyPendingMac() }
                    .font(IBFont.bodyMedium)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background { Capsule().fill(.white.opacity(0.15)) }
                    .buttonStyle(.plain)
                Button(IBLocale.Pairing.allow) { engine.approvePendingMac() }
                    .font(IBFont.bodyMedium.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background { Capsule().fill(Color.accentColor) }
                    .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: 300)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.black.opacity(0.6))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - File transfer banner

    /// Floating progress capsule shown while a file is being sent.
    private func transferBanner(_ progress: Double) -> some View {
        VStack {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.85)
                Text("\(IBLocale.Transfer.sending) \(Int(progress * 100))%")
                    .font(IBFont.caption)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background { Capsule().fill(.black.opacity(0.6)) }
            .padding(.top, 96)
            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Transient top toast for one-line hints (e.g. "resumed after
    /// background"). Read-only, auto-dismissing.
    private func hintBanner(_ text: String) -> some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                Text(text)
                    .font(IBFont.caption)
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background { Capsule().fill(.black.opacity(0.65)) }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Surfaces

    @ViewBuilder
    private func surface(topInset: CGFloat) -> some View {
        switch engine.features.activeSurface {
        case .cameraPreview:
            if demoMode {
                DemoCameraView()
            } else if engine.features.cameraOn {
                if engine.captureSessionReady, let previewView = engine.previewView {
                    // Purely visual — VoiceOver users control the camera
                    // from the dock toggle and the status pill.
                    CameraPreview(view: previewView)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                        .overlay(alignment: .topTrailing) {
                            flipCameraButton(topInset: topInset)
                        }
                } else {
                    cameraStartingPlaceholder
                }
            } else {
                cameraOffPlaceholder
            }
        case .trackpad:
            TouchpadScreen()
        case .keyboard:
            KeyboardScreen()
        }
    }

    /// Camera flip. Styled identically to the top-bar icons
    /// (`IBMaterial.bar` Liquid Glass chip) and parked one row BELOW the
    /// floating top bar — the bar occupies safeArea.top + 16pt padding +
    /// 44pt row, so a hardcoded 56pt top pad collided with it on
    /// Dynamic Island phones.
    private func flipCameraButton(topInset: CGFloat) -> some View {
        Button {
            engine.toggleCamera()
        } label: {
            topBarIcon("arrow.triangle.2.circlepath.camera")
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .buttonStyle(.plain)
        .padding(.top, topInset + 16 + 44 + 12)
        .padding(.trailing, IBSpace.l.pt)
        .accessibilityLabel("Switch camera")
        .accessibilityHint("Flips between the front and back cameras")
    }

    /// Shown while the capture session is still starting (a cold
    /// `startRunning()` can take several seconds). Deliberately NOT a
    /// preview attached early — see `captureSessionReady`.
    private var cameraStartingPlaceholder: some View {
        VStack(spacing: IBSpace.l.pt) {
            ProgressView()
                .controlSize(.large)
                .tint(.white.opacity(0.8))
            Text(IBLocale.Capture.cameraStarting)
                .font(IBFont.eyebrowMono)
                .ibEyebrowTracking()
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var cameraOffPlaceholder: some View {
        VStack(spacing: IBSpace.l.pt) {
            Image(systemName: "video.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text(IBLocale.Capture.cameraOff)
                .font(IBFont.eyebrowMono)
                .ibEyebrowTracking()
                .foregroundStyle(.white.opacity(0.7))
            Button {
                engine.features.set(feature: .camera, enabled: true)
            } label: {
                Text(IBLocale.Capture.turnCameraOn)
                    .font(IBFont.eyebrowMono)
                    .ibEyebrowTracking()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background {
                        Capsule().fill(Color.accentColor)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn camera on")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Compact status icon — the wordy state now lives in the
            // alert banner below, so the live view stays uncluttered.
            Button { showConnectionSheet = true } label: {
                topBarIcon(statusSymbol, tint: statusTint)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .buttonStyle(.plain)
            .accessibilityLabel(IBLocale.Connection.info)

            if demoMode {
                Text(IBLocale.Demo.badge)
                    .font(IBFont.eyebrowMono)
                    .ibEyebrowTracking()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background { Capsule().fill(IBColor.warning.opacity(0.9)) }
                    .accessibilityLabel(IBLocale.Demo.title)
            }
            Spacer()

            // The camera-preview exit is contextual and stays direct.
            if engine.features.activeSurface == .cameraPreview {
                Button {
                    withAnimation(IBAnimation.snappy) {
                        engine.features.activeSurface = .trackpad
                    }
                } label: {
                    topBarIcon("xmark")
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .buttonStyle(.plain)
                .accessibilityLabel(IBLocale.Settings.done)
            }

            // Everything else lives in ONE overflow menu. The bar used
            // to carry five buttons, which crowded the live view.
            Menu {
                Button { showAppSwitcher = true } label: {
                    Label(IBLocale.Switcher.title, systemImage: "square.grid.2x2")
                }
                Button { showSendDialog = true } label: {
                    Label(IBLocale.Transfer.sendTitle, systemImage: "square.and.arrow.up")
                }
                Button { engine.sendClipboard() } label: {
                    Label(IBLocale.Transfer.clipboardToMac, systemImage: "doc.on.clipboard")
                }
                Divider()
                Button { showConnectionSheet = true } label: {
                    Label(IBLocale.Connection.info, systemImage: "antenna.radiowaves.left.and.right")
                }
                Button { showSettings = true } label: {
                    Label(IBLocale.Settings.title, systemImage: "gear")
                }
            } label: {
                topBarIcon("ellipsis.circle")
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .accessibilityLabel(IBLocale.App.more)
        }
    }

    private func topBarIcon(_ name: String, tint: Color = .white) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .padding(IBSpace.s.pt + 2)
            .background { IBMaterial.bar(in: Circle()) }
    }

    // MARK: - Connection status (icon + alert)

    private var statusSymbol: String {
        switch engine.connectionState {
        case .idle:      return "circle.dashed"
        case .starting:  return "antenna.radiowaves.left.and.right"
        case .connected: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch engine.connectionState {
        case .connected: return IBColor.success
        case .failed:    return IBColor.error
        case .starting:  return IBColor.warning
        case .idle:      return .white.opacity(0.6)
        }
    }

    private struct StatusAlert {
        let symbol: String
        let tint: Color
        let title: String
        let subtitle: String?
    }

    /// Non-nil only for states worth surfacing; connected/idle are silent.
    private var currentAlert: StatusAlert? {
        switch engine.connectionState {
        case .connected, .idle:
            return nil
        case .starting:
            // The iPhone is the TCP server: it can only wait for a Mac
            // to dial in. Show the manual-connect escape hatch (own
            // IP:port) as soon as the address is known — Bonjour is
            // blocked on VPNs, hotspots and isolated networks, and
            // "连接中" forever was the top user complaint.
            let subtitle: String
            if let ip = engine.localAddress {
                let port = engine.listeningPort.map(String.init) ?? "8765"
                subtitle = IBLocale.Error.manualConnectHint("\(ip):\(port)")
            } else {
                subtitle = IBLocale.Error.searchingHint
            }
            return StatusAlert(symbol: "antenna.radiowaves.left.and.right",
                               tint: IBColor.warning,
                               title: IBLocale.Error.waitingForMac,
                               subtitle: subtitle)
        case .failed:
            return StatusAlert(symbol: "exclamationmark.triangle.fill",
                               tint: IBColor.error,
                               title: IBLocale.Status.offline,
                               subtitle: IBLocale.Error.connectionLost)
        }
    }

    /// Centered alert card (not a top bar) so it never collides with a
    /// surface's own header — e.g. the keyboard screen.
    @ViewBuilder
    private var statusBanner: some View {
        // Demo mode is deliberately offline — don't nag with the
        // "disconnected" alert over the sample content.
        if !demoMode, let alert = currentAlert {
            ZStack {
                // Dim backdrop so the card reads as a modal alert
                // rather than a stray box over the surface.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                VStack(spacing: 10) {
                Image(systemName: alert.symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(alert.tint)
                Text(alert.title)
                    .font(IBFont.bodyMedium.weight(.semibold))
                    .foregroundStyle(.white)
                if let subtitle = alert.subtitle {
                    Text(subtitle)
                        .font(IBFont.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: 300)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.black.opacity(0.75))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(alert.tint.opacity(0.35), lineWidth: 1)
                        }
                }
            }
            .transition(.opacity.combined(with: .scale))
        }
    }

    // MARK: - Voice recognition card

    /// Floating hold-to-talk card, hovers above the dock on every
    /// surface. Shows the live interim transcription while the
    /// recognizer runs, then a brief "Sent" confirmation (~0.8 s)
    /// after the final text is dispatched.
    private var voiceCard: some View {
        HStack(spacing: IBSpace.m.pt - 2) {
            Image(systemName: voiceErrorFlash
                  ? "exclamationmark.triangle"
                  : (voiceSentFlash ? "checkmark" : "waveform"))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(voiceErrorFlash ? IBColor.error : (voiceSentFlash ? IBColor.success : IBColor.recording))
                .symbolEffect(.pulse, isActive: voice.isRunning)
            Text(voiceErrorFlash
                 ? (voice.lastError ?? "Voice input stopped")
                 : (voiceSentFlash
                    ? IBLocale.Voice.sent
                    : (voice.partialText.isEmpty ? IBLocale.Voice.listening : voice.partialText)))
                .font(IBFont.bodyMedium)
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, IBSpace.l.pt)
        .padding(.vertical, IBSpace.m.pt - 2)
        .background {
            IBMaterial.bar(in: RoundedRectangle(cornerRadius: IBRadius.continuous.pt, style: .continuous))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        // Clear the dock below — and on the trackpad also clear the
        // floating ⌃⌥⌘⇧ modifier bar so the PTT pill never covers it.
        .padding(.bottom, voiceCardBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceErrorFlash
                            ? "Voice input error. \(voice.lastError ?? "")"
                            : (voiceSentFlash
                               ? "Dictation sent"
                               : "Voice input. \(voice.partialText.isEmpty ? "Listening" : voice.partialText)"))
    }

    /// Dock top is ~134pt from the bottom; on the trackpad the ⌃⌥⌘⇧
    /// modifier bar adds another ~56pt above that, so the dictation
    /// card floats above both instead of covering them.
    private var voiceCardBottomInset: CGFloat {
        engine.features.activeSurface == .trackpad ? 204 : 146
    }

    // MARK: - PiP camera preview

    private var showsPiP: Bool {
        engine.features.cameraOn && engine.features.activeSurface != .cameraPreview
    }

    private func pip(in size: CGSize, view: CameraPreview.PreviewView) -> some View {
        let liveOffset = clampedPiPOffset(
            CGSize(
                width: pipOffset.width + pipTranslation.width,
                height: pipOffset.height + pipTranslation.height
            ),
            in: size
        )
        return CameraPreview(view: view)
            .frame(width: pipSize.width, height: pipSize.height)
            .clipShape(RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous)
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

}

// MARK: - Connection sheet

private struct ConnectionSheet: View {
    @ObservedObject var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss
    /// True while `toggleStreaming()` is in flight — the listener +
    /// Bonjour publish resolve asynchronously, so the button shows an
    /// inline spinner instead of the sheet vanishing with no feedback.
    @State private var toggling = false

    /// The iPhone's WiFi address + port, for the Mac's manual-connect path.
    private var connectionAddressText: String {
        guard let ip = engine.localAddress else { return "—" }
        let port = engine.listeningPort.map(String.init) ?? "—"
        return "\(ip):\(port)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section(IBLocale.Connection.bonjourService) {
                    LabeledContent(IBLocale.Connection.address) {
                        monoValue(connectionAddressText)
                    }
                    LabeledContent("Type") { monoValue(IBServiceType.tcp) }
                    LabeledContent("Domain") { monoValue(IBServiceType.domain) }
                    LabeledContent("Status") {
                        Text(connectionLabel)
                            .foregroundStyle(connectionColor)
                    }
                }
                Section(IBLocale.Connection.streamSection) {
                    LabeledContent("Resolution") {
                        monoValue("\(engine.metadata.width)×\(engine.metadata.height)")
                    }
                    LabeledContent("FPS") {
                        monoValue(IBLocale.Preview.frameRate(engine.metadata.fps))
                    }
                    LabeledContent("Bitrate") {
                        monoValue(IBLocale.Preview.bitrate(engine.metadata.bitrateBps / 1_000_000))
                    }
                    LabeledContent("Codec") {
                        monoValue(engine.metadata.codec.uppercased())
                    }
                }
                Section {
                    Button {
                        guard !toggling else { return }
                        Task {
                            toggling = true
                            await engine.toggleStreaming()
                            toggling = false
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: IBSpace.s.pt) {
                            if toggling {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: engine.isStreaming ? "stop.circle" : "play.circle")
                            }
                            Text(engine.isStreaming
                                 ? IBLocale.Connection.stopStreaming
                                 : (toggling ? IBLocale.Connection.starting : IBLocale.Connection.startStreaming))
                        }
                    }
                    .disabled(toggling)
                }
            }
            .navigationTitle("RemoteCrab")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Every technical readout is SF Mono (IBTypography).
    private func monoValue(_ value: String) -> some View {
        Text(value)
            .font(IBFont.monoMedium)
    }

    private var connectionLabel: String {
        switch engine.connectionState {
        case .idle:      return IBLocale.Status.ready
        case .starting:  return IBLocale.Status.waiting
        case .connected: return IBLocale.Status.live
        case .failed:    return IBLocale.Status.offline
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
