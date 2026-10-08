import XCTest
@testable import RemoteCrabCore

/// The inbound (phone-initiated) admission rule. An unauthenticated LAN peer
/// can read the advertised id and open the presence port itself, so the
/// decision to grant input injection must be a tested function, not a
/// fall-through in a socket handler.
final class InboundGrantPolicyTests: XCTestCase {

    // MARK: - Paired phone: proof or nothing

    func testPairedPhoneWithValidProofIsGranted() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: true, challenge: .proven,
                                      firstContactApproved: false),
            .grant)
    }

    func testPairedPhoneWithBareAcceptedIsRefused() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: true, challenge: .notOffered,
                                      firstContactApproved: false),
            .refuse)
    }

    func testPairedPhoneWithNoKeyIsRefused() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: true, challenge: .noKey,
                                      firstContactApproved: false),
            .refuse)
    }

    /// A first-contact approval must not rescue a paired phone that could not
    /// prove itself — the approval prompt is only ever raised for an unpaired
    /// phone, so this combination means the caller mis-wired the flow.
    func testPairedPhoneIsRefusedEvenIfApprovalFlagIsSet() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: true, challenge: .notOffered,
                                      firstContactApproved: true),
            .refuse)
    }

    // MARK: - Unpaired phone: first contact needs the receiver's user

    func testUnpairedAcceptedWithoutApprovalPrompts() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: false, challenge: .notOffered,
                                      firstContactApproved: false),
            .promptFirstContact)
    }

    func testUnpairedWithAKeyThisReceiverLacksStillPrompts() {
        // The phone thinks it is paired (it offered a MAC) but this receiver
        // has lost the token. Re-pairing is the way back, so it prompts rather
        // than being refused like an impostor.
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: false, challenge: .noKey,
                                      firstContactApproved: false),
            .promptFirstContact)
    }

    func testUnpairedWithApprovalIsGranted() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: false, challenge: .notOffered,
                                      firstContactApproved: true),
            .grant)
    }

    // MARK: - A failed challenge is always refused

    func testFailedChallengeIsRefusedWhetherPairedOrNot() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: true, challenge: .failed,
                                      firstContactApproved: true),
            .refuse)
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: false, challenge: .failed,
                                      firstContactApproved: true),
            .refuse)
    }
}
