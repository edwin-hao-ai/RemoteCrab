import Foundation

/// Resolves a relayed notification's source app to a **running** Mac app, so
/// tapping the notification can activate it — the same "tap a notification,
/// land in the app" behaviour as a local iOS notification.
///
/// The banner carries only the app's **localized display name** (the AX tree
/// exposes no bundle id), while `IBActivateApp` needs an id from the Mac's
/// app list. Matching is therefore a graded name lookup, and it is pure so
/// the policy is unit-tested rather than only reachable by tapping a banner.
public enum NotificationAppResolver {

    /// The running app a relayed notification belongs to, or nil when it is
    /// not running.
    ///
    /// Nil means "do nothing" by design: activating an app the user quit
    /// would be a surprise, and a notification is a poor place to launch
    /// something.
    ///
    /// Order: exact → case-insensitive → either name contains the other
    /// (which also bridges helper processes: a "Google Chrome Helper"
    /// banner resolves to "Google Chrome"). Ties prefer the currently
    /// active app, then the first entry (the Mac publishes frontmost-first).
    public static func resolve(name: String, in apps: [IBAppInfo]) -> IBAppInfo? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }

        if let exact = apps.first(where: { $0.name == wanted }) { return exact }

        let lowered = wanted.lowercased()
        let caseInsensitive = apps.filter { $0.name.lowercased() == lowered }
        if let hit = pick(caseInsensitive) { return hit }

        let partial = apps.filter {
            let candidate = $0.name.lowercased()
            return candidate.contains(lowered) || lowered.contains(candidate)
        }
        return pick(partial)
    }

    /// The active app if present, else the first.
    private static func pick(_ candidates: [IBAppInfo]) -> IBAppInfo? {
        candidates.first(where: { $0.isActive }) ?? candidates.first
    }
}
