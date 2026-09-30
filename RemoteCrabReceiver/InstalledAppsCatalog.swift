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
                    byID[id] = IBInstalledApp(id: id, name: name, iconPNG: iconPNG(for: appURL))
                }
            }
            return Array(byID.values)
        }.value
        log.info("installed apps: \(apps.count, privacy: .public)")
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// App icons are expensive to rasterise, so memoise them by path —
    /// the launcher may be re-opened several times per session.
    /// (`NSCache` is internally thread-safe; the compiler just can't see it.)
    nonisolated(unsafe) private static let iconCache = NSCache<NSString, NSData>()

    /// The app's icon for the iPhone's launcher grid, as a **128 px PNG**.
    ///
    /// Two defects lived here and both are load-bearing:
    ///
    /// 1. `NSImage.lockFocus` sizes the backing store to the *current
    ///    backing scale*, so a "96 pt" box silently became **192×192** and
    ///    cost ~94 KB per icon. A real `/Applications` (113 apps) made the
    ///    `installedApps` frame a single **14.25 MB** message.
    /// 2. The obvious fix — JPEG, 12× smaller — was tried and reverted:
    ///    JPEG has **no alpha channel**, and a macOS icon is a squircle
    ///    with transparent corners, so the encoder fills them with opaque
    ///    white and the phone draws a white square behind every tile. Size
    ///    has to be won on the pixel axis, not the format axis.
    ///
    /// 128 px is not arbitrary: the launcher tile is 64 pt and an iPhone 14
    /// is @2x, so 128 px is pixel-exact for the device this shipped on.
    /// Drawn into an explicit rep so the Mac's own display scale can never
    /// change the payload again.
    private static func iconPNG(for appURL: URL) -> Data? {
        let key = appURL.path as NSString
        if let cached = iconCache.object(forKey: key) { return cached as Data }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let px = Self.iconPixels
        guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                  from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        iconCache.setObject(png as NSData, forKey: key)
        return png
    }

    /// Fixed on purpose: a 64 pt launcher tile at 2× (an iPhone 14) is
    /// 128 px, and a value derived from the Mac's own screen would make the
    /// payload size depend on which display the receiver happens to sit on.
    private static let iconPixels = 128

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
