import XCTest
@testable import RemoteCrabCore

final class ClipboardWireTests: XCTestCase {
    func testRoundTripClipboard() throws {
        let clip = IBClipboard(text: "hello 世界\nline 2")
        let frames = IBWire.Parser().append(try IBWire.encode(clipboard: clip))

        XCTAssertEqual(frames[0].kind, .clipboardSet)
        XCTAssertEqual(try IBWire.decodeClipboard(frames[0]), clip)
    }
}
