import XCTest
@testable import RemoteCrabCore

/// The headless-test-only auto-approval of an unpaired phone's first contact.
///
/// The first-contact prompt is a security gate: an unauthenticated LAN peer can
/// open the presence port itself, so the receiver must not grant it until its
/// user confirms. The e2e harness needs to run that grant without a click, but
/// the only property that matters here is that the opt-in is **inert** unless
/// the environment says exactly `"1"` — a stray presence, a `"0"`, or a `"true"`
/// must never approve a stranger's connection on a real user's Mac.
final class InboundAutoApproveTests: XCTestCase {

    func testInertWhenKeyIsAbsent() {
        XCTAssertFalse(InboundAutoApprove.isEnabled(in: [:]))
        XCTAssertFalse(InboundAutoApprove.isEnabled(in: ["REMOTECRAB_E2E_MAC_ID": "x"]))
    }

    func testInertForAnyValueOtherThanExactlyOne() {
        for value in ["0", "true", "yes", "", " 1", "1 "] {
            XCTAssertFalse(
                InboundAutoApprove.isEnabled(in: [InboundAutoApprove.environmentKey: value]),
                "\(InboundAutoApprove.environmentKey)=\(value.debugDescription) must not enable the hook")
        }
    }

    func testEnabledOnlyForExactlyOne() {
        XCTAssertTrue(InboundAutoApprove.isEnabled(in: [InboundAutoApprove.environmentKey: "1"]))
    }
}
