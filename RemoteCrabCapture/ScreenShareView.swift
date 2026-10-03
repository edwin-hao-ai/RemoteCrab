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
    /// Which OS owns the session — the shortcut bar's modifier row shows
    /// Ctrl/Alt/⊞/Shift for a Windows peer instead of ⌃⌥⌘⇧. No default:
    /// this view is the mirror's only route to that row, and an inherited
    /// `.mac` is exactly how the mirror kept advertising a key that isn't
    /// on the peer's keyboard.
    let platform: IBModifierBar.PeerPlatform
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
    /// Extra chrome heights (the app top bar / the shortcut bar + PTT row)
    /// the content is inset by, so it can never sit under the floating
    /// buttons — the landscape "pan hides under the top bar" fix.
    var contentTopChrome: CGFloat = 0
    var contentBottomChrome: CGFloat = 0
    /// Immersive mode (landscape): the surface's own chrome (handle + window
    /// chip + shortcut bar) is hidden too, so the stream owns the screen.
    var chromeCollapsed: Bool = false

    @State private var zoomState = ScreenZoomState(windowWidth: 1, windowHeight: 1, viewSize: .zero)
    /// Sticky / held modifiers, translated to the `IBScreenInput` bitmask.
    @State private var modifiers: Set<IBModifierBar.Modifier> = []
    /// Mirrors the persisted fit/fill choice for `rebuild`.
    @State private var fillsView = false
    /// Secondary chrome (window chip + zoom) revealed by the handle.
    @State private var chromeVisible = false
    @AppStorage("remotecrab.ios.screenFill") private var fillsViewStored = false
    @AppStorage("remotecrab.ios.screenGuideShown") private var guideShown = false
    /// Opens the complete gesture reference, which lives outside the mirror
    /// so it can stay re-readable long after this one-shot hint is gone.
    @State private var showFullGuide = false

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

                // The content is positioned by the pure viewport model (which
                // knows the chrome insets), not a full-screen layer scaled
                // over the black — that is what let a pan slide under the
                // top buttons in landscape.
                ScreenDisplayView(view: displayView)
                    .frame(width: max(1, zoomState.displayedContentRect.width),
                           height: max(1, zoomState.displayedContentRect.height))
                    .position(x: zoomState.displayedContentRect.midX,
                              y: zoomState.displayedContentRect.midY)

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
            .onChange(of: viewportKey) { _, _ in rebuild(size: geo.size, reset: true) }
        }
    }

    /// Identity of the thing being mirrored, for deciding whether a new
    /// `screenInfo` should throw the user's zoom and pan away.
    ///
    /// `screenInfo` is republished every time the window *moves* (the Mac
    /// re-reads its global frame on a 1 s timer so taps keep tracking), and
    /// `CaptureEngine` assigns every one of them. Resetting the viewport on
    /// all of them silently undid the user's pinch on a window that had not
    /// even changed — only a different window or a different capture
    /// resolution needs a fresh viewport, and that is exactly what the
    /// engine already computes to reset the decoder.
    private var viewportKey: String {
        guard let info else { return "-" }
        return "\(info.windowId ?? "-")@\(info.pixelWidth)x\(info.pixelHeight)"
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
            fillsView: fillsView,
            topInset: Double(topInset + contentTopChrome),
            bottomInset: Double(bottomInset + contentBottomChrome)
        )
        if reset { state.reset() }
        zoomState = state
        // Degenerate layouts are the mirror's "black screen with a tiny
        // thumbnail in the corner" failure. `fitSize` divides by
        // `viewSize - insets`, which is floored at 1, so any frame where the
        // GeometryReader reports a collapsed size yields a content rect far
        // smaller than the view — and `max(1, …)` in the view then keeps that
        // stub on screen instead of ignoring it.
        //
        // The test is *relative on both axes*: in fit mode the content always
        // touches the view on ONE axis (the constrained one) and letterboxes
        // on the other — a landscape window on a portrait phone is ~66 %
        // short on the vertical axis and that is correct, so a one-sided gap
        // threshold fired immediately on a healthy layout. Only a gap on
        // *both* axes means the inputs were bad.
        let c = state.displayedContentRect
        let u = size.width - Double(topInset)
        let v = size.height - Double(topInset) - Double(bottomInset)
        let gapX = u > 1 ? (u - c.width) / u : 1
        let gapY = v > 1 ? (v - c.height) / v : 1
        if size.width < 40 || size.height < 40 || (gapX > 0.1 && gapY > 0.1) {
            Forensic.log("[mirror] degenerate layout view=\(Int(size.width))x\(Int(size.height))"
                + " window=\(Int(windowWidth))x\(Int(windowHeight))"
                + " content=\(Int(c.width))x\(Int(c.height)) gap=\(Int(gapX * 100))%/\(Int(gapY * 100))%"
                + " insets=\(Int(topInset))/\(Int(bottomInset)) zoom=\(state.zoom) reset=\(reset)")
        }
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
        if chromeCollapsed {
            // Immersive landscape: nothing floats over the stream.
            EmptyView()
        } else {
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
                              platform: platform,
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
                .background { Capsule().fill(.black.opacity(0.45)) }
                .contentShape(Capsule())
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.94))
        .accessibilityLabel(chromeVisible ? IBLocale.Mirror.hideControls : IBLocale.Mirror.showControls)
    }

    private var chipTitle: String {
        if let name = info?.appName, !name.isEmpty { return name }
        return IBLocale.Mirror.window
    }

    /// Compact window picker. Auto-following costs a single 40 pt icon (same
    /// footprint as fit/fill/zoom); a pinned window adds its short title so
    /// the user can see what is being held. The old chip always carried an
    /// app name + a bare window count, which read as a status readout and ate
    /// a third of the row — nobody could tell it was the "which window"
    /// picker. The menu now states the mode too, so "跟随前面的应用" is no
    /// longer a mystery action.
    private var windowChip: some View {
        let pinned = pinnedWindowId != nil
        return Menu {
            Section(IBLocale.Mirror.windowPicker) {
                Button {
                    onFollowFrontmost()
                } label: {
                    if pinned {
                        Text(IBLocale.Mirror.autoFollow)
                    } else {
                        Label(IBLocale.Mirror.autoFollow, systemImage: "checkmark")
                    }
                }
                ForEach(windows) { window in
                    Button {
                        onSelectWindow(window.id)
                    } label: {
                        if window.id == pinnedWindowId {
                            Label(windowLabel(window), systemImage: "checkmark")
                        } else {
                            Text(windowLabel(window))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pinned ? "pin.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pinned ? Color.accentColor : .white)
                if pinned {
                    Text(chipTitle)
                        .font(IBFont.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, pinned ? 12 : 0)
            .frame(width: pinned ? nil : 40, height: 40)
            .frame(maxWidth: pinned ? 150 : 40)
            .background {
                if pinned {
                    Capsule().fill(.ultraThinMaterial)
                } else {
                    Circle().fill(.ultraThinMaterial)
                }
            }
            .contentShape(pinned ? AnyShape(Capsule()) : AnyShape(Circle()))
        }
        .accessibilityLabel(pinned
                            ? "\(IBLocale.Mirror.pinned): \(chipTitle)"
                            : IBLocale.Mirror.windowPicker)
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
    ///
    /// Its job is DISCOVERY, so it stays to the three gestures that make the
    /// surface make sense; the complete reference (both surfaces, every
    /// gesture, re-readable any time) is one tap away. Cramming all of them
    /// in here is what made this line unreadable in the first place.
    private var coachMark: some View {
        VStack(spacing: 10) {
            Text(IBLocale.Mirror.guideTitle)
                .font(IBFont.caption.weight(.semibold))
                .foregroundStyle(.white)
            Text(IBLocale.Mirror.guideBody)
                .font(IBFont.caption)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(IBLocale.Mirror.windowPickerHint)
                .font(IBFont.caption)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    showFullGuide = true
                } label: {
                    Text(IBLocale.Coach.seeAll)
                        .font(IBFont.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background { Capsule().fill(.ultraThinMaterial) }
                        .contentShape(Capsule())
                }
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
        }
        .padding(16)
        .frame(maxWidth: 280)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .sheet(isPresented: $showFullGuide) {
            TrackpadGuideView(surface: .mirror)
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

        func setZoom(_ zoom: Double, anchor: CGPoint?) {
            var s = binding.wrappedValue
            s.setZoom(zoom, anchor: anchor)
            binding.wrappedValue = s
        }

        func toggleZoom(at point: CGPoint) {
            var s = binding.wrappedValue
            s.toggleZoom(at: point)
            binding.wrappedValue = s
        }

        func twoFinger(axis: ScreenDragAxis, translation: CGSize) -> ScreenZoomState.TwoFingerResult {
            binding.wrappedValue.twoFinger(axis: axis, translation: translation)
        }

        func panGesture(translation: CGSize) -> ScreenZoomState.TwoFingerResult {
            binding.wrappedValue.panGesture(translation: translation)
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

        /// A scroll needs no position: the mirror shows exactly one window,
        /// so the Mac does not have to be told where to scroll — and sending
        /// a position is what used to drag the Mac's cursor away from the
        /// button the user was aiming at. `.scroll` is therefore never
        /// dropped for landing on the letterbox, which is where a
        /// two-finger swipe usually starts when the window is letterboxed.
        func sendScroll(dx: Float, dy: Float) {
            onInput(IBScreenInput(action: .scroll,
                                  u: 0.5, v: 0.5,
                                  dx: dx, dy: dy,
                                  modifiers: modifierMask,
                                  clickCount: 1,
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
        private let threeFingerPan = UIPanGestureRecognizer()
        private let twoFingerTap = UITapGestureRecognizer()
        private let twoFingerDoubleTap = UITapGestureRecognizer()
        private let pinch = UIPinchGestureRecognizer()

        private var dragStarted = false
        private var dragStartPoint: CGPoint = .zero
        private var lastUV: (u: Double, v: Double)?
        /// True while a long-press right-click owns the current touch, so
        /// the single-finger pan/tap don't also fire.
        private var rightClickActive = false
        /// A two-finger swipe does ONE thing for its whole lifetime, chosen
        /// once from the accumulated travel: a **scroll** on the locked axis
        /// or a **pan** on the other. Latching it at `.began` from the zoom
        /// level was wrong twice over — it made a zoomed mirror impossible
        /// to scroll (「双指上下滚动失灵，被感应成拖动镜像」), and because the
        /// first pinch starts at zoom 1 it made *pinching* scroll the remote
        /// app too.
        private var twoFingerAxis: ScreenDragAxis = .undecided
        private var twoFingerTravel: CGSize = .zero

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

            // Free 2-axis viewport pan. Two fingers are axis-locked (one of
            // them has to mean "scroll the app"), so panning needs its own
            // gesture — and three fingers is the one that cannot collide
            // with anything else on the surface.
            threeFingerPan.minimumNumberOfTouches = 3
            threeFingerPan.maximumNumberOfTouches = 3
            threeFingerPan.addTarget(self, action: #selector(handleThreeFingerPan))

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
                      twoFingerPan, threeFingerPan, twoFingerTap, twoFingerDoubleTap,
                      pinch] as [UIGestureRecognizer] {
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
                // The slop is a CONTENT distance, so it grows with the zoom:
                // a fixed 10 view points is only 2.5 content points at 4×,
                // which is a real drag on the Mac — a slightly-off tap on a
                // button became a drag-select instead of a click.
                if !dragStarted, moved > (coordinator.state.dragSlop) {
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

        /// Two fingers: ONE axis for the whole gesture, decided from the
        /// accumulated travel. The locked axis scrolls the Mac; the other
        /// pans the viewport when there is room, and scrolls when there
        /// isn't. See `ScreenDragAxis` for why vertical wins a near-tie.
        @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
            guard let coordinator else { return }
            switch g.state {
            case .began:
                g.setTranslation(.zero, in: self)
                twoFingerAxis = .undecided
                twoFingerTravel = .zero
            case .changed:
                let t = g.translation(in: self)
                // Always consume the translation, even while yielding: leaving
                // it banked would hand the pinch's centroid drift to the axis
                // lock as one huge delta the moment the pinch ended.
                g.setTranslation(.zero, in: self)
                // The pinch owns both fingers while it is running. Letting the
                // pan run too meant a pinch whose centroid drifted also
                // scrolled or panned the view — the user asked to magnify and
                // got a transform nobody asked for.
                guard pinch.state != .began, pinch.state != .changed else { return }
                twoFingerTravel.width += t.x
                twoFingerTravel.height += t.y
                let axisJustLocked = twoFingerAxis == .undecided
                if twoFingerAxis == .undecided {
                    twoFingerAxis = ScreenDragAxis.decide(twoFingerTravel)
                    if axisJustLocked {
                        Forensic.log("[mirror] two-finger latched \(axisLogName(twoFingerAxis))"
                            + " travel=(\(Int(twoFingerTravel.width)),\(Int(twoFingerTravel.height)))"
                            + " zoom=\(String(format: "%.2f", coordinator.state.zoom))"
                            + " canPanX=\(coordinator.state.canPanHorizontally)")
                    }
                }
                let result = coordinator.twoFinger(
                    axis: twoFingerAxis,
                    translation: CGSize(width: t.x, height: t.y))
                coordinator.commitPan(result.pan)
                if result.isScroll {
                    coordinator.sendScroll(dx: Float(result.scrollDX),
                                           dy: Float(result.scrollDY))
                }
            default:
                twoFingerAxis = .undecided
                twoFingerTravel = .zero
            }
        }

        /// Three fingers: free 2-axis viewport pan, handing off to a scroll
        /// once an edge is reached (so a pan that runs out of room still
        /// does something useful).
        @objc private func handleThreeFingerPan(_ g: UIPanGestureRecognizer) {
            guard let coordinator else { return }
            switch g.state {
            case .began:
                g.setTranslation(.zero, in: self)
            case .changed:
                let t = g.translation(in: self)
                g.setTranslation(.zero, in: self)
                // A three-finger drag is not a magnifier: UIPinch also tracks
                // three touches, and letting it run would drift the zoom on
                // every pan.
                guard pinch.state != .began, pinch.state != .changed else { return }
                let result = coordinator.panGesture(
                    translation: CGSize(width: t.x, height: t.y))
                coordinator.commitPan(result.pan)
                if result.isScroll {
                    coordinator.sendScroll(dx: Float(result.scrollDX),
                                           dy: Float(result.scrollDY))
                }
            default:
                break
            }
        }

        /// Marker-friendly name for the latched axis. The whole point of the
        /// latch is that it is invisible until it is wrong, so it has to be
        /// observable from the device log.
        private func axisLogName(_ axis: ScreenDragAxis) -> String {
            switch axis {
            case .undecided: return "undecided"
            case .horizontal: return "horizontal"
            case .vertical: return "vertical"
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
            // Anchor on the point BETWEEN the two fingers. Zooming about the
            // view centre instead made the thing you were pinching slide out
            // from under your fingertips — measured at 168 pt for a 2× pinch
            // near the top-left of the content, usually off the screen
            // entirely — so afterwards there was no button left to hit.
            // `ScreenZoomState.setZoom(_:anchor:)` already does this and is
            // tested; the pinch path simply never called it.
            let anchor = g.location(in: self)
            if g.state == .began {
                Forensic.log("[mirror] pinch began anchor=(\(Int(anchor.x)),\(Int(anchor.y)))"
                    + " zoom=\(String(format: "%.2f", coordinator.state.zoom))"
                    + " rect=\(Int(coordinator.state.displayedContentRect.minX)),\(Int(coordinator.state.displayedContentRect.minY))"
                    + " \(Int(coordinator.state.displayedContentRect.width))x\(Int(coordinator.state.displayedContentRect.height))")
            }
            coordinator.setZoom(coordinator.state.zoom * Double(g.scale),
                                anchor: anchor)
            if g.state == .ended {
                Forensic.log("[mirror] pinch ended zoom=\(String(format: "%.2f", coordinator.state.zoom))"
                    + " rect=\(Int(coordinator.state.displayedContentRect.minX)),\(Int(coordinator.state.displayedContentRect.minY))"
                    + " \(Int(coordinator.state.displayedContentRect.width))x\(Int(coordinator.state.displayedContentRect.height))"
                    + " slop=\(Int(coordinator.state.dragSlop))")
            }
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
