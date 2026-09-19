import AppKit
import CoreGraphics
import ScreenCaptureKit
import RemoteCrabCore

/// Enumerates the Mac's on-screen windows and, when macOS has granted
/// Screen Recording, captures a downsampled JPEG of each. Feeds the
/// iPhone's full-screen window picker.
///
/// Main-actor isolated on purpose: `CGWindowListCopyWindowInfo` and the
/// per-window JPEG encoding are cheap, while the expensive capture is an
/// `async` ScreenCaptureKit call that suspends without blocking the UI.
@MainActor
enum WindowCapture {

    /// True when macOS has granted this app Screen Recording.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask macOS to show the Screen Recording prompt. Returns immediately
    /// (the grant is asynchronous, via System Settings).
    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    private struct RawWindow {
        let id: String
        let appId: String
        let appName: String
        let title: String
        let isActive: Bool
        let width: Double
        let height: Double
        let windowNumber: Int
    }

    /// Build the list the iPhone renders. Falls back to one app-level
    /// entry per running app when Screen Recording is not granted (window
    /// titles and pixels are unreadable without it).
    static func buildList(maxWidth: CGFloat = 480, maxWindows: Int = 16) async -> IBWindowList {
        guard isAuthorized else {
            return IBWindowList(windows: appLevelEntries(), canCapture: false)
        }
        let raw = enumerate()
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var windows: [IBWindowInfo] = []
        windows.reserveCapacity(min(raw.count, maxWindows))
        for rawWindow in raw.prefix(maxWindows) {
            var jpeg: Data?
            if let content,
               let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(rawWindow.windowNumber) }) {
                jpeg = await capture(scWindow, maxWidth: maxWidth)
            }
            windows.append(IBWindowInfo(id: rawWindow.id,
                                        appId: rawWindow.appId,
                                        appName: rawWindow.appName,
                                        title: rawWindow.title,
                                        isActive: rawWindow.isActive,
                                        width: rawWindow.width,
                                        height: rawWindow.height,
                                        snapshotJPEG: jpeg))
        }
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

    /// Normal application windows, front-to-back. Skips the menu bar,
    /// dock, tooltips and tiny helper windows (layer != 0 or too small).
    private static func enumerate() -> [RawWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var activeMarked = false
        var windows: [RawWindow] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let width = Double(bounds["Width"] ?? 0)
            let height = Double(bounds["Height"] ?? 0)
            guard width >= 160, height >= 120 else { continue }
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let bundleID = app.bundleIdentifier ?? "pid:\(pid)"
            // The first window of the frontmost app is the key window.
            var isActive = false
            if !activeMarked, pid == frontPID {
                isActive = true
                activeMarked = true
            }
            windows.append(RawWindow(id: "\(pid):\(number)",
                                     appId: bundleID,
                                     appName: app.localizedName ?? bundleID,
                                     title: title,
                                     isActive: isActive,
                                     width: width,
                                     height: height,
                                     windowNumber: number))
        }
        return windows
    }

    /// Capture a single window (even if occluded) and encode it as a
    /// downsampled JPEG.
    private static func capture(_ window: SCWindow, maxWidth: CGFloat) async -> Data? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, maxWidth / max(1, window.frame.width))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                      configuration: config) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
}
