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
    /// False while the mirror is only a backdrop (e.g. behind the
    /// keyboard surface) so it never steals touches from the layer above.
    var inputEnabled: Bool = true
    /// Locked / held modifiers forwarded as REAL key events (the Mac
    /// injector sends them as physical keys so an input method's panel
    /// opens, exactly like the trackpad's bar).
    var onModifierKey: ((UInt16, Bool) -> Void)?
    /// Quick keys (⏎ ⌫ esc ，。) forwarded to the Mac as KeyEvents.
    var onKey: ((KeyEvent) -> Void)?
    /// Opens the context sheet (情景模式) from the bar's context chip.
    var onOpenContext: (() -> Void)?
    /// Mac windows offered by the window chip (already filtered/sorted).
    var windows: [IBWindowInfo] = []
    /// The window the user pinned; nil = following the Mac's frontmost app.
    var pinnedWindowId: String?
    var onSelectWindow: (String) -> Void = { _ in }
    var onFollowFrontmost: () -> Void = {}
    /// Safe-area insets, so the floating controls clear the app's top bar
    /// and the bottom keyboard/PTT row.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    @State private var zoomState = ScreenZoomState(windowWidth: 1, windowHeight: 1, viewSize: .zero)
    /// Sticky / held modifiers, translated to the `IBScreenInput` bitmask.
    @State private var modifiers: Set<IBModifierBar.Modifier> = []
    /// Mirrors the persisted fit/fill choice for `rebuild`.
    @State private var fillsView = false
    /// Secondary chrome (window chip + zoom) revealed by the handle.
    @State private var chromeVisible = false
    @AppStorage("remotecrab.ios.screenFill") private var fillsViewStored = false
    @AppStorage("remotecrab.ios.screenGuideShown") private var guideShown = false

    /// shift=1, control=2, option=4, command=8 — matches `TouchEvent`.
    private var modifierMask: UInt8 {
        var mask: UInt8 = 0
        if modifiers.contains(.shift) { mask |= 1 }
        if modifiers.contains(.control) { mask |= 2 }
        if modifiers.contains(.option) { mask |= 4 }
        if modifiers.contains(.command) { mask |= 8 }
        return mask
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                ScreenDisplayView(view: displayView)
                    .scaleEffect(zoomState.zoom)
                    .offset(zoomState.pan)

                ScreenGestureOverlay(zoomState: $zoomState,
                                     onInput: onInput,
                                     modifierMask: modifierMask)
                    .allowsHitTesting(inputEnabled)

                if inputEnabled {
                    controls(in: geo.size)
                }
            }
            .onAppear {
                fillsView = fillsViewStored
                applyVideoGravity()
                rebuild(size: geo.size, reset: true)
            }
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
            pan: reset ? .zero : zoomState.pan,
            fillsView: fillsView
        )
        if reset { state.reset() }
        zoomState = state
    }

    /// `resizeAspect` letterboxes (fit); `resizeAspectFill` crops (fill).
    /// Without this the two viewport modes would map touches to the wrong
    /// content coordinates.
    private func applyVideoGravity() {
        displayView.displayLayer.videoGravity = fillsView ? .resizeAspectFill : .resizeAspect
    }

    // MARK: - Floating controls

    private var controlsBottomPad: CGFloat { bottomInset + 76 }
    private var controlsTopPad: CGFloat { topInset + 72 }

    @ViewBuilder
    private func controls(in size: CGSize) -> some View {
        ZStack {
            // Secondary chrome (window chip + fit/fill + zoom) is COLLAPSED
            // by default so the mirrored window gets the whole screen; a
            // small handle centred under the top bar reveals it.
            VStack(spacing: IBSpace.s.pt) {
                chromeHandle
                if chromeVisible {
                    HStack(spacing: IBSpace.s.pt) {
                        windowChip
                        Spacer(minLength: 0)
                        zoomControls(in: size)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, IBSpace.l.pt)
            .padding(.top, controlsTopPad)

            // Same shortcut bar as the trackpad: pinned context chip +
            // one horizontally-scrollable row of keys + modifier bar.
            VStack {
                Spacer(minLength: 0)
                IBShortcutBar(activeModifiers: $modifiers,
                              contextTitle: info?.appName ?? IBLocale.Mirror.computer,
                              onContext: onOpenContext,
                              onKey: { onKey?($0) },
                              onModifierKey: onModifierKey)
            }
            .padding(.bottom, controlsBottomPad)

            if !guideShown {
                coachMark
            }
        }
    }

    /// The grab handle that reveals/hides the secondary chrome.
    private var chromeHandle: some View {
        Button {
            withAnimation(IBAnimation.snappy) { chromeVisible.toggle() }
        } label: {
            Image(systemName: chromeVisible ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 66, height: 26)
                .background { Capsule().fill(.ultraThinMaterial) }
                .contentShape(Capsule())
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.94))
        .accessibilityLabel(chromeVisible ? IBLocale.Mirror.hideControls : IBLocale.Mirror.showControls)
    }

    private var chipTitle: String {
        if let name = info?.appName, !name.isEmpty { return name }
        return IBLocale.Mirror.window
    }

    private var windowChip: some View {
        Menu {
            ForEach(windows) { window in
                Button {
                    onSelectWindow(window.id)
                } label: {
                    if window.id == (info?.windowId ?? pinnedWindowId) {
                        Label(windowLabel(window), systemImage: "checkmark")
                    } else {
                        Text(windowLabel(window))
                    }
                }
            }
            if !windows.isEmpty { Divider() }
            Button {
                onFollowFrontmost()
            } label: {
                Label(IBLocale.Mirror.followFrontmost, systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "macwindow")
                    .font(.system(size: 12, weight: .medium))
                Text(chipTitle)
                    .font(IBFont.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(windows.count)")
                    .font(IBFont.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.6))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background { Capsule().fill(.ultraThinMaterial) }
            .contentShape(Capsule())
        }
    }

    private func windowLabel(_ window: IBWindowInfo) -> String {
        if !window.title.isEmpty { return window.title }
        if !window.appName.isEmpty { return window.appName }
        return window.id
    }

    private func zoomControls(in size: CGSize) -> some View {
        HStack(spacing: 8) {
            Button {
                toggleFills(in: size)
            } label: {
                controlIcon(fillsView
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel(fillsView ? IBLocale.Mirror.fitWindow : IBLocale.Mirror.fillView)

            Button {
                toggleZoom(in: size)
            } label: {
                Text(zoomState.zoom > 1.01 ? "1×" : "2×")
                    .font(IBFont.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background { Circle().fill(.ultraThinMaterial) }
                    .contentShape(Circle())
            }
            .accessibilityLabel(IBLocale.Mirror.toggleZoom)
        }
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background { Circle().fill(.ultraThinMaterial) }
            .contentShape(Circle())
    }

    private func toggleFills(in size: CGSize) {
        let newValue = !fillsView
        fillsView = newValue
        fillsViewStored = newValue
        applyVideoGravity()
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var state = zoomState
        state.setFillsView(newValue, anchor: center)
        zoomState = state
        rebuild(size: size)
    }

    private func toggleZoom(in size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var state = zoomState
        state.toggleZoom(at: center)
        zoomState = state
    }

    /// First-use hint. Non-blocking: only the card itself is hit-testable,
    /// so the mirror still responds everywhere else.
    private var coachMark: some View {
        VStack(spacing: 10) {
            Text(IBLocale.Mirror.guideTitle)
                .font(IBFont.caption.weight(.semibold))
                .foregroundStyle(.white)
            Text(IBLocale.Mirror.guideBody)
                .font(IBFont.caption)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button {
                guideShown = true
            } label: {
                Text(IBLocale.Mirror.gotIt)
                    .font(IBFont.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background { Capsule().fill(Color.accentColor) }
                    .contentShape(Capsule())
            }
        }
        .padding(16)
        .frame(maxWidth: 280)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }
}

// MARK: - Gesture overlay

/// UIKit gesture layer over the mirror. SwiftUI can't express a
/// two-finger pan, so all recognizers live here and report positions
/// converted to window `(u, v)` through `ScreenZoomState`.
struct ScreenGestureOverlay: UIViewRepresentable {

    @Binding var zoomState: ScreenZoomState
    var onInput: (IBScreenInput) -> Void
    /// Modifier bitmask applied to every emitted input.
    var modifierMask: UInt8 = 0

    func makeUIView(context: Context) -> ScreenGestureView {
        let view = ScreenGestureView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ScreenGestureView, context: Context) {
        uiView.coordinator = context.coordinator
        context.coordinator.onInput = onInput
        context.coordinator.modifierMask = modifierMask
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomState: $zoomState, onInput: onInput, modifierMask: modifierMask)
    }

    /// Bridges the SwiftUI `@State` viewport model to the UIKit gesture
    /// callbacks (which always run on the main thread).
    final class Coordinator {
        private let binding: Binding<ScreenZoomState>
        var onInput: (IBScreenInput) -> Void
        var modifierMask: UInt8

        init(zoomState: Binding<ScreenZoomState>,
             onInput: @escaping (IBScreenInput) -> Void,
             modifierMask: UInt8) {
            self.binding = zoomState
            self.onInput = onInput
            self.modifierMask = modifierMask
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

        func toggleZoom(at point: CGPoint) {
            var s = binding.wrappedValue
            s.toggleZoom(at: point)
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
                  dx: Float = 0, dy: Float = 0,
                  clickCount: Int = 1) {
            guard let uv else { return }
            onInput(IBScreenInput(action: action,
                                  u: Float(uv.u), v: Float(uv.v),
                                  dx: dx, dy: dy,
                                  modifiers: modifierMask,
                                  clickCount: clickCount,
                                  timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000)))
        }
    }

    final class ScreenGestureView: UIView, UIGestureRecognizerDelegate {

        weak var coordinator: Coordinator?

        private let singleTap = UITapGestureRecognizer()
        private let doubleTap = UITapGestureRecognizer()
        private let tripleTap = UITapGestureRecognizer()
        private let singlePan = UIPanGestureRecognizer()
        private let longPress = UILongPressGestureRecognizer()
        private let twoFingerPan = UIPanGestureRecognizer()
        private let twoFingerTap = UITapGestureRecognizer()
        private let twoFingerDoubleTap = UITapGestureRecognizer()
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

            // Double = select word, triple = select paragraph. They must
            // NOT be mapped to zoom (that would steal word selection).
            doubleTap.numberOfTapsRequired = 2
            doubleTap.addTarget(self, action: #selector(handleDoubleTap))
            tripleTap.numberOfTapsRequired = 3
            tripleTap.addTarget(self, action: #selector(handleTripleTap))

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

            // Gesture-only zoom shortcut; the single two-finger tap stays
            // right-click, so chain double behind single.
            twoFingerDoubleTap.numberOfTouchesRequired = 2
            twoFingerDoubleTap.numberOfTapsRequired = 2
            twoFingerDoubleTap.addTarget(self, action: #selector(handleTwoFingerDoubleTap))

            pinch.addTarget(self, action: #selector(handlePinch))

            // A stationary tap makes the pan fail, then the tap fires.
            // A long press must win over the tap; a drag still begins as
            // soon as it moves past the pan threshold (well under 0.45 s).
            singleTap.require(toFail: singlePan)
            singleTap.require(toFail: longPress)
            // single < double < triple.
            singleTap.require(toFail: doubleTap)
            doubleTap.require(toFail: tripleTap)
            twoFingerTap.require(toFail: twoFingerPan)
            twoFingerTap.require(toFail: twoFingerDoubleTap)

            for g in [singleTap, doubleTap, tripleTap, singlePan, longPress,
                      twoFingerPan, twoFingerTap, twoFingerDoubleTap, pinch] as [UIGestureRecognizer] {
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

        @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard !rightClickActive else { return }
            coordinator?.send(.click, uv: coordinator?.contentUV(for: g.location(in: self)),
                              clickCount: 2)
        }

        @objc private func handleTripleTap(_ g: UITapGestureRecognizer) {
            guard !rightClickActive else { return }
            coordinator?.send(.click, uv: coordinator?.contentUV(for: g.location(in: self)),
                              clickCount: 3)
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

        @objc private func handleTwoFingerDoubleTap(_ g: UITapGestureRecognizer) {
            coordinator?.toggleZoom(at: g.location(in: self))
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
