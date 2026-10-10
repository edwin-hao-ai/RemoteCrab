import XCTest
@testable import RemoteCrabCore

final class TokenStoreTests: XCTestCase {

    func testTokenLeavesTheCleartextJSONWhenAStoreIsSupplied() throws {
        let suite = "f2-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = InMemoryTokenStore()

        let macs = MacPairingStore(defaults: defaults, tokenStore: store)
        let mac = macs.pair(IBClientHello(name: "Mac", id: "m1", token: nil))
        XCTAssertFalse(mac.token.isEmpty)

        // The JSON no longer carries the token in the clear…
        let json = String(data: defaults.data(forKey: "remotecrab.ios.pairedMacs") ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains(mac.token))
        // …the store has it instead…
        XCTAssertEqual(store.token(for: "m1"), mac.token)
        // …and a reload restores it.
        let reloaded = MacPairingStore(defaults: defaults, tokenStore: store)
        XCTAssertEqual(reloaded.paired.first(where: { $0.id == "m1" })?.token, mac.token)
    }

    func testLegacyCleartextTokenIsMigratedWithoutLoss() throws {
        let suite = "f2-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let legacy = [PairedMac(id: "m2", name: "Mac", token: "legacy-tok")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "remotecrab.ios.pairedMacs")

        let store = InMemoryTokenStore()
        let macs = MacPairingStore(defaults: defaults, tokenStore: store)
        XCTAssertEqual(macs.paired.first?.token, "legacy-tok")   // nothing lost
        XCTAssertEqual(store.token(for: "m2"), "legacy-tok")     // migrated
        // …and the cleartext copy left storage immediately, not on the next save.
        let stored = try JSONDecoder().decode([PairedMac].self,
                                              from: defaults.data(forKey: "remotecrab.ios.pairedMacs")!)
        XCTAssertEqual(stored.first?.token, "")
    }

    func testForgetRemovesTheStoredToken() {
        let defaults = UserDefaults(suiteName: "f2-forget-\(UUID().uuidString)")!
        let store = InMemoryTokenStore()
        let macs = MacPairingStore(defaults: defaults, tokenStore: store)
        _ = macs.pair(IBClientHello(name: "Mac", id: "m3", token: nil))
        XCTAssertNotNil(store.token(for: "m3"))
        macs.forget(id: "m3")
        XCTAssertNil(store.token(for: "m3"))
    }

    func testNoStoreKeepsTheLegacyBehaviour() {
        // The default (no store) must be unchanged — this is what every
        // existing test and any non-app caller gets.
        let defaults = UserDefaults(suiteName: "f2-legacy-default-\(UUID().uuidString)")!
        let macs = MacPairingStore(defaults: defaults)
        let mac = macs.pair(IBClientHello(name: "Mac", id: "m4", token: nil))
        let reloaded = MacPairingStore(defaults: defaults)
        XCTAssertEqual(reloaded.paired.first(where: { $0.id == "m4" })?.token, mac.token)
    }
}
