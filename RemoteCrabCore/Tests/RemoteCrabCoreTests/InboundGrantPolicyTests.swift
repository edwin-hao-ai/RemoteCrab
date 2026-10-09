import XCTest
@testable import RemoteCrabCore

/// The inbound (phone-initiated) admission rule.
///
/// The user's tap in the phone's picker is the consent, so the receiver does
/// not add a second hidden gate: every outcome except a *wrong proof* is
/// admitted. Only a proof that does not match a paired token — an impersonation
/// attempt on an existing pairing — is refused.
final class InboundGrantPolicyTests: XCTestCase {

    func testProvenIsGranted() {
        XCTAssertEqual(InboundGrantPolicy.decide(challenge: .proven), .grant)
    }

    /// A reinstalled app / new phone / lost token offers no proof. The phone's
    /// own confirmation card is the consent, so it is admitted (and re-paired
    /// with the token it sends).
    func testNotOfferedIsGranted() {
        XCTAssertEqual(InboundGrantPolicy.decide(challenge: .notOffered), .grant)
    }

    /// The phone holds a token this receiver does not know — a re-pair. Admitted.
    func testNoKeyIsGranted() {
        XCTAssertEqual(InboundGrantPolicy.decide(challenge: .noKey), .grant)
    }

    /// The one refusal: a proof that does not match the paired token. That is an
    /// impersonation attempt on an existing pairing, not a re-pair.
    func testFailedIsRefused() {
        XCTAssertEqual(InboundGrantPolicy.decide(challenge: .failed), .refuse)
    }
}
