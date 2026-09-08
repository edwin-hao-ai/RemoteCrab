import Foundation
import Network
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

    let browser = BonjourBrowser()
    let decoder = H264Decoder()
    let parser = IBWire.Parser()

    /// Where `TouchEvent` / `KeyEvent` get posted. Defaults to a no-op
    /// mock; the host wires up a real `CGEventInjector` (or a recording
    /// one in tests).
    var inputInjector: InputInjector = RecordingInputInjector()

    /// Where `AudioPacket` get played through Mac speakers.
    let audioPlayer = AudioPlayer()

    private var connection: NWConnection?
    private var connectionStartedAt: Date?

    init() {
        decoder.onDecoded = { [weak self] image in
            Task { @MainActor in
                self?.latestFrame = image
            }
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
                self?.handleConnectionState(newState)
            }
        }
        startReceiving(on: conn)
        conn.start(queue: .global())
        connection = conn
    }

    private func handleConnectionState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            connectionStartedAt = Date()
            if let name = currentPhoneName() {
                state = .streaming(name: name, latencyMs: 0)
            }
        case .failed(let error):
            state = .error("\(error)")
            connection = nil
        case .cancelled:
            state = .searching
            connection = nil
        default:
            break
        }
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
            case .pps:
                decoder.feedPPS(frame.payload)
            case .video:
                decoder.feedVideo(frame.payload)
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
            }
        }

        if case .streaming(let name, _) = state, let startedAt = connectionStartedAt {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            state = .streaming(name: name, latencyMs: ms)
        }
    }

    private func handleMetadata(_ payload: Data) {
        do {
            let decoded = try JSONDecoder().decode(IBStreamMetadata.self, from: payload)
            metadata = decoded
            if let sps = decoded.sps { decoder.feedSPS(sps) }
            if let pps = decoded.pps { decoder.feedPPS(pps) }
        } catch {
            print("[iBridge] metadata decode failed: \(error)")
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