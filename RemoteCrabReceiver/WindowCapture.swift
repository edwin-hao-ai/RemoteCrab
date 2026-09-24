import AppKit
import CoreGraphics
import ScreenCaptureKit
import os
import RemoteCrabCore

/// Enumerates the Mac's windows and, when macOS has granted Screen
/// Recording, captures a downsampled JPEG of each. Feeds the iPhone's
/// full-screen window picker.
///
/// The window list comes from ScreenCaptureKit itself rather than
/// `CGWindowListCopyWindowInfo`: the two disagree (`CGWindowList` can
/// report a single window while `SCShareableContent` sees dozens), and
/// enumerating from ScreenCaptureKit guarantees every listed window has a
/// matching, capturable `SCWindow`.
///
/// Main-actor isolated on purpose: the per-window JPEG encoding is cheap,
/// while the expensive capture is an `async` call that suspends without
/// blocking the UI.
@MainActor
enum WindowCapture {

    private static let log = Logger(subsystem: "com.remotecrab", category: "windowcapture")

    /// True when macOS has granted this app Screen Recording.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask macOS to show the Screen Recording prompt. Returns immediately
    /// (the grant is asynchronous, via System Settings).
    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    /// A window we intend to capture. `SCWindow` isn't `Sendable`, but the
    /// concurrent capture tasks only read it, so it's boxed to cross the
    /// task boundary.
    private struct UnsafeWindow: @unchecked Sendable {
        let window: SCWindow
    }

    /// Resolved window metadata, kept alongside the `SCWindow` so the
    /// parallel capture results can be zipped back in order.
    private struct Candidate {
        let scWindow: SCWindow
        let pid: pid_t
        let appId: String
        let appName: String
        let isActive: Bool
    }

    /// Build the list the iPhone renders. Falls back to one app-level
    /// entry per running app when Screen Recording is not granted (window
    /// titles and pixels are unreadable without it).
    static func buildList(maxWidth: CGFloat = 960, maxWindows: Int = 16) async -> IBWindowList {
        guard isAuthorized else {
            return IBWindowList(windows: appLevelEntries(), canCapture: false)
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            log.error("SCShareableContent failed; degrading to app list")
            return IBWindowList(windows: appLevelEntries(), canCapture: false)
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var activeMarked = false
        var candidates: [Candidate] = []

        for scWindow in content.windows {
            guard scWindow.windowLayer == 0,
                  scWindow.isOnScreen,
                  let owner = scWindow.owningApplication,
                  owner.processID != myPID,
                  let running = NSRunningApplication(processIdentifier: owner.processID),
                  running.activationPolicy == .regular,
                  scWindow.frame.width >= 160, scWindow.frame.height >= 120 else { continue }

            let bundleID = owner.bundleIdentifier.isEmpty ? "pid:\(owner.processID)" : owner.bundleIdentifier
            var isActive = false
            if !activeMarked, owner.processID == frontPID {
                isActive = true
                activeMarked = true
            }
            candidates.append(Candidate(scWindow: scWindow,
                                        pid: owner.processID,
                                        appId: bundleID,
                                        appName: owner.applicationName,
                                        isActive: isActive))
            if candidates.count >= maxWindows { break }
        }

        // Capture every preview concurrently (bounded), preserving order —
        // sequential capture made switching-app thumbnails slow.
        let previews = await capturePreviews(candidates.map { UnsafeWindow(window: $0.scWindow) },
                                             maxWidth: maxWidth)

        var windows: [IBWindowInfo] = []
        for (index, candidate) in candidates.enumerated() {
            windows.append(IBWindowInfo(id: "\(candidate.pid):\(candidate.scWindow.windowID)",
                                        appId: candidate.appId,
                                        appName: candidate.appName,
                                        title: candidate.scWindow.title ?? "",
                                        isActive: candidate.isActive,
                                        width: Double(candidate.scWindow.frame.width),
                                        height: Double(candidate.scWindow.frame.height),
                                        snapshotJPEG: previews[index]))
        }

        // Active first, then windows with a real preview, then grouped by
        // app / title — SC gives no z-order, so this is the best ordering
        // available.
        windows.sort { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let lhsHasPreview = lhs.snapshotJPEG != nil
            let rhsHasPreview = rhs.snapshotJPEG != nil
            if lhsHasPreview != rhsHasPreview { return lhsHasPreview }
            if lhs.appName != rhs.appName {
                return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        // Apps with no on-screen window (minimized / hidden / on another
        // Space, or every window under the size floor) would otherwise
        // vanish from the picker entirely — merge them back as app-level
        // entries. Tapping one still activates (and un-hides) the app.
        let listedAppIds = Set(windows.map(\.appId))
        windows.append(contentsOf: appLevelEntries().filter { !listedAppIds.contains($0.appId) })

        let previewCount = windows.filter { $0.snapshotJPEG != nil }.count
        log.info("window list: \(windows.count, privacy: .public) windows from \(content.windows.count, privacy: .public) SC windows, \(previewCount, privacy: .public) with previews")
        return IBWindowList(windows: windows, canCapture: true)
    }

    /// Capture every window's JPEG with at most four in flight at once,
    /// returning the results in the original order.
    private static func capturePreviews(_ windows: [UnsafeWindow], maxWidth: CGFloat) async -> [Data?] {
        var results = [Data?](repeating: nil, count: windows.count)
        guard !windows.isEmpty else { return results }
        let maxConcurrent = min(4, windows.count)
        await withTaskGroup(of: (Int, Data?).self) { group in
            for index in 0..<maxConcurrent {
                group.addTask { (index, await capture(windows[index].window, maxWidth: maxWidth)) }
            }
            var next = maxConcurrent
            for await (index, jpeg) in group {
                results[index] = jpeg
                if next < windows.count {
                    let index = next
                    group.addTask { (index, await capture(windows[index].window, maxWidth: maxWidth)) }
                    next += 1
                }
            }
        }
        return results
    }

    /// One entry per running regular app, used when Screen Recording is off.
    static func appLevelEntries() -> [IBWindowInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                let bid = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
                return IBWindowInfo(id: bid, appId: bid, appName: app.localizedName ?? bid,
                                    title: "", isActive: app.isActive)
            }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    /// Capture a single window (even if occluded) and encode it as a
    /// downsampled JPEG. ScreenCaptureKit intermittently fails to start
    /// the stream for a window (`-3811`), so retry once before giving up.
    private static func capture(_ window: SCWindow, maxWidth: CGFloat) async -> Data? {
        if let data = await attemptCapture(window, maxWidth: maxWidth) { return data }
        try? await Task.sleep(for: .milliseconds(80))
        return await attemptCapture(window, maxWidth: maxWidth)
    }

    private static func attemptCapture(_ window: SCWindow, maxWidth: CGFloat) async -> Data? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, maxWidth / max(1, window.frame.width))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.72])
        } catch {
            let name = window.owningApplication?.applicationName ?? "?"
            log.error("captureImage failed (\(name, privacy: .public) — \(window.title ?? "", privacy: .public)): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
