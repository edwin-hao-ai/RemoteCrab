import XCTest
@testable import RemoteCrabCore

/// The transport negotiation decision (F1 task 7): a peer that did not
/// advertise `aead-v1`, or a session missing a token/nonce, stays cleartext.
final class TransportNegotiationTests: XCTestCase {

    func testAnOldPeerStaysCleartext() {
        XCTAssertNil(TransportNegotiation.sessionKey(peerTransport: nil, token: "t", clientNonce: "a", serverNonce: "b"))
        XCTAssertNil(TransportNegotiation.sessionKey(peerTransport: "something-else", token: "t", clientNonce: "a", serverNonce: "b"))
    }

    func testAMissingTokenOrNonceStaysCleartext() {
        XCTAssertNil(TransportNegotiation.sessionKey(peerTransport: "aead-v1", token: nil, clientNonce: "a", serverNonce: "b"))
        XCTAssertNil(TransportNegotiation.sessionKey(peerTransport: "aead-v1", token: "t", clientNonce: nil, serverNonce: "b"))
        XCTAssertNil(TransportNegotiation.sessionKey(peerTransport: "aead-v1", token: "t", clientNonce: "a", serverNonce: nil))
    }

    func testBothSidesSupportingDeriveTheSameKey() {
        let a = TransportNegotiation.sessionKey(peerTransport: "aead-v1", token: "t", clientNonce: "a", serverNonce: "b")!
        let b = TransportNegotiation.sessionKey(peerTransport: "aead-v1", token: "t", clientNonce: "a", serverNonce: "b")!
        var sa = TransportCipher.Sealer(key: a)
        var sb = TransportCipher.Sealer(key: b)
        XCTAssertEqual(sa.seal(Data("x".utf8), kind: 1), sb.seal(Data("x".utf8), kind: 1))
    }
}
