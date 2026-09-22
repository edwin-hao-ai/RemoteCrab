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
    /// Clutch state: finger lifted mid-drag but the Mac's button is
    /// still DOWN, waiting for the finger to come back. Host shows a
    /// "keep dragging" hint.
    var onClutchChange: ((Bool) -> Void)?
    /// Modifier bitmask bridged from the host's IBModifierBar state.
    var modifierMask: UInt8 = 0
    /// 1...5 pointer sensitivity, read by the host from @AppStorage.
    var sensitivity: Int = 3
    /// 1...5 two-finger scroll sensitivity (separate from the pointer).
    var scrollSensitivity: Int = 3
    /// Match macOS "natural scrolling" (content follows the fingers).
    /// The pref is applied by the trackpad driver, which synthetic events
    /// bypass — so we honour it here.
    var naturalScroll: Bool = true
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
    private var fourPan: UIPanGestureRecognizer!
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
            // Leaving the window mid-drag must not strand the Mac's
            // left button down.
            endDragNow(at: nil)
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

        fourPan = UIPanGestureRecognizer(target: self, action: #selector(handleFourPan(_:)))
        fourPan.minimumNumberOfTouches = 4
        fourPan.maximumNumberOfTouches = 4
        fourPan.cancelsTouchesInView = false
        addGestureRecognizer(fourPan)

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTouchesRequired = 1
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        tapRecognizer = tap

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
            if dragArmed {
                // Already armed by the long-press state machine
                // (touchesBegan) — this pan is the finger finally
                // moving, which is exactly the drag's first motion.
                break
            }
            if Date().timeIntervalSince1970 - lastTapTime < doubleTapWindow
                && hypot(location.x - lastTapLocation.x, location.y - lastTapLocation.y) < doubleTapSlop {
                dragArmed = true
                Self.log.debug("dragStart (double-tap-hold)")
                emit(phase: .dragStart, at: location)
                if clickHaptics { fire(heavyImpact) }
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
            cancelLongPressDrag()
            lastDragLocation = nil
            if dragArmed {
                if rec.state == .ended {
                    // Finger lifted mid-drag: clutch instead of
                    // releasing, so the drag can continue after the
                    // user repositions their finger.
                    startClutch(at: location)
                } else {
                    endDragNow(at: location)
                }
            }
            onTouch?(normalize(location), false)
        default:
            break
        }
    }

    @objc private func handleScrollPan(_ rec: UIPanGestureRecognizer) {
        switch rec.state {
        case .changed:
            let translation = rec.translation(in: self)
            rec.setTranslation(.zero, in: self)
            let scaled = TrackpadMath.accelerateScroll(
                dx: translation.x, dy: translation.y, sensitivity: scrollSensitivity)
            if let out = scrollCoalescer.add(scaled, at: CACurrentMediaTime()) {
                let v = rec.velocity(in: self)
                emitScroll(deltaPoints: out, speed: hypot(v.x, v.y))
            }
        case .ended:
            rec.setTranslation(.zero, in: self)
            let velocity = rec.velocity(in: self)
            if let out = scrollCoalescer.flush() {
                emitScroll(deltaPoints: out, speed: hypot(velocity.x, velocity.y))
            }
            if hypot(velocity.x, velocity.y) >= TrackpadMath.momentumCutoff {
                startMomentum(velocity: velocity)
            }
        case .cancelled:
            rec.setTranslation(.zero, in: self)
            _ = scrollCoalescer.flush()
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
        fire(mediumImpact)
    }

    /// Four-finger swipes emit the same phase as three-finger ones:
    /// macOS maps both to the same Mission Control family (switch
    /// Space, Mission Control, App Exposé) by default.
    @objc private func handleFourPan(_ rec: UIPanGestureRecognizer) {
        guard rec.state == .ended else { return }
        let t = rec.translation(in: self)
        guard hypot(t.x, t.y) > 60 else { return }
        let dx: Float = abs(t.y) >= abs(t.x) ? 0 : (t.x > 0 ? 1 : -1)
        let dy: Float = abs(t.y) >= abs(t.x) ? (t.y > 0 ? -1 : 1) : 0
        Self.log.debug("fourFingerSwipe dx=\(dx, privacy: .public) dy=\(dy, privacy: .public)")
        emit(phase: .threeFingerSwipe, at: rec.location(in: self), dx: dx, dy: dy)
        fire(mediumImpact)
    }

    @objc private func handlePinch(_ rec: UIPinchGestureRecognizer) {
        switch rec.state {
        case .began:
            lastPinchScale = 1
            pinchBoundaryFired = false
            pinchSmoother.reset()
        case .changed:
            let raw = rec.scale - lastPinchScale
            lastPinchScale = rec.scale
            if let delta = pinchSmoother.delta(forScaleDelta: raw) {
                emit(phase: .pinch, at: rec.location(in: self), dx: Float(delta))
            }
            if !pinchBoundaryFired && abs(rec.scale - 1) > 0.5 {
                pinchBoundaryFired = true
                fire(mediumImpact)
            }
        case .ended, .cancelled, .failed:
            lastPinchScale = 1
            pinchSmoother.reset()
        default:
            break
        }
    }

    @objc private func handleTap(_ rec: UITapGestureRecognizer) {
        // Tapping to brake a momentum glide stops the scroll, it does not
        // click (macOS behaviour).
        if CACurrentMediaTime() - momentumStoppedAt < 0.12 { return }
        let location = rec.location(in: self)
        lastTapTime = Date().timeIntervalSince1970
        lastTapLocation = location
        onTouch?(normalize(location), false)
        emit(phase: .click, at: location)
        if clickHaptics { fire(mediumImpact) }
    }

    @objc private func handleRightTap(_ rec: UITapGestureRecognizer) {
        let location = rec.location(in: self)
        emit(phase: .rightDown, at: location)
        emit(phase: .rightUp, at: location, timestampOffsetMicros: 1)
        if clickHaptics { fire(mediumImpact) }
    }

    @objc private func handleThreeTap(_ rec: UITapGestureRecognizer) {
        emit(phase: .threeFingerTap, at: rec.location(in: self))
        fire(mediumImpact)
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
            // A drag's release must never land as a click on the Mac.
            tapRecognizer?.isEnabled = !dragArmed
            onDragArmedChange?(dragArmed)
        }
    }
    private let doubleTapWindow: TimeInterval = 0.35
    private let doubleTapSlop: CGFloat = 30   // pt

    // Long-press drag (press-and-hold still) — same drag, discoverable
    // trigger. The state machine lives in touchesBegan/Moved/Ended,
    // NOT in the pan recognizer (a pan only begins on movement).
    private var longPressDragWork: DispatchWorkItem?
    private var pressOrigin: CGPoint?
    /// Latest finger position while the hold is pending, so the armed
    // drag starts where the finger actually is.
    private var longPressCurrent: CGPoint?
    private let longPressDragDelay: TimeInterval = 0.45
    private let longPressDragSlop: CGFloat = 12  // pt of allowed jitter while holding
    private weak var tapRecognizer: UITapGestureRecognizer?

    private func cancelLongPressDrag() {
        longPressDragWork?.cancel()
        longPressDragWork = nil
        pressOrigin = nil
        longPressCurrent = nil
    }

    // MARK: - Drag clutch (lift-and-continue)

    /// macOS three-finger-drag style clutch: lifting the finger mid-drag
    /// keeps the Mac's left button DOWN for `clutchWindow`, so the user
    /// can reposition their finger (the cursor dot springs back to
    /// center on lift — the joystick convention) and continue the SAME
    /// selection. Without this, selecting more than one screenful of
    /// text was impossible: the drag ended the moment the finger ran
    /// out of surface. One finger back down continues; a second finger
    /// or the timeout ends the drag for real.
    private var clutchWork: DispatchWorkItem?
    private var clutching = false
    private let clutchWindow: TimeInterval = 0.8

    private func startClutch(at location: CGPoint?) {
        clutchWork?.cancel()
        if !clutching {
            clutching = true
            onClutchChange?(true)
            // Subtle tick: "the button is still held — you're free to
            // lift and reposition". Without feedback the still-down
            // state is invisible on a touchscreen.
            selectionFeedback.prepare()
            selectionFeedback.selectionChanged()
        }
        Self.log.debug("drag clutch started")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.clutching else { return }
            self.endDragNow(at: nil)
        }
        clutchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + clutchWindow, execute: work)
    }

    /// Finger came back down during the clutch window: the drag
    /// continues. A second finger means the user moved on to
    /// scroll/pinch — end the drag instead.
    private func resolveClutchOnTouchDown(touchCount: Int, at location: CGPoint?) {
        guard clutching else { return }
        clutchWork?.cancel()
        clutchWork = nil
        clutching = false
        onClutchChange?(false)
        if touchCount > 1 {
            endDragNow(at: location)
        }
        // Single finger: dragArmed stays true; the pan recognizer's
        // next .began sees the armed state and resumes drag motion
        // without re-emitting dragStart.
    }

    private func endDragNow(at location: CGPoint?) {
        clutchWork?.cancel()
        clutchWork = nil
        if clutching {
            clutching = false
            onClutchChange?(false)
        }
        guard dragArmed else { return }
        dragArmed = false
        Self.log.debug("dragEnd")
        emit(phase: .up, at: location)
        if clickHaptics { fire(lightImpact) }
    }

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
        // A finger landing during a glide brakes it (macOS behaviour);
        // the resulting tap must stop the scroll, not click.
        if momentumLink != nil { momentumStoppedAt = CACurrentMediaTime() }
        stopMomentum()
        // A finger landing during the clutch window either continues
        // the drag (one finger) or ends it (second finger = scroll).
        resolveClutchOnTouchDown(
            touchCount: event?.allTouches?.count ?? touches.count,
            at: touches.first?.location(in: self)
        )
        if wheelScrollEnabled && wheelArmed, let touch = touches.first {
            wheelOrigin = touch.location(in: self)
            wheelTouch = touch
            wheelLastAngle = nil
        }
        if primaryTouch == nil, let touch = touches.first {
            primaryTouch = touch
            forceClickFiredThisSequence = false
        }
        // Long-press drag: ONE finger down and STILL arms the drag —
        // the discoverable touch-screen pattern (double-tap-hold is Mac
        // muscle memory; many users never find it). This MUST live in
        // touchesBegan: a UIPanGestureRecognizer only reaches .began
        // when the finger MOVES, so keying the hold timer off the pan
        // made press-and-hold-still undetectable (the "can't select
        // text" bug). Cancelled by any real movement before the delay.
        if (event?.allTouches?.count ?? 0) > 1 {
            // A second finger means scroll/pinch, never a hold.
            cancelLongPressDrag()
        } else if !dragArmed, let touch = touches.first {
            pressOrigin = touch.location(in: self)
            longPressCurrent = pressOrigin
            let hold = DispatchWorkItem { [weak self] in
                guard let self, !self.dragArmed, self.primaryTouch != nil,
                      let at = self.longPressCurrent ?? self.pressOrigin else { return }
                self.dragArmed = true
                Self.log.debug("dragStart (long-press)")
                self.emit(phase: .dragStart, at: at)
                if self.clickHaptics { self.fire(self.heavyImpact) }
            }
            longPressDragWork?.cancel()
            longPressDragWork = hold
            DispatchQueue.main.asyncAfter(deadline: .now() + longPressDragDelay, execute: hold)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        if wheelScrollEnabled && wheelArmed {
            handleWheelMove(touches)
            return
        }
        // Movement before the hold delay means "positioning the
        // cursor", not "holding to drag" — drop the long-press arm.
        if longPressDragWork != nil, let origin = pressOrigin, let touch = touches.first {
            let point = touch.location(in: self)
            longPressCurrent = point
            if hypot(point.x - origin.x, point.y - origin.y) > longPressDragSlop {
                cancelLongPressDrag()
            }
        }
        guard !forceClickFiredThisSequence,
              let primary = primaryTouch,
              touches.contains(primary),
              event?.allTouches?.count == 1,
              primary.majorRadius > 30.0 else { return }
        forceClickFiredThisSequence = true
        Self.log.debug("forceClick majorRadius=\(primary.majorRadius, privacy: .public)")
        emit(phase: .forceClick, at: primary.location(in: self))
        fire(rigidImpact)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        cancelLongPressDrag()
        // A long-press that armed while the finger was STILL never
        // started the pan recognizer, so no .ended will release the
        // drag — release it here or the Mac's button stays down.
        // Same clutch rule as a pan-ending lift: give the user the
        // reposition window before letting go of the button.
        if dragArmed, singlePan.state == .possible, !clutching {
            startClutch(at: touches.first?.location(in: self))
        }
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
        // A system cancel (gesture stolen, interruption) releases the
        // drag immediately — no clutch grace period.
        endDragNow(at: touches.first?.location(in: self))
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
        fire(mediumImpact)
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
    /// Per-frame retention for the current glide (velocity-scaled).
    private var momentumRetention: CGFloat = 0.94
    /// When the last glide was braked by a touch-down — a tap right after
    /// stops the scroll, it does not click (macOS behaviour).
    private var momentumStoppedAt: CFTimeInterval = 0

    /// Coalesces 120 Hz pan callbacks into ≤60 Hz scroll events.
    private var scrollCoalescer = ScrollCoalescer()
    /// Damps pinch jitter.
    private var pinchSmoother = PinchSmoother()

    private func startMomentum(velocity: CGPoint) {
        stopMomentum()
        momentumVelocity = velocity
        momentumRetention = TrackpadMath.momentumRetention(
            initialSpeed: hypot(velocity.x, velocity.y))
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
            elapsedSeconds: elapsed,
            retention: momentumRetention
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

    /// Accumulates scroll travel; fires a selection tick every
    /// `TrackpadMath.scrollTickDistance` points (speed-adaptive).
    private var scrollTickAccumulator: CGFloat = 0

    private func prepareHaptics() {
        mediumImpact.prepare()
        heavyImpact.prepare()
        lightImpact.prepare()
        rigidImpact.prepare()
        selectionFeedback.prepare()
    }

    /// Generators go stale a few seconds after prepare(); re-arming
    /// right before firing keeps the tap crisp instead of dropped.
    private func fire(_ generator: UIImpactFeedbackGenerator) {
        generator.prepare()
        generator.impactOccurred()
    }

    private func tickScrollHaptics(deltaPoints: CGPoint, speed: CGFloat) {
        guard scrollTickHaptics else { return }
        scrollTickAccumulator += hypot(deltaPoints.x, deltaPoints.y)
        // Adaptive spacing: fast flicks tick less often (no buzz), slow
        // scrubbing ticks tightly for precision.
        let distance = TrackpadMath.scrollTickDistance(speedPointsPerSecond: speed)
        while scrollTickAccumulator >= distance {
            scrollTickAccumulator -= distance
            selectionFeedback.selectionChanged()
        }
    }

    // MARK: - Emit

    private func emitScroll(deltaPoints: CGPoint, speed: CGFloat = 0, momentum: Bool = false) {
        guard uniformReference > 0 else { return }
        // Honour macOS's natural-scrolling preference (vertical axis).
        let dy = naturalScroll ? deltaPoints.y : -deltaPoints.y
        emit(
            phase: .scroll,
            at: nil,
            dx: Float(deltaPoints.x) / Float(uniformReference),
            dy: Float(dy) / Float(uniformReference),
            momentum: momentum
        )
        // No ticks during the glide — a real trackpad goes silent once
        // the fingers are off.
        if !momentum { tickScrollHaptics(deltaPoints: deltaPoints, speed: speed) }
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
    var scrollSensitivity: Int = 3
    var naturalScroll: Bool = true
    var scrollTickHaptics: Bool = true
    var clickHaptics: Bool = true
    var airMouseEnabled: Bool = false
    var wheelScrollEnabled: Bool = false
    var airMouseActive: Bool = false
    var wheelArmed: Bool = false
    var onEvent: ((TouchEvent) -> Void)?
    var onTouch: ((CGPoint, Bool) -> Void)?
    var onDragArmedChange: ((Bool) -> Void)?
    var onClutchChange: ((Bool) -> Void)?

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
        view.scrollSensitivity = scrollSensitivity
        view.naturalScroll = naturalScroll
        view.scrollTickHaptics = scrollTickHaptics
        view.clickHaptics = clickHaptics
        view.airMouseEnabled = airMouseEnabled
        view.wheelScrollEnabled = wheelScrollEnabled
        view.airMouseActive = airMouseActive
        view.wheelArmed = wheelArmed
        view.onEvent = onEvent
        view.onTouch = onTouch
        view.onDragArmedChange = onDragArmedChange
        view.onClutchChange = onClutchChange
    }
}
