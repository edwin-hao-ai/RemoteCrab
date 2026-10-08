import XCTest
@testable import RemoteCrabCore

/// Forgetting a computer must survive a relaunch (spec §7.3): presence is live
/// Bonjour, so an online forgotten computer would otherwise reappear the moment
/// the app restarts. Re-pairing or explicitly picking it removes it again.
final class ForgottenComputersTests: XCTestCase {

    func testForgetThenContains() {
        var f = ForgottenComputers()
        XCTAssertFalse(f.contains("mac-a"))
        f.forget("mac-a")
        XCTAssertTrue(f.contains("mac-a"))
    }

    func testRememberRemoves() {
        var f = ForgottenComputers(ids: ["mac-a", "mac-b"])
        f.remember("mac-a")
        XCTAssertFalse(f.contains("mac-a"))
        XCTAssertTrue(f.contains("mac-b"))
    }

    func testIdsRoundTripAsASet() {
        // Whatever the persisted representation, decoding the ids back must
        // preserve the exact set — a forgotten computer that does not reload is
        // indistinguishable from one that was never forgotten.
        let f = ForgottenComputers(ids: ["mac-a", "mac-b"])
        XCTAssertEqual(ForgottenComputers(ids: f.ids), f)
    }

    func testRememberingAnAbsentIdIsANoop() {
        var f = ForgottenComputers()
        f.remember("never-forgotten")
        XCTAssertEqual(f, ForgottenComputers())
    }
}
