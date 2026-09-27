import AppKit
import ApplicationServices
import Foundation
import os
import RemoteCrabCore

/// Best-effort capture of macOS notification banners, relayed to the
/// iPhone by `ReceiverSession`.
///
/// macOS has no supported API to observe the notification center, so we
/// poll the Accessibility tree of `com.apple.notificationcenterui` for
/// `AXNotificationCenterBanner` elements (the probe-verified structure):
///
/// ```
/// AXWindow/AXSystemDialog
///   AXGroup/AXNotificationCenterBanner   (AXIdentifier = UUID,
///                                         AXDescription = "<app> <title>, …")
///     AXStaticText AXIdentifier="title"     AXValue=<title>
///     AXStaticText AXIdentifier="subtitle"  AXValue=<subtitle>
///     AXStaticText AXIdentifier="body"      AXValue=<body>
/// ```
///
/// Banners are transient (~5 s) so we poll every 0.5 s and dedup by the
/// banner's UUID identifier. Everything is best-effort: any AX failure is
/// logged and ignored — the rest of the app is unaffected. Do Not Disturb
/// / Focus notifications never reach the AX tree, so they cannot be seen.
///
/// All mutable state lives on the main actor; only the AX read runs on a
/// background queue (it can block briefly on a busy Accessibility server).
@MainActor
final class NotificationCapture {

    private static let log = Logger(subsystem: "com.remotecrab", category: "notifycapture")

    /// Poll interval. Banners live ~5 s, so 0.5 s is comfortably inside.
    private static let pollInterval: TimeInterval = 0.5
    /// Cap the dedup set so a long session cannot grow it forever (FIFO).
    private static let seenLimit = 200

    /// Called on the main actor for each newly seen banner that passes the
    /// denylist. The receiver turns it into a wire frame.
    var onBanner: ((IBNotification) -> Void)?

    private let filter: NotificationFilter
    private let queue = DispatchQueue(label: "com.remotecrab.notifycapture")
    private var timer: DispatchSourceTimer?
    private var seen: Set<String> = []
    private var seenOrder: [String] = []

    init(denylist: [String]) {
        self.filter = NotificationFilter(denylist: denylist)
    }

    /// Begin polling. Idempotent.
    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.pollInterval,
                        repeating: Self.pollInterval,
                        leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            self?.poll()
        }
        source.resume()
        timer = source
        Self.log.info("notification capture started")
    }

    /// Stop polling. Safe to call when not running.
    func stop() {
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        Self.log.info("notification capture stopped")
    }

    /// Runs on the background queue: read the AX tree (can block), then
    /// hand the parsed banners back to the main actor for dedup + filter.
    private nonisolated func poll() {
        let banners = readNotificationBanners()
        guard !banners.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.ingest(banners)
        }
    }

    /// Main-actor: dedup, filter, and emit. Content is never logged —
    /// only the source app name (and only when it is filtered out).
    private func ingest(_ banners: [CapturedBanner]) {
        for banner in banners {
            guard !seen.contains(banner.id) else { continue }
            markSeen(banner.id)
            guard filter.shouldRelay(app: banner.app) else {
                Self.log.info("filtered notification from \(banner.app, privacy: .public)")
                continue
            }
            Self.log.info("relaying notification from \(banner.app, privacy: .public)")
            onBanner?(IBNotification(app: banner.app,
                                     title: banner.title,
                                     subtitle: banner.subtitle,
                                     body: banner.body))
        }
    }

    private func markSeen(_ id: String) {
        seen.insert(id)
        seenOrder.append(id)
        if seenOrder.count > Self.seenLimit {
            let overflow = seenOrder.count - Self.seenLimit
            for _ in 0..<overflow {
                seen.remove(seenOrder.removeFirst())
            }
        }
    }
}

// MARK: - AX parsing (nonisolated; runs on the capture queue)

/// One parsed banner. Internal to the capture loop.
private struct CapturedBanner: Sendable {
    let id: String
    let app: String
    let title: String
    let subtitle: String
    let body: String
}

/// Read every notification banner currently in the Accessibility tree.
/// Returns an empty array on any failure (best-effort).
private func readNotificationBanners() -> [CapturedBanner] {
    guard let pid = notificationCenterPID() else { return [] }
    let app = AXUIElementCreateApplication(pid)

    // The banner lives under the app's windows (`AXWindow/AXSystemDialog`).
    // Prefer the window list — falling back to the app's direct children
    // only when it is empty — so the (large) menu-bar subtree is not
    // re-walked every poll.
    let windows = (axAttribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    let roots = windows.isEmpty ? axChildren(app) : windows

    var out: [CapturedBanner] = []
    for root in roots {
        collectBanners(in: root, depth: 0, into: &out)
    }
    return out
}

/// Pid of the notification-center UI process, or nil when it isn't running
/// (nothing is on screen to capture).
private func notificationCenterPID() -> pid_t? {
    NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
        .first?
        .processIdentifier
}

/// Depth-limited recursive walk; stops descending once a banner is found
/// (its children are the title/subtitle/body static texts).
private func collectBanners(in element: AXUIElement, depth: Int, into out: inout [CapturedBanner]) {
    guard depth < 8 else { return }
    let identifier = axAttribute(element, kAXIdentifierAttribute) as? String
    // The probe-verified element is `AXGroup` with **subrole**
    // `AXNotificationCenterBanner` (its `AXIdentifier` is the banner
    // UUID, not the marker). Role/identifier are also checked so a future
    // macOS that moves the marker still matches.
    let role = axAttribute(element, kAXRoleAttribute) as? String
    let subrole = axAttribute(element, kAXSubroleAttribute) as? String
    let isBanner = subrole == "AXNotificationCenterBanner"
        || (identifier?.contains("AXNotificationCenterBanner") ?? false)
        || (role?.contains("AXNotificationCenterBanner") ?? false)
    if isBanner {
        if let banner = parseBanner(element, identifier: identifier) {
            out.append(banner)
        }
        return
    }
    for child in axChildren(element) {
        collectBanners(in: child, depth: depth + 1, into: &out)
    }
}

/// Turn a banner AX element into a `CapturedBanner`, or nil when it lacks
/// a usable UUID / any text.
private func parseBanner(_ element: AXUIElement, identifier: String?) -> CapturedBanner? {
    guard let id = identifier, !id.isEmpty else { return nil }

    var title = ""
    var subtitle = ""
    var body = ""
    for child in axChildren(element) {
        guard let field = axAttribute(child, kAXIdentifierAttribute) as? String,
              let value = axAttribute(child, kAXValueAttribute) as? String else { continue }
        switch field {
        case "title":    title = value
        case "subtitle": subtitle = value
        case "body":     body = value
        default:         break
        }
    }
    guard !(title.isEmpty && subtitle.isEmpty && body.isEmpty) else { return nil }

    let description = (axAttribute(element, kAXDescriptionAttribute) as? String) ?? ""
    let app = extractAppName(description: description,
                             title: title, subtitle: subtitle, body: body)
    guard !app.isEmpty else { return nil }

    return CapturedBanner(id: id, app: app, title: title, subtitle: subtitle, body: body)
}

/// App name is the banner `AXDescription` prefix before the title/subtitle/
/// body text ("<app> <title>, <subtitle>, <body>"). Cut at the earliest
/// matching field, then trim separators. Falls back to the text before the
/// first comma when nothing matched.
private func extractAppName(description: String, title: String, subtitle: String, body: String) -> String {
    var cut = description.endIndex
    for field in [title, subtitle, body] where !field.isEmpty {
        if let range = description.range(of: field), range.lowerBound < cut {
            cut = range.lowerBound
        }
    }
    var name = String(description[..<cut])
    name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ,，、:：-—"))
    if name.isEmpty,
       let comma = description.firstIndex(where: { $0 == "," || $0 == "，" }) {
        name = String(description[..<comma]).trimmingCharacters(in: .whitespaces)
    }
    return name
}

/// Copy one AX attribute, or nil on failure.
private func axAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (axAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
