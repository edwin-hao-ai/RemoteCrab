import Foundation
import Network
import os
import SwiftUI
import VideoToolbox
import iBridgeCore

/// The Mac-side counterpart to iOS `CaptureEngine`. Browses for the
/// Bonjour service, opens the first connection it sees, decodes H.264
/// frames via VideoToolbox, dispatches touch / key / audio events
/// to their respective handlers, and republishes the latest decoded
/// frame for the SwiftUI preview view.
@MainActor
final class ReceiverSession: ObservableObject {

    enum State: Equatable {
        case searching
        case connecting(name: String)
        case streaming(name: String, latencyMs: Int)
        case error(String)
    }

    @Published private(set) var state: State = .searching
    @Published private(set) var metadata: IBStreamMetadata?
    @Published private(set) var discovered: [DiscoveredPhone] = []

    /// The most recent decoded frame as a `CGImage` ready for display.
    @Published private(set) var latestFrame: CGImage?

    /// Latest feature-state snapshot from the iPhone. nil until the
    /// first `featureState` frame arrives (older iOS builds never
    /// send one — the UI must treat nil as "remote control unavailable").
    @Published private(set) var featureState: FeatureStateSnapshot?

    private var pingTimer: Timer?
    private static let log = Logger(subsystem: "com.ibridge", category: "receiver")

    let browser = BonjourBrowser()
    let decoder = H264Decoder()
    let parser = IBWire.Parser()

    /// Feeds a copy of every inbound NAL to the camera extension.
    /// Falls back to a no-op when the extension isn't reachable.
    let cameraBridge = CameraExtensionBridge(
        mode: .xpc(machServiceName: IBridgeCameraXPC.machServiceName)
    )

    /// Where `TouchEvent` / `KeyEvent` get posted. Defaults to a no-op
    /// mock; the host wires up a real `CGEventInjector` (or a recording
    /// one in tests).
    var inputInjector: InputInjector = RecordingInputInjector()

    /// Where `AudioPacket` get played through Mac speakers.
    let audioPlayer = AudioPlayer()

    private var connection: NWConnection?

    init() {
        decoder.onDecoded = { [weak self] image in
            Task { @MainActor in
                self?.latestFrame = image
            }
        }
        Task { [cameraBridge] in
            try? await cameraBridge.start(sink: NullFrameSink())
        }
        audioPlayer.start()
    }

    // MARK: - Discovery

    func start() {
        browser.start(serviceType: IBServiceType.tcp) { [weak self] phones in
            Task { @MainActor in
                self?.handleDiscovered(phones)
            }
        }
    }

    /// Mac → iPhone: toggle a feature remotely. No-op when disconnected.
    func setFeature(_ feature: IBFeature, _ enabled: Bool) {
        guard let connection, connection.state == .ready else { return }
        do {
            let data = try IBWire.encode(featureControl: FeatureControl(feature: feature, enabled: enabled))
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            Self.log.error("featureControl encode failed: \(error, privacy: .public)")
        }
    }

    private func handleDiscovered(_ phones: [DiscoveredPhone]) {
        discovered = phones
        if connection == nil, let phone = phones.first {
            connect(to: phone)
        }
    }

    private func connect(to phone: DiscoveredPhone) {
        connection?.cancel()
        connection = nil

        state = .connecting(name: phone.name)

        let conn = NWConnection(
            host: NWEndpoint.Host(phone.endpoint),
            port: NWEndpoint.Port(rawValue: phone.port) ?? .any,
            using: NWParameters.tcp
        )
        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                self.handleConnectionState(newState)
            }
        }
        startReceiving(on: conn)
        conn.start(queue: .global())
        connection = conn
    }

    private func handleConnectionState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            if let name = currentPhoneName() {
                state = .streaming(name: name, latencyMs: 0)
            }
            if let connection {
                startPingLoop(on: connection)
            }
        case .failed(let error):
            stopPingLoop()
            state = .error("\(error)")
            featureState = nil
            connection = nil
            cameraBridge.streamStopped()
        case .cancelled:
            stopPingLoop()
            state = .searching
            featureState = nil
            connection = nil
            cameraBridge.streamStopped()
        default:
            break
        }
    }

    private func startPingLoop(on connection: NWConnection) {
        stopPingLoop()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self, weak connection] _ in
            guard let connection, connection.state == .ready else { return }
            let micros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            connection.send(content: IBWire.encodePing(sentMicros: micros),
                            completion: .contentProcessed { _ in })
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPingLoop() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func currentPhoneName() -> String? {
        connection?.endpoint.debugDescription
    }

    // MARK: - Receive loop

    private func startReceiving(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.handleInbound(data)
                }
            }
            if let error {
                Task { @MainActor in
                    self.state = .error("\(error)")
                }
                return
            }
            if !isComplete && self.connection != nil {
                self.startReceiving(on: connection)
            }
        }
    }

    private func handleInbound(_ data: Data) {
        let frames = parser.append(data)
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        for frame in frames {
            switch frame.kind {
            case .metadata:
                handleMetadata(frame.payload)
            case .sps:
                decoder.feedSPS(frame.payload)
                cameraBridge.feed(nalUnit: frame.payload, kind: Int(IBNalFrame.Kind.sps.rawValue))
            case .pps:
                decoder.feedPPS(frame.payload)
                cameraBridge.feed(nalUnit: frame.payload, kind: Int(IBNalFrame.Kind.pps.rawValue))
            case .video:
                decoder.feedVideo(frame.payload)
                cameraBridge.feed(nalUnit: frame.payload, kind: Int(IBNalFrame.Kind.video.rawValue))
            case .touch:
                if let event = try? IBWire.decodeTouch(frame) {
                    inputInjector.inject(touch: event, screenSize: screenSize)
                }
            case .key:
                if let event = try? IBWire.decodeKey(frame) {
                    inputInjector.inject(key: event)
                }
            case .audio:
                if let packet = try? IBWire.decodeAudio(frame) {
                    audioPlayer.consume(packet)
                }
            case .featureControl:
                // Mac → iPhone direction only; ignore if we ever receive one.
                break
            case .featureState:
                if let snap = try? IBWire.decodeFeatureState(frame) {
                    featureState = snap
                }
            case .ping:
                guard frame.payload.count == 8 else {
                    Self.log.warning("ping frame with malformed payload (\(frame.payload.count) bytes), skipping")
                    continue
                }
                let sentMicros = IBWire.decodePing(frame)
                let nowMicros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                let rttMs = Int((nowMicros &- sentMicros) / 1_000)
                if case .streaming(let name, _) = state {
                    state = .streaming(name: name, latencyMs: rttMs)
                }
            }
        }
    }

    private func handleMetadata(_ payload: Data) {
        do {
            let decoded = try JSONDecoder().decode(IBStreamMetadata.self, from: payload)
            metadata = decoded
            if let sps = decoded.sps { decoder.feedSPS(sps) }
            if let pps = decoded.pps { decoder.feedPPS(pps) }
            cameraBridge.updateFormat(width: decoded.width, height: decoded.height, fps: decoded.fps)
            cameraBridge.updateDeviceName(decoded.deviceName)
            if let sps = decoded.sps {
                cameraBridge.feed(nalUnit: sps, kind: Int(IBNalFrame.Kind.sps.rawValue))
            }
            if let pps = decoded.pps {
                cameraBridge.feed(nalUnit: pps, kind: Int(IBNalFrame.Kind.pps.rawValue))
            }
        } catch {
            Self.log.error("metadata decode failed: \(error, privacy: .public)")
        }
    }
}

struct DiscoveredPhone: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: String
    let port: UInt16

    static func == (lhs: DiscoveredPhone, rhs: DiscoveredPhone) -> Bool {
        lhs.id == rhs.id
    }
}