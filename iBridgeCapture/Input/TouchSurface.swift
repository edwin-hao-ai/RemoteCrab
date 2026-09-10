import QuartzCore
import SwiftUI
import UIKit
import iBridgeCore
import os

/// Unified UIKit touch surface that turns finger input into
/// `TouchEvent`s. Embedded by the trackpad screen and the
/// keyboard's mini-trackpad; owns every gesture recognizer, the
/// double-tap-hold drag state machine, scroll momentum, and haptics.
final class TouchSurfaceUIView: UIView {

    // MARK: - Configuration

    /// One callback per decoded gesture; the host forwards to the Mac.
    var onEvent: ((TouchEvent) -> Void)?
    /// Cursor-preview callback: normalized 0...1 location + pressed flag.
    var onTouch: ((CGPoint, Bool) -> Void)?
    /// Modifier bitmask bridged from the host's IBModifierBar state.
    var modifierMask: UInt8 = 0
    /// 1...5 pointer sensitivity, read by the host from @AppStorage.
    var sensitivity: Int = 3
    var scrollTickHaptics: Bool = true
    var clickHaptics: Bool = true

    private static let log = Logger(subsystem: "com.ibridge", category: "touchsurface")

    private var singlePan: UIPanGestureRecognizer!
    private var scrollPan: UIPanGestureRecognizer!
    private var threePan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Trackpad surface"
        accessibilityTraits = .allowsDirectInteraction
        installRecognizers()
        prepareHaptics()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// CADisplayLink strongly retains its target; stop momentum when the
    /// view leaves the window so the view isn't kept alive mid-switch.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopMomentum()
        }
    }

    // MARK: - Recognizers

    private func installRecognizers() {
        singlePan = UIPanGestureRecognizer(target: self, action: #selector(handleSinglePan(_:)))
        singlePan.minimumNumberOfTouches = 1
        singlePan.maximumNumberOfTouches = 1
        singlePan.cancelsTouchesInView = false
        addGestureRecognizer(singlePan)

        scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        scrollPan.cancelsTouchesInView = false
        addGestureRecognizer(scrollPan)

        threePan = UIPanGestureRecognizer(target: self, action: #selector(handleThreePan(_:)))
        threePan.minimumNumberOfTouches = 3
        threePan.maximumNumberOfTouches = 3
        threePan.cancelsTouchesInView = false
        addGestureRecognizer(threePan)

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTouchesRequired = 1
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleRightTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        rightTap.cancelsTouchesInView = false
        addGestureRecognizer(rightTap)

        let threeTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeTap(_:)))
        threeTap.numberOfTouchesRequired = 3
        threeTap.cancelsTouchesInView = false
        addGestureRecognizer(threeTap)
    }

    @objc private func handleSinglePan(_ rec: UIPanGestureRecognizer) {
        let location = rec.location(in: self)
        switch rec.state {
        case .began:
            lastDragLocation = location
            onTouch?(normalize(location), true)
            if Date().timeIntervalSince1970 - lastTapTime < doubleTapWindow
                && hypot(location.x - lastTapLocation.x, location.y - lastTapLocation.y) < doubleTapSlop {
                dragArmed = true
                Self.log.debug("dragStart (double-tap-hold)")
                emit(phase: .dragStart, at: location)
                if clickHaptics { heavyImpact.impactOccurred() }
            } else {
                emit(phase: .down, at: location)
            }
        case .changed:
            guard let last = lastDragLocation,
                  bounds.width > 0, bounds.height > 0 else { return }
            let rawDX = Float(location.x - last.x) / Float(bounds.width)
            let rawDY = Float(location.y - last.y) / Float(bounds.height)
            lastDragLocation = location
            onTouch?(normalize(location), true)
            let (dx, dy) = TrackpadMath.accelerate(dx: rawDX, dy: rawDY, sensitivity: sensitivity)
            emit(phase: .move, at: location, dx: dx, dy: dy)
        case .ended, .cancelled, .failed:
            lastDragLocation = nil
            if dragArmed {
                dragArmed = false
                if clickHaptics { lightImpact.impactOccurred() }
            }
            onTouch?(normalize(location), false)
            emit(phase: .up, at: location)
        default:
            break
        }
    }

    @objc private func handleScrollPan(_ rec: UIPanGestureRecognizer) {
        let translation = rec.translation(in: self)
        switch rec.state {
        case .changed:
            rec.setTranslation(.zero, in: self)
            emitScroll(deltaPoints: translation)
        case .ended:
            rec.setTranslation(.zero, in: self)
            let velocity = rec.velocity(in: self)
            if hypot(velocity.x, velocity.y) > 40 {
                startMomentum(velocity: velocity)
            }
        case .cancelled:
            rec.setTranslation(.zero, in: self)
        default:
            break
        }
    }

    @objc private func handleThreePan(_ rec: UIPanGestureRecognizer) {
        guard rec.state == .ended else { return }
        let t = rec.translation(in: self)
        guard hypot(t.x, t.y) > 60 else { return }
        // Main-axis unit vector; up on screen (t.y < 0) is +1.
        let dx: Float = abs(t.y) >= abs(t.x) ? 0 : (t.x > 0 ? 1 : -1)
        let dy: Float = abs(t.y) >= abs(t.x) ? (t.y > 0 ? -1 : 1) : 0
        Self.log.debug("threeFingerSwipe dx=\(dx, privacy: .public) dy=\(dy, privacy: .public)")
        emit(phase: .threeFingerSwipe, at: rec.location(in: self), dx: dx, dy: dy)
    }

    @objc private func handlePinch(_ rec: UIPinchGestureRecognizer) {
        switch rec.state {
        case .began:
            lastPinchScale = 1
            pinchBoundaryFired = false
        case .changed:
            let delta = Float(rec.scale - lastPinchScale)
            lastPinchScale = rec.scale
            emit(phase: .pinch, at: rec.location(in: self), dx: delta)
            if !pinchBoundaryFired && abs(rec.scale - 1) > 0.5 {
                pinchBoundaryFired = true
                mediumImpact.impactOccurred()
            }
        case .ended, .cancelled, .failed:
            lastPinchScale = 1
        default:
            break
        }
    }

    @objc private func handleTap(_ rec: UITapGestureRecognizer) {
        let location = rec.location(in: self)
        lastTapTime = Date().timeIntervalSince1970
        lastTapLocation = location
        onTouch?(normalize(location), false)
        emit(phase: .click, at: location)
        if clickHaptics { mediumImpact.impactOccurred() }
    }

    @objc private func handleRightTap(_ rec: UITapGestureRecognizer) {
        let location = rec.location(in: self)
        emit(phase: .rightDown, at: location)
        emit(phase: .rightUp, at: location, timestampOffsetMicros: 1)
        if clickHaptics { mediumImpact.impactOccurred() }
    }

    @objc private func handleThreeTap(_ rec: UITapGestureRecognizer) {
        emit(phase: .threeFingerTap, at: rec.location(in: self))
    }

    // MARK: - Drag state machine

    private var lastDragLocation: CGPoint?
    private var lastTapTime: TimeInterval = 0
    private var lastTapLocation: CGPoint = .zero
    private var dragArmed = false        // second tap held down
    private let doubleTapWindow: TimeInterval = 0.28
    private let doubleTapSlop: CGFloat = 30   // pt

    // Pinch bookkeeping lives with the drag state (per-sequence).
    private var lastPinchScale: CGFloat = 1
    private var pinchBoundaryFired = false

    // MARK: - Force click (majorRadius)

    private weak var primaryTouch: UITouch?
    private var forceClickFiredThisSequence = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        stopMomentum()
        if primaryTouch == nil, let touch = touches.first {
            primaryTouch = touch
            forceClickFiredThisSequence = false
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard !forceClickFiredThisSequence,
              let primary = primaryTouch,
              touches.contains(primary),
              event?.allTouches?.count == 1,
              primary.majorRadius > 30.0 else { return }
        forceClickFiredThisSequence = true
        Self.log.debug("forceClick majorRadius=\(primary.majorRadius, privacy: .public)")
        emit(phase: .forceClick, at: primary.location(in: self))
        rigidImpact.impactOccurred()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        if let primary = primaryTouch, touches.contains(primary) {
            primaryTouch = nil
            forceClickFiredThisSequence = false
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        touchesEnded(touches, with: event)
    }

    // MARK: - Momentum

    private var momentumLink: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero   // pt/s
    private var momentumLastTimestamp: CFTimeInterval = 0

    private func startMomentum(velocity: CGPoint) {
        stopMomentum()
        momentumVelocity = velocity
        momentumLastTimestamp = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(momentumFrame(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
    }

    @objc private func momentumFrame(_ link: CADisplayLink) {
        let elapsed = link.timestamp - momentumLastTimestamp
        guard elapsed > 0 else { return }
        momentumLastTimestamp = link.timestamp
        guard let step = TrackpadMath.momentumStep(
            velocity: momentumVelocity,
            elapsedSeconds: elapsed
        ) else {
            stopMomentum()
            return
        }
        momentumVelocity = step.newVelocity
        emitScroll(deltaPoints: step.delta)
    }

    // MARK: - Haptics

    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    /// Accumulates scroll travel; fires a selection tick every 24 pt.
    private var scrollTickAccumulator: CGFloat = 0
    private let scrollTickDistance: CGFloat = 24

    private func prepareHaptics() {
        mediumImpact.prepare()
        heavyImpact.prepare()
        lightImpact.prepare()
        rigidImpact.prepare()
        selectionFeedback.prepare()
    }

    private func tickScrollHaptics(deltaPoints: CGPoint) {
        guard scrollTickHaptics else { return }
        scrollTickAccumulator += hypot(deltaPoints.x, deltaPoints.y)
        while scrollTickAccumulator >= scrollTickDistance {
            scrollTickAccumulator -= scrollTickDistance
            selectionFeedback.selectionChanged()
        }
    }

    // MARK: - Emit

    private func emitScroll(deltaPoints: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        emit(
            phase: .scroll,
            at: nil,
            dx: Float(deltaPoints.x) / Float(bounds.width),
            dy: Float(deltaPoints.y) / Float(bounds.height)
        )
        tickScrollHaptics(deltaPoints: deltaPoints)
    }

    private func emit(
        phase: TouchEvent.Phase,
        at location: CGPoint?,
        dx: Float = 0,
        dy: Float = 0,
        timestampOffsetMicros: UInt64 = 0
    ) {
        let ts = UInt64(Date().timeIntervalSince1970 * 1_000_000) &+ timestampOffsetMicros
        var x: Float = 0
        var y: Float = 0
        if let location, bounds.width > 0, bounds.height > 0 {
            x = Float(location.x / bounds.width)
            y = Float(location.y / bounds.height)
        }
        onEvent?(TouchEvent(
            phase: phase,
            x: x, y: y,
            dx: dx, dy: dy,
            modifiers: modifierMask,
            timestampMicros: ts
        ))
    }

    private func normalize(_ p: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: p.x / bounds.width, y: p.y / bounds.height)
    }
}

// MARK: - Simultaneous pinch + two-finger scroll

extension TouchSurfaceUIView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        let pair = Set([gestureRecognizer, other])
        return pair == Set([pinch as UIGestureRecognizer, scrollPan as UIGestureRecognizer])
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI embedding of `TouchSurfaceUIView`. The host owns the
/// modifier-bar state, the sensitivity setting, and the cursor
/// preview; this view only reports gestures.
struct TouchSurface: UIViewRepresentable {

    var modifierMask: UInt8 = 0
    var sensitivity: Int = 3
    var scrollTickHaptics: Bool = true
    var clickHaptics: Bool = true
    var onEvent: ((TouchEvent) -> Void)?
    var onTouch: ((CGPoint, Bool) -> Void)?

    func makeUIView(context: Context) -> TouchSurfaceUIView {
        let view = TouchSurfaceUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: TouchSurfaceUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: TouchSurfaceUIView) {
        view.modifierMask = modifierMask
        view.sensitivity = sensitivity
        view.scrollTickHaptics = scrollTickHaptics
        view.clickHaptics = clickHaptics
        view.onEvent = onEvent
        view.onTouch = onTouch
    }
}
