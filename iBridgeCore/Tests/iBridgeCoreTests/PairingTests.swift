import XCTest
@testable import iBridgeCore

/// Tests for the multi-Mac pairing handshake: wire round-trips,
/// the pure ownership policy, and the persisted allow-list.
final class PairingTests: XCTestCase {

    // MARK: - Wire round-trip

    func testRoundTripClientHelloWithoutToken() throws {
        let hello = IBClientHello(name: "Edwin's MacBook Pro", id: "mac-1", appVersion: "0.2")
        let encoded = try IBWire.encode(clientHello: hello)
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .clientHello)
        XCTAssertEqual(try IBWire.decodeClientHello(frames[0]), hello)
    }

    func testRoundTripClientHelloWithToken() throws {
        let hello = IBClientHello(name: "Mac mini", id: "mac-2", token: "tok-abc", appVersion: "0.2")
        let encoded = try IBWire.encode(clientHello: hello)
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(try IBWire.decodeClientHello(frames[0]), hello)
        XCTAssertEqual(try IBWire.decodeClientHello(frames[0]).token, "tok-abc")
    }

    func testRoundTripSessionReplyEachResult() throws {
        for result in [IBSessionReplyResult.accepted, .pending, .busy, .denied] {
            let reply = IBSessionReply(result: result, ownerName: "Mac A", token: "tok")
            let encoded = try IBWire.encode(sessionReply: reply)
            let frames = IBWire.Parser().append(encoded)

            XCTAssertEqual(frames[0].kind, .sessionReply)
            XCTAssertEqual(try IBWire.decodeSessionReply(frames[0]), reply)
        }
    }

    // MARK: - Policy

    private func pairedMac(id: String = "mac-1", name: String = "Mac A", token: String = "tok") -> PairedMac {
        PairedMac(id: id, name: name, pairedAt: Date(timeIntervalSince1970: 0), token: token)
    }

    func testUnknownMacIsPending() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "New", id: "mac-9"),
            paired: [],
            owner: nil
        )
        XCTAssertEqual(decision, .pending)
    }

    func testPairedMacWithCorrectTokenIsAccepted() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac A", id: "mac-1", token: "tok"),
            paired: [pairedMac()],
            owner: nil
        )
        XCTAssertEqual(decision, .accept)
    }

    func testPairedMacWithWrongTokenIsPending() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Impostor", id: "mac-1", token: "wrong"),
            paired: [pairedMac()],
            owner: nil
        )
        XCTAssertEqual(decision, .pending)
    }

    func testPairedMacWithoutTokenIsPending() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac A", id: "mac-1", token: nil),
            paired: [pairedMac()],
            owner: nil
        )
        XCTAssertEqual(decision, .pending)
    }

    func testOtherMacWhileOwnedIsBusy() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac B", id: "mac-2", token: "tok-b"),
            paired: [pairedMac(), pairedMac(id: "mac-2", name: "Mac B", token: "tok-b")],
            owner: pairedMac()
        )
        XCTAssertEqual(decision, .busy(ownerName: "Mac A"))
    }

    func testOwnerReconnectWithTokenIsAccepted() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac A", id: "mac-1", token: "tok"),
            paired: [pairedMac()],
            owner: pairedMac()
        )
        XCTAssertEqual(decision, .accept)
    }

    // MARK: - Store

    private func freshStore() -> MacPairingStore {
        let suite = "test.ibridge.pairing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return MacPairingStore(defaults: defaults)
    }

    func testPairMintsTokenAndPersists() {
        let suite = "test.ibridge.pairing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = MacPairingStore(defaults: defaults)
        let mac = store.pair(IBClientHello(name: "Mac A", id: "mac-1"))
        XCTAssertFalse(mac.token.isEmpty)
        XCTAssertEqual(store.paired.count, 1)

        // A second store over the same defaults sees the pairing.
        let reloaded = MacPairingStore(defaults: defaults)
        XCTAssertEqual(reloaded.paired, store.paired)
    }

    func testRePairKeepsTokenAndUpdatesName() {
        let store = freshStore()
        let first = store.pair(IBClientHello(name: "Old Name", id: "mac-1"))
        let second = store.pair(IBClientHello(name: "New Name", id: "mac-1"))

        XCTAssertEqual(first.token, second.token)
        XCTAssertEqual(store.paired.count, 1)
        XCTAssertEqual(store.paired[0].name, "New Name")
    }

    func testForgetAndRename() {
        let store = freshStore()
        store.pair(IBClientHello(name: "Mac A", id: "mac-1"))
        store.pair(IBClientHello(name: "Mac B", id: "mac-2"))

        store.rename(id: "mac-1", to: "Renamed")
        XCTAssertEqual(store.paired.first(where: { $0.id == "mac-1" })?.name, "Renamed")

        store.forget(id: "mac-1")
        XCTAssertEqual(store.paired.map(\.id), ["mac-2"])
    }
}
