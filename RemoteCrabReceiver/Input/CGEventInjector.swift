import AppKit
import CoreGraphics
import os
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
            // Uniform-axis gain: the iPhone normalizes both axes by the
            // same reference, so both are scaled by the screen HEIGHT
            // here — using the width for dx made the same finger travel
            // cover more physical pixels horizontally in portrait.
            let dx = Double(touch.dx) * Double(screenSize.height)
            let dy = Double(touch.dy) * Double(screenSize.height)
            moveCursor(to: CGPoint(x: lastCursor.x + dx, y: lastCursor.y + dy),
                       screenSize: screenSize)
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
            guard let text = key.text else { return }
            let flags = eventFlags(for: key.modifiers)
            if key.modifiers != 0 {
                // A locked/held modifier must produce a REAL key chord, or
                // macOS won't match a menu shortcut (⌘A, ⇧←…). Unicode-string
                // events never do — send keycode events instead, and fall
                // back to the string for characters with no US keycode (CJK).
                Self.log.info("modified text \(text, privacy: .public) -> keycodes (mods=\(key.modifiers, privacy: .public))")
                for char in text {
                    guard let (code, needsShift) = Self.keycode(forCharacter: char) else {
                        typeText(String(char), flags: flags)
                        continue
                    }
                    var f = flags
                    if needsShift { f.insert(.maskShift) }
                    postKey(code: code, down: true, flags: f)
                    postKey(code: code, down: false, flags: f)
                }
            } else {
                typeText(text, flags: flags)
            }
        }
    }

    /// US-ANSI character → (virtual keycode, needsShift). Enough for the
    /// letters/digits/punctuation that make up shortcuts.
    private static let log = Logger(subsystem: "com.remotecrab", category: "injector")

    private static func keycode(forCharacter ch: Character) -> (UInt16, Bool)? {
        let lower: [Character: UInt16] = [
            "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,
            "q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
            "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,
            "-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,
            "l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,
            "m":46,".":47,"`":50," ":49,
        ]
        let shifted: [Character: UInt16] = [
            "!":18,"@":19,"#":20,"$":21,"^":22,"%":23,"+":24,"(":25,"&":26,
            "_":27,"*":28,")":29,"}":30,"{":33,":":41,"\"":39,"<":43,">":47,
            "?":44,"~":50,"|":42,
        ]
        if let code = lower[ch] { return (code, false) }
        if let code = shifted[ch] { return (code, true) }
        let s = String(ch)
        if s.count == 1, let l = s.lowercased().first, let code = lower[l] { return (code, true) } // uppercase
        return nil
    }

    // MARK: - Helpers

    private var isDragging = false
    private var lastPhase: TouchEvent.Phase?

    private func moveCursor(to point: CGPoint, screenSize: CGSize) {
        // Clamp the tracked position to the screen: the physical cursor
        // can't leave the display, and an offscreen lastCursor posts
        // events at meaningless coordinates (drags land nowhere).
        // Clamping also makes the cursor position deterministic —
        // enough negative deltas always reach (0,0).
        let clamped = CGPoint(x: min(max(point.x, 0), screenSize.width - 1),
                              y: min(max(point.y, 0), screenSize.height - 1))
        lastCursor = clamped
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: clamped, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
    }

    private func post(type: CGEventType, at point: CGPoint, flags: CGEventFlags = []) {
        // The button must match the event type — a rightMouseDown
        // built with .left confuses apps that read the button field.
        let button: CGMouseButton
        switch type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            button = .right
        default:
            button = .left
        }
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: button)
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
        let down = CGEvent(keyboardEventSource: keySource, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: keySource, virtualKey: code, keyDown: false)
        up?.post(tap: .cghidEventTap)
    }

    /// Modifier virtual keycodes → the device-independent flag they set.
    private static func modifierFlag(for code: UInt16) -> CGEventFlags? {
        switch code {
        case 55, 54: return .maskCommand      // ⌘ / right ⌘
        case 56, 60: return .maskShift        // ⇧ / right ⇧
        case 58, 61: return .maskAlternate    // ⌥ / right ⌥
        case 59, 62: return .maskControl      // ⌃ / right ⌃
        default: return nil
        }
    }

    /// Current modifier state, so a flagsChanged event carries the FULL
    /// set (macOS replaces the state each event).
    private var heldModifierFlags: CGEventFlags = []

    /// Dedicated HID event source. Posting ⌘-flagged events through the
    /// shared system state can LATCH the modifier onto later synthetic
    /// events; our own source + explicitly setting `flags` on every event
    /// avoids that (lan-mouse #450, agent-remote-hands #96).
    private let keySource = CGEventSource(stateID: .hidSystemState)

    /// Device-dependent low-word modifier bits. Real hardware sets these
    /// alongside the device-independent flag; some consumers (input
    /// methods, VM guests) read them, so a synthetic FlagsChanged without
    /// them can be ignored (lan-mouse #450).
    private static func deviceBits(for code: UInt16) -> CGEventFlags {
        let raw: UInt64
        switch code {
        case 59: raw = 0x0000_0001   // left control
        case 56: raw = 0x0000_0002   // left shift
        case 60: raw = 0x0000_0004   // right shift
        case 55: raw = 0x0000_0008   // left command
        case 54: raw = 0x0000_0010   // right command
        case 58: raw = 0x0000_0020   // left option
        case 61: raw = 0x0000_0040   // right option
        case 62: raw = 0x0000_2000   // right control
        default: raw = 0
        }
        return CGEventFlags(rawValue: raw)
    }

    private func postKey(code: UInt16, down: Bool, flags: CGEventFlags = []) {
        // A modifier key press is a `flagsChanged` event, NOT a keyDown —
        // posting keyDown for ⌥/⌘/⌃/⇧ does nothing (so a held ⌥ never
        // reached an input method like 豆包输入法). Emulate the real thing,
        // including the device-dependent bits real hardware carries.
        if let flag = Self.modifierFlag(for: code) {
            if down { heldModifierFlags.insert(flag) } else { heldModifierFlags.remove(flag) }
            let event = CGEvent(keyboardEventSource: keySource, virtualKey: CGKeyCode(code), keyDown: down)
            event?.type = .flagsChanged
            var f = heldModifierFlags
            if down { f.insert(Self.deviceBits(for: code)) }
            f.insert(.maskNonCoalesced)
            event?.flags = f
            event?.post(tap: .cghidEventTap)
            return
        }
        let event = CGEvent(keyboardEventSource: keySource, virtualKey: CGKeyCode(code), keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String, flags: CGEventFlags = []) {
        for char in text.unicodeScalars {
            let utf16 = Array(String(char).utf16)
            guard utf16.count <= 2 else { continue }
            let down = CGEvent(keyboardEventSource: keySource, virtualKey: 0, keyDown: true)
            down?.flags = flags
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: keySource, virtualKey: 0, keyDown: false)
            up?.flags = flags
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up?.post(tap: .cghidEventTap)
        }
    }

}