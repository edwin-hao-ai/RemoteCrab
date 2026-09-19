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

    /// Build the list the iPhone renders. Falls back to one app-level
    /// entry per running app when Screen Recording is not granted (window
    /// titles and pixels are unreadable without it).
    static func buildList(maxWidth: CGFloat = 480, maxWindows: Int = 16) async -> IBWindowList {
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
        var windows: [IBWindowInfo] = []

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
            let jpeg = await capture(scWindow, maxWidth: maxWidth)
            // Only surface windows we can actually show a picture of, so
            // every card in the picker is real — no icon-only placeholders.
            guard let jpeg else { continue }
            windows.append(IBWindowInfo(id: "\(owner.processID):\(scWindow.windowID)",
                                        appId: bundleID,
                                        appName: owner.applicationName,
                                        title: scWindow.title ?? "",
                                        isActive: isActive,
                                        width: Double(scWindow.frame.width),
                                        height: Double(scWindow.frame.height),
                                        snapshotJPEG: jpeg))
            if windows.count >= maxWindows { break }
        }

        // The active window first, then grouped by app / title — SC gives
        // no z-order, so this is the best ordering available.
        windows.sort { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.appName != rhs.appName { return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let previews = windows.filter { $0.snapshotJPEG != nil }.count
        log.info("window list: \(windows.count, privacy: .public) windows from \(content.windows.count, privacy: .public) SC windows, \(previews, privacy: .public) with previews")
        return IBWindowList(windows: windows, canCapture: true)
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
        try? await Task.sleep(for: .milliseconds(150))
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
            return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        } catch {
            let name = window.owningApplication?.applicationName ?? "?"
            log.error("captureImage failed (\(name, privacy: .public) — \(window.title ?? "", privacy: .public)): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
