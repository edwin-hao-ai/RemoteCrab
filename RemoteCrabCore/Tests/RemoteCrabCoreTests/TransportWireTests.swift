import XCTest
@testable import RemoteCrabCore

/// `IBWire` seal/open over the frame payload (F1 task 4).
final class TransportWireTests: XCTestCase {

    private func cipher() -> (TransportCipher.Sealer, TransportCipher.Opener) {
        let key = TransportCipher.sessionKey(token: "t", initiatorNonce: Data([1]), responderNonce: Data([2]))
        return (TransportCipher.Sealer(key: key), TransportCipher.Opener(key: key))
    }

    func testSealedFrameRoutesOnKindAndDecrypts() throws {
        var (sealer, opener) = cipher()
        let original = IBWire.Frame(kind: .clipboardSet, payload: Data("RemoteCrab-e2e-OK".utf8))
        let wire = IBWire.seal(frame: original, using: &sealer)
        let frames = try IBWire.open(data: wire, using: &opener, parser: IBWire.Parser())
        XCTAssertEqual(frames, [original])
    }

    func testSealedFrameKeepsTheKindCleartextOnTheWire() throws {
        var (sealer, _) = cipher()
        let wire = IBWire.seal(frame: IBWire.Frame(kind: .touch, payload: Data("x".utf8)), using: &sealer)
        // The plaintext must NOT appear on the wire.
        XCTAssertNil(wire.range(of: Data("x".utf8)))
        // But the kind byte is still routeable.
        let frames = IBWire.Parser().append(wire)
        XCTAssertEqual(frames.first?.kind, .touch)
    }

    /// The sniffer assertion (F1 task 7): a known plaintext marker — here the
    /// exact string the device e2e uses for the clipboard — must not appear in
    /// the bytes on the wire.
    func testThePlaintextMarkerNeverAppearsOnTheWire() throws {
        var (sealer, opener) = cipher()
        let marker = "RemoteCrab-e2e-OK"
        let wire = IBWire.seal(frame: IBWire.Frame(kind: .clipboardSet, payload: Data(marker.utf8)),
                               using: &sealer)
        XCTAssertNil(wire.range(of: Data(marker.utf8)))
        let frames = try IBWire.open(data: wire, using: &opener, parser: IBWire.Parser())
        XCTAssertEqual(frames.first?.payload, Data(marker.utf8))
    }
}
