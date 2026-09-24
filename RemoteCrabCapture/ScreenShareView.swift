import AVFoundation
import SwiftUI
import UIKit
import RemoteCrabCore

/// The display host for the screen mirror. Backed by an
/// `AVSampleBufferDisplayLayer`; `CaptureEngine` enqueues decoded
/// sample buffers into `displayLayer`. The view is owned by the engine
/// (one per app) so SwiftUI can reparent it without recreating layers.
final class ScreenDisplayUIView: UIView {

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// SwiftUI wrapper that reparents the engine's shared display view
/// (`videoGravity = .resizeAspect` fits the window into the bounds).
struct ScreenDisplayView: UIViewRepresentable {
    let view: ScreenDisplayUIView

    func makeUIView(context: Context) -> ScreenDisplayUIView { view }

    func updateUIView(_ uiView: ScreenDisplayUIView, context: Context) {}
}

/// Full-screen mirror surface: the display layer plus local zoom/pan and
/// direct-manipulation input. All viewport math lives in the pure
/// `ScreenZoomState` (RemoteCrabCore).
struct ScreenShareView: View {

    let displayView: ScreenDisplayUIView
    /// Current mirror geometry; drives `ScreenZoomState.windowSize`.
    let info: IBScreenInfo?
    /// Called for every input the user performs on the mirror.
    var onInput: (IBScreenInput) -> Void

    @State private var zoomState = ScreenZoomState(windowWidth: 1, windowHeight: 1, viewSize: .zero)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                ScreenDisplayView(view: displayView)
                    .scaleEffect(zoomState.zoom)
                    .offset(zoomState.pan)

                ScreenGestureOverlay(zoomState: $zoomState, onInput: onInput)
            }
            .onAppear { rebuild(size: geo.size, reset: true) }
            .onChange(of: geo.size) { _, size in rebuild(size: size) }
            .onChange(of: info) { _, _ in rebuild(size: geo.size, reset: true) }
        }
    }

    /// Rebuild the pure viewport model for the current window + view
    /// size. `reset` is used when the target window changes, so a new
    /// window starts fitted instead of at the old zoom/pan.
    private func rebuild(size: CGSize, reset: Bool = false) {
        let windowWidth = info?.width ?? 1
        let windowHeight = info?.height ?? 1
        var state = ScreenZoomState(
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            viewSize: size,
            zoom: reset ? 1 : zoomState.zoom,
            pan: reset ? .zero : zoomState.pan
        )
        if reset { state.reset() }
        zoomState = state
    }
}

// MARK: - Gesture overlay

/// UIKit gesture layer over the mirror. SwiftUI can't express a
/// two-finger pan, so all recognizers live here and report positions
/// converted to window `(u, v)` through `ScreenZoomState`.
struct ScreenGestureOverlay: UIViewRepresentable {

    @Binding var zoomState: ScreenZoomState
    var onInput: (IBScreenInput) -> Void

    func makeUIView(context: Context) -> ScreenGestureView {
        let view = ScreenGestureView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ScreenGestureView, context: Context) {
        uiView.coordinator = context.coordinator
        context.coordinator.onInput = onInput
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomState: $zoomState, onInput: onInput)
    }

    /// Bridges the SwiftUI `@State` viewport model to the UIKit gesture
    /// callbacks (which always run on the main thread).
    final class Coordinator {
        private let binding: Binding<ScreenZoomState>
        var onInput: (IBScreenInput) -> Void

        init(zoomState: Binding<ScreenZoomState>, onInput: @escaping (IBScreenInput) -> Void) {
            self.binding = zoomState
            self.onInput = onInput
        }

        var state: ScreenZoomState { binding.wrappedValue }

        func commitPan(_ pan: CGSize) {
            var s = binding.wrappedValue
            s.commitPan(pan)
            binding.wrappedValue = s
        }

        func setZoom(_ zoom: Double) {
            var s = binding.wrappedValue
            s.setZoom(zoom)
            binding.wrappedValue = s
        }

        func twoFinger(translation: CGSize) -> ScreenZoomState.TwoFingerResult {
            binding.wrappedValue.twoFinger(translation: translation)
        }

        func contentUV(for point: CGPoint) -> (u: Double, v: Double)? {
            binding.wrappedValue.contentUV(forViewPoint: point)
        }

        func send(_ action: IBScreenInput.Action,
                  uv: (u: Double, v: Double)?,
                  dx: Float = 0, dy: Float = 0) {
            guard let uv else { return }
            onInput(IBScreenInput(action: action,
                                  u: Float(uv.u), v: Float(uv.v),
                                  dx: dx, dy: dy,
                                  timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000)))
        }
    }

    final class ScreenGestureView: UIView, UIGestureRecognizerDelegate {

        weak var coordinator: Coordinator?

        private let singleTap = UITapGestureRecognizer()
        private let singlePan = UIPanGestureRecognizer()
        private let longPress = UILongPressGestureRecognizer()
        private let twoFingerPan = UIPanGestureRecognizer()
        private let twoFingerTap = UITapGestureRecognizer()
        private let pinch = UIPinchGestureRecognizer()

        private var dragStarted = false
        private var dragStartPoint: CGPoint = .zero
        private var lastUV: (u: Double, v: Double)?
        /// True while a long-press right-click owns the current touch, so
        /// the single-finger pan/tap don't also fire.
        private var rightClickActive = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = true
            setupGestures()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private func setupGestures() {
            singleTap.numberOfTouchesRequired = 1
            singleTap.addTarget(self, action: #selector(handleTap))

            singlePan.minimumNumberOfTouches = 1
            singlePan.maximumNumberOfTouches = 1
            singlePan.addTarget(self, action: #selector(handleSinglePan))

            longPress.minimumPressDuration = 0.45
            longPress.allowableMovement = 12
            longPress.addTarget(self, action: #selector(handleLongPress))

            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.addTarget(self, action: #selector(handleTwoFingerPan))

            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.addTarget(self, action: #selector(handleTwoFingerTap))

            pinch.addTarget(self, action: #selector(handlePinch))

            // A stationary tap makes the pan fail, then the tap fires.
            // A long press must win over the tap; a drag still begins as
            // soon as it moves past the pan threshold (well under 0.45 s).
            singleTap.require(toFail: singlePan)
            singleTap.require(toFail: longPress)
            twoFingerTap.require(toFail: twoFingerPan)

            for g in [singleTap, singlePan, longPress, twoFingerPan, twoFingerTap, pinch] as [UIGestureRecognizer] {
                g.cancelsTouchesInView = false
                g.delegate = self
                addGestureRecognizer(g)
            }
        }

        // MARK: - Single finger

        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            guard !rightClickActive else { return }
            coordinator?.send(.click, uv: coordinator?.contentUV(for: g.location(in: self)))
        }

        @objc private func handleSinglePan(_ g: UIPanGestureRecognizer) {
            guard !rightClickActive, let coordinator else { return }
            let point = g.location(in: self)
            switch g.state {
            case .began:
                dragStarted = false
                dragStartPoint = point
                lastUV = coordinator.contentUV(for: dragStartPoint)
            case .changed:
                let moved = hypot(point.x - dragStartPoint.x, point.y - dragStartPoint.y)
                if !dragStarted, moved > 10 {
                    dragStarted = true
                    let startUV = coordinator.contentUV(for: dragStartPoint)
                    if let startUV {
                        lastUV = startUV
                        coordinator.send(.dragStart, uv: startUV)
                    }
                }
                if dragStarted, let uv = coordinator.contentUV(for: point) {
                    lastUV = uv
                    coordinator.send(.dragMove, uv: uv)
                }
            case .ended, .cancelled:
                if dragStarted {
                    let uv = coordinator.contentUV(for: point) ?? lastUV
                    coordinator.send(.dragEnd, uv: uv)
                }
                dragStarted = false
                lastUV = nil
            default:
                break
            }
        }

        @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                guard let coordinator else { return }
                rightClickActive = true
                // Cancel the single-finger pan that is still tracking this
                // touch (a plain `guard` in the pan handler isn't enough:
                // the pan hasn't begun yet, but toggling isEnabled aborts
                // its in-flight touch so no drag starts after the press).
                singlePan.isEnabled = false
                singlePan.isEnabled = true
                coordinator.send(.rightClick, uv: coordinator.contentUV(for: g.location(in: self)))
            case .ended, .cancelled, .failed:
                rightClickActive = false
            default:
                break
            }
        }

        // MARK: - Two finger

        @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
            guard let coordinator else { return }
            let point = g.location(in: self)
            switch g.state {
            case .began:
                g.setTranslation(.zero, in: self)
            case .changed:
                let t = g.translation(in: self)
                g.setTranslation(.zero, in: self)
                let delta = CGSize(width: t.x, height: t.y)
                let result = coordinator.twoFinger(translation: delta)
                coordinator.commitPan(result.pan)
                if result.isScroll {
                    coordinator.send(.scroll,
                                     uv: coordinator.contentUV(for: point),
                                     dx: Float(result.scrollDX),
                                     dy: Float(result.scrollDY))
                }
            default:
                break
            }
        }

        @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
            coordinator?.send(.rightClick, uv: coordinator?.contentUV(for: g.location(in: self)))
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let coordinator else { return }
            coordinator.setZoom(coordinator.state.zoom * Double(g.scale))
            g.scale = 1
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Pinch and the two-finger pan cooperate; everything else is
            // ordered by `require(toFail:)`.
            let pair: Set<ObjectIdentifier> = [
                ObjectIdentifier(gestureRecognizer), ObjectIdentifier(other)
            ]
            return pair == [ObjectIdentifier(pinch), ObjectIdentifier(twoFingerPan)]
        }
    }
}
