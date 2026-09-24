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

    /// Last cursor position — tests read this back to verify movement.
    var lastCursor: CGPoint { get }
}

public extension InputInjector {
    /// Post an absolute direct-manipulation input inside the mirrored
    /// window (screen mirror). `windowOrigin`/`windowSize` are the
    /// window frame in Mac screen points; `u`/`v` are normalized `0...1`
    /// inside the window content. Default is a no-op so injectors that
    /// don't model the mirror still conform.
    func inject(screenInput: IBScreenInput, windowOrigin: CGPoint, windowSize: CGSize) {}
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

    public func inject(screenInput: IBScreenInput, windowOrigin: CGPoint, windowSize: CGSize) {
        let absX = windowOrigin.x + CGFloat(screenInput.u) * windowSize.width
        let absY = windowOrigin.y + CGFloat(screenInput.v) * windowSize.height
        lastCursor = CGPoint(x: absX, y: absY)
        screens.append(.init(action: screenInput.action,
                             u: screenInput.u, v: screenInput.v,
                             cursor: lastCursor))
    }
}