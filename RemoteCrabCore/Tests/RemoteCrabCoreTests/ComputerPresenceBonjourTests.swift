import XCTest
import Network
@testable import RemoteCrabCore

final class ComputerPresenceBonjourTests: XCTestCase {
    /// The TXT contract, as data. Pure, so it is asserted regardless of host
    /// networking and pins the exact keys the Windows side must match.
    func testPresenceTXTRecordHasTheFrozenKeys() {
        let record = IBServiceType.PresenceTXT.record(id: "id-1", name: "Test Mac", platform: "windows")
        XCTAssertEqual(record, ["id": "id-1", "name": "Test Mac", "platform": "windows"])
    }

    /// Proves the presence service is discoverable with its TXT on a real
    /// Bonjour stack. **Skips on hosts where the process cannot browse its own
    /// advertisement** (the swift-test CLI has no local-network TCC grant, and
    /// `NWBrowser` does not reliably discover an `NWListener` in the same
    /// process — the package's other Bonjour test connects to `127.0.0.1`
    /// directly for the same reason). When the host *can* browse, it asserts the
    /// TXT; when it cannot, it skips with that reason rather than passing
    /// vacuously. The live path is verified on-device (Task 9) and via
    /// `dns-sd -B _remotecrab-computer._tcp` against the running Mac receiver.
    func testABrowserFindsThePresenceAndItsTXT() throws {
        let txt = NWTXTRecord(IBServiceType.PresenceTXT.record(id: "id-1", name: "Test Mac", platform: "macos"))
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: "presence-test-\(UUID().uuidString)",
                                              type: IBServiceType.computer,
                                              domain: IBServiceType.domain,
                                              txtRecord: txt)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)

        let box = RecordBox()
        let browser = NWBrowser(for: .bonjour(type: IBServiceType.computer, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case let .bonjour(record) = result.metadata,
                   record.dictionary[IBServiceType.PresenceTXT.id] == "id-1" {
                    box.set(record.dictionary)
                    return
                }
            }
        }
        browser.start(queue: .global())

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if box.get() != nil { break }
            usleep(100_000)
        }
        browser.cancel()
        listener.cancel()

        guard let record = box.get() else {
            throw XCTSkip("this host cannot browse its own same-process Bonjour advertisement; live presence is verified on-device (Task 9)")
        }
        XCTAssertEqual(record[IBServiceType.PresenceTXT.name], "Test Mac")
        XCTAssertEqual(record[IBServiceType.PresenceTXT.platform], "macos")
    }
}

/// A locked box for the browse callback's result (Swift 6 forbids mutating a
/// captured `var` from a concurrent closure).
private final class RecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: String]?
    func set(_ v: [String: String]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [String: String]? { lock.lock(); defer { lock.unlock() }; return value }
}
