import Foundation
import os

/// One-shot migration for the App Sandbox removal (V1.3).
///
/// The receiver used to be sandboxed, so `UserDefaults.standard` lived in
/// the app's container. Dropping the sandbox moves it to
/// `~/Library/Preferences/<bundle-id>.plist`, which would silently orphan
/// the user's paired-Mac tokens, last-connected IP and settings. On the
/// first launch after the change, copy any `remotecrab.*` keys across.
enum SandboxDefaultsMigration {

    private static let log = Logger(subsystem: "com.remotecrab", category: "migration")

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        let flag = "remotecrab.migratedFromSandbox"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)

        let bundleID = Bundle.main.bundleIdentifier ?? "com.remotecrab.RemoteCrabReceiver"
        let container = ("~/Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist" as NSString)
            .expandingTildeInPath
        guard let old = NSDictionary(contentsOfFile: container) as? [String: Any] else { return }

        var copied = 0
        for (key, value) in old where key.hasPrefix("remotecrab.") {
            // The Mac's identity is the one the iPhone paired with — it
            // must win, or every upgraded Mac looks like a stranger and
            // gets "busy"/re-approval. Other keys never clobber a value
            // the new (non-sandboxed) location already holds.
            let isIdentity = (key == "remotecrab.mac.id")
            if isIdentity || defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
        }
        if copied > 0 {
            log.info("migrated \(copied, privacy: .public) defaults from the sandbox container")
        }
    }
}
