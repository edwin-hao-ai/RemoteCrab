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
            post(type: .leftMouseDown, at: lastCursor, flags: eventFlags(for: touch.modifiers))
        case .up:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseUp, at: lastCursor, flags: eventFlags(for: touch.modifiers))
        case .move:
            let dx = Double(touch.dx) * Double(screenSize.width)
            let dy = Double(touch.dy) * Double(screenSize.height)
            moveCursor(to: CGPoint(x: lastCursor.x + dx, y: lastCursor.y + dy))
            // Plain finger move = hover; while a drag is armed
            // (dragStart seen, no up yet) = left-drag.
            if isDragging {
                post(type: .leftMouseDragged, at: lastCursor)
            }
        case .dragStart:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseDown, at: lastCursor, flags: eventFlags(for: touch.modifiers))
            isDragging = true
        case .scroll:
            postScroll(dx: touch.dx, dy: touch.dy, commandHeld: false)
        case .pinch:
            // No public API posts magnification gestures; ⌘+scroll is
            // the standard zoom shortcut honoured by most apps.
            postScroll(dx: 0, dy: touch.dx, commandHeld: true)
        case .rightDown:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .rightMouseDown, at: lastCursor, flags: eventFlags(for: touch.modifiers))
        case .rightUp:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .rightMouseUp, at: lastCursor, flags: eventFlags(for: touch.modifiers))
        case .click:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseDown, at: lastCursor, flags: eventFlags(for: touch.modifiers))
            post(type: .leftMouseUp, at: lastCursor, flags: eventFlags(for: touch.modifiers))
        case .threeFingerTap:
            moveCursor(to: CGPoint(x: absX, y: absY))
            postOther(button: 2, down: true, at: lastCursor)   // middle click
            postOther(button: 2, down: false, at: lastCursor)
        case .threeFingerSwipe:
            postMissionControl(dx: touch.dx, dy: touch.dy)
        case .forceClick:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .rightMouseDown, at: lastCursor, flags: eventFlags(for: touch.modifiers))
            post(type: .rightMouseUp, at: lastCursor, flags: eventFlags(for: touch.modifiers))
        }
        if touch.phase == .up { isDragging = false }
        lastPhase = touch.phase
    }

    public func inject(key: KeyEvent) {
        switch key.action {
        case .down:
            if let code = key.keycode {
                postKey(code: code, down: true, flags: eventFlags(for: key.modifiers))
            }
        case .up:
            if let code = key.keycode {
                postKey(code: code, down: false, flags: eventFlags(for: key.modifiers))
            }
        case .text:
            if let text = key.text {
                typeText(text)
            }
        }
    }

    // MARK: - Helpers

    private var isDragging = false
    private var lastPhase: TouchEvent.Phase?

    private func moveCursor(to point: CGPoint) {
        lastCursor = point
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
    }

    private func post(type: CGEventType, at point: CGPoint, flags: CGEventFlags = []) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// TouchEvent/KeyEvent modifier bitmask (shift=1, control=2,
    /// option=4, command=8) → CGEventFlags.
    private func eventFlags(for mask: UInt8) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mask & 1 != 0 { flags.insert(.maskShift) }
        if mask & 2 != 0 { flags.insert(.maskControl) }
        if mask & 4 != 0 { flags.insert(.maskAlternate) }
        if mask & 8 != 0 { flags.insert(.maskCommand) }
        return flags
    }

    private func postScroll(dx: Float, dy: Float, commandHeld: Bool) {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-dy * 50),
            wheel2: Int32(-dx * 50),
            wheel3: 0
        )
        if commandHeld { event?.flags = .maskCommand }
        event?.post(tap: .cghidEventTap)
    }

    private func postOther(button: Int, down: Bool, at point: CGPoint) {
        let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: CGMouseButton(rawValue: UInt32(button))!)
        event?.post(tap: .cghidEventTap)
    }

    /// Three-finger swipes map to the Mac's built-in shortcuts:
    /// up = Mission Control (⌃↑), down = App Exposé (⌃↓),
    /// left/right = switch Space (⌃← / ⌃→).
    private func postMissionControl(dx: Float, dy: Float) {
        let keyCode: CGKeyCode
        if abs(dy) >= abs(dx) {
            keyCode = dy > 0 ? 126 : 125        // up / down
        } else {
            keyCode = dx > 0 ? 124 : 123        // right / left
        }
        postKeyCombo(code: keyCode, flags: .maskControl)
    }

    private func postKeyCombo(code: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        up?.post(tap: .cghidEventTap)
    }

    private func postKey(code: UInt16, down: Bool, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
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