import Foundation

/// Pure parsing/policy layer for the Mac notification-banner AX scan.
///
/// Deliberately split out of `RemoteCrabReceiver/NotificationCapture.swift`.
/// The decisions that actually *lose* notifications — which roots to walk,
/// how a banner is recognised, what identity to use, how the source app is
/// named — used to live only inside an AX loop that needs a real banner on
/// screen to exercise at all, which makes them unverifiable and easy to get
/// subtly wrong (a dead fallback branch shipped exactly that way). They are
/// pure here, so they are unit-tested.
public enum NotificationBannerParsing {

    /// Marker subrole carried by the banner element itself.
    public static let bannerMarker = "AXNotificationCenterBanner"
    /// Role/subrole carried by the panel that hosts banners.
    public static let dialogMarker = "AXSystemDialog"

    // MARK: - Element classification

    /// True when role/subrole/identifier identify a notification banner.
    public static func isBanner(role: String?, subrole: String?, identifier: String?) -> Bool {
        if subrole == bannerMarker { return true }
        if let role, role.contains(bannerMarker) { return true }
        if let identifier, identifier.contains(bannerMarker) { return true }
        return false
    }

    /// True when role/subrole identify Notification Center's banner panel.
    public static func isSystemDialog(role: String?, subrole: String?) -> Bool {
        (role?.contains(dialogMarker) ?? false) || (subrole?.contains(dialogMarker) ?? false)
    }

    // MARK: - Scan plan

    /// Which AX roots to walk this tick.
    public enum ScanPlan: Equatable, Sendable {
        /// Walk the window(s) carrying the dialog marker (the normal path).
        case dialogWindows
        /// No dialog marker, but something on screen looks like a banner:
        /// walk every window's subtree.
        case allWindows
        /// No windows at all: the panel is a direct child of the app.
        case appChildren
        /// Nothing on screen — skip the walk entirely.
        case none
    }

    /// Decide the roots to walk.
    ///
    /// The previous rule was "walk dialog-marked windows; fall back to the
    /// app's children **only when there are no windows at all**". Desktop
    /// widgets are owned by `com.apple.notificationcenterui` on macOS 14+, so
    /// `totalWindows` is never 0 in a normal session and that fallback could
    /// never run — a banner that macOS exposed anywhere outside a
    /// dialog-marked window would be missed silently, forever. The plan takes
    /// the banner marker into account instead of relying on `totalWindows`.
    public static func scanPlan(dialogMarkedWindows: Int,
                               bannerMarkedWindows: Int,
                               totalWindows: Int) -> ScanPlan {
        if dialogMarkedWindows > 0 { return .dialogWindows }
        if bannerMarkedWindows > 0 { return .allWindows }
        if totalWindows == 0 { return .appChildren }
        return .none
    }

    // MARK: - Identity

    /// Identity independent of the (not reliably stable) AX UUID.
    public static func contentKey(app: String, title: String, subtitle: String, body: String) -> String {
        [app, title, subtitle, body].joined(separator: "\u{0}")
    }

    /// A banner's identity on the wire.
    ///
    /// `AXIdentifier` carries the banner UUID on the macOS versions seen so
    /// far, but the UUID is documented-unstable and optional — the code
    /// already keeps a content key because of that. Requiring a non-empty
    /// identifier would drop every banner on a macOS that stops exposing it,
    /// so the content key is used as the fallback identity (dedup still
    /// works: identical content is suppressed by the content key anyway).
    public static func bannerID(axIdentifier: String?, contentKey: String) -> String {
        if let id = axIdentifier, !id.isEmpty { return id }
        return "content:" + contentKey
    }

    /// True when the banner carries anything worth relaying.
    public static func hasAnyText(title: String, subtitle: String, body: String) -> Bool {
        !(title.isEmpty && subtitle.isEmpty && body.isEmpty)
    }

    // MARK: - Source app name

    /// The source app's display name, derived from the banner `AXDescription`.
    ///
    /// The description reads "<app> <title>, <subtitle>, <body>", so we cut at
    /// the earliest matching field. Three fallbacks, in order, so a naming
    /// quirk never silently drops a notification:
    ///  1. cut → trimmed head;
    ///  2. head empty (e.g. the title is a prefix of, or equal to, the app
    ///     name — "Messages" vs title "Message") → text before the first comma;
    ///  3. still empty → the whole description.
    ///
    /// Callers that use the name for the privacy denylist must ALSO match the
    /// raw description (see `NotificationFilter.shouldRelay(app:description:)`),
    /// because fallback 3 can no longer be trusted as a bare app name.
    public static func appName(axDescription: String,
                              title: String,
                              subtitle: String,
                              body: String) -> String {
        let description = axDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return "" }

        var cut = description.endIndex
        for field in [title, subtitle, body] where !field.isEmpty {
            if let range = description.range(of: field), range.lowerBound < cut {
                cut = range.lowerBound
            }
        }
        let head = String(description[..<cut]).trimmedBannerSeparators()
        if !head.isEmpty { return head }

        if let comma = description.firstIndex(where: { $0 == "," || $0 == "，" }) {
            let before = String(description[..<comma]).trimmedBannerSeparators()
            if !before.isEmpty { return before }
        }
        return description
    }
}

private extension String {
    func trimmedBannerSeparators() -> String {
        trimmingCharacters(in: CharacterSet(charactersIn: " ,，、:：-—"))
    }
}
