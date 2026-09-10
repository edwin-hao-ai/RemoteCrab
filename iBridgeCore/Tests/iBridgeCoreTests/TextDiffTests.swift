import XCTest
@testable import iBridgeCore

final class TextDiffTests: XCTestCase {

    func testPureInsertion() {
        let events = TextDiff.events(from: "abc", to: "abcd")
        XCTAssertEqual(events, [KeyEvent(action: .text, text: "d")])
    }

    func testPureDeletion() {
        let events = TextDiff.events(from: "abcd", to: "ab")
        // two backspaces: down+up each, keycode 51 (macOS delete)
        XCTAssertEqual(events, [
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
        ])
    }

    func testReplacement() {
        // "abc" → "axc": delete "b" then insert "x"
        let events = TextDiff.events(from: "abc", to: "axc")
        XCTAssertEqual(events, [
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
            KeyEvent(action: .text, text: "x"),
        ])
    }

    func testNoChangeProducesNothing() {
        XCTAssertTrue(TextDiff.events(from: "same", to: "same").isEmpty)
    }

    func testUnicodeInsertion() {
        let events = TextDiff.events(from: "", to: "你好")
        XCTAssertEqual(events, [KeyEvent(action: .text, text: "你好")])
    }

    func testEmptyFromIsPureInsertion() {
        XCTAssertEqual(TextDiff.events(from: "", to: "hello"),
                       [KeyEvent(action: .text, text: "hello")])
    }
}
