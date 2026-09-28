import Foundation

/// One window reduced to the fields the notification relay needs, so the
/// "which window was that app showing" decision is testable without a real
/// window server.
///
/// `CGWindowListCopyWindowInfo` returns windows **front to back**, which is
/// what makes the frontmost pick a simple first-match.
public struct NotificationWindowInfo: Equatable, Sendable {
    public let ownerName: String
    public let pid: Int32
    public let layer: Int
    public let title: String?

    public init(ownerName: String, pid: Int32, layer: Int = 0, title: String?) {
        self.ownerName = ownerName
        self.pid = pid
        self.layer = layer
        self.title = title
    }
}

public enum NotificationWindowMatch {

    /// Title of the frontmost normal window (layer 0) belonging to
    /// `ownerName`, or nil.
    ///
    /// Only the **first** layer-0 window of that owner is considered: if it
    /// has no readable title, nil is returned so the caller falls back to
    /// plain app activation. Returning a *later* window's title would raise
    /// the wrong window — worse than not raising one.
    ///
    /// Window *names* are redacted unless Screen Recording is granted, so
    /// nil here is the normal no-permission case, not an error.
    public static func frontWindowTitle(ownerName: String,
                                        in windows: [NotificationWindowInfo]) -> String? {
        let wanted = ownerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        guard let front = windows.first(where: {
            $0.layer == 0 && $0.ownerName.lowercased() == wanted
        }) else { return nil }
        guard let title = front.title, !title.isEmpty else { return nil }
        return title
    }
}
