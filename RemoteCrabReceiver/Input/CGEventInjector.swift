import AppKit
import CoreGraphics
import Foundation
import RemoteCrabCore

/// Posts the events to the real Mac via `CGEventPost`.
///
/// Positioning is joystick-style relative: hover moves apply deltas
/// to `lastCursor`, and discrete events (click / right-click / drag)
/// fire at wherever the cursor already is. The absolute x/y in
/// `TouchEvent` is deliberately NOT mapped to screen coordinates —
/// teleporting on every tap made the cursor jump across the screen
/// ("飘") whenever the finger lifted and landed somewhere new.
public final class CGEventInjector: InputInjector {

    public private(set) var lastCursor: CGPoint = .zero

    public init() {}

    public func inject(touch: TouchEvent, screenSize: CGSize) {
        switch touch.phase {
        case .down:
            post(type: .leftMouseDown, at: lastCursor, flags: eventFlags(for: touch.modifiers))
        case .up:
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
            post(type: .leftMouseDown, at: lastCursor, flags: eventFlags(for: touch.modifiers))
            isDragging = true
        case .scroll:
            postScroll(dx: touch.dx, dy: touch.dy, commandHeld: false,
                       momentum: touch.momentum ?? false, screenHeight: screenSize.height)
        case .pinch:
            // No public API posts magnification gestures; ⌘+scroll is
            // the standard zoom shortcut honoured by most apps.
            postScroll(dx: 0, dy: touch.dx, commandHeld: true,
                       momentum: false, screenHeight: screenSize.height)
        case .rightDown:
            post(type: .rightMouseDown, at: lastCursor, flags: eventFlags(for: touch.modifiers))
        case .rightUp:
            post(type: .rightMouseUp, at: lastCursor, flags: eventFlags(for: touch.modifiers))
        case .click:
            post(type: .leftMouseDown, at: lastCursor, flags: eventFlags(for: touch.modifiers))
            post(type: .leftMouseUp, at: lastCursor, flags: eventFlags(for: touch.modifiers))
        case .threeFingerTap:
            postOther(button: 2, down: true, at: lastCursor)   // middle click
            postOther(button: 2, down: false, at: lastCursor)
        case .threeFingerSwipe:
            postMissionControl(dx: touch.dx, dy: touch.dy)
        case .forceClick:
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

    /// Scroll state for phase tracking: macOS gives native-feel
    /// scrolling (rubber band, per-pixel precision) only to events
    /// flagged continuous + carrying a scroll phase. We infer phases
    /// from the event stream: first event after a quiet gap = began,
    /// steady stream = changed, and a trailing timer posts ended.
    private var scrollActive = false
    private var momentumActive = false
    private var scrollEndWork: DispatchWorkItem?

    /// `dx`/`dy` are normalized finger deltas (fraction of the iPhone
    /// surface). Gain maps one full phone-height swipe to roughly one
    /// Mac screen of travel — the old fixed ×50 made a full swipe
    /// scroll ~50 px total, which read as "dead".
    private func postScroll(dx: Float, dy: Float, commandHeld: Bool,
                            momentum: Bool, screenHeight: CGFloat) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0, wheel2: 0, wheel3: 0
        ) else { return }

        let gain = Double(screenHeight) * 1.2
        let pixelDY = Double(-dy) * gain
        let pixelDX = Double(-dx) * gain

        // Pixel deltas as doubles — the Int32 initializer truncates
        // sub-pixel deltas to 0, which made gentle scrolls feel dead.
        event.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: pixelDY)
        event.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: pixelDX)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: pixelDY)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: pixelDX)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: pixelDY)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: pixelDX)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if momentum {
            // iOS-side glide after finger lift → native momentum phases.
            event.setIntegerValueField(
                .scrollWheelEventMomentumPhase,
                value: momentumActive ? MomentumPhase.continued.rawValue : MomentumPhase.began.rawValue
            )
        } else {
            event.setIntegerValueField(
                .scrollWheelEventScrollPhase,
                value: scrollActive ? ScrollPhase.changed.rawValue : ScrollPhase.began.rawValue
            )
        }
        if commandHeld { event.flags = .maskCommand }
        event.post(tap: .cghidEventTap)

        if momentum { momentumActive = true } else { scrollActive = true }
        scrollEndWork?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.momentumActive {
                self.postMomentumPhase(.ended)
                self.momentumActive = false
            }
            if self.scrollActive {
                self.postScrollPhase(.ended)
                self.scrollActive = false
            }
        }
        scrollEndWork = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: end)
    }

    private enum ScrollPhase: Int64 {
        case began = 1, changed = 2, ended = 4
    }

    private enum MomentumPhase: Int64 {
        case began = 1, continued = 2, ended = 3
    }

    private func makeScrollEvent() -> CGEvent? {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0, wheel2: 0, wheel3: 0
        )
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return event
    }

    private func postScrollPhase(_ phase: ScrollPhase) {
        guard let event = makeScrollEvent() else { return }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        event.post(tap: .cghidEventTap)
    }

    private func postMomentumPhase(_ phase: MomentumPhase) {
        guard let event = makeScrollEvent() else { return }
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase.rawValue)
        event.post(tap: .cghidEventTap)
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