import XCTest
@testable import RemoteCrabCore

/// The `transport` capability on the handshake (F1 task 3).
final class TransportHandshakeTests: XCTestCase {

    func testClientHelloWithoutTransportStillDecodes() throws {
        // An old peer omits the field entirely — it must decode, not fail.
        let json = #"{"name":"M","id":"i","appVersion":"1"}"#
        let hello = try JSONDecoder().decode(IBClientHello.self, from: Data(json.utf8))
        XCTAssertNil(hello.transport)
    }

    func testClientHelloWithTransportRoundTrips() throws {
        let hello = IBClientHello(name: "M", id: "i", token: nil, appVersion: "1",
                                  transport: TransportCipher.versionName)
        let data = try JSONEncoder().encode(hello)
        XCTAssertEqual(try JSONDecoder().decode(IBClientHello.self, from: data).transport, "aead-v1")
    }

    func testSessionReplyWithoutTransportStillDecodes() throws {
        let json = #"{"result":"accepted"}"#
        let reply = try JSONDecoder().decode(IBSessionReply.self, from: Data(json.utf8))
        XCTAssertNil(reply.transport)
    }

    func testSessionReplyWithTransportRoundTrips() throws {
        let reply = IBSessionReply(result: .accepted, token: "t", transport: TransportCipher.versionName)
        let data = try JSONEncoder().encode(reply)
        XCTAssertEqual(try JSONDecoder().decode(IBSessionReply.self, from: data).transport, "aead-v1")
    }
}
