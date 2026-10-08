import XCTest
@testable import RemoteCrabCore

/// The receiver's pairing tokens used to be keyed by the phone's **name**.
///
/// A name is a display string, not an identity: two phones can share one, and
/// a user can rename theirs. The phone-initiated connection design gives every
/// phone a stable `phoneId`, so the receiver must look tokens up by id — but a
/// phone that paired before this change has its token stored under the old name
/// key only, and dropping it would force every existing user to re-approve.
///
/// `PeerTokenIndex` is that migration as a pure value: `token(phoneId:name:)`
/// answers from the id table when it can, falls back to the name key when it
/// cannot, and **backfills the id entry on a name hit** so the next lookup no
/// longer needs the name.
final class PeerTokenIndexTests: XCTestCase {

    // MARK: - Legacy name → id migration

    func testNameKeyedLegacyTokenMigratesToId() {
        var idx = PeerTokenIndex(byPhoneId: [:], byName: ["Edwin's iPhone": "old-token"], phoneInitiated: [])
        XCTAssertEqual(idx.token(phoneId: "phone-uuid", name: "Edwin's iPhone"), "old-token")
        XCTAssertEqual(idx.byPhoneId["phone-uuid"], "old-token", "命中后要 backfill 到 id 表")
    }

    func testIdKeyWinsOverNameKey() {
        var idx = PeerTokenIndex(byPhoneId: ["p1": "id-token"],
                                 byName: ["Phone": "name-token"], phoneInitiated: [])
        XCTAssertEqual(idx.token(phoneId: "p1", name: "Phone"), "id-token")
    }

    func testTokenNilWhenNeitherKeyPresent() {
        var idx = PeerTokenIndex()
        XCTAssertNil(idx.token(phoneId: "p1", name: "Phone"))
    }

    // MARK: - set

    func testSetStoresUnderBothKeys() {
        var idx = PeerTokenIndex()
        idx.set(phoneId: "p1", name: "Phone", token: "t")
        XCTAssertEqual(idx.byPhoneId["p1"], "t")
        XCTAssertEqual(idx.byName["Phone"], "t")
        XCTAssertEqual(idx.token(phoneId: "p1", name: "Phone"), "t")
    }

    func testSetKeepsLaterLegacyLookupsWorking() {
        // A brand-new pair records both keys, so an older name-only lookup
        // path against the same index still resolves.
        var idx = PeerTokenIndex()
        idx.set(phoneId: "p1", name: "Phone", token: "fresh")
        XCTAssertEqual(idx.token(phoneId: "other-id", name: "Phone"), "fresh")
    }

    // MARK: - phone-initiated flag

    func testPhoneInitiatedFlagPersists() {
        var idx = PeerTokenIndex(byPhoneId: [:], byName: [:], phoneInitiated: [])
        XCTAssertFalse(idx.isPhoneInitiated(phoneId: "p1"))
        idx.markPhoneInitiated(phoneId: "p1")
        XCTAssertTrue(idx.isPhoneInitiated(phoneId: "p1"))
        idx.forget(phoneId: "p1")
        XCTAssertFalse(idx.isPhoneInitiated(phoneId: "p1"))
    }

    // MARK: - forget

    func testForgetRemovesIdTokenAndFlag() {
        var idx = PeerTokenIndex(byPhoneId: ["p1": "t"], byName: ["Phone": "t"],
                                 phoneInitiated: ["p1"])
        idx.forget(phoneId: "p1")
        XCTAssertNil(idx.byPhoneId["p1"])
        XCTAssertFalse(idx.isPhoneInitiated(phoneId: "p1"))
    }

    func testForgetLeavesOtherPhonesAlone() {
        var idx = PeerTokenIndex(byPhoneId: ["p1": "t1", "p2": "t2"],
                                 byName: [:], phoneInitiated: ["p1", "p2"])
        idx.forget(phoneId: "p1")
        XCTAssertEqual(idx.byPhoneId["p2"], "t2")
        XCTAssertTrue(idx.isPhoneInitiated(phoneId: "p2"))
    }

    // MARK: - value semantics

    func testValueSemanticsDoNotShareStorage() {
        var a = PeerTokenIndex(byPhoneId: ["p1": "t"], byName: [:], phoneInitiated: ["p1"])
        var b = a
        b.forget(phoneId: "p1")
        b.markPhoneInitiated(phoneId: "p2")
        XCTAssertEqual(a.byPhoneId["p1"], "t")
        XCTAssertEqual(b.byPhoneId["p1"], nil)
        XCTAssertTrue(a.isPhoneInitiated(phoneId: "p1"))
        XCTAssertFalse(a.isPhoneInitiated(phoneId: "p2"))
    }

    func testDefaultInitIsEmpty() {
        let idx = PeerTokenIndex()
        XCTAssertTrue(idx.byPhoneId.isEmpty)
        XCTAssertTrue(idx.byName.isEmpty)
        XCTAssertTrue(idx.phoneInitiated.isEmpty)
    }
}
