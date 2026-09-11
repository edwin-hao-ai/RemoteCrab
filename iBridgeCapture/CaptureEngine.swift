import AVFoundation
import Combine
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
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.ibridge.encoder")
    private var didConfigure = false

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

        await requestPermissions()

        do {
            try configureCaptureSession()
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
    func sendVoiceText(_ text: String) {
        broadcaster?.send(KeyEvent(action: .text, text: text))
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
        connection?.cancel()
        connection = nil
        isStreaming = false
        connectionState = .idle
        parser.reset()
        UIApplication.shared.isIdleTimerDisabled = false
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

    private func startListener() throws {
        let parameters = NWParameters.tcp

        let listener = try NWListener(using: parameters)
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

    private func defaultServiceName() -> String {
        "iBridge — \(UIDevice.current.name)"
    }

    private func handleListenerState(_ state: NWListener.State) {
        FileHandle.standardError.write("[e2e] listener state: \(state)\n".data(using: .utf8)!)
        switch state {
        case .ready:
            Self.log.info("listener ready")
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

    private func accept(connection: NWConnection) {
        // Drop any existing connection; we currently support one Mac at a time.
        self.connection?.cancel()
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }
        connection.start(queue: queue)
        startReceiving(from: connection)

        // Send the metadata frame immediately so the receiver can set up
        // its H.264 decoder.
        sendMetadata(on: connection)

        // Forward encoded frames to this connection from now on.
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectionState = .connected
            Self.log.info("Mac connected")
            // Build the event broadcaster now that we have a connection.
            if let connection {
                let b = IBEventBroadcaster(connection: connection, queue: queue)
                broadcaster = b
                // Tell the Mac the full feature state right away.
                b.send(features.snapshot())
                // Start mic only if the feature is on; the voice
                // recognizer owns the audio input while held.
                syncMicrophone(features.micOn && !features.voiceOn)
            }
        case .failed(let error):
            Self.log.error("connection failed: \(error, privacy: .public)")
            connectionState = .failed
            broadcaster = nil
            audioEncoder?.stop()
        case .cancelled:
            connectionState = .idle
            broadcaster = nil
            audioEncoder?.stop()
        default:
            break
        }
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

    private func handleEncodedFrame(_ frame: IBNalFrame) {
        guard features.cameraOn else { return }
        guard let connection, connection.state == .ready else { return }
        let encoded = IBWire.encode(frame: frame)
        connection.send(content: encoded, completion: .contentProcessed { _ in })
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