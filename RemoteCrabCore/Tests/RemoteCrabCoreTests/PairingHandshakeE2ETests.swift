import XCTest
import Network
@testable import RemoteCrabCore

/// End-to-end pairing handshake over a real TCP socket:
///
///   Mac (client)  ── clientHello ──►  iPhone (listener)
///                 ◄── sessionReply ──
///
/// Proves the new `0x0A`/`0x0B` frames survive the wire and that the
/// server-side policy decision is `accepted` for a known Mac.
final class PairingHandshakeE2ETests: XCTestCase {

    func testClientHelloOverTCPDecidesAccept() throws {
        let listener = try NWListener(using: NWParameters.tcp)
        let serverQueue = DispatchQueue(label: "com.remotecrab.test.pairing.server")
        let clientQueue = DispatchQueue(label: "com.remotecrab.test.pairing.client")
        let portRef = PortBox()

        let receivedHello = expectation(description: "server received hello")
        let replyReceived = expectation(description: "client received reply")
        let helloBox = Box<IBClientHello>()
        let replyBox = Box<IBSessionReply>()
        let ready = expectation(description: "listener ready")

        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port {
                portRef.value = port
                ready.fulfill()
            }
        }

        listener.newConnectionHandler = { conn in
            conn.start(queue: serverQueue)
            let parser = IBWire.Parser()
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        for frame in parser.append(data) where frame.kind == .clientHello {
                            guard let hello = try? IBWire.decodeClientHello(frame) else { continue }
                            helloBox.value = hello
                            receivedHello.fulfill()

                            let paired = [PairedMac(id: hello.id, name: hello.name, token: "tok-1")]
                            let decision = PairingPolicy.decide(hello: hello, paired: paired, owner: nil)
                            XCTAssertEqual(decision, .accept)
                            if let reply = try? IBWire.encode(sessionReply: IBSessionReply(result: .accepted, token: "tok-1")) {
                                conn.send(content: reply, completion: .contentProcessed { _ in })
                            }
                            return
                        }
                    }
                    if error != nil || isComplete { return }
                    receive()
                }
            }
            receive()
        }

        listener.start(queue: .global())
        wait(for: [ready], timeout: 3)

        let client = NWConnection(host: NWEndpoint.Host("127.0.0.1"),
                                  port: portRef.value ?? .any,
                                  using: NWParameters.tcp)
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            if let data = try? IBWire.encode(clientHello: IBClientHello(name: "Test Mac", id: "mac-e2e", token: "tok-1")) {
                client.send(content: data, completion: .contentProcessed { _ in })
            }
            let parser = IBWire.Parser()
            func receive() {
                client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        for frame in parser.append(data) where frame.kind == .sessionReply {
                            guard let reply = try? IBWire.decodeSessionReply(frame) else { continue }
                            replyBox.value = reply
                            replyReceived.fulfill()
                            return
                        }
                    }
                    if error != nil || isComplete { return }
                    receive()
                }
            }
            receive()
        }
        client.start(queue: clientQueue)

        wait(for: [receivedHello, replyReceived], timeout: 5)
        XCTAssertEqual(helloBox.value?.id, "mac-e2e")
        XCTAssertEqual(helloBox.value?.name, "Test Mac")
        XCTAssertEqual(replyBox.value?.result, .accepted)
        XCTAssertEqual(replyBox.value?.token, "tok-1")

        client.cancel()
        listener.cancel()
    }

    /// The audit found the Swift suite only ever tests ONE connection. The bug
    /// class that survives one-connection tests is persistence across a
    /// restart: the Windows receiver shipped a "the token was never persisted"
    /// bug that no single-connection test could catch. This spans the boundary
    /// — pair, rebuild the store (simulated relaunch) from the SAME defaults,
    /// and assert the token is still there and a reconnect is accepted.
    func testAPairedTokenSurvivesRestartAndReconnectIsAccepted() {
        let suite = "pairing-restart-\(UUID().uuidString)"
        let mac = MacPairingStore(defaults: UserDefaults(suiteName: suite)!)
            .pair(IBClientHello(name: "Mac R", id: "mac-r", token: nil))
        XCTAssertFalse(mac.token.isEmpty)

        let afterRestart = MacPairingStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(afterRestart.paired.first(where: { $0.id == "mac-r" })?.token, mac.token,
                       "token did not survive a restart")

        let hello = IBClientHello(name: "Mac R", id: "mac-r", token: mac.token)
        XCTAssertEqual(PairingPolicy.decide(hello: hello, paired: afterRestart.paired, owner: nil), .accept)
    }
}

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NWEndpoint.Port?
    var value: NWEndpoint.Port? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Minimal lock-box so the NW callbacks can hand values back to the test.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
