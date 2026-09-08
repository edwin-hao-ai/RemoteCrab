import AVFoundation
import Combine
import Foundation
import Network
import UIKit
import VideoToolbox
import iBridgeCore

/// The brain of iBridgeCapture. Owns the camera, H.264 encoder, and
/// the Bonjour-published TCP listener. Pushes compressed NAL frames
/// out to whichever Mac connected first.
@MainActor
final class CaptureEngine: ObservableObject {

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

    private let encoder = H264Encoder()
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.ibridge.encoder")
    private var didConfigure = false

    // MARK: - Lifecycle

    /// Request permissions and start the AVCaptureSession. Called from
    /// the SwiftUI `.task` modifier on the root view.
    func startIfNeeded() async {
        guard !didConfigure else { return }
        didConfigure = true

        await requestPermissions()

        do {
            try configureCaptureSession()
            try await encoder.start { [weak self] frame in
                Task { @MainActor in
                    self?.handleEncodedFrame(frame)
                }
            }
        } catch {
            print("[iBridge] capture start failed: \(error)")
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

    func startStreaming() async {
        guard !isStreaming else { return }
        connectionState = .starting
        do {
            try startListener()
            isStreaming = true
        } catch {
            print("[iBridge] listener start failed: \(error)")
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
    }

    // MARK: - Setup

    private func requestPermissions() async {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        if !camera || !mic {
            print("[iBridge] permissions denied — camera=\(camera) mic=\(mic)")
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
        print("[iBridge] Bonjour publishing: \(IBServiceType.tcp) / \(defaultServiceName())")
    }

    private func defaultServiceName() -> String {
        "iBridge — \(UIDevice.current.name)"
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("[iBridge] listener ready")
        case .failed(let error):
            print("[iBridge] listener failed: \(error)")
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

        // Send the metadata frame immediately so the receiver can set up
        // its H.264 decoder.
        sendMetadata(on: connection)

        // Forward encoded frames to this connection from now on.
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectionState = .connected
            print("[iBridge] Mac connected")
        case .failed(let error):
            print("[iBridge] connection failed: \(error)")
            connectionState = .failed
        case .cancelled:
            connectionState = .idle
        default:
            break
        }
    }

    // MARK: - Sending

    private func sendMetadata(on connection: NWConnection) {
        do {
            let encoded = try IBWire.encode(metadata: metadata)
            connection.send(content: encoded, completion: .contentProcessed { error in
                if let error {
                    print("[iBridge] metadata send error: \(error)")
                }
            })
        } catch {
            print("[iBridge] metadata encode error: \(error)")
        }
    }

    private func handleEncodedFrame(_ frame: IBNalFrame) {
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