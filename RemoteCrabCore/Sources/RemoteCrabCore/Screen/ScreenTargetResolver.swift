import Foundation

/// One window as reported by `CGWindowListCopyWindowInfo`, reduced to the
/// fields the mirror cares about. Kept free of AppKit/CoreGraphics types
/// so `ScreenTargetResolver` is pure and unit-testable.
public struct ScreenWindowDescriptor: Sendable, Equatable {
    public let windowNumber: Int
    public let pid: Int32
    /// `kCGWindowLayer` — 0 is the normal application-window layer.
    public let layer: Int
    public let width: Double
    public let height: Double
    public let isOnScreen: Bool
    /// `kCGWindowAlpha` > 0.
    public let hasAlpha: Bool

    public init(windowNumber: Int, pid: Int32, layer: Int,
                width: Double, height: Double,
                isOnScreen: Bool = true, hasAlpha: Bool = true) {
        self.windowNumber = windowNumber
        self.pid = pid
        self.layer = layer
        self.width = width
        self.height = height
        self.isOnScreen = isOnScreen
        self.hasAlpha = hasAlpha
    }
}

/// Picks which Mac window the screen mirror should capture.
///
/// The mirror follows the frontmost application and shows its frontmost
/// eligible window ("main/active window"). `CGWindowListCopyWindowInfo`
/// returns windows in **front-to-back** order, so the first eligible
/// descriptor for the frontmost PID is the one that should be captured.
public enum ScreenTargetResolver {

    public static let minWidth: Double = 160
    public static let minHeight: Double = 120

    /// A window is eligible if it belongs to `frontmostPID`, is on
    /// screen, sits in the normal window layer, is opaque, and is large
    /// enough to be a real content window (filters out tooltips, menu
    /// extras, shadows and the like).
    public static func isEligible(_ w: ScreenWindowDescriptor,
                                  frontmostPID: Int32) -> Bool {
        w.pid == frontmostPID
            && w.isOnScreen
            && w.layer == 0
            && w.hasAlpha
            && w.width >= minWidth
            && w.height >= minHeight
    }

    /// Frontmost eligible window for `frontmostPID`, or nil when the app
    /// currently has none (e.g. Finder with no open window).
    public static func resolve(frontmostPID: Int32,
                               windows: [ScreenWindowDescriptor]) -> ScreenWindowDescriptor? {
        windows.first { isEligible($0, frontmostPID: frontmostPID) }
    }

    /// Same as `resolve`, but keeps `previous` when the new frontmost app
    /// has no eligible window. This prevents a focus change to a
    /// window-less app (Spotlight, a menu-bar helper) from blanking the
    /// mirror and thrashing the capture stream.
    public static func resolveKeepingPrevious(frontmostPID: Int32,
                                              windows: [ScreenWindowDescriptor],
                                              previous: ScreenWindowDescriptor?) -> ScreenWindowDescriptor? {
        resolve(frontmostPID: frontmostPID, windows: windows) ?? previous
    }
}
