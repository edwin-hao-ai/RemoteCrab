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
/// Banners are transient (~5 s) so we poll every 0.5 s. Dedup keys on the
/// banner UUID *and* on its content (app/title/subtitle/body within a short
/// window), because the UUID is not reliably stable across reads — without
/// the content key a single banner relays several times as it is re-read.
/// Everything is best-effort: any AX failure is logged and ignored — the
/// rest of the app is unaffected. Do Not Disturb / Focus notifications
/// never reach the AX tree, so they cannot be seen.
///
/// All mutable state lives on the main actor; only the AX read runs on a
/// background queue (it can block briefly on a busy Accessibility server).
@MainActor
final class NotificationCapture {

    // `nonisolated`: `poll()` runs on the capture queue, not the main actor,
    // so it cannot reach main-actor-isolated statics (the compiler rejects
    // it — this is the compile-time half of the isolation trap in lesson 80).
    nonisolated private static let log = Logger(subsystem: "com.remotecrab", category: "notifycapture")

    /// Poll interval. Banners live ~5 s, so 0.5 s is comfortably inside.
    private static let pollInterval: TimeInterval = 0.5
    /// Cap the dedup set so a long session cannot grow it forever (FIFO).
    private static let seenLimit = 200
    /// An identical banner (same app/title/subtitle/body) is treated as the
    /// same banner for this long. The AX UUID is not always stable across
    /// the 0.5 s polls, so content is the reliable key; a genuine repeat of
    /// byte-identical text within this window is rare enough to drop.
    private static let contentWindow: TimeInterval = 10

    /// Called on the main actor for each newly seen banner that passes the
    /// denylist. The receiver turns it into a wire frame.
    var onBanner: ((IBNotification) -> Void)?

    private let filter: NotificationFilter
    private let queue = DispatchQueue(label: "com.remotecrab.notifycapture")
    private var timer: DispatchSourceTimer?
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    /// Content key → last-seen time. Pruned past `contentWindow`.
    private var seenContent: [String: Date] = [:]
    private var contentOrder: [String] = []

    /// `REMOTECRAB_DEBUG_NOTIFY=1` logs one line per scan tick.
    nonisolated private static let debugScan =
        ProcessInfo.processInfo.environment["REMOTECRAB_DEBUG_NOTIFY"] == "1"

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
        // The timer fires on `queue`, never on the main actor, so the handler
        // must be an explicitly-`@Sendable` closure. A closure literal
        // written in this `@MainActor` method inherits the actor isolation
        // and traps in `swift_task_checkIsolated` (SIGTRAP via
        // `_dispatch_assert_queue_fail`) the first time the timer fires —
        // i.e. ~0.5 s after a session is accepted with the relay on, which
        // killed the whole receiver. Same class of bug as lessons 2 / 7 / 53.
        // `poll()` is `nonisolated` and hops back to the main actor itself.
        let handler: @Sendable () -> Void = { [weak self] in
            self?.poll()
        }
        source.setEventHandler(handler: handler)
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
        let scan = readNotificationBanners()
        if Self.debugScan {
            // One line per tick: the only way to tell "no banner on screen"
            // from "the AX read returned nothing".
            Self.log.info("scan plan=\(String(describing: scan.plan), privacy: .public) windows=\(scan.windows, privacy: .public) dialogs=\(scan.dialogs, privacy: .public) banners=\(scan.banners.count, privacy: .public)")
        }
        guard !scan.banners.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.ingest(scan.banners)
        }
    }

    /// Main-actor: dedup, filter, and emit. Notification content is never
    /// logged; the source app name is logged at `.private` so it does not
    /// leak into the system log.
    private func ingest(_ banners: [CapturedBanner]) {
        let now = Date()
        pruneContent(now: now)
        for banner in banners {
            let contentKey = banner.contentKey
            guard !seen.contains(banner.id),
                  seenContent[contentKey] == nil else { continue }
            markSeen(banner.id)
            markContent(contentKey, at: now)
            guard filter.shouldRelay(app: banner.app, description: banner.description) else {
                // `.private`: the app name is benign, but the fallback can
                // echo title/body fragments — never leak those to the log.
                Self.log.info("filtered notification from \(banner.app, privacy: .private)")
                continue
            }
            Self.log.info("relaying notification from \(banner.app, privacy: .private)")
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

    private func markContent(_ key: String, at date: Date) {
        seenContent[key] = date
        contentOrder.append(key)
        if contentOrder.count > Self.seenLimit {
            let overflow = contentOrder.count - Self.seenLimit
            for _ in 0..<overflow {
                seenContent.removeValue(forKey: contentOrder.removeFirst())
            }
        }
    }

    private func pruneContent(now: Date) {
        while let first = contentOrder.first,
              let seenAt = seenContent[first],
              now.timeIntervalSince(seenAt) > Self.contentWindow {
            contentOrder.removeFirst()
            seenContent.removeValue(forKey: first)
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
    /// Raw banner `AXDescription`. The denylist also matches this: `app` is a
    /// heuristic, and it must not be the only thing standing between a
    /// private message and a cleartext wire.
    let description: String

    /// Identity independent of the (sometimes-unstable) AX UUID.
    var contentKey: String {
        NotificationBannerParsing.contentKey(app: app, title: title,
                                             subtitle: subtitle, body: body)
    }
}

/// One scan tick's outcome. `plan`/`windows`/`dialogs` are carried so the
/// debug log can tell "nothing on screen" apart from "the walk found
/// nothing" — indistinguishable without them, which is what made this
/// feature hard to diagnose in the field.
private struct ScanResult {
    var plan: NotificationBannerParsing.ScanPlan = .none
    var windows = 0
    var dialogs = 0
    var banners: [CapturedBanner] = []
}

/// Read every notification banner currently in the Accessibility tree.
/// Returns an empty result on any failure (best-effort).
private func readNotificationBanners() -> ScanResult {
    var result = ScanResult()
    guard let pid = notificationCenterPID() else { return result }

    let app = AXUIElementCreateApplication(pid)
    let windows = (axAttribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    result.windows = windows.count

    // Two cheap marker probes per window. The panel that hosts banners is
    // marked `AXSystemDialog`; a banner itself is marked
    // `AXNotificationCenterBanner` (we look one level deeper for it, because
    // the banner is normally a grandchild: window → dialog → banner).
    let dialogWindows = windows.filter { hasMarker($0, depth: 1, matching: isDialogElement) }
    let bannerWindows = windows.filter { hasMarker($0, depth: 2, matching: isBannerElement) }
    result.dialogs = dialogWindows.count

    switch NotificationBannerParsing.scanPlan(dialogMarkedWindows: dialogWindows.count,
                                             bannerMarkedWindows: bannerWindows.count,
                                             totalWindows: windows.count) {
    case .dialogWindows:
        result.plan = .dialogWindows
        for root in dialogWindows {
            collectBanners(in: root, depth: 0, into: &result.banners)
        }
    case .allWindows:
        // No dialog marker anywhere, but something looked like a banner:
        // walk every window rather than give up. (Desktop widgets keep
        // `windows` non-empty, so "no windows at all" is not the test for
        // whether a banner can be present.)
        result.plan = .allWindows
        for root in windows {
            collectBanners(in: root, depth: 0, into: &result.banners)
        }
    case .appChildren:
        // No windows at all: the panel is a direct child of the app.
        result.plan = .appChildren
        for root in axChildren(app) {
            collectBanners(in: root, depth: 0, into: &result.banners)
        }
    case .none:
        result.plan = .none
    }
    return result
}

/// True when `element` or a descendant within `depth` satisfies `predicate`.
/// Shallow on purpose — this runs every 0.5 s.
private func hasMarker(_ element: AXUIElement, depth: Int,
                       matching predicate: (AXUIElement) -> Bool) -> Bool {
    if predicate(element) { return true }
    guard depth > 0 else { return false }
    return axChildren(element).contains { hasMarker($0, depth: depth - 1, matching: predicate) }
}

private func isDialogElement(_ element: AXUIElement) -> Bool {
    NotificationBannerParsing.isSystemDialog(
        role: axAttribute(element, kAXRoleAttribute) as? String,
        subrole: axAttribute(element, kAXSubroleAttribute) as? String)
}

private func isBannerElement(_ element: AXUIElement) -> Bool {
    NotificationBannerParsing.isBanner(
        role: axAttribute(element, kAXRoleAttribute) as? String,
        subrole: axAttribute(element, kAXSubroleAttribute) as? String,
        identifier: axAttribute(element, kAXIdentifierAttribute) as? String)
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
    // `AXNotificationCenterBanner` (its `AXIdentifier` is the banner UUID,
    // not the marker). Role/identifier are also checked so a future macOS
    // that moves the marker still matches — see the pure, tested
    // `NotificationBannerParsing.isBanner`.
    let role = axAttribute(element, kAXRoleAttribute) as? String
    let subrole = axAttribute(element, kAXSubroleAttribute) as? String
    if NotificationBannerParsing.isBanner(role: role, subrole: subrole, identifier: identifier) {
        if let banner = parseBanner(element, identifier: identifier) {
            out.append(banner)
        }
        return
    }
    for child in axChildren(element) {
        collectBanners(in: child, depth: depth + 1, into: &out)
    }
}

/// Turn a banner AX element into a `CapturedBanner`, or nil when it carries
/// no text at all.
private func parseBanner(_ element: AXUIElement, identifier: String?) -> CapturedBanner? {
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
    guard NotificationBannerParsing.hasAnyText(title: title, subtitle: subtitle, body: body) else {
        return nil
    }

    let description = (axAttribute(element, kAXDescriptionAttribute) as? String) ?? ""
    let app = NotificationBannerParsing.appName(axDescription: description,
                                               title: title, subtitle: subtitle, body: body)
    let contentKey = NotificationBannerParsing.contentKey(app: app, title: title,
                                                          subtitle: subtitle, body: body)
    // A missing/unstable AX UUID no longer drops the banner: the content key
    // is the fallback identity (dedup still suppresses identical content).
    let id = NotificationBannerParsing.bannerID(axIdentifier: identifier, contentKey: contentKey)
    return CapturedBanner(id: id, app: app, title: title, subtitle: subtitle, body: body,
                          description: description)
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
