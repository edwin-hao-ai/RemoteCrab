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

    // MARK: - Connection test mirrors (read-only for the UI)

    /// Rolling tail of everything typed from the iPhone keyboard,
    /// truncated to the most recent 200 characters.
    @Published private(set) var typedText: String = ""
    /// The most recent `.down` / `.text` key event.
    @Published private(set) var lastKey: KeyEvent?
    /// The most recent touch event, mirrored for the test-board view.
    @Published private(set) var touchVisual: TouchVisual?
    /// Live microphone RMS level (0..1), ~10 Hz from `AudioPlayer`.
    @Published private(set) var micLevel: Float = 0
    /// The 30 most recent ping round-trip times, oldest first.
    @Published private(set) var latencyHistory: [Int] = []

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

    /// Where `TouchEvent` / `KeyEvent` get posted. Defaults to the real
    /// `CGEventInjector` so iPhone gestures drive the Mac cursor; tests
    /// swap in a `RecordingInputInjector`. UI mirroring for the test
    /// window happens in `handleInbound` before injection, so it works
    /// regardless of which injector is installed.
    var inputInjector: InputInjector = CGEventInjector()

    /// Where `AudioPacket` get played through Mac speakers.
    let audioPlayer = AudioPlayer()

    private var connection: NWConnection?
    /// Display name of the phone we're connected to (from Bonjour),
    /// kept so the UI never shows a raw IP:port endpoint string.
    private var connectedPhoneName: String?

    init() {
        decoder.onDecoded = { [weak self] image in
            Task { @MainActor in
                self?.latestFrame = image
            }
        }
        Task { [cameraBridge] in
            try? await cameraBridge.start(sink: NullFrameSink())
        }
        audioPlayer.onLevel = { [weak self] level in
            // onLevel fires on the audio player's private queue.
            Task { @MainActor in
                self?.micLevel = level
            }
        }
        audioPlayer.start()
        start()
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
        Self.log.info("discovered \(phones.count, privacy: .public) phone(s); connection==nil: \(self.connection == nil, privacy: .public)")
        if connection == nil, let phone = phones.first {
            connect(to: phone)
        }
    }

    private func connect(to phone: DiscoveredPhone) {
        connection?.cancel()
        connection = nil

        state = .connecting(name: phone.name)
        Self.log.info("connecting to \(phone.name, privacy: .public) (serviceEndpoint: \(phone.serviceEndpoint != nil, privacy: .public))")

        let conn: NWConnection
        if let serviceEndpoint = phone.serviceEndpoint {
            conn = NWConnection(to: serviceEndpoint, using: .tcp)
        } else {
            conn = NWConnection(
                host: NWEndpoint.Host(phone.endpoint),
                port: NWEndpoint.Port(rawValue: phone.port) ?? .any,
                using: NWParameters.tcp
            )
        }
        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                self.handleConnectionState(newState)
            }
        }
        startReceiving(on: conn)
        conn.start(queue: .global())
        connection = conn
        connectedPhoneName = phone.name
    }

    private func handleConnectionState(_ newState: NWConnection.State) {
        Self.log.info("connection state: \(String(describing: newState), privacy: .public)")
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
            clearConnectionState()
        case .cancelled:
            stopPingLoop()
            state = .searching
            clearConnectionState()
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
        connectedPhoneName
    }

    /// Wipe every piece of per-connection state when the link goes
    /// away: the feature snapshot, the test-window mirrors, and the
    /// stream state (metadata / last frame / latency) so no window
    /// keeps showing stale evidence of a dead connection.
    private func clearConnectionState() {
        featureState = nil
        connection = nil
        connectedPhoneName = nil
        metadata = nil
        latestFrame = nil
        latencyHistory = []
        cameraBridge.streamStopped()
        typedText = ""
        lastKey = nil
        touchVisual = nil
        micLevel = 0
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
                    touchVisual = TouchVisual(event: event)
                    inputInjector.inject(touch: event, screenSize: screenSize)
                }
            case .key:
                if let event = try? IBWire.decodeKey(frame) {
                    switch event.action {
                    case .text:
                        if let text = event.text {
                            typedText.append(text)
                            if typedText.count > 200 {
                                typedText = String(typedText.suffix(200))
                            }
                        }
                        lastKey = event
                    case .down:
                        lastKey = event
                    case .up:
                        break
                    }
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
                latencyHistory.append(rttMs)
                if latencyHistory.count > 30 {
                    latencyHistory.removeFirst(latencyHistory.count - 30)
                }
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

/// UI-friendly mirror of the most recent `TouchEvent`, consumed by
/// the connection test window's trackpad board. Coordinates stay
/// normalized 0..1 (no screen remapping).
struct TouchVisual: Equatable, Sendable {
    let phase: TouchEvent.Phase
    let x: Float
    let y: Float
    let dx: Float
    let dy: Float
    let modifiers: UInt8
    /// When the Mac received the event — drives the idle fade-out.
    let receivedAt: Date

    init(event: TouchEvent, receivedAt: Date = Date()) {
        phase = event.phase
        x = event.x
        y = event.y
        dx = event.dx
        dy = event.dy
        modifiers = event.modifiers
        self.receivedAt = receivedAt
    }
}

struct DiscoveredPhone: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: String
    let port: UInt16
    /// The raw Bonjour service endpoint. Connecting to this directly lets
    /// Network.framework resolve SRV/A records itself; the string fields
    /// above are for display and the pre-Bonjour fallback path only.
    let serviceEndpoint: NWEndpoint?

    static func == (lhs: DiscoveredPhone, rhs: DiscoveredPhone) -> Bool {
        lhs.id == rhs.id
    }
}