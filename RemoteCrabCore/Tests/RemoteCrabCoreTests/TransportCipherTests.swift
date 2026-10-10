import XCTest
@testable import RemoteCrabCore

final class TransportCipherTests: XCTestCase {

    func testSealOpenRoundTripsAndRejectsReplay() throws {
        let key = TransportCipher.sessionKey(token: "tok",
                                            initiatorNonce: Data([1, 2, 3]),
                                            responderNonce: Data([4, 5, 6]))
        var sealer = TransportCipher.Sealer(key: key)
        var opener = TransportCipher.Opener(key: key)

        let sealed = sealer.seal(Data("hello".utf8), kind: 0x13)
        XCTAssertEqual(try opener.open(sealed, kind: 0x13), Data("hello".utf8))
        // Replaying the exact frame must fail (nonce reuse / replay).
        XCTAssertThrowsError(try opener.open(sealed, kind: 0x13))
    }

    func testDifferentTokensDoNotInteroperate() throws {
        let a = TransportCipher.sessionKey(token: "tok-a", initiatorNonce: Data([1]), responderNonce: Data([2]))
        let b = TransportCipher.sessionKey(token: "tok-b", initiatorNonce: Data([1]), responderNonce: Data([2]))
        var sealer = TransportCipher.Sealer(key: a)
        var opener = TransportCipher.Opener(key: b)
        let sealed = sealer.seal(Data("secret".utf8), kind: 0x04)
        XCTAssertThrowsError(try opener.open(sealed, kind: 0x04))
    }

    func testTamperedCiphertextIsRejected() throws {
        let key = TransportCipher.sessionKey(token: "tok", initiatorNonce: Data([1]), responderNonce: Data([2]))
        var sealer = TransportCipher.Sealer(key: key)
        var opener = TransportCipher.Opener(key: key)
        var sealed = sealer.seal(Data("hello".utf8), kind: 0x13)
        sealed[sealed.count - 1] ^= 0x01   // flip a tag bit
        XCTAssertThrowsError(try opener.open(sealed, kind: 0x13))
    }

    func testOutOfOrderWithinWindowStillOpens() throws {
        let key = TransportCipher.sessionKey(token: "tok", initiatorNonce: Data([1]), responderNonce: Data([2]))
        var sealer = TransportCipher.Sealer(key: key)
        var opener = TransportCipher.Opener(key: key)
        let first = sealer.seal(Data("1".utf8), kind: 0x04)
        let second = sealer.seal(Data("2".utf8), kind: 0x04)
        // The second arrives first; the window must still accept the first.
        XCTAssertEqual(try opener.open(second, kind: 0x04), Data("2".utf8))
        XCTAssertEqual(try opener.open(first, kind: 0x04), Data("1".utf8))
    }
}
