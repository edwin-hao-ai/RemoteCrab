import XCTest
@testable import RemoteCrabCore

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

    // MARK: - tailEvents (voice: cursor is always at the end)

    func testTailPureInsertion() {
        XCTAssertEqual(TextDiff.tailEvents(from: "abc", to: "abcd"),
                       [KeyEvent(action: .text, text: "d")])
    }

    func testTailRevisionBackspacesThenRetypesTail() {
        // "滑滑" → "滑板": cannot edit the middle, so delete the changed
        // tail and retype it. Events: 1 backspace, then type "板".
        XCTAssertEqual(TextDiff.tailEvents(from: "滑滑", to: "滑板"), [
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
            KeyEvent(action: .text, text: "板"),
        ])
    }

    func testTailMiddleRevisionDoesNotPreserveSuffix() {
        // "abXcd" → "abYcd": a fixed end cursor can only backspace the
        // tail, so the whole changed tail ("Xcd") is deleted and "Ycd"
        // retyped — NOT a single middle replacement.
        XCTAssertEqual(TextDiff.tailEvents(from: "abXcd", to: "abYcd"), [
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
            KeyEvent(action: .text, text: "Ycd"),
        ])
    }

    func testTailShrinkDeletesExtra() {
        let events = TextDiff.tailEvents(from: "你今天", to: "你今")
        XCTAssertEqual(events, [
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
        ])
    }

    func testTailNoChangeProducesNothing() {
        XCTAssertTrue(TextDiff.tailEvents(from: "相同", to: "相同").isEmpty)
    }
}
