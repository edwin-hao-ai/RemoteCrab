import XCTest
@testable import RemoteCrabCore

/// A phone-initiated connection arrives at the receiver's presence/knock port
/// with no prior context. Its **first frame** is the only thing that can say
/// what the connection is, so the receiver must classify it before deciding
/// whether to run the server handshake or fall back to the legacy knock.
///
/// `InboundHelloClassifier` is that decision as a pure function, so the rule is
/// machine-verified where the socket wiring cannot be.
final class InboundHelloClassifierTests: XCTestCase {

    func testPhoneHelloTargetingThisMacIsData() {
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: .phoneHello, targetPcId: "mac-1", myPcId: "mac-1"),
            .data)
    }

    func testPhoneHelloTargetingAnotherMacIsForeign() {
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: .phoneHello, targetPcId: "mac-2", myPcId: "mac-1"),
            .foreign)
    }

    func testNoFrameIsKnock() {
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: nil, targetPcId: nil, myPcId: "mac-1"),
            .knock)
    }

    func testNonPhoneHelloKindIsKnock() {
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: .metadata, targetPcId: nil, myPcId: "mac-1"),
            .knock)
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: .unknown, targetPcId: nil, myPcId: "mac-1"),
            .knock)
    }

    func testUndecodablePhoneHelloIsKnock() {
        // The kind says phoneHello but the payload could not be decoded, so
        // there is no target to honour — it is not a data connection for us.
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: .phoneHello, targetPcId: nil, myPcId: "mac-1"),
            .knock)
    }

    // MARK: - Live-session guard (a stranger must not displace the owner)

    func testSamePhoneIdReconnectingIsData() {
        let owner = InboundSessionOwner(phoneId: "phone-a", name: "A")
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: .phoneHello, targetPcId: "mac-1",
                                            myPcId: "mac-1", owner: owner,
                                            incomingPhoneId: "phone-a"),
            .data)
    }

    func testDifferentPhoneIdWhileOwnedIsBusy() {
        let owner = InboundSessionOwner(phoneId: "phone-a", name: "A")
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: .phoneHello, targetPcId: "mac-1",
                                            myPcId: "mac-1", owner: owner,
                                            incomingPhoneId: "phone-b"),
            .busy)
    }

    func testNameOnlyOwnerYieldsToThePhoneThatDials() {
        // A name-only owner is a session THIS receiver dialed (the outbound path
        // records no phoneId). A phone that dials us asserts it can initiate, so
        // it wins — answering `busy` here was the auto-dial-vs-own-dial race
        // that made a first contact intermittent. The candidate still has to
        // pass the grant policy before anything is displaced.
        let owner = InboundSessionOwner(phoneId: nil, name: "Edwin's iPhone")
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: .phoneHello, targetPcId: "mac-1",
                                            myPcId: "mac-1", owner: owner,
                                            incomingPhoneId: "phone-b"),
            .data)
    }

    func testBusyNeverBeatsForeignOrKnock() {
        let owner = InboundSessionOwner(phoneId: "phone-a", name: "A")
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: .phoneHello, targetPcId: "mac-2",
                                            myPcId: "mac-1", owner: owner,
                                            incomingPhoneId: "phone-b"),
            .foreign)
        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: nil, targetPcId: nil, myPcId: "mac-1",
                                            owner: owner),
            .knock)
    }

    /// The real path, short of a socket: encode a `phoneHello`, feed the bytes
    /// to the same incremental parser the receiver uses, decode the first frame
    /// and classify it. This is what `routeInboundFirstFrame` does.
    func testEncodedPhoneHelloClassifiesAsDataOverTheWire() throws {
        let hello = IBPhoneHello(phoneId: "phone-uuid", phoneName: "Edwin's iPhone",
                                 targetPcId: "mac-1", appVersion: "1.2")
        let data = try IBWire.encode(phoneHello: hello)

        let parser = IBWire.Parser()
        let frame = try XCTUnwrap(parser.append(data).first)
        let decoded = try IBWire.decodePhoneHello(frame)

        XCTAssertEqual(
            InboundHelloClassifier.classify(kind: frame.kind,
                                            targetPcId: decoded.targetPcId,
                                            myPcId: "mac-1"),
            .data)
    }
}
