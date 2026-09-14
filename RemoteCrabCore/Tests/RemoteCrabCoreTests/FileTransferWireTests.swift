import XCTest
@testable import RemoteCrabCore

/// Wire round-trips for the file-transfer frames.
final class FileTransferWireTests: XCTestCase {

    func testRoundTripFileOffer() throws {
        let offer = IBFileOffer(id: "xfer-1", name: "photo.heic", size: 2_345_678)
        let encoded = try IBWire.encode(fileOffer: offer)
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames[0].kind, .fileOffer)
        XCTAssertEqual(try IBWire.decodeFileOffer(frames[0]), offer)
    }

    func testFileChunkCarriesRawBytes() {
        let payload = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        let encoded = IBWire.encodeFileChunk(payload)
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames[0].kind, .fileChunk)
        XCTAssertEqual(frames[0].payload, payload)
    }

    func testRoundTripFileCompleteAndAck() throws {
        let complete = IBFileComplete(id: "xfer-1")
        let cFrames = IBWire.Parser().append(try IBWire.encode(fileComplete: complete))
        XCTAssertEqual(cFrames[0].kind, .fileComplete)
        XCTAssertEqual(try IBWire.decodeFileComplete(cFrames[0]), complete)

        let ack = IBFileAck(id: "xfer-1", status: .saved, receivedBytes: 123, path: "/Users/me/Downloads/RemoteCrab/a.bin")
        let aFrames = IBWire.Parser().append(try IBWire.encode(fileAck: ack))
        XCTAssertEqual(aFrames[0].kind, .fileAck)
        XCTAssertEqual(try IBWire.decodeFileAck(aFrames[0]), ack)
    }
}
