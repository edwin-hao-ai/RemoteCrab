import CoreMotion
import QuartzCore
import SwiftUI
import UIKit
import RemoteCrabCore
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
    /// Selection-mode (double-tap-hold drag) state, for host UI feedback.
    var onDragArmedChange: ((Bool) -> Void)?
    /// Modifier bitmask bridged from the host's IBModifierBar state.
    var modifierMask: UInt8 = 0
    /// 1...5 pointer sensitivity, read by the host from @AppStorage.
    var sensitivity: Int = 3
    var scrollTickHaptics: Bool = true
    var clickHaptics: Bool = true

    /// Labs: gyro air mouse. Bridged from @AppStorage by the host.
    var airMouseEnabled: Bool = false
    /// Labs: circular wheel scrolling. Bridged from @AppStorage by the host.
    var wheelScrollEnabled: Bool = false

    /// Set by the host while its floating air-mouse button is held.
    /// Starts/stops device-motion updates on change.
    var airMouseActive: Bool = false {
        didSet {
            guard airMouseActive != oldValue else { return }
            if airMouseActive { startAirMouse() } else { stopAirMouse() }
        }
    }

    /// Set by the host while its floating wheel button is held. While
    /// armed, single-finger touches steer the scroll wheel instead of
    /// emitting .down/.move.
    var wheelArmed: Bool = false {
        didSet {
            guard wheelArmed != oldValue else { return }
            singlePan.isEnabled = !wheelArmed
            wheelOrigin = nil
            wheelTouch = nil
            wheelLastAngle = nil
            wheelAccumulator = 0
        }
    }

    private static let log = Logger(subsystem: "com.remotecrab", category: "touchsurface")

    private var singlePan: UIPanGestureRecognizer!
    private var scrollPan: UIPanGestureRecognizer!
    private var threePan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = IBLocale.A11y.trackpadSurface
        accessibilityHint = IBLocale.A11y.trackpadSurfaceHint
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
            airMouseActive = false
            wheelArmed = false
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
            }
            // Plain touch-down emits nothing: on the Mac a .down posts a
            // real leftMouseDown, so every casual slide used to arrive as
            // click-hold-drag-release (stealing focus, starting text
            // selections). Pointer motion is hover-only; clicks come from
            // the tap recognizer, drags from double-tap-hold.
        case .changed:
            guard let last = lastDragLocation,
                  uniformReference > 0 else { return }
            // Uniform-axis mapping: BOTH axes are normalized by the
            // same reference (the surface's long edge), so one point of
            // finger travel moves the Mac cursor by the same distance
            // horizontally and vertically. Per-axis normalization made
            // portrait X ~3× more sensitive than Y (short axis mapped
            // to the Mac's long axis) — the "方向感不一致" complaint.
            let rawDX = Float(location.x - last.x) / Float(uniformReference)
            let rawDY = Float(location.y - last.y) / Float(uniformReference)
            lastDragLocation = location
            onTouch?(normalize(location), true)
            // Selection drags use the precision curve: low fixed gain,
            // no acceleration boost, no momentum.
            let (dx, dy) = dragArmed
                ? TrackpadMath.selectionAccelerate(dx: rawDX, dy: rawDY)
                : TrackpadMath.accelerate(dx: rawDX, dy: rawDY, sensitivity: sensitivity)
            emit(phase: .move, at: location, dx: dx, dy: dy)
        case .ended, .cancelled, .failed:
            lastDragLocation = nil
            if dragArmed {
                dragArmed = false
                emit(phase: .up, at: location)   // release the drag
                if clickHaptics { lightImpact.impactOccurred() }
            }
            onTouch?(normalize(location), false)
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
    /// Second tap held down = selection drag. While armed the
    /// two-finger scroll recognizer is disabled (a resting second
    /// finger must not turn a text selection into a scroll) and the
    /// host is notified for visual feedback.
    private var dragArmed = false {
        didSet {
            guard dragArmed != oldValue else { return }
            scrollPan.isEnabled = !dragArmed
            onDragArmedChange?(dragArmed)
        }
    }
    private let doubleTapWindow: TimeInterval = 0.28
    private let doubleTapSlop: CGFloat = 30   // pt

    /// Both pointer and scroll deltas are normalized by the surface's
    /// long edge for BOTH axes — keeps the physical-to-cursor gain
    /// axis-uniform in portrait and landscape alike (the Mac side
    /// multiplies both axes by the screen height).
    private var uniformReference: CGFloat { max(bounds.width, bounds.height) }

    // Pinch bookkeeping lives with the drag state (per-sequence).
    private var lastPinchScale: CGFloat = 1
    private var pinchBoundaryFired = false

    // MARK: - Force click (majorRadius)

    private weak var primaryTouch: UITouch?
    private var forceClickFiredThisSequence = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        stopMomentum()
        if wheelScrollEnabled && wheelArmed, let touch = touches.first {
            wheelOrigin = touch.location(in: self)
            wheelTouch = touch
            wheelLastAngle = nil
        }
        if primaryTouch == nil, let touch = touches.first {
            primaryTouch = touch
            forceClickFiredThisSequence = false
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        if wheelScrollEnabled && wheelArmed {
            handleWheelMove(touches)
            return
        }
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
        if let wheel = wheelTouch, touches.contains(wheel) {
            wheelTouch = nil
            wheelOrigin = nil
            wheelLastAngle = nil
            wheelAccumulator = 0
        }
        if let primary = primaryTouch, touches.contains(primary) {
            primaryTouch = nil
            forceClickFiredThisSequence = false
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        touchesEnded(touches, with: event)
    }

    // MARK: - Air mouse (labs)

    private let motionManager = CMMotionManager()
    /// Attitude captured on the first motion frame after activation;
    /// subsequent frames emit .move deltas relative to it, so holding
    /// a tilt keeps the cursor moving (joystick-style rate control).
    private var referenceAttitude: CMAttitude?

    /// Screen-width fraction of cursor travel per radian of tilt
    /// (π rad ≈ 0.35 screen widths). Sign/direction to be calibrated
    /// on a real device (方向待真机校准).
    private let tiltGain: Float = 0.35 / .pi

    private func startAirMouse() {
        guard airMouseEnabled, motionManager.isDeviceMotionAvailable else { return }
        referenceAttitude = nil
        mediumImpact.impactOccurred()
        Self.log.debug("air mouse activated")
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let attitude = motion.attitude
            guard let ref = self.referenceAttitude else {
                self.referenceAttitude = attitude
                return
            }
            let dx = Float(attitude.roll - ref.roll) * self.tiltGain
            let dy = Float(attitude.pitch - ref.pitch) * self.tiltGain
            guard dx != 0 || dy != 0 else { return }
            self.emit(phase: .move, at: nil, dx: dx, dy: dy)
        }
    }

    private func stopAirMouse() {
        motionManager.stopDeviceMotionUpdates()
        referenceAttitude = nil
    }

    // MARK: - Wheel scrolling (labs)

    private var wheelOrigin: CGPoint?
    /// The finger that armed the wheel; only its moves steer it.
    /// (touches.first on the unordered set can pick a second finger.)
    private weak var wheelTouch: UITouch?
    private var wheelLastAngle: CGFloat?
    private var wheelAccumulator: CGFloat = 0
    /// One scroll tick per 45° of rotation around the hold origin.
    private let wheelTickAngle: CGFloat = .pi / 4
    private let wheelTickDelta: Float = 0.02
    /// Ignore angle samples this close to the origin — atan2 is too
    /// jittery there to accumulate meaningfully.
    private let wheelMinRadius: CGFloat = 20

    private func handleWheelMove(_ touches: Set<UITouch>) {
        guard let origin = wheelOrigin,
              let touch = wheelTouch,
              touches.contains(touch) else { return }
        let p = touch.location(in: self)
        let dx = p.x - origin.x
        let dy = p.y - origin.y
        guard hypot(dx, dy) >= wheelMinRadius else { return }
        let angle = atan2(dy, dx)
        defer { wheelLastAngle = angle }
        guard let last = wheelLastAngle else { return }
        // Wrap the angular delta to ±π so crossing the ±π seam of
        // atan2 doesn't emit a full-turn tick.
        var diff = angle - last
        while diff > .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        // Screen coordinates (y down): increasing angle = clockwise.
        // Clockwise positive → dy +0.02 per tick (natural scroll down).
        wheelAccumulator += diff
        while wheelAccumulator >= wheelTickAngle {
            wheelAccumulator -= wheelTickAngle
            emit(phase: .scroll, at: nil, dy: wheelTickDelta)
            if scrollTickHaptics { selectionFeedback.selectionChanged() }
        }
        while wheelAccumulator <= -wheelTickAngle {
            wheelAccumulator += wheelTickAngle
            emit(phase: .scroll, at: nil, dy: -wheelTickDelta)
            if scrollTickHaptics { selectionFeedback.selectionChanged() }
        }
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
        emitScroll(deltaPoints: step.delta, momentum: true)
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

    private func emitScroll(deltaPoints: CGPoint, momentum: Bool = false) {
        guard uniformReference > 0 else { return }
        emit(
            phase: .scroll,
            at: nil,
            dx: Float(deltaPoints.x) / Float(uniformReference),
            dy: Float(deltaPoints.y) / Float(uniformReference),
            momentum: momentum
        )
        tickScrollHaptics(deltaPoints: deltaPoints)
    }

    private func emit(
        phase: TouchEvent.Phase,
        at location: CGPoint?,
        dx: Float = 0,
        dy: Float = 0,
        momentum: Bool = false,
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
            momentum: momentum ? true : nil,
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
///
/// Contract: `airMouseActive` / `wheelArmed` take effect through
/// `didSet` side effects on the UIView (starting/stopping motion
/// updates, re-arming recognizers). Those setters are only driven
/// from `updateUIView` → `apply`, so the host must route every labs
/// state change through this representable's vars and let SwiftUI
/// re-update the view. A host that caches the UIView and pokes it
/// directly — or stops re-rendering — would silently leave stale
/// labs state behind.
struct TouchSurface: UIViewRepresentable {

    /// VoiceOver label override — the keyboard screen's mini trackpad
    /// reads "Mini trackpad" instead of the full-screen default.
    var label: String? = nil
    var modifierMask: UInt8 = 0
    var sensitivity: Int = 3
    var scrollTickHaptics: Bool = true
    var clickHaptics: Bool = true
    var airMouseEnabled: Bool = false
    var wheelScrollEnabled: Bool = false
    var airMouseActive: Bool = false
    var wheelArmed: Bool = false
    var onEvent: ((TouchEvent) -> Void)?
    var onTouch: ((CGPoint, Bool) -> Void)?
    var onDragArmedChange: ((Bool) -> Void)?

    func makeUIView(context: Context) -> TouchSurfaceUIView {
        let view = TouchSurfaceUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: TouchSurfaceUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: TouchSurfaceUIView) {
        if let label {
            view.accessibilityLabel = label
        }
        view.modifierMask = modifierMask
        view.sensitivity = sensitivity
        view.scrollTickHaptics = scrollTickHaptics
        view.clickHaptics = clickHaptics
        view.airMouseEnabled = airMouseEnabled
        view.wheelScrollEnabled = wheelScrollEnabled
        view.airMouseActive = airMouseActive
        view.wheelArmed = wheelArmed
        view.onEvent = onEvent
        view.onTouch = onTouch
        view.onDragArmedChange = onDragArmedChange
    }
}
