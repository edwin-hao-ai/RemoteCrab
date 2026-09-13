import AVFoundation
import Combine
import Darwin
import Foundation
import Network
import UIKit
import VideoToolbox
import iBridgeCore
import os

/// The brain of iBridgeCapture. Owns the camera, H.264 encoder, and
/// the Bonjour-published TCP listener. Pushes compressed NAL frames
/// out to whichever Mac connected first.
@MainActor
final class CaptureEngine: ObservableObject {

    private static let log = Logger(subsystem: "com.ibridge", category: "capture")

    // Public state surfaced to SwiftUI.
    @Published private(set) var isStreaming = false
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var metadata: IBStreamMetadata = .defaultConfig()
    @Published private(set) var lastLatencyMs: Int?

    // Multi-Mac pairing surface for the UI.
    /// Every Mac the user has approved (settings → Paired Macs).
    @Published private(set) var pairedMacs: [PairedMac] = []
    /// Name of a Mac waiting for the user's approval, if any.
    @Published private(set) var pendingMacName: String?
    /// Name of the Mac currently owning the session, if any.
    @Published private(set) var connectedMacName: String?
    /// Running apps on the Mac, for the app switcher.
    @Published private(set) var macApps: [IBAppInfo] = []
    /// Fixed listening port (for manual "connect by IP" when Bonjour is
    /// blocked) + this device's WiFi address, shown in the connection sheet.
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var localAddress: String?
    /// 0…1 while sending a file to the Mac; nil when idle.
    @Published private(set) var fileTransferProgress: Double?
    /// Latest transfer ack from the Mac.
    @Published private(set) var lastFileAck: IBFileAck?

    let captureSession = AVCaptureSession()

    enum ConnectionState: Equatable {
        case idle
        case starting
        case connected
        case failed
    }

    // MARK: - Private state

    private var encoder = H264Encoder()
    private var listener: NWListener?
    /// The granted owner connection. Only this connection streams and
    /// may send `featureControl`; candidates live in `candidate` until
    /// the pairing handshake admits them.
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.ibridge.encoder")
    private var didConfigure = false

    // MARK: - Multi-Mac handshake state

    private var ownerMac: PairedMac?
    /// Connection currently awaiting a `clientHello` (not yet granted).
    private var candidate: NWConnection?
    private var candidateParser: IBWire.Parser?
    /// Connection whose `clientHello` is waiting on the user's approval.
    private var pendingConnection: NWConnection?
    private var pendingHello: IBClientHello?
    /// Identifies the in-flight candidate read so late callbacks from a
    /// superseded connection can't admit the wrong Mac.
    private var handshakeToken: UUID?
    private var handshakeTask: Task<Void, Never>?

    let pairingStore = MacPairingStore()

    /// Shared broadcaster for touch / key / audio events. Created when
    /// a Mac connects and torn down when the connection drops.
    private(set) var broadcaster: IBEventBroadcaster?

    private(set) var audioEncoder: MicrophoneEncoder?

    /// Single source of truth for capability state. Bound by the UI
    /// and mutated by remote FeatureControl frames alike.
    let features = FeatureStore()

    private let parser = IBWire.Parser()

    // MARK: - Lifecycle

    /// Request permissions and start the AVCaptureSession. Called from
    /// the SwiftUI `.task` modifier on the root view.
    func startIfNeeded() async {
        guard !didConfigure else { return }
        didConfigure = true
        FileHandle.standardError.write("[e2e] startIfNeeded begin\n".data(using: .utf8)!)

        features.onChange = { [weak self] snapshot in
            self?.handleFeaturesChanged(snapshot)
        }
        refreshPairedMacs()

        await requestPermissions()

        do {
            try configureCaptureSession()
            observeCaptureInterruptions()
            try await encoder.start { [weak self] frame in
                Task { @MainActor in
                    self?.handleEncodedFrame(frame)
                }
            }
            let savedResolution = UserDefaults.standard.string(forKey: "ibridge.ios.resolution") ?? "1080p"
            let savedFps = UserDefaults.standard.integer(forKey: "ibridge.ios.frameRate")
            let fps = savedFps == 0 ? 30 : savedFps
            if savedResolution != "1080p" || fps != 30 {
                await applyVideoConfig(resolution: savedResolution, fps: fps)
            }
        } catch {
            Self.log.error("capture start failed: \(error, privacy: .public)")
            connectionState = .failed
            didConfigure = false
        }
    }

    func toggleStreaming() async {
        if isStreaming {
            stopStreaming()
        } else {
            await startStreaming()
        }
    }

    /// V0.2 — receive touch events from the SwiftUI trackpad view
    /// and forward them over the wire.
    func sendTouch(_ event: TouchEvent) {
        guard features.trackpadOn else { return }
        broadcaster?.send(event)
    }

    /// V0.2 — receive key events from the SwiftUI keyboard view and
    /// forward them over the wire.
    func sendKey(_ event: KeyEvent) {
        guard features.keyboardOn else { return }
        broadcaster?.send(event)
    }

    /// Voice dictation result. Ships as a `.text` KeyEvent over the
    /// same wire channel as the keyboard, but is deliberately NOT
    /// gated on `keyboardOn` — voice is its own feature and must work
    /// from any surface.
    ///
    /// Also doubles as a tiny voice-command surface: "open X" /
    /// "切换到 X" activates a running Mac app instead of typing.
    func sendVoiceText(_ text: String) {
        if handleVoiceCommand(text) { return }
        broadcaster?.send(KeyEvent(action: .text, text: text))
    }

    private func handleVoiceCommand(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // "open X" / "切换到 X" → activate a running Mac app.
        let appPrefixes = ["切换到", "打开", "跳转到", "switch to ", "open ", "launch ", "go to "]
        for prefix in appPrefixes where t.hasPrefix(prefix) {
            let target = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            if let app = macApps.first(where: {
                $0.name.lowercased().contains(target) || $0.id.lowercased().contains(target)
            }) {
                Self.log.info("voice command → activate \(app.name, privacy: .public)")
                activateMacApp(id: app.id)
                return true
            }
        }

        // "改写成大写" / "make this bullet list" → transform the Mac's
        // current selection. Requires an explicit trigger so ordinary
        // dictation that merely contains a keyword isn't hijacked.
        let triggers = ["改写", "格式化", "变成", "转成", "改成",
                        "rewrite", "reformat", "format", "make it", "make this"]
        guard triggers.contains(where: { t.hasPrefix($0) }) else { return false }
        let commands: [(String, IBTextCommand)] = [
            ("全部大写", .uppercase), ("大写", .uppercase), ("uppercase", .uppercase),
            ("小写", .lowercase), ("lowercase", .lowercase),
            ("首字母大写", .capitalize), ("标题", .capitalize),
            ("capitalize", .capitalize), ("title case", .capitalize),
            ("去空格", .trimWhitespace), ("多余空格", .trimWhitespace), ("trim", .trimWhitespace),
            ("去掉换行", .stripNewlines), ("合并成一行", .stripNewlines), ("一行", .stripNewlines),
            ("项目符号", .bulletList), ("变成列表", .bulletList), ("bullet", .bulletList)
        ]
        for (phrase, command) in commands.sorted(by: { $0.0.count > $1.0.count })
        where t.contains(phrase) {
            broadcaster?.send(IBTextCommandMessage(command: command))
            Self.log.info("voice command → transform \(command.rawValue, privacy: .public)")
            return true
        }
        return false
    }

    // MARK: - Clipboard

    /// Send the iPhone clipboard text to the Mac.
    func sendClipboard() {
        let text = UIPasteboard.general.string ?? ""
        guard !text.isEmpty else { return }
        broadcaster?.send(IBClipboard(text: text))
    }

    func startStreaming() async {
        FileHandle.standardError.write("[e2e] startStreaming called, isStreaming=\(isStreaming)\n".data(using: .utf8)!)
        guard !isStreaming else { return }
        connectionState = .starting
        do {
            try startListener()
            FileHandle.standardError.write("[e2e] listener started OK\n".data(using: .utf8)!)
            isStreaming = true
            UIApplication.shared.isIdleTimerDisabled =
                UserDefaults.standard.bool(forKey: "ibridge.ios.keepScreenOn")
                || ProcessInfo.processInfo.environment["IBRIDGE_AUTOSTREAM"] == "1"
        } catch {
            Self.log.error("listener start failed: \(error, privacy: .public)")
            FileHandle.standardError.write("[e2e] listener start FAILED: \(error)\n".data(using: .utf8)!)
            connectionState = .failed
        }
    }

    func stopStreaming() {
        listener?.cancel()
        listener = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        handshakeToken = nil
        candidate?.cancel()
        candidate = nil
        candidateParser = nil
        pendingConnection?.cancel()
        pendingConnection = nil
        pendingHello = nil
        pendingMacName = nil
        connection?.cancel()
        clearOwner()
        isStreaming = false
        connectionState = .idle
        parser.reset()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Called on every return to the foreground (scenePhase == .active).
    /// iOS suspends the Bonjour listener while the app is backgrounded,
    /// so a previously-streaming app comes back with a dead
    /// advertisement and usually a reset TCP link while `isStreaming`
    /// still reads true. Recreate the listener to force the service to
    /// re-register; the Mac side auto-reconnects once we're visible.
    func handleDidBecomeActive() {
        guard isStreaming else { return }
        if !captureSession.isRunning {
            // Backgrounding interrupts the capture session; audio
            // (separate AVAudioEngine) survives but video stays dead
            // until we explicitly restart.
            Self.log.info("foreground: capture session not running — restarting")
            queue.async { [captureSession] in captureSession.startRunning() }
        }
        let linkAlive = connection?.state == .ready
        Self.log.info("foreground: isStreaming=true linkAlive=\(linkAlive, privacy: .public)")
        guard !linkAlive else { return }
        Task {
            stopStreaming()
            await startStreaming()
        }
    }

    // MARK: - Capture session interruptions

    /// Backgrounding interrupts the AVCaptureSession (video device
    /// unavailable in background) and a media-services reset can kill
    /// it outright. iOS does NOT guarantee automatic recovery — an
    /// unhandled interruption is why video went silent after every
    /// background round-trip while audio kept flowing.
    private func observeCaptureInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                           object: captureSession, queue: nil) { [weak self] _ in
            Self.log.info("capture interruption ended — ensuring running")
            self?.restartCaptureIfNeeded()
        }
        center.addObserver(forName: .AVCaptureSessionRuntimeError,
                           object: captureSession, queue: nil) { [weak self] note in
            Self.log.error("capture runtime error: \(note.userInfo ?? [:], privacy: .public)")
            self?.restartCaptureIfNeeded()
        }
        center.addObserver(forName: .AVCaptureSessionWasInterrupted,
                           object: captureSession, queue: nil) { _ in
            Self.log.info("capture session interrupted")
        }
    }

    private func restartCaptureIfNeeded() {
        queue.async { [weak self] in
            guard let self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    // MARK: - Video reconfiguration

    /// Reconfigure capture + encode for a new resolution / frame rate.
    /// Safe to call while streaming; the Mac re-reads dimensions from
    /// the metadata frame we re-send.
    func applyVideoConfig(resolution: String, fps: Int) async {
        let (preset, width, height): (AVCaptureSession.Preset, Int, Int) = {
            switch resolution {
            case "720p": return (.hd1280x720, 1280, 720)
            case "4K":   return (.hd4K3840x2160, 3840, 2160)
            default:     return (.hd1920x1080, 1920, 1080)
            }
        }()
        captureSession.beginConfiguration()
        captureSession.sessionPreset = preset
        captureSession.commitConfiguration()

        let newEncoder = H264Encoder(width: Int32(width), height: Int32(height),
                                     fps: fps, bitrate: bitrateFor(width: width, height: height, fps: fps))
        do {
            try await newEncoder.start { [weak self] frame in
                Task { @MainActor in self?.handleEncodedFrame(frame) }
            }
            encoder = newEncoder
            // Re-point the video output's delegate at the new encoder.
            captureSession.beginConfiguration()
            for output in captureSession.outputs {
                if let video = output as? AVCaptureVideoDataOutput {
                    video.setSampleBufferDelegate(newEncoder, queue: queue)
                }
            }
            captureSession.commitConfiguration()

            metadata = IBStreamMetadata(deviceName: UIDevice.current.name,
                                        width: width, height: height,
                                        fps: fps, bitrateBps: bitrateFor(width: width, height: height, fps: fps))
            if let connection, connection.state == .ready {
                sendMetadata(on: connection)
            }
        } catch {
            Self.log.error("applyVideoConfig failed: \(error, privacy: .public)")
        }
    }

    /// ~0.1 bpp real-time talk-band heuristic, clamped to [1, 12] Mbps.
    private func bitrateFor(width: Int, height: Int, fps: Int) -> Int {
        let raw = Int(Double(width * height * fps) * 0.1)
        return min(max(raw, 1_000_000), 12_000_000)
    }

    // MARK: - Setup

    private func requestPermissions() async {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        if !camera || !mic {
            Self.log.error("permissions denied — camera=\(camera, privacy: .public) mic=\(mic, privacy: .public)")
        }
    }

    private func configureCaptureSession() throws {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw NSError(domain: "iBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "No camera"])
        }

        let videoInput = try AVCaptureDeviceInput(device: device)
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.setSampleBufferDelegate(encoder, queue: queue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        if let micDevice = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: micDevice)
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
            }
        }

        captureSession.commitConfiguration()
        captureSession.startRunning()
    }

    // MARK: - Bonjour listener

    /// Preferred fixed port so the Mac can reach us without Bonjour.
    static let preferredPort: UInt16 = 8765

    private func startListener() throws {
        let parameters = NWParameters.tcp

        // Try the fixed port first (manual-IP fallback); fall back to a
        // dynamic port if it's taken.
        let listener: NWListener
        if let fixed = NWEndpoint.Port(rawValue: Self.preferredPort),
           let fixedListener = try? NWListener(using: parameters, on: fixed) {
            listener = fixedListener
        } else {
            listener = try NWListener(using: parameters)
        }
        listener.service = NWListener.Service(
            name: defaultServiceName(),
            type: IBServiceType.tcp,
            domain: IBServiceType.domain
        )
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection: connection)
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        Self.log.info("Bonjour publishing: \(IBServiceType.tcp, privacy: .public) / \(self.defaultServiceName(), privacy: .public)")
    }

    private func refreshNetworkInfo() {
        listeningPort = listener?.port?.rawValue
        localAddress = Self.wifiAddress()
    }

    private func defaultServiceName() -> String {
        "Familiar — \(UIDevice.current.name)"
    }

    /// The iPhone's WiFi (en0) IPv4 address, for the manual-connect hint.
    private static func wifiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
            }
        }
        return address
    }

    private func handleListenerState(_ state: NWListener.State) {
        FileHandle.standardError.write("[e2e] listener state: \(state)\n".data(using: .utf8)!)
        switch state {
        case .ready:
            Self.log.info("listener ready")
            refreshNetworkInfo()
            FileHandle.standardError.write("[e2e] listener port: \(String(describing: self.listener?.port))\n".data(using: .utf8)!)
        case .failed(let error):
            Self.log.error("listener failed: \(error, privacy: .public)")
            connectionState = .failed
        case .cancelled:
            connectionState = connection == nil ? .idle : .connected
        default:
            break
        }
    }

    /// A Mac just opened a TCP connection. We do NOT stream yet: the
    /// Mac must first identify itself with a `clientHello`, then the
    /// pairing policy decides whether it becomes the owner.
    ///
    /// If another Mac already owns the session we answer `busy` and
    /// close the newcomer without disturbing the owner — that is the
    /// fix for multiple Macs fighting over one iPhone.
    private func accept(connection newConnection: NWConnection) {
        if connection != nil {
            replyBusy(on: newConnection, ownerName: connectedMacName ?? "another Mac")
            return
        }
        // Supersede any candidate that hasn't finished handshaking.
        if let pendingConnection, pendingConnection !== newConnection {
            pendingConnection.cancel()
        }
        pendingConnection = nil
        pendingHello = nil
        beginHandshake(with: newConnection)
    }

    private func beginHandshake(with conn: NWConnection) {
        let parser = IBWire.Parser()
        candidate = conn
        candidateParser = parser
        let token = UUID()
        handshakeToken = token

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleCandidateState(state, token: token) }
        }
        conn.start(queue: queue)
        readHello(on: conn, parser: parser, token: token)

        // Legacy fallback: an old Mac never sends a hello. After 3 s,
        // admit it first-come so an upgrade doesn't brick the pairing.
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.handshakeToken == token,
                  self.connection == nil, self.pendingConnection == nil else { return }
            Self.log.info("clientHello timeout — admitting legacy Mac")
            self.sendSessionReply(IBSessionReply(result: .accepted), on: conn)
            self.grant(connection: conn, mac: nil)
        }
    }

    private func readHello(on conn: NWConnection, parser: IBWire.Parser, token: UUID) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.handshakeToken == token else { return }
                if let data, !data.isEmpty {
                    for frame in parser.append(data) where frame.kind == .clientHello {
                        if let hello = try? IBWire.decodeClientHello(frame) {
                            self.handleHello(hello, on: conn, token: token)
                            return
                        }
                    }
                }
                if error != nil { conn.cancel(); return }
                if isComplete { return }
                self.readHello(on: conn, parser: parser, token: token)
            }
        }
    }

    private func handleHello(_ hello: IBClientHello, on conn: NWConnection, token: UUID) {
        guard handshakeToken == token, connection == nil else { return }
        // A second Mac showed up while the first was mid-handshake.
        if pendingConnection != nil && pendingConnection !== conn {
            replyBusy(on: conn, ownerName: pendingMacName ?? "another Mac")
            return
        }
        let decision = PairingPolicy.decide(hello: hello, paired: pairingStore.paired, owner: nil)
        Self.log.info("clientHello \(hello.name, privacy: .public) -> \(String(describing: decision), privacy: .public)")

        switch decision {
        case .accept:
            guard let mac = pairingStore.paired.first(where: { $0.id == hello.id }) else {
                // Shouldn't happen, but never strand the Mac.
                sendSessionReply(IBSessionReply(result: .pending), on: conn)
                pendingConnection = conn
                pendingHello = hello
                pendingMacName = hello.name
                return
            }
            sendSessionReply(IBSessionReply(result: .accepted, token: mac.token), on: conn)
            grant(connection: conn, mac: mac)
        case .pending:
            // Headless e2e: auto-approve so a run needs no phone tap.
            if ProcessInfo.processInfo.environment["IBRIDGE_E2E_AUTOPAIR"] == "1" {
                sendSessionReply(IBSessionReply(result: .pending), on: conn)
                pendingConnection = conn
                pendingHello = hello
                pendingMacName = hello.name
                approvePendingMac()
                return
            }
            sendSessionReply(IBSessionReply(result: .pending), on: conn)
            pendingConnection = conn
            pendingHello = hello
            pendingMacName = hello.name
        case .busy(let ownerName):
            replyBusy(on: conn, ownerName: ownerName)
        }
    }

    /// Promote a connection to the session owner and start streaming.
    private func grant(connection conn: NWConnection, mac: PairedMac?) {
        handshakeTask?.cancel()
        handshakeTask = nil
        handshakeToken = nil
        candidate = nil
        candidateParser = nil
        pendingConnection = nil
        pendingHello = nil
        pendingMacName = nil

        ownerMac = mac
        connection = conn
        connectedMacName = mac?.name ?? "Mac (legacy)"
        connectionState = .connected
        Self.log.info("session granted to \(self.connectedMacName ?? "?", privacy: .public)")

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleOwnerState(state, on: conn) }
        }

        let broadcaster = IBEventBroadcaster(connection: conn, queue: queue)
        self.broadcaster = broadcaster
        broadcaster.send(features.snapshot())

        // Metadata + cached parameter sets so the decoder can start.
        sendMetadata(on: conn)
        for param in [lastSPSFrame, lastPPSFrame] {
            guard let param else { continue }
            conn.send(content: IBWire.encode(frame: param),
                      completion: .contentProcessed { _ in })
        }

        if ProcessInfo.processInfo.environment["IBRIDGE_E2E_MIC"] == "1", !features.micOn {
            features.set(feature: .microphone, enabled: true)
        }
        syncMicrophone(features.micOn && !features.voiceOn)
        if ProcessInfo.processInfo.environment["IBRIDGE_E2E_INPUT"] == "1" {
            runE2EInputSequence()
        }
        // E2E: send a generated file so the receive + Finder-reveal
        // path is verifiable from the receiver log.
        if ProcessInfo.processInfo.environment["IBRIDGE_E2E_SEND_FILE"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                let data = Data(repeating: 0xAB, count: 1_500_000)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ibridge-e2e-file.bin")
                try? data.write(to: url)
                self?.sendFile(at: url)
            }
        }
        // E2E: push a known clipboard string so the Mac receive path is
        // verifiable from the receiver log.
        if ProcessInfo.processInfo.environment["IBRIDGE_E2E_CLIPBOARD"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                UIPasteboard.general.string = "iBridge-clipboard-e2e"
                self?.sendClipboard()
            }
        }
        // E2E: exercise the app switcher headlessly — request the Mac's
        // app list, then activate the app named in IBRIDGE_E2E_SWITCH
        // (a bundle id). The Mac log confirms "activated app …".
        if let target = ProcessInfo.processInfo.environment["IBRIDGE_E2E_SWITCH"], !target.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.requestMacApps()
                try? await Task.sleep(for: .seconds(2))
                self?.activateMacApp(id: target)
                FileHandle.standardError.write("[e2e] switch requested: \(target)\n".data(using: .utf8)!)
            }
        }

        parser.reset()
        startReceiving(from: conn)
    }

    private func handleCandidateState(_ state: NWConnection.State, token: UUID) {
        guard handshakeToken == token else { return }
        switch state {
        case .failed, .cancelled:
            handshakeTask?.cancel()
            candidate = nil
            candidateParser = nil
            if pendingConnection === candidate {
                pendingConnection = nil
                pendingHello = nil
                pendingMacName = nil
            }
        default:
            break
        }
    }

    private func replyBusy(on conn: NWConnection, ownerName: String) {
        Self.log.info("refusing Mac: \(ownerName, privacy: .public) already owns the session")
        conn.stateUpdateHandler = { _ in }
        conn.start(queue: queue)
        sendSessionReply(IBSessionReply(result: .busy, ownerName: ownerName), on: conn)
        queue.asyncAfter(deadline: .now() + 0.4) { conn.cancel() }
    }

    private func sendSessionReply(_ reply: IBSessionReply, on conn: NWConnection) {
        guard let data = try? IBWire.encode(sessionReply: reply) else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - UI actions (pairing)

    /// Approve the Mac currently waiting on the iPhone prompt.
    func approvePendingMac() {
        guard let conn = pendingConnection, let hello = pendingHello else { return }
        let mac = pairingStore.pair(hello)
        refreshPairedMacs()
        sendSessionReply(IBSessionReply(result: .accepted, token: mac.token), on: conn)
        grant(connection: conn, mac: mac)
    }

    /// Deny the waiting Mac and close its connection.
    func denyPendingMac() {
        guard let conn = pendingConnection else { return }
        sendSessionReply(IBSessionReply(result: .denied), on: conn)
        pendingConnection = nil
        pendingHello = nil
        pendingMacName = nil
        queue.asyncAfter(deadline: .now() + 0.4) { conn.cancel() }
    }

    /// Drop the current owner (settings / connected banner).
    func disconnectCurrentMac() {
        connection?.cancel()
        clearOwner()
    }

    func forgetPairedMac(id: String) {
        pairingStore.forget(id: id)
        refreshPairedMacs()
    }

    // MARK: - App switcher

    /// Ask the Mac for a fresh running-app list.
    func requestMacApps() {
        broadcaster?.send(IBAppListRequest())
    }

    /// Bring a Mac app to the front.
    func activateMacApp(id: String) {
        broadcaster?.send(IBActivateApp(id: id))
    }

    // MARK: - File transfer

    /// Stream a file to the Mac (offer → chunks → complete). Safe to
    /// call from any surface; a no-op when no Mac owns the session.
    func sendFile(at url: URL) {
        guard broadcaster != nil else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        let name = url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let offer = IBFileOffer(name: name, size: size)
        FileHandle.standardError.write("[e2e] sendFile \(name) size=\(size)\n".data(using: .utf8)!)
        broadcaster?.send(offer)
        fileTransferProgress = 0
        lastFileAck = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let self else { return }
            let broadcaster = await self.broadcaster
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                await self.finishFileSend(offer)
                return
            }
            var sent: Int64 = 0
            var lastReported = -1
            while true {
                let chunk = (try? handle.read(upToCount: 128 * 1024)) ?? Data()
                if chunk.isEmpty { break }
                broadcaster?.sendFileChunk(chunk)
                sent += Int64(chunk.count)
                if size > 0 {
                    let pct = Int(sent * 100 / size)
                    if pct / 5 != lastReported / 5 {
                        lastReported = pct
                        await self.setFileProgress(Double(sent) / Double(size))
                    }
                }
            }
            try? handle.close()
            await self.finishFileSend(offer)
        }
    }

    private func setFileProgress(_ value: Double) {
        fileTransferProgress = value
    }

    private func finishFileSend(_ offer: IBFileOffer) {
        broadcaster?.send(IBFileComplete(id: offer.id))
        fileTransferProgress = nil
    }

    func renamePairedMac(id: String, to name: String) {
        pairingStore.rename(id: id, to: name)
        refreshPairedMacs()
    }

    private func refreshPairedMacs() {
        pairedMacs = pairingStore.paired
    }

    /// E2E self-test: right after connect, emit a scripted touch-move
    /// burst plus one text event so the Mac side can prove CGEventPost
    /// injection really moves the cursor and types. Only runs when the
    /// app is launched with IBRIDGE_E2E_INPUT=1.
    private func runE2EInputSequence() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            for _ in 0..<10 {
                self.sendTouch(TouchEvent(phase: .move, dx: 0.02, dy: 0.02))
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.sendKey(KeyEvent(action: .text, text: "iBridge-e2e-OK"))
            FileHandle.standardError.write("[e2e] input sequence sent\n".data(using: .utf8)!)
        }
    }

    /// State changes for the granted owner connection.
    private func handleOwnerState(_ state: NWConnection.State, on conn: NWConnection) {
        guard connection === conn else { return }
        switch state {
        case .ready:
            break // grant() already set everything up.
        case .failed(let error):
            Self.log.error("connection failed: \(error, privacy: .public)")
            connectionState = .failed
            clearOwner()
        case .cancelled:
            connectionState = .idle
            clearOwner()
        default:
            break
        }
    }

    private func clearOwner() {
        broadcaster = nil
        audioEncoder?.stop()
        connection = nil
        ownerMac = nil
        connectedMacName = nil
    }

    // MARK: - Receiving (Mac → iPhone control)

    private func startReceiving(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.handleInbound(data)
                }
            }
            if error != nil { return }
            if !isComplete && self.connection != nil {
                self.startReceiving(from: connection)
            }
        }
    }

    private func handleInbound(_ data: Data) {
        for frame in parser.append(data) {
            switch frame.kind {
            case .featureControl:
                if let control = try? IBWire.decodeFeatureControl(frame) {
                    features.apply(control)
                }
            case .ping:
                broadcaster?.sendPingEcho(frame.payload)
            case .appList:
                if let list = try? IBWire.decodeAppList(frame) {
                    macApps = list.apps
                }
            case .clipboardSet:
                if let clip = try? IBWire.decodeClipboard(frame) {
                    UIPasteboard.general.string = clip.text
                }
            case .fileAck:
                if let ack = try? IBWire.decodeFileAck(frame) {
                    lastFileAck = ack
                    if ack.status == .saved || ack.status == .error {
                        fileTransferProgress = nil
                    } else if ack.status == .progress {
                        fileTransferProgress = ack.receivedBytes > 0 ? fileTransferProgress : 0
                    }
                }
            default:
                break // all other kinds are iPhone → Mac only
            }
        }
    }

    // MARK: - Feature state

    private func handleFeaturesChanged(_ snapshot: FeatureStateSnapshot) {
        broadcaster?.send(snapshot)
        syncMicrophone(snapshot.micOn && !snapshot.voiceOn)
    }

    private func syncMicrophone(_ enabled: Bool) {
        if enabled {
            if audioEncoder == nil {
                audioEncoder = MicrophoneEncoder()
            }
            if let broadcaster { audioEncoder?.start(broadcaster: broadcaster) }
        } else {
            audioEncoder?.stop()
        }
    }

    // MARK: - Sending

    private func sendMetadata(on connection: NWConnection) {
        do {
            let encoded = try IBWire.encode(metadata: metadata)
            connection.send(content: encoded, completion: .contentProcessed { error in
                if let error {
                    Self.log.error("metadata send error: \(error, privacy: .public)")
                }
            })
        } catch {
            Self.log.error("metadata encode error: \(error, privacy: .public)")
        }
    }

    private var e2eFrameCount = 0
    private var e2eFrameBytes = 0
    private var e2eDropCount = 0
    private var lastSPSFrame: IBNalFrame?
    private var lastPPSFrame: IBNalFrame?

    private func handleEncodedFrame(_ frame: IBNalFrame) {
        switch frame.kind {
        case .sps: lastSPSFrame = frame
        case .pps: lastPPSFrame = frame
        default: break
        }
        guard features.cameraOn else { return }
        guard let connection, connection.state == .ready else { return }
        let encoded = IBWire.encode(frame: frame)
        connection.send(content: encoded, completion: .contentProcessed { _ in })
        if ProcessInfo.processInfo.environment["IBRIDGE_AUTOSTREAM"] == "1" {
            e2eFrameCount += 1
            e2eFrameBytes += encoded.count
            if e2eFrameCount % 60 == 0 {
                FileHandle.standardError.write(
                    "[e2e] video frames sent: \(e2eFrameCount), bytes: \(e2eFrameBytes)\n"
                        .data(using: .utf8)!)
            }
        }
    }
}

extension IBStreamMetadata {
    @MainActor
    static func defaultConfig() -> IBStreamMetadata {
        IBStreamMetadata(
            deviceName: UIDevice.current.name,
            width: 1920,
            height: 1080,
            fps: 30,
            bitrateBps: 4_000_000
        )
    }
}