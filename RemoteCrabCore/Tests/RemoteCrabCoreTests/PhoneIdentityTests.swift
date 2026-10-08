import XCTest
@testable import RemoteCrabCore

final class PhoneIdentityTests: XCTestCase {

    private func freshStore(_ name: String = #function) -> (UserDefaults, String) {
        let suite = "phone-id.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    // These three pass `override: nil` explicitly: the default argument reads
    // the ambient `REMOTECRAB_E2E_PHONE_ID`, so under an e2e run they would
    // otherwise short-circuit generation/persistence and pass vacuously.
    func testFreshStoreGeneratesANonEmptyId() {
        let (defaults, _) = freshStore()
        XCTAssertFalse(PhoneIdentity.loadPhoneId(defaults: defaults, override: nil).isEmpty)
    }

    func testTwoCallsWithTheSameDefaultsReturnTheSameId() {
        let (defaults, _) = freshStore()
        XCTAssertEqual(PhoneIdentity.loadPhoneId(defaults: defaults, override: nil),
                       PhoneIdentity.loadPhoneId(defaults: defaults, override: nil))
    }

    /// The id must be *persisted*, not merely stable within one object: a
    /// second `UserDefaults` handle over the same suite is what a relaunch
    /// looks like.
    func testIdSurvivesAFreshStoreHandle() {
        let (first, suite) = freshStore()
        let id = PhoneIdentity.loadPhoneId(defaults: first, override: nil)

        let relaunched = UserDefaults(suiteName: suite)!
        XCTAssertEqual(PhoneIdentity.loadPhoneId(defaults: relaunched, override: nil), id)
    }

    func testOverrideWins() {
        let (defaults, _) = freshStore()
        XCTAssertEqual(PhoneIdentity.loadPhoneId(defaults: defaults, override: "e2e-phone"),
                       "e2e-phone")
    }

    /// The override is a test affordance and must not leak into the persisted
    /// id — a later launch without it has to fall back to a real identity.
    func testOverrideIsNotPersisted() {
        let (defaults, _) = freshStore()
        _ = PhoneIdentity.loadPhoneId(defaults: defaults, override: "e2e-phone")

        let generated = PhoneIdentity.loadPhoneId(defaults: defaults, override: nil)
        XCTAssertFalse(generated.isEmpty)
        XCTAssertNotEqual(generated, "e2e-phone")
    }

    func testBlankOverrideIsIgnored() {
        let (defaults, _) = freshStore()
        XCTAssertFalse(PhoneIdentity.loadPhoneId(defaults: defaults, override: "").isEmpty)
    }
}
