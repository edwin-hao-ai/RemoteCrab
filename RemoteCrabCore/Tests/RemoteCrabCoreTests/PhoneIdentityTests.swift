import XCTest
@testable import RemoteCrabCore

final class PhoneIdentityTests: XCTestCase {

    private func freshStore(_ name: String = #function) -> (UserDefaults, String) {
        let suite = "phone-id.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testFreshStoreGeneratesANonEmptyId() {
        let (defaults, _) = freshStore()
        XCTAssertFalse(PhoneIdentity.loadPhoneId(defaults: defaults).isEmpty)
    }

    func testTwoCallsWithTheSameDefaultsReturnTheSameId() {
        let (defaults, _) = freshStore()
        XCTAssertEqual(PhoneIdentity.loadPhoneId(defaults: defaults),
                       PhoneIdentity.loadPhoneId(defaults: defaults))
    }

    /// The id must be *persisted*, not merely stable within one object: a
    /// second `UserDefaults` handle over the same suite is what a relaunch
    /// looks like.
    func testIdSurvivesAFreshStoreHandle() {
        let (first, suite) = freshStore()
        let id = PhoneIdentity.loadPhoneId(defaults: first)

        let relaunched = UserDefaults(suiteName: suite)!
        XCTAssertEqual(PhoneIdentity.loadPhoneId(defaults: relaunched), id)
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
