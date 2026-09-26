import AppKit
import os
import RemoteCrabCore

/// Enumerates every launch-able application on this Mac for the iPhone's
/// launcher sheet. `id` is the bundle identifier — exactly the argument
/// `SystemCommandHandler.launchApp` expects — and `name` the display name
/// from the bundle's Info.plist. Entries are deduped by bundle id, with the
/// user-visible `/Applications` copy winning over a system copy.
///
/// The walk is file I/O per bundle, so it runs detached off the main actor.
enum InstalledAppsCatalog {

    private static let log = Logger(subsystem: "com.remotecrab", category: "apps-catalog")

    /// Roots scanned, in priority order: a bundle id seen in an earlier root
    /// shadows the same id from a later (system) root.
    private static let roots: [String] = [
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    static func all() async -> [IBInstalledApp] {
        let roots = roots
        let apps: [IBInstalledApp] = await Task.detached(priority: .userInitiated) {
            var byID: [String: IBInstalledApp] = [:]
            for root in roots {
                for appURL in appBundles(in: URL(fileURLWithPath: root)) {
                    guard let bundle = Bundle(url: appURL),
                          let id = bundle.bundleIdentifier, !id.isEmpty else { continue }
                    guard byID[id] == nil else { continue }
                    let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? appURL.deletingPathExtension().lastPathComponent
                    byID[id] = IBInstalledApp(id: id, name: name)
                }
            }
            return Array(byID.values)
        }.value
        log.info("installed apps: \(apps.count, privacy: .public)")
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `.app` bundles directly in `root`, plus one level inside a child
    /// `Utilities` folder — the shape `/Applications` actually uses.
    private static func appBundles(in root: URL) -> [URL] {
        let fm = FileManager.default
        var searchRoots: [URL] = [root]
        if let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children where child.lastPathComponent == "Utilities" {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    searchRoots.append(child)
                }
            }
        }
        var out: [URL] = []
        for searchRoot in searchRoots {
            if let entries = try? fm.contentsOfDirectory(at: searchRoot, includingPropertiesForKeys: nil) {
                out.append(contentsOf: entries.filter { $0.pathExtension == "app" })
            }
        }
        return out
    }
}
