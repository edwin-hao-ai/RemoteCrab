import CoreGraphics
import Foundation

/// Abstraction over Mac input injection so the receiver can be unit
/// tested without touching the real event system.
public protocol InputInjector: AnyObject {
    /// Post a touch event. `screenSize` is the destination display
    /// rectangle, in points.
    func inject(touch: TouchEvent, screenSize: CGSize)

    /// Post a key event (down/up for keycodes, text for IME strings).
    func inject(key: KeyEvent)

    /// Post an absolute direct-manipulation input inside the mirrored
    /// window (screen mirror). `windowOrigin`/`windowSize` are the
    /// window frame in Mac screen points; `u`/`v` are normalized `0...1`
    /// inside the window content.
    ///
    /// NOTE: this must be a protocol *requirement*, not just an extension
    /// method — an extension-only method dispatches statically, so a call
    /// through `any InputInjector` would silently invoke the no-op default
    /// instead of `CGEventInjector`'s real implementation.
    func inject(screenInput: IBScreenInput, windowOrigin: CGPoint, windowSize: CGSize)

    /// Forget that the cursor is inside the mirrored window.
    ///
    /// Called when a mirror session ends. The injector outlives the session
    /// (it is a long-lived property on `ReceiverSession`), so without this
    /// the "already placed" memory survives a disconnect — and the user's
    /// own mouse may have moved the cursor to another app in the meantime,
    /// so the next session's first scroll would land in the wrong window.
    func resetMirrorCursor()

    /// Last cursor position — tests read this back to verify movement.
    var lastCursor: CGPoint { get }

    /// Seed the tracked cursor from the real system cursor, at the start of a
    /// session. The joystick model applies deltas to `lastCursor`; leaving it at
    /// `.zero` made the first trackpad move after a fresh connect jump the Mac
    /// cursor to the top-left instead of nudging it from where it already was.
    func syncToSystemCursor()
}

public extension InputInjector {
    /// Default no-op so injectors that don't model the mirror still
    /// conform (e.g. a future test double).
    func inject(screenInput: IBScreenInput, windowOrigin: CGPoint, windowSize: CGSize) {}
    func resetMirrorCursor() {}
    func syncToSystemCursor() {}
    var hasMirrorCursor: Bool { false }
}

/// Records every input event for inspection in tests. Lives in
/// `RemoteCrabCore` so the e2e tests don't need a macOS-specific test
/// target.
public final class RecordingInputInjector: InputInjector, @unchecked Sendable {

    public struct RecordedTouch: Equatable {
        public let phase: TouchEvent.Phase
        public let x: Float
        public let y: Float
        public init(phase: TouchEvent.Phase, x: Float, y: Float) {
            self.phase = phase
            self.x = x
            self.y = y
        }
    }

    public struct RecordedKey: Equatable {
        public let action: KeyEvent.Action
        public let keycode: UInt16?
        public let text: String?
        public init(action: KeyEvent.Action, keycode: UInt16?, text: String?) {
            self.action = action
            self.keycode = keycode
            self.text = text
        }
    }

    public private(set) var touches: [RecordedTouch] = []
    public private(set) var keys: [RecordedKey] = []
    public private(set) var lastCursor: CGPoint = .zero

    /// One recorded absolute mirror input, plus the global cursor point it
    /// resolved to. Lets tests assert the normalized→global mapping.
    public struct RecordedScreen: Equatable {
        public let action: IBScreenInput.Action
        public let u: Float
        public let v: Float
        public let cursor: CGPoint
        public init(action: IBScreenInput.Action, u: Float, v: Float, cursor: CGPoint) {
            self.action = action
            self.u = u
            self.v = v
            self.cursor = cursor
        }
    }

    public private(set) var screens: [RecordedScreen] = []
    /// Mirrors `CGEventInjector`'s placement memory so the cross-session
    /// behaviour is testable without a macOS target.
    public private(set) var hasMirrorCursor = false

    public init() {}

    public func resetMirrorCursor() { hasMirrorCursor = false }

    public func inject(touch: TouchEvent, screenSize: CGSize) {
        let absX = CGFloat(touch.x) * screenSize.width
        let absY = CGFloat(touch.y) * screenSize.height
        lastCursor = CGPoint(x: absX, y: absY)
        touches.append(.init(phase: touch.phase, x: touch.x, y: touch.y))
    }

    public func inject(key: KeyEvent) {
        keys.append(.init(action: key.action, keycode: key.keycode, text: key.text))
    }

    public func inject(screenInput: IBScreenInput, windowOrigin: CGPoint, windowSize: CGSize) {
        let absX = windowOrigin.x + CGFloat(screenInput.u) * windowSize.width
        let absY = windowOrigin.y + CGFloat(screenInput.v) * windowSize.height
        lastCursor = CGPoint(x: absX, y: absY)
        // Same rule as the real injector: a scroll does not move the cursor,
        // so it must not claim the cursor is placed. A click / drag /
        // right-click does place it.
        if screenInput.action != .scroll { hasMirrorCursor = true }
        screens.append(.init(action: screenInput.action,
                             u: screenInput.u, v: screenInput.v,
                             cursor: lastCursor))
    }
}