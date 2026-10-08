import XCTest
@testable import RemoteCrabCore

final class ComputerRosterTests: XCTestCase {
    private func seen(_ id: String, _ name: String, _ platform: String, _ t: TimeInterval) -> SeenComputer {
        SeenComputer(id: id, name: name, platform: platform, lastSeen: Date(timeIntervalSince1970: t))
    }
    private func live(_ id: String, _ name: String, _ platform: String) -> ComputerPresence {
        ComputerPresence(id: id, name: name, platform: platform)
    }

    func testAnOnlineComputerIsOnline() {
        let entries = ComputerRoster.entries(online: [live("a", "iMac", "macos")], seen: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].state, .online)
        XCTAssertTrue(entries[0].isOnline)
    }

    func testKnownButNotAnnouncingIsOfflineWithLastSeen() {
        let s = seen("a", "iMac", "macos", 100)
        let entries = ComputerRoster.entries(online: [], seen: [s])
        XCTAssertEqual(entries[0].state, .offline(lastSeen: s.lastSeen))
        XCTAssertFalse(entries[0].isOnline)
    }

    func testDeduplicatesByIdNotName() {
        // Two computers sharing a name must NOT collapse (lesson 135).
        let entries = ComputerRoster.entries(
            online: [live("a", "EDWIN", "macos"), live("b", "EDWIN", "windows")],
            seen: [seen("a", "EDWIN", "macos", 1), seen("b", "EDWIN", "windows", 2)])
        XCTAssertEqual(entries.count, 2)
    }

    func testLiveBeatsHistoryForTheSameId() {
        let entries = ComputerRoster.entries(
            online: [live("a", "Studio Mac", "macos")],
            seen: [seen("a", "Old Name", "macos", 100)])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Studio Mac")
        XCTAssertEqual(entries[0].state, .online)
    }

    func testOnlineFirstThenMostRecentlySeen() {
        let entries = ComputerRoster.entries(
            online: [live("on1", "Zed", "macos")],
            seen: [seen("off1", "Old", "macos", 100), seen("off2", "Newer", "windows", 200)])
        XCTAssertEqual(entries.map(\.id), ["on1", "off2", "off1"])
    }

    func testEmptyRosterIsEmpty() {
        XCTAssertTrue(ComputerRoster.entries(online: [], seen: []).isEmpty)
    }

    // MARK: - name(for:online:seen:)

    /// A brand-new computer is only in the live browse results (it has never
    /// sent a `clientHello`, so it is not in `seen`). Arming a switch to it must
    /// resolve its name from presence — this is the "pair a new computer" path
    /// the 10-07 current-computer design depends on.
    func testNameResolvesAnOnlineComputerNotYetInHistory() {
        XCTAssertEqual(
            ComputerRoster.name(for: "b", online: [live("b", "Windows PC", "windows")], seen: []),
            "Windows PC")
    }

    func testNameFallsBackToHistoryWhenNotOnline() {
        XCTAssertEqual(
            ComputerRoster.name(for: "a", online: [], seen: [seen("a", "Old Mac", "macos", 100)]),
            "Old Mac")
    }

    func testOnlineNameBeatsHistory() {
        XCTAssertEqual(
            ComputerRoster.name(for: "a",
                                online: [live("a", "New Name", "macos")],
                                seen: [seen("a", "Old Name", "macos", 100)]),
            "New Name")
    }

    func testNameIsNilWhenTheComputerIsUnknown() {
        XCTAssertNil(ComputerRoster.name(for: "x", online: [], seen: []))
    }

    // MARK: - N-computer invariants (store + policy)
    //
    // With N computers on the network: every one is listed, only the owner is
    // served, and `forget` removes a computer from every list it appears on.
    // These are the "N computers never steal or collapse into one" guarantees
    // that would otherwise only be exercised by hand on a real LAN.

    func testTenComputersAllListed() {
        let store = MacPairingStore(defaults: UserDefaults(suiteName: "roster-\(UUID())")!)
        for i in 0..<10 {
            let hello = IBClientHello(name: "PC\(i)", id: "id-\(i)", token: nil,
                                      appVersion: "1", platform: "windows")
            store.noteSeen(hello)
        }
        XCTAssertEqual(store.seen.count, 10)
        // By id, not collapsed by name — none share an id or a name here.
        XCTAssertEqual(Set(store.seen.map(\.id)).count, 10)
    }

    func testOnlyChosenIsAcceptedRestBusy() {
        let chosen = PairedMac(id: "id-3", name: "PC3", token: "t3")
        let others = (0..<10).filter { $0 != 3 }.map {
            PairedMac(id: "id-\($0)", name: "PC\($0)", token: "t\($0)")
        }
        let all = [chosen] + others
        for o in others {
            let hello = IBClientHello(name: o.name, id: o.id, token: o.token, appVersion: "1")
            XCTAssertEqual(PairingPolicy.decide(hello: hello, paired: all,
                                                owner: chosen, preferred: nil, disconnected: nil),
                           .busy(ownerName: chosen.name))
        }
        // The owner itself, presenting its valid token, is accepted.
        let ownerHello = IBClientHello(name: chosen.name, id: chosen.id,
                                       token: chosen.token, appVersion: "1")
        XCTAssertEqual(PairingPolicy.decide(hello: ownerHello, paired: all,
                                            owner: chosen, preferred: nil, disconnected: nil),
                       .accept)
    }

    func testForgetRemovesFromEveryList() {
        let store = MacPairingStore(defaults: UserDefaults(suiteName: "roster-forget-\(UUID())")!)
        store.pair(IBClientHello(name: "PC", id: "id-x", token: nil, appVersion: "1"))
        store.noteSeen(IBClientHello(name: "PC", id: "id-x", token: nil, appVersion: "1"))
        store.setPreferred(id: "id-x", name: "PC")
        store.markDisconnected(id: "id-x", name: "PC")
        store.setCurrent(id: "id-x", name: "PC")
        store.forget(id: "id-x")
        XCTAssertTrue(store.paired.isEmpty)
        XCTAssertFalse(store.seen.contains { $0.id == "id-x" })
        XCTAssertNil(store.preferredId)
        XCTAssertNil(store.disconnected)
        XCTAssertNil(store.currentId)
    }

    /// Forgetting the computer the phone is currently set to serve must clear
    /// `currentId` (and not trap) — otherwise a forgotten computer would keep
    /// owning the session. Store-level; the UI disconnect wiring is a later task.
    func testForgetCurrentComputerClearsCurrent() {
        let store = MacPairingStore(defaults: UserDefaults(suiteName: "roster-cur-\(UUID())")!)
        store.setCurrent(id: "id-cur", name: "PC-cur")
        XCTAssertEqual(store.currentId, "id-cur")

        store.forget(id: "id-cur")

        XCTAssertNil(store.currentId)
        XCTAssertNil(store.current)
    }
}
