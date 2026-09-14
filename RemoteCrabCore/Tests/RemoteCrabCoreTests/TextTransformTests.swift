import XCTest
@testable import RemoteCrabCore

/// Local selection-rewrite transforms + their wire framing.
final class TextTransformTests: XCTestCase {

    func testCaseCommands() {
        XCTAssertEqual(TextTransform.apply(.uppercase, to: "hello World"), "HELLO WORLD")
        XCTAssertEqual(TextTransform.apply(.lowercase, to: "Hello World"), "hello world")
        XCTAssertEqual(TextTransform.apply(.capitalize, to: "hello world"), "Hello World")
    }

    func testTrimWhitespace() {
        XCTAssertEqual(TextTransform.apply(.trimWhitespace, to: "  hi\n\n"), "hi")
    }

    func testStripNewlinesCollapsesToOneLine() {
        let input = "first\nsecond\n\n  third  "
        XCTAssertEqual(TextTransform.apply(.stripNewlines, to: input), "first second third")
    }

    func testBulletList() {
        let input = "one\ntwo\n\nthree"
        XCTAssertEqual(TextTransform.apply(.bulletList, to: input), "• one\n• two\n• three")
    }

    func testWireRoundTrip() throws {
        for command in IBTextCommand.allCases {
            let frames = IBWire.Parser().append(
                try IBWire.encode(textCommand: IBTextCommandMessage(command: command)))
            XCTAssertEqual(frames[0].kind, .textCommand)
            XCTAssertEqual(try IBWire.decodeTextCommand(frames[0]).command, command)
        }
    }
}
