import AppKit
import CoreGraphics
import Foundation
import iBridgeCore

/// Abstraction over Mac input injection so the receiver can be unit
/// tested without touching the real event system.
public protocol InputInjector: AnyObject {
    /// Post a touch event. `screenSize` is the destination display
    /// rectangle, in points.
    func inject(touch: TouchEvent, screenSize: CGSize)

    /// Post a key event (down/up for keycodes, text for IME strings).
    func inject(key: KeyEvent)

    /// Last cursor position — tests read this back to verify movement.
    var lastCursor: CGPoint { get }
}

/// Posts the events to the real Mac via `CGEventPost`.
public final class CGEventInjector: InputInjector {

    public private(set) var lastCursor: CGPoint = .zero

    public init() {}

    public func inject(touch: TouchEvent, screenSize: CGSize) {
        let absX = Double(touch.x) * Double(screenSize.width)
        let absY = Double(touch.y) * Double(screenSize.height)

        switch touch.phase {
        case .down:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseDown, at: lastCursor)
        case .up:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseUp, at: lastCursor)
        case .move:
            // Apply incremental delta for smooth dragging.
            let dx = Double(touch.dx) * Double(screenSize.width)
            let dy = Double(touch.dy) * Double(screenSize.height)
            moveCursor(to: CGPoint(x: lastCursor.x + dx, y: lastCursor.y + dy))
            post(type: .leftMouseDragged, at: lastCursor)
        case .scroll:
            // Post a scroll event. Positive dy scrolls up; we follow
            // Apple's "natural" convention (inverse).
            let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: Int32(-touch.dy * 50),
                wheel2: Int32(-touch.dx * 50),
                wheel3: 0
            )
            scrollEvent?.post(tap: .cghidEventTap)
        case .rightDown:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .rightMouseDown, at: lastCursor)
        case .rightUp:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .rightMouseUp, at: lastCursor)
        case .click:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseDown, at: lastCursor)
            post(type: .leftMouseUp, at: lastCursor)
        }
    }

    public func inject(key: KeyEvent) {
        switch key.action {
        case .down:
            if let code = key.keycode {
                postKey(code: code, down: true)
            }
        case .up:
            if let code = key.keycode {
                postKey(code: code, down: false)
            }
        case .text:
            if let text = key.text {
                typeText(text)
            }
        }
    }

    // MARK: - Helpers

    private func moveCursor(to point: CGPoint) {
        lastCursor = point
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
    }

    private func post(type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    private func postKey(code: UInt16, down: Bool) {
        // USB HID keycode → virtual keycode conversion would go here.
        // For V0.2 we only support .text events, so this is rarely called.
        // Still, log the key for debugging.
        print("[iBridge] key \(down ? "down" : "up"): hid=\(code)")
    }

    private func typeText(_ text: String) {
        for char in text.unicodeScalars {
            let utf16 = Array(String(char).utf16)
            guard utf16.count <= 2 else { continue }    // skip surrogate pairs beyond BMP for now
            let down = CGEvent(keyboardEventSource: nil,
                               virtualKey: 0,                   // ignored when using unicode below
                               keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: nil,
                             virtualKey: 0,
                             keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up?.post(tap: .cghidEventTap)
        }
    }
}

/// Records every input event for inspection in tests.
public final class RecordingInputInjector: InputInjector {

    public struct RecordedTouch: Equatable {
        public let phase: TouchEvent.Phase
        public let x: Float
        public let y: Float
    }

    public struct RecordedKey: Equatable {
        public let action: KeyEvent.Action
        public let keycode: UInt16?
        public let text: String?
    }

    public private(set) var touches: [RecordedTouch] = []
    public private(set) var keys: [RecordedKey] = []
    public private(set) var lastCursor: CGPoint = .zero

    public init() {}

    public func inject(touch: TouchEvent, screenSize: CGSize) {
        let absX = CGFloat(touch.x) * screenSize.width
        let absY = CGFloat(touch.y) * screenSize.height
        lastCursor = CGPoint(x: absX, y: absY)
        touches.append(.init(phase: touch.phase, x: touch.x, y: touch.y))
    }

    public func inject(key: KeyEvent) {
        keys.append(.init(action: key.action, keycode: key.keycode, text: key.text))
    }
}