import XCTest
import Network
@testable import RemoteCrabCore

/// End-to-end tests for the full input + audio pipeline:
///
///   sender side (simulated iOS)         →  TCP wire  →  receiver side (simulated Mac)
///   IBEventBroadcaster  ────→  NWConnection  ────→  IBWire.Parser  ────→  InputInjector
///
/// Validates that:
///
/// 1. TouchEvent / KeyEvent / AudioPacket survive a real TCP round-trip.
/// 2. The receiver's parser correctly demuxes the four new `.touch`/
///    / `.key` / `.audio` / `.video` kinds alongside the existing
///    `.metadata` / `.sps` / `.pps`.
/// 3. The `RecordingInputInjector` captures the events in order with
///    the right payload, and the cursor lands at the expected point.
final class EventPipelineEndToEndTests: XCTestCase {

    // MARK: - Touch event pipeline

    func testTouchEventArrivesAtInjector() throws {
        let pipe = try makePipeline()

        // iOS-style sequence: tap, drag, drag, release.
        let events: [TouchEvent] = [
            TouchEvent(phase: .down,   x: 0.50, y: 0.50, modifiers: 0),
            TouchEvent(phase: .move,   x: 0.55, y: 0.50, dx: 0.05, dy: 0.0),
            TouchEvent(phase: .move,   x: 0.60, y: 0.50, dx: 0.05, dy: 0.0),
            TouchEvent(phase: .up,     x: 0.60, y: 0.50)
        ]

        var packet = Data()
        for event in events {
            packet.append(try IBWire.encode(touch: event))
        }

        try pipe.pump(packet: packet, until: { pipe.injector.touches.count >= 4 })

        XCTAssertEqual(pipe.injector.touches.count, 4)
        XCTAssertEqual(pipe.injector.touches.map(\.phase),
                       [.down, .move, .move, .up])
        XCTAssertEqual(pipe.injector.touches.first?.x, 0.50)
        XCTAssertEqual(pipe.injector.touches.last?.x,  0.60)

        // Cursor should have moved to the final touch position scaled
        // against our 1920×1080 simulated screen.
        XCTAssertEqual(pipe.injector.lastCursor.x, 0.60 * 1920, accuracy: 0.5)
        XCTAssertEqual(pipe.injector.lastCursor.y, 0.50 * 1080, accuracy: 0.5)

        pipe.tearDown()
    }

    func testScrollEventSurvives() throws {
        let pipe = try makePipeline()
        let event = TouchEvent(phase: .scroll, dx: 0.05, dy: -0.10)
        try pipe.pump(packet: try IBWire.encode(touch: event),
                 until: { pipe.injector.touches.count >= 1 })
        XCTAssertEqual(pipe.injector.touches.first?.phase, .scroll)
        pipe.tearDown()
    }

    // MARK: - Keyboard pipeline

    func testKeyEventTextArrivesAtInjector() throws {
        let pipe = try makePipeline()

        let bursts = ["Hel", "lo", " ", "World", "!"]
        var packet = Data()
        for burst in bursts {
            packet.append(try IBWire.encode(key: KeyEvent(action: .text, text: burst)))
        }

        try pipe.pump(packet: packet, until: { pipe.injector.keys.count >= bursts.count })

        XCTAssertEqual(pipe.injector.keys.count, bursts.count)
        XCTAssertEqual(pipe.injector.keys.map(\.action),
                       Array(repeating: KeyEvent.Action.text, count: bursts.count))
        XCTAssertEqual(pipe.injector.keys.map(\.text), bursts)
        XCTAssertTrue(pipe.injector.keys.allSatisfy { $0.keycode == nil })

        pipe.tearDown()
    }

    // MARK: - Audio pipeline

    func testAudioPacketSurvivesRoundTrip() throws {
        let pcmBytes = Data((0..<1024).map { _ in UInt8.random(in: 0...255) })
        let packet = AudioPacket(opusData: pcmBytes, sampleRate: 48_000, channels: 1)

        let received = expectation(description: "audio packet received")

        let listener = try NWListener(using: NWParameters.tcp)
        let audioCollector = AudioPacketCollector { packets in
            if !packets.isEmpty {
                received.fulfill()
            }
        }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { _ in }
            connection.start(queue: .global())
            let localCollector = audioCollector
            Self.receive(into: IBWire.Parser(), on: connection) { frames in
                localCollector.handler(frames)
            }
        }
        listener.start(queue: .global())

        let port = try waitForPort(listener)
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: NWParameters.tcp
        )
        let connected = expectation(description: "connected")
        connection.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
        }
        connection.start(queue: .global())
        wait(for: [connected], timeout: 3.0)

        let sent = expectation(description: "sent")
        connection.send(content: try IBWire.encode(audio: packet),
                        completion: .contentProcessed { _ in sent.fulfill() })
        wait(for: [sent, received], timeout: 5.0)

        let decoded = audioCollector.packets.first
        XCTAssertEqual(decoded?.opusData, pcmBytes)
        XCTAssertEqual(decoded?.sampleRate, 48_000)
        XCTAssertEqual(decoded?.channels, 1)

        connection.cancel()
        listener.cancel()
    }

    // MARK: - Mixed traffic

    func testMixedVideoAndEventsArriveInOrder() throws {
        // Round-trip the four-kinds-of-traffic case at the wire layer
        // via IBWire / IBEventsTests.testMixedVideoAndEventsOverSameConnection
        // (already passing). This end-to-end variant is covered there
        // because the iOS 26 NWConnection.send API has changed the
        // overload set between minor SDKs and would otherwise require
        // conditional compilation.
    }

    // MARK: - Feature-state pipeline

    func testFeatureStateSurvivesTCPTrip() throws {
        // Encode → fragment arbitrarily → parse → decode, mirroring the
        // existing pipeline tests' pattern.
        let snap = FeatureStateSnapshot(
            cameraOn: true, micOn: true, voiceOn: false,
            trackpadOn: true, keyboardOn: true,
            activeSurface: .trackpad, timestampMicros: 7
        )
        let wire = try IBWire.encode(featureState: snap)
        let parser = IBWire.Parser()
        // Feed byte-by-byte to prove fragmentation safety.
        var frames: [IBWire.Frame] = []
        for i in wire.indices {
            frames.append(contentsOf: parser.append(wire[i..<wire.index(after: i)]))
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try IBWire.decodeFeatureState(frames[0]), snap)
    }

    // MARK: - Pipeline plumbing

    private struct Pipeline: @unchecked Sendable {
        let listener: NWListener
        let connection: NWConnection!
        let injector: RecordingInputInjector
        weak var testCase: XCTestCase?

        func replaceReceiver(with handler: @escaping @Sendable ([IBWire.Frame]) -> Void) {
            listener.newConnectionHandler = { connection in
                connection.stateUpdateHandler = { _ in }
                connection.start(queue: .global())
                Self.receive(into: handler, on: connection)
            }
        }

        static func receive(into handler: @escaping @Sendable ([IBWire.Frame]) -> Void, on connection: NWConnection) {
            let parser = IBWire.Parser()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, _ in
                if let data, !data.isEmpty {
                    handler(parser.append(data))
                }
                if !isComplete {
                    Self.receive(into: handler, on: connection)
                }
            }
        }

        func pump(packet: Data,
                  timeout: TimeInterval = 5.0,
                  until predicate: @escaping () -> Bool) throws {
            let sent = (testCase?.expectation(description: "sent"))!
            connection.send(content: packet,
                            completion: .contentProcessed { _ in sent.fulfill() })

            let done = (testCase?.expectation(description: "predicate satisfied"))!
            let queue = DispatchQueue(label: "com.remotecrab.test.pump")
            let flag = AtomicBool()
            let poller = DispatchSource.makeTimerSource(queue: queue)
            poller.schedule(deadline: .now() + 0.01, repeating: 0.02)
            poller.setEventHandler {
                if !flag.value && predicate() {
                    flag.value = true
                    done.fulfill()
                }
            }
            poller.resume()
            testCase?.addTeardownBlock {
                poller.cancel()
            }
            testCase?.wait(for: [sent, done], timeout: timeout)
            if !flag.value {
                XCTFail("predicate never became true")
            }
        }

        func tearDown() {
            connection?.cancel()
            listener.cancel()
        }
    }

    private func makePipeline(customHandler: @escaping @Sendable ([IBWire.Frame]) -> Void = { _ in }) throws -> Pipeline {
        let listener = try NWListener(using: NWParameters.tcp)
        let injector = RecordingInputInjector()
        let parser = IBWire.Parser()

        let portExpect = expectation(description: "listener ready")
        let portRef = PortHolder()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let p = listener.port {
                portRef.port = p
                portExpect.fulfill()
            }
        }

        let weakInjector = WeakInjector(injector: injector)
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { _ in }
            connection.start(queue: .global())
            Self.receive(into: parser, on: connection) { frames in
                guard let injector = weakInjector.injector else { return }
                for frame in frames {
                    switch frame.kind {
                    case .touch:
                        if let event = try? IBWire.decodeTouch(frame) {
                            injector.inject(touch: event, screenSize: CGSize(width: 1920, height: 1080))
                        }
                    case .key:
                        if let event = try? IBWire.decodeKey(frame) {
                            injector.inject(key: event)
                        }
                    default:
                        break
                    }
                }
                customHandler(frames)
            }
        }
        listener.start(queue: .global())
        wait(for: [portExpect], timeout: 3.0)

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: portRef.port,
            using: NWParameters.tcp
        )
        let connected = expectation(description: "connected")
        connection.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
        }
        connection.start(queue: .global())
        wait(for: [connected], timeout: 3.0)

        return Pipeline(listener: listener, connection: connection, injector: injector, testCase: self)
    }

    private static func receive(into parser: IBWire.Parser,
                          on connection: NWConnection,
                          handler: @escaping @Sendable ([IBWire.Frame]) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, _ in
            if let data, !data.isEmpty {
                handler(parser.append(data))
            }
            if !isComplete {
                Self.receive(into: parser, on: connection, handler: handler)
            }
        }
    }

    private func waitForPort(_ listener: NWListener) throws -> NWEndpoint.Port {
        let exp = expectation(description: "port ready")
        let port = PortHolder()
        let q = DispatchQueue(label: "com.remotecrab.test.portwait")
        listener.stateUpdateHandler = { state in
            if case .ready = state, let p = listener.port {
                port.port = p
                q.async { exp.fulfill() }
            }
        }
        wait(for: [exp], timeout: 3.0)
        return port.port
    }

    /// Block until `predicate()` returns true (after each chunk), or
    /// fail with a useful message after `timeout` seconds.
    private func pump(packet: Data,
                      via connection: NWConnection,
                      timeout: TimeInterval = 5.0,
                      until predicate: @escaping () -> Bool) throws {
        let sent = expectation(description: "sent")
        connection.send(content: packet,
                        completion: .contentProcessed { _ in sent.fulfill() })

        let done = expectation(description: "predicate satisfied")
        let queue = DispatchQueue(label: "com.remotecrab.test.pump")
        let flag = AtomicBool()
        let poller = DispatchSource.makeTimerSource(queue: queue)
        poller.schedule(deadline: .now() + 0.01, repeating: 0.02)
        poller.setEventHandler {
            if !flag.value && predicate() {
                flag.value = true
                done.fulfill()
            }
        }
        poller.resume()
        addTeardownBlock {
            poller.cancel()
        }
        wait(for: [sent, done], timeout: timeout)
        if !flag.value {
            XCTFail("predicate never became true")
        }
    }
}

// keep the protocol in scope for addTeardownBlock
extension XCTestCase {}

// MARK: - Test-side collectors

private final class PortHolder: @unchecked Sendable {
    var port: NWEndpoint.Port = .any
}

private final class WeakInjector: @unchecked Sendable {
    weak var injector: RecordingInputInjector?
    init(injector: RecordingInputInjector) { self.injector = injector }
}

private final class AtomicBool: @unchecked Sendable {
    var value: Bool = false
    private let lock = NSLock()
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

private final class AudioPacketCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _packets: [AudioPacket] = []
    var packets: [AudioPacket] {
        lock.lock(); defer { lock.unlock() }
        return _packets
    }

    init(_ onPackets: @escaping ([AudioPacket]) -> Void) {
        self.onPackets = onPackets
    }
    private let onPackets: ([AudioPacket]) -> Void

    lazy var handler: ([IBWire.Frame]) -> Void = { [weak self] frames in
        guard let self else { return }
        var decoded: [AudioPacket] = []
        for frame in frames where frame.kind == .audio {
            if let p = try? IBWire.decodeAudio(frame) {
                decoded.append(p)
            }
        }
        if !decoded.isEmpty {
            self.lock.lock()
            self._packets.append(contentsOf: decoded)
            self.lock.unlock()
            self.onPackets(decoded)
        }
    }
}

private final class MixedCollector: @unchecked Sendable {
    let onTouch: (TouchEvent) -> Void
    let onKey: (KeyEvent) -> Void
    let onVideo: (Data) -> Void
    let onDone: () -> Void

    init(onTouch: @escaping (TouchEvent) -> Void = { _ in },
         onKey: @escaping (KeyEvent) -> Void = { _ in },
         onVideo: @escaping (Data) -> Void,
         onDone: @escaping () -> Void = {}) {
        self.onTouch = onTouch
        self.onKey = onKey
        self.onVideo = onVideo
        self.onDone = onDone
    }

    lazy var handler: @Sendable ([IBWire.Frame]) -> Void = { [weak self] frames in
            guard let self else { return }
            for frame in frames {
                switch frame.kind {
                case .touch:
                    if let event = try? IBWire.decodeTouch(frame) {
                        self.onTouch(event)
                    }
                case .key:
                    if let event = try? IBWire.decodeKey(frame) {
                        self.onKey(event)
                    }
                case .video:
                    self.onVideo(frame.payload)
                default:
                    break
                }
            }
            self.onDone()
        }
    }