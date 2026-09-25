import CoreGraphics
import Foundation

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

    public init(windowWidth: Double, windowHeight: Double,
                viewSize: CGSize, zoom: Double = 1, pan: CGSize = .zero,
                fillsView: Bool = false) {
        self.windowSize = CGSize(width: max(1, windowWidth), height: max(1, windowHeight))
        self.viewSize = viewSize
        self.zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
        self.fillsView = fillsView
        self.pan = pan
        self.pan = clampedPan(pan)
    }

    /// Largest size with the window's aspect ratio that fits in the view
    /// (`fillsView` flips this to the smallest size that covers the view).
    public var fitSize: CGSize {
        let sx = viewSize.width / windowSize.width
        let sy = viewSize.height / windowSize.height
        let scale = fillsView ? max(sx, sy) : min(sx, sy)
        return CGSize(width: windowSize.width * scale,
                      height: windowSize.height * scale)
    }

    /// Where the (zoom = 1) content sits inside the view, centered.
    public var fittedContentRect: CGRect {
        let s = fitSize
        return CGRect(x: (viewSize.width - s.width) / 2,
                      y: (viewSize.height - s.height) / 2,
                      width: s.width, height: s.height)
    }

    /// Where the zoomed + panned content sits inside the view.
    public var displayedContentRect: CGRect {
        let f = fitSize
        let w = f.width * zoom
        let h = f.height * zoom
        return CGRect(x: (viewSize.width - w) / 2 + pan.width,
                      y: (viewSize.height - h) / 2 + pan.height,
                      width: w, height: h)
    }

    /// Maximum pan offset before the content edge reaches the view edge.
    public var maxPan: CGSize {
        let f = fitSize
        return CGSize(width: max(0, (f.width * zoom - viewSize.width) / 2),
                      height: max(0, (f.height * zoom - viewSize.height) / 2))
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
            height: anchor.y - (viewSize.height - h) / 2 - v * h))
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
                                      pan: pan, fillsView: fills)
        if let anchor {
            let s = rebuilt.fitSize
            let w = s.width * rebuilt.zoom
            let h = s.height * rebuilt.zoom
            rebuilt.pan = rebuilt.clampedPan(CGSize(
                width: anchor.x - (viewSize.width - w) / 2 - u * w,
                height: anchor.y - (viewSize.height - h) / 2 - v * h))
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

    // MARK: - Two-finger drag: pan first, then scroll

    /// Result of a two-finger drag: the committed pan and any residual
    /// finger travel that the pan could not absorb (to be sent as scroll).
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

    /// Advance by one two-finger drag `translation` (in view points).
    /// While the content can still pan in that direction it pans; the
    /// leftover once an edge is reached becomes a normalized scroll delta
    /// (option X: pan first, then hand off to the Mac's content scroll).
    public func twoFinger(translation: CGSize) -> TwoFingerResult {
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
