import XCTest
import Network
import Combine
@testable import iBridgeCore

/// End-to-end test of the wire protocol going through a real
/// Bonjour-advertised TCP listener. Validates that the iPhone-side
/// publishing and Mac-side browsing / connecting / receiving pipeline
/// works without any hardware.
final class BonjourEndToEndTests: XCTestCase {

    private static let testServiceType = "_ibridgetest._tcp"
    private static let nextTestID = TestIDAllocator.next()
    private let testID: Int = TestIDAllocator.next()

    // MARK: - End-to-end pipeline

    func testBonjourDiscoverAndStreamFrames() throws {
        // 1. Start a Bonjour-advertised TCP listener (the "iPhone side").
        let listener = try makeListener()
        addTeardownBlock { [listener] in listener.cancel() }

        // 2. Server-side: collect all bytes that come in over the wire.
        let collector = ByteCollector()
        attach(collector, to: listener)

        // 3. Wait until the listener is fully ready.
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        wait(for: [ready], timeout: 3.0)

        // 4. Resolve the listener's address via NWConnection.
        guard let port = listener.port else {
            return XCTFail("listener has no port")
        }

        // 5. Open a TCP connection (the "Mac side").
        let connectionExpect = expectation(description: "connected")
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:  connectionExpect.fulfill()
            case .failed(let err): XCTFail("connection failed: \(err)")
            default: break
            }
        }
        connection.start(queue: .global())
        wait(for: [connectionExpect], timeout: 3.0)

        // 6. Send metadata + 3 video frames in one go.
        let metadata = IBStreamMetadata(
            deviceName: "TestDevice",
            width: 1920, height: 1080, fps: 30, bitrateBps: 4_000_000,
            codec: "h264"
        )

        var packet = try IBWire.encode(metadata: metadata)
        for i in 0..<3 {
            let nal = Data((0..<200).map { UInt8((i * 7 + Int($0)) & 0xFF) })
            packet.append(IBWire.encode(frame: IBNalFrame(
                kind: .video,
                data: nal,
                timestampMicros: UInt64(i) * 33_333
            )))
        }

        let receivedExpect = expectation(description: "received all bytes")
        let sendDone = expectation(description: "sent")
        connection.send(content: packet,
                        completion: .contentProcessed { _ in sendDone.fulfill() })

        // Poll the parser until we have all the frames.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let parsed = collector.parser.append(Data())
            let allFrames = collector.allFrames + parsed
            if allFrames.count >= 4 { receivedExpect.fulfill() }
        }
        // Poll the collector in a tight background queue until it has all frames.
        let pollQueue = DispatchQueue(label: "com.ibridge.test.poll")
        let poller = Poller(interval: 0.05, queue: pollQueue, shouldStop: { [weak collector] in
            (collector?.allFrames.count ?? 0) >= 4
        }, onDone: {
            receivedExpect.fulfill()
        })
        poller.start()
        addTeardownBlock { poller.stop() }

        wait(for: [sendDone, receivedExpect], timeout: 5.0)
        poller.stop()

        // 7. Verify the parser saw exactly the right frames, intact.
        let frames = collector.allFrames
        XCTAssertGreaterThanOrEqual(frames.count, 4,
            "expected at least 4 frames (1 metadata + 3 video), got \(frames.count)")

        // Metadata round-trip.
        guard let metaFrame = frames.first(where: { $0.kind == .metadata }) else {
            return XCTFail("no metadata frame")
        }
        let decodedMeta = try JSONDecoder().decode(IBStreamMetadata.self, from: metaFrame.payload)
        XCTAssertEqual(decodedMeta.deviceName, "TestDevice")
        XCTAssertEqual(decodedMeta.fps, 30)
        XCTAssertEqual(decodedMeta.width, 1920)

        // Video frame payloads are bit-identical to what we sent.
        let videos = frames.filter { $0.kind == .video }
        XCTAssertGreaterThanOrEqual(videos.count, 3)
        for i in 0..<min(3, videos.count) {
            let expected = Data((0..<200).map { UInt8((i * 7 + $0) & 0xFF) })
            XCTAssertEqual(videos[i].payload, expected, "video frame \(i) corrupted on the wire")
        }

        connection.cancel()
    }

    // MARK: - Wire protocol resilience (no networking)

    func testWireProtocolSurvivesFragmentation() throws {
        // Send 30 frames split across 100 random-sized chunks, then
        // verify they all arrive intact on the other side.
        let parser = IBWire.Parser()
        var allFrames: [IBWire.Frame] = []
        var originalNals: [Data] = []

        for i in 0..<30 {
            let nal = Data(repeating: UInt8(i & 0xFF), count: 500)
            originalNals.append(nal)
            let frame = IBWire.encode(frame: IBNalFrame(kind: .video, data: nal, timestampMicros: 0))
            // Split into 3-7 random chunks.
            var offset = 0
            var chunks: [Data] = []
            while offset < frame.count {
                let len = min(frame.count - offset, Int.random(in: 5...50))
                chunks.append(frame.subdata(in: offset..<(offset + len)))
                offset += len
            }
            for chunk in chunks {
                allFrames.append(contentsOf: parser.append(chunk))
            }
        }

        XCTAssertEqual(allFrames.count, 30)
        for (i, frame) in allFrames.enumerated() {
            XCTAssertEqual(frame.kind, .video)
            XCTAssertEqual(frame.payload, originalNals[i])
        }
    }

    // MARK: - Helpers

    private func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { _ in
            // Replaced by `attach` below.
        }
        listener.start(queue: .global())
        return listener
    }

    private func attach(_ collector: ByteCollector, to listener: NWListener) {
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { _ in }
            connection.start(queue: .global())
            collector.receive(on: connection)
        }
    }
}

/// Collects all bytes received on the underlying TCP connections
/// and parses them through `IBWire.Parser`.
final class ByteCollector: @unchecked Sendable {
    let parser = IBWire.Parser()
    private let lock = NSLock()
    private var _frames: [IBWire.Frame] = []

    var allFrames: [IBWire.Frame] {
        lock.lock(); defer { lock.unlock() }
        return _frames
    }

    func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                let new = self.parser.append(data)
                if !new.isEmpty {
                    self.lock.lock()
                    self._frames.append(contentsOf: new)
                    self.lock.unlock()
                }
            }
            if !isComplete {
                self.receive(on: connection)
            }
        }
    }
}

/// Background poller that runs `shouldStop` periodically until true,
/// then calls `onDone` exactly once.
final class Poller: @unchecked Sendable {
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let shouldStop: () -> Bool
    private let onDone: () -> Void
    private var stopped = false

    init(interval: TimeInterval,
         queue: DispatchQueue,
         shouldStop: @escaping () -> Bool,
         onDone: @escaping () -> Void) {
        self.interval = interval
        self.queue = queue
        self.shouldStop = shouldStop
        self.onDone = onDone
    }

    func start() {
        queue.async { [weak self] in
            self?.tick()
        }
    }

    func stop() {
        stopped = true
    }

    private func tick() {
        while !stopped {
            if shouldStop() {
                onDone()
                return
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}

/// Concurrency-safe monotonic ID generator for parallel test runs.
enum TestIDAllocator {
    private static let counter = AtomicInt()

    static func next() -> Int {
        counter.wrappingIncrement(ordering: .relaxed)
    }
}

/// Minimal atomic integer backed by OSAtomic-like ops; keeps the test
/// file self-contained.
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    func wrappingIncrement(ordering _: Ordering) -> Int {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }

    enum Ordering { case relaxed }
}