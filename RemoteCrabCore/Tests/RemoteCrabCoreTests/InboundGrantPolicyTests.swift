import XCTest
@testable import RemoteCrabCore

/// The inbound (phone-initiated) admission rule. An unauthenticated LAN peer
/// can read the advertised id and open the presence port itself, so the
/// decision to grant input injection must be a tested function, not a
/// fall-through in a socket handler.
final class InboundGrantPolicyTests: XCTestCase {

    // MARK: - Paired phone: proof, or a human-gated re-pair

    func testPairedPhoneWithValidProofIsGranted() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: true, challenge: .proven,
                                      firstContactApproved: false),
            .grant)
    }

    /// The receiver still has a token for this phone, but the phone offered no
    /// proof at all — a reinstalled app, a new phone, or a lost token. This is
    /// the case that must NOT be refused: refusing it made a reinstall
    /// unrecoverable, because the phone then minted a fresh token and the two
    /// ends disagreed about the token forever. The receiver's own user confirms
    /// the re-pair, exactly as for a first contact.
    func testPairedPhoneWithBareAcceptedPromptsToRepair() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: true, challenge: .notOffered,
                                      firstContactApproved: false),
            .promptFirstContact)
    }

    /// A proof this receiver cannot match — the phone holds a token this Mac
    /// does not — is a stale pairing too, not an impostor we can tell apart
    /// (the impostor and the reinstalled phone look identical here). So it is
    /// the receiver's user who decides, never a silent fall-through.
    func testPairedPhoneWithNoKeyPromptsToRepair() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: true, challenge: .noKey,
                                      firstContactApproved: false),
            .promptFirstContact)
    }

    /// With the receiver's user's approval the stale pairing is replaced (the
    /// phone's fresh token is stored when the candidate is adopted).
    func testPairedPhoneWithApprovalIsGrantedOnRepair() {
        XCTAssertEqual(
            InboundGrantPolicy.decide(paired: true, challenge: .notOffered,
                                      firstContactApproved: true),
            .grant)
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
