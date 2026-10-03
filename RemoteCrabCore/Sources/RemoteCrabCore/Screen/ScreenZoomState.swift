import CoreGraphics
import Foundation

/// Which axis a two-finger drag means, latched once per gesture.
///
/// Two fingers have to mean two different things — a content scroll
/// and a viewport pan — and neither can own the gesture outright: a
/// zoomed mirror still has to scroll, and a scroll still needs to be
/// reachable. So the axis is decided ONCE from the accumulated travel
/// and the whole gesture means that one thing.
///
/// The rule follows libinput, Chrome (`kMinSnapRatio`) and Safari's
/// dominant-axis scrolling: ignore the cross axis unless the locked
/// axis wins by a clear margin, and **prefer vertical on a near-tie**
/// because fingers almost always drift sideways while scrolling up or
/// down — locking those to horizontal is what makes "scroll feels
/// broken".
public enum ScreenDragAxis: Equatable, Sendable {
    case undecided
    case horizontal
    case vertical

    /// Travel (view points) before an axis is chosen at all.
    public static let threshold: Double = 12
    /// How much the dominant axis must beat the other one by.
    public static let ratio: Double = 1.4

    /// Decide from the gesture's **accumulated** travel, so many small
    /// deltas still count (a single delta under the threshold must
    /// not be the only thing that can decide).
    public static func decide(_ travel: CGSize) -> ScreenDragAxis {
        let dx = abs(travel.width), dy = abs(travel.height)
        guard dx >= threshold || dy >= threshold else { return .undecided }
        guard dx > dy * ratio else { return .vertical }
        return .horizontal
    }
}

/// Pure viewport model for the iOS screen-mirror surface.
///
/// The mirrored Mac window is laid out inside the phone's view with a
/// "fit whole window" default (letterboxed), then zoomed and panned
/// locally. Touches are mapped back to normalized window content
/// coordinates so the Mac never needs to know the phone's gesture state.
///
/// Everything here is pure math — no SwiftUI/UIKit — so it is unit-tested
/// directly.
public struct ScreenZoomState: Equatable, Sendable {

    public static let minZoom: Double = 1.0
    public static let maxZoom: Double = 4.0

    /// Window content size in points (from `IBScreenInfo.width/height`).
    public let windowSize: CGSize
    /// The surface's view size in points.
    public let viewSize: CGSize
    /// Current zoom (>= 1).
    public private(set) var zoom: Double
    /// Current pan offset in view points, applied after zoom about center.
    public private(set) var pan: CGSize
    /// false = fit the whole window (letterboxed); true = fill the view
    /// (crop the overflowing axis, pannable at zoom 1).
    public let fillsView: Bool
    /// Chrome (top bar, shortcut bar, PTT row) that overlays the surface.
    /// The content is laid out in the band between them, so a pan can never
    /// hide the top of the window under the floating buttons.
    public let topInset: Double
    public let bottomInset: Double

    public init(windowWidth: Double, windowHeight: Double,
                viewSize: CGSize, zoom: Double = 1, pan: CGSize = .zero,
                fillsView: Bool = false,
                topInset: Double = 0, bottomInset: Double = 0) {
        self.windowSize = CGSize(width: max(1, windowWidth), height: max(1, windowHeight))
        self.viewSize = viewSize
        self.zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
        self.fillsView = fillsView
        self.topInset = max(0, topInset)
        self.bottomInset = max(0, bottomInset)
        self.pan = pan
        self.pan = clampedPan(pan)
    }

    /// The view minus the chrome — where content may actually be laid out.
    private var usableSize: CGSize {
        CGSize(width: max(1, viewSize.width),
               height: max(1, viewSize.height - topInset - bottomInset))
    }

    /// Y origin that centers a content of height `h` in the usable band.
    private func centeredY(_ h: Double) -> Double {
        topInset + (usableSize.height - h) / 2
    }

    /// Largest size with the window's aspect ratio that fits in the view
    /// (`fillsView` flips this to the smallest size that covers the view).
    public var fitSize: CGSize {
        let u = usableSize
        let sx = u.width / windowSize.width
        let sy = u.height / windowSize.height
        let scale = fillsView ? max(sx, sy) : min(sx, sy)
        return CGSize(width: windowSize.width * scale,
                      height: windowSize.height * scale)
    }

    /// Where the (zoom = 1) content sits inside the view, centered.
    public var fittedContentRect: CGRect {
        let s = fitSize
        return CGRect(x: (viewSize.width - s.width) / 2,
                      y: centeredY(s.height),
                      width: s.width, height: s.height)
    }

    /// Where the zoomed + panned content sits inside the view.
    public var displayedContentRect: CGRect {
        let f = fitSize
        let w = f.width * zoom
        let h = f.height * zoom
        return CGRect(x: (viewSize.width - w) / 2 + pan.width,
                      y: centeredY(h) + pan.height,
                      width: w, height: h)
    }

    /// Maximum pan offset before the content edge reaches the usable edge.
    public var maxPan: CGSize {
        let f = fitSize
        return CGSize(width: max(0, (f.width * zoom - viewSize.width) / 2),
                      height: max(0, (f.height * zoom - usableSize.height) / 2))
    }

    public var canPan: Bool { maxPan.width > 0.5 || maxPan.height > 0.5 }

    private func clampedPan(_ p: CGSize) -> CGSize {
        let m = maxPan
        return CGSize(width: min(max(p.width, -m.width), m.width),
                      height: min(max(p.height, -m.height), m.height))
    }

    // MARK: - Mutations

    public mutating func setZoom(_ z: Double) {
        zoom = min(max(z, Self.minZoom), Self.maxZoom)
        pan = clampedPan(pan)
    }

    /// Zoom while keeping the content point under `anchor` fixed on screen
    /// (the pinch / double-tap anchor). `anchor == nil` zooms about center.
    public mutating func setZoom(_ z: Double, anchor: CGPoint?) {
        let newZoom = min(max(z, Self.minZoom), Self.maxZoom)
        guard let anchor else {
            zoom = newZoom
            pan = clampedPan(pan)
            return
        }
        let r = displayedContentRect
        guard r.width > 0, r.height > 0 else {
            zoom = newZoom
            pan = clampedPan(pan)
            return
        }
        let u = (anchor.x - r.minX) / r.width
        let v = (anchor.y - r.minY) / r.height
        zoom = newZoom
        let s = fitSize
        let w = s.width * newZoom
        let h = s.height * newZoom
        pan = clampedPan(CGSize(
            width: anchor.x - (viewSize.width - w) / 2 - u * w,
            height: anchor.y - centeredY(h) - v * h))
    }

    /// Double-tap zoom: 1× → 2× at the tap, otherwise back to 1×.
    public mutating func toggleZoom(at anchor: CGPoint?) {
        if zoom > 1.01 {
            setZoom(1)
        } else {
            setZoom(min(2, Self.maxZoom), anchor: anchor)
        }
    }

    /// Flip fit ⇄ fill, preserving the content point under `anchor`.
    public mutating func setFillsView(_ fills: Bool, anchor: CGPoint?) {
        guard fills != fillsView else { return }
        let r = displayedContentRect
        let u = r.width > 0 ? (anchor.map { ($0.x - r.minX) / r.width } ?? 0.5) : 0.5
        let v = r.height > 0 ? (anchor.map { ($0.y - r.minY) / r.height } ?? 0.5) : 0.5
        var rebuilt = ScreenZoomState(windowWidth: windowSize.width,
                                      windowHeight: windowSize.height,
                                      viewSize: viewSize, zoom: zoom,
                                      pan: pan, fillsView: fills,
                                      topInset: topInset, bottomInset: bottomInset)
        if let anchor {
            let s = rebuilt.fitSize
            let w = s.width * rebuilt.zoom
            let h = s.height * rebuilt.zoom
            rebuilt.pan = rebuilt.clampedPan(CGSize(
                width: anchor.x - (viewSize.width - w) / 2 - u * w,
                height: anchor.y - rebuilt.centeredY(h) - v * h))
        }
        self = rebuilt
    }

    public mutating func commitPan(_ p: CGSize) {
        pan = clampedPan(p)
    }

    public mutating func reset() {
        zoom = Self.minZoom
        pan = .zero
    }

    // MARK: - Touch mapping

    /// Map a point in view coordinates to normalized content `(u, v)`.
    /// Returns nil when the point is on the letterbox (outside the
    /// displayed content), so taps in the black bars do nothing.
    public func contentUV(forViewPoint p: CGPoint) -> (u: Double, v: Double)? {
        let r = displayedContentRect
        guard r.width > 0, r.height > 0 else { return nil }
        let u = (p.x - r.minX) / r.width
        let v = (p.y - r.minY) / r.height
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        return (u: Double(u), v: Double(v))
    }

    // MARK: - Tap vs drag

    /// View points a finger may travel before a tap becomes a Mac drag.
    ///
    /// The slop is a *content* distance, because that is what the Mac
    /// sees: a fixed 10 view points is 10 content points at 1× but only
    /// 2.5 content points at 4×, which is a real drag on the Mac — so a
    /// slightly-off tap on a button became a drag-select (「点了没点中」).
    public var dragSlop: Double { min(28, max(10, 4 * zoom)) }

    // MARK: - Two-finger axis lock

    /// Advance an axis-locked two-finger drag. The locked axis scrolls the
    /// Mac; the other axis pans the viewport, or scrolls too when there is
    /// nothing left to pan.
    public func twoFinger(axis: ScreenDragAxis, translation: CGSize) -> TwoFingerResult {
        switch axis {
        case .undecided:
            return TwoFingerResult(pan: pan, scrollDX: 0, scrollDY: 0)
        case .vertical:
            return TwoFingerResult(
                pan: pan,
                scrollDX: 0,
                scrollDY: viewSize.height > 0 ? Double(translation.height / viewSize.height) : 0
            )
        case .horizontal:
            guard canPanHorizontally else {
                return TwoFingerResult(
                    pan: pan,
                    scrollDX: viewSize.width > 0 ? Double(translation.width / viewSize.width) : 0,
                    scrollDY: 0
                )
            }
            // Pan on X only. The cross axis is DROPPED, not handed off to
            // the Mac: a locked gesture means one thing, and forwarding the
            // vertical drift as a scroll is how a horizontal pan ended up
            // scrolling the app sideways. Only the locked axis's own
            // residual — the pan running out of room — becomes a scroll.
            let proposed = CGSize(width: pan.width + translation.width,
                                  height: pan.height)
            let clamped = clampedPan(proposed)
            let residualX = proposed.width - clamped.width
            return TwoFingerResult(
                pan: clamped,
                scrollDX: viewSize.width > 0 ? Double(residualX / viewSize.width) : 0,
                scrollDY: 0
            )
        }
    }

    /// Whether the viewport can still be moved on the horizontal axis.
    public var canPanHorizontally: Bool { maxPan.width > 0.5 }

    // MARK: - Viewport pan: pan first, then scroll the residual

    /// Result of a pan gesture: the committed pan and any residual finger
    /// travel that the pan could not absorb (to be sent as scroll).
    public struct TwoFingerResult: Equatable, Sendable {
        public let pan: CGSize
        /// Residual normalized to the view size (fraction). Zero when the
        /// pan absorbed the whole gesture.
        public let scrollDX: Double
        public let scrollDY: Double
        public var isScroll: Bool { scrollDX != 0 || scrollDY != 0 }

        public init(pan: CGSize, scrollDX: Double, scrollDY: Double) {
            self.pan = pan
            self.scrollDX = scrollDX
            self.scrollDY = scrollDY
        }
    }

    /// Advance a free 2-axis viewport pan by one `translation` (in view
    /// points). While the content can still pan in that direction it pans;
    /// the leftover once an edge is reached becomes a normalized scroll
    /// delta, so a pan that runs out of room still does something useful.
    ///
    /// This is the THREE-finger gesture. Two fingers are axis-locked (see
    /// `twoFinger(axis:translation:)`) because "scroll the app" and "move
    /// the picture" are both two-finger intents and only the axis tells
    /// them apart.
    public func panGesture(translation: CGSize) -> TwoFingerResult {
        // Panning is only meaningful when the content is bigger than the
        // band BECAUSE THE USER ZOOMED (or chose fill). The chrome insets
        // can also make the fitted content taller than the band — treating
        // that as pannable turned every drag into a pan and broke content
        // scrolling, so fit-at-zoom-1 scrolls.
        guard zoom > 1.01 || fillsView else {
            return TwoFingerResult(
                pan: pan,
                scrollDX: viewSize.width > 0 ? Double(translation.width / viewSize.width) : 0,
                scrollDY: viewSize.height > 0 ? Double(translation.height / viewSize.height) : 0
            )
        }
        let proposed = CGSize(width: pan.width + translation.width,
                              height: pan.height + translation.height)
        let clamped = clampedPan(proposed)
        let residualX = proposed.width - clamped.width
        let residualY = proposed.height - clamped.height
        return TwoFingerResult(
            pan: clamped,
            scrollDX: viewSize.width > 0 ? Double(residualX / viewSize.width) : 0,
            scrollDY: viewSize.height > 0 ? Double(residualY / viewSize.height) : 0
        )
    }
}
