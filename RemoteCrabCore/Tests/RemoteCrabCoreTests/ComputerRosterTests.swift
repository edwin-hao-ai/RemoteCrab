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
}
