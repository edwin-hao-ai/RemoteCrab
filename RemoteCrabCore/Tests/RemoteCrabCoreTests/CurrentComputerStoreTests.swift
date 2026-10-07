import XCTest
@testable import RemoteCrabCore

final class CurrentComputerStoreTests: XCTestCase {

    private func store(_ name: String = #function) -> (MacPairingStore, UserDefaults) {
        let d = UserDefaults(suiteName: "test.current.\(name)")!
        d.removePersistentDomain(forName: "test.current.\(name)")
        return (MacPairingStore(defaults: d, key: "k"), d)
    }

    func testCurrentDefaultsToNil() {
        let (s, _) = store()
        XCTAssertNil(s.current)
        XCTAssertNil(s.currentId)
    }

    func testSetCurrentPersistsAcrossReload() {
        let (s, d) = store()
        s.setCurrent(id: "pc-1", name: "Living room PC")
        let reloaded = MacPairingStore(defaults: d, key: "k")
        XCTAssertEqual(reloaded.currentId, "pc-1")
        XCTAssertEqual(reloaded.current?.name, "Living room PC")
    }

    func testCurrentResolvesToThePairedRecordWhenPresent() {
        let (s, _) = store()
        let hello = IBClientHello(name: "MacBook", id: "mac-1", token: "t")
        let mac = s.pair(hello)
        s.setCurrent(id: mac.id, name: mac.name)
        XCTAssertEqual(s.current?.token, mac.token)
    }

    func testForgetClearsCurrent() {
        let (s, _) = store()
        s.setCurrent(id: "pc-1", name: "PC")
        s.forget(id: "pc-1")
        XCTAssertNil(s.current)
    }

    func testRemoveAllClearsCurrent() {
        let (s, _) = store()
        s.setCurrent(id: "pc-1", name: "PC")
        s.removeAll()
        XCTAssertNil(s.current)
    }

    /// Rule 2: a blob from a build without these keys loads unchanged.
    func testOldBlobWithoutCurrentStillLoadsThePairing() {
        let (s, d) = store()
        let hello = IBClientHello(name: "MacBook", id: "mac-1", token: "t")
        let mac = s.pair(hello)
        // Simulate an old write: no current keys present at all.
        d.removeObject(forKey: "k.currentId")
        d.removeObject(forKey: "k.currentName")
        let reloaded = MacPairingStore(defaults: d, key: "k")
        XCTAssertEqual(reloaded.paired.first?.id, mac.id)
        XCTAssertNil(reloaded.current)
    }
}
