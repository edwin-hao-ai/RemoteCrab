import XCTest
@testable import RemoteCrabCore

/// Wire-level tests for the identity exchange. Kept apart from `PeerAuthTests`
/// (the math) so a failure here says "the bytes on the wire", not "the HMAC".
final class PeerAuthWireTests: XCTestCase {

    // MARK: - ClientProof (0x26)

    func testClientProofRoundTrip() throws {
        let proof = IBClientProof(mac: "abc123")
        let encoded = try IBWire.encode(clientProof: proof)
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .clientProof)
        XCTAssertEqual(try IBWire.decodeClientProof(frames[0]), proof)
    }

    func testClientProofKindIs0x26() {
        XCTAssertEqual(IBWire.Kind.clientProof.rawValue, 0x26)
    }

    // MARK: - ClientHello.nonce

    func testClientHelloRoundTripsNonce() throws {
        let hello = IBClientHello(name: "PC", id: "pc-1", token: "tok",
                                  appVersion: "1.0", platform: "windows",
                                  capabilities: [.latencyProbe, .peerAuth],
                                  nonce: "nonce-c")
        let encoded = try IBWire.encode(clientHello: hello)
        let frames = IBWire.Parser().append(encoded)

        let decoded = try IBWire.decodeClientHello(frames[0])
        XCTAssertEqual(decoded, hello)
        XCTAssertEqual(decoded.nonce, "nonce-c")
        XCTAssertTrue(decoded.supports(.peerAuth))
    }

    /// A Mac from before this feature omits `nonce` entirely — it must decode to
    /// nil rather than failing the whole handshake.
    func testLegacyClientHelloWithoutNonceDecodesNil() throws {
        let json = #"{"name":"Old Mac","id":"mac-1","appVersion":"0.1"}"#
        let frame = IBWire.Frame(kind: .clientHello, payload: Data(json.utf8))

        let hello = try IBWire.decodeClientHello(frame)
        XCTAssertNil(hello.nonce)
        XCTAssertNil(hello.capabilities)
    }

    // MARK: - SessionReply auth fields

    func testSessionReplyRoundTripsAuthFields() throws {
        let reply = IBSessionReply(result: .pending, ownerName: nil, token: nil,
                                   nonce: "nonce-s", mac: "mac-s",
                                   capabilities: [PeerAuth.capability])
        let encoded = try IBWire.encode(sessionReply: reply)
        let frames = IBWire.Parser().append(encoded)

        let decoded = try IBWire.decodeSessionReply(frames[0])
        XCTAssertEqual(decoded, reply)
        XCTAssertEqual(decoded.nonce, "nonce-s")
        XCTAssertEqual(decoded.mac, "mac-s")
        XCTAssertEqual(decoded.capabilities, ["peerAuth"])
    }

    /// A phone from before this feature sends only `result` (+ maybe token).
    /// Every auth field must default to nil, not fail the handshake.
    func testLegacySessionReplyWithoutAuthFieldsDecodesNil() throws {
        let json = #"{"result":"accepted","token":"tok"}"#
        let frame = IBWire.Frame(kind: .sessionReply, payload: Data(json.utf8))

        let reply = try IBWire.decodeSessionReply(frame)
        XCTAssertEqual(reply.result, .accepted)
        XCTAssertEqual(reply.token, "tok")
        XCTAssertNil(reply.nonce)
        XCTAssertNil(reply.mac)
        XCTAssertNil(reply.capabilities)
    }

    /// An unknown capability word from a newer peer must not fail the decode.
    func testUnknownCapabilityDoesNotFailTheClientHello() throws {
        let json = #"{"name":"Future PC","id":"pc-9","appVersion":"9","capabilities":["latencyProbe","teleport"]}"#
        let frame = IBWire.Frame(kind: .clientHello, payload: Data(json.utf8))

        let hello = try IBWire.decodeClientHello(frame)
        XCTAssertTrue(hello.supports(.latencyProbe))
        XCTAssertEqual(hello.capabilities?.count, 1)
    }
}
