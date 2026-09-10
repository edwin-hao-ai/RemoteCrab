import AppKit
import CoreGraphics
import Foundation
import iBridgeCore

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
        case .dragStart:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseDown, at: lastCursor)
        case .threeFingerTap:
            moveCursor(to: CGPoint(x: absX, y: absY))
            let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                               mouseCursorPosition: lastCursor, mouseButton: .center)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp,
                             mouseCursorPosition: lastCursor, mouseButton: .center)
            up?.post(tap: .cghidEventTap)
        case .forceClick:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .rightMouseDown, at: lastCursor)
            post(type: .rightMouseUp, at: lastCursor)
        case .pinch, .threeFingerSwipe:
            // System-level gestures (zoom / Mission Control) have no
            // simple CGEvent equivalent; ignored for now.
            break
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
        print("[iBridge] key \(down ? "down" : "up"): hid=\(code)")
    }

    private func typeText(_ text: String) {
        for char in text.unicodeScalars {
            let utf16 = Array(String(char).utf16)
            guard utf16.count <= 2 else { continue }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up?.post(tap: .cghidEventTap)
        }
    }
}