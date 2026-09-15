import Foundation
import UIKit

/// Darwin-notification entry point for `Forensic.SelfShot` — must live
/// at file scope because `CFNotificationCallback` is a C function
/// pointer and cannot capture context.
private func selfShotDarwinCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    Forensic.SelfShot.capture()
}

/// Forensic log for live debugging on device.
/// Writes each line to BOTH stderr (visible via
/// `devicectl device process launch --console`, which is flaky) and a
/// file in the app container's Documents dir (reliably pullable via
/// `devicectl device copy from --domain-type appDataContainer`).
/// Created to hunt the silent-video-stop bug.
///
/// Gated: always on in DEBUG builds; in release builds only when
/// launched with REMOTECRAB_FORENSIC=1. All entry points no-op when
/// disabled, so production pays nothing for it.
enum Forensic {
    static let enabled: Bool = {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["REMOTECRAB_FORENSIC"] == "1"
        #endif
    }()
    // ISO8601DateFormatter isn't Sendable; all access is serialized by
    // `lock` below.
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()
    private static let lock = NSLock()
    static let fileURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("forensic.log")

    /// Start a fresh log (called once at app startup).
    static func reset() {
        guard enabled else { return }
        try? FileManager.default.removeItem(at: fileURL)
        log("=== forensic log start ===")
    }

    static func log(_ message: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// On-demand screen dump for headless device debugging: legacy
    /// `idevicescreenshot` is dead on modern iOS (no screenshotr service
    /// without a personalized DDI), so the app shoots itself. Post the
    /// Darwin notification from the Mac —
    ///   xcrun devicectl device notification post --device <id> com.remotecrab.selfshot
    /// — and the current window lands in Documents/selfshot-<stamp>.png,
    /// pullable via `devicectl device copy from`.
    enum SelfShot {
        private static let notificationName = "com.remotecrab.selfshot"
        nonisolated(unsafe) private static var installed = false

        static func install() {
            guard Forensic.enabled, !installed else { return }
            installed = true
            let callback: CFNotificationCallback = { center, observer, name, object, userInfo in
                selfShotDarwinCallback(center, observer, name, object, userInfo)
            }
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                nil,
                callback,
                notificationName as CFString,
                nil,
                .deliverImmediately
            )
        }

        /// Called from the Darwin-notification C callback (file scope —
        /// C function pointers can't capture context).
        fileprivate static func capture() {
            DispatchQueue.main.async {
                guard let scene = UIApplication.shared.connectedScenes
                        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                      let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
                else {
                    Forensic.log("[selfshot] no foreground window")
                    return
                }
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let stamp = Int(Date().timeIntervalSince1970)
                let url = FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("selfshot-\(stamp).png")
                do {
                    try image.pngData()?.write(to: url)
                    Forensic.log("[selfshot] saved \(url.lastPathComponent)")
                } catch {
                    Forensic.log("[selfshot] write failed: \(error)")
                }
            }
        }
    }

    /// Watches for main-thread stalls: a background timer pings the main
    /// queue every 500 ms and logs whenever the ping takes >300 ms to be
    /// serviced. Silent when the UI is healthy; turns "app feels frozen"
    /// reports into timestamped evidence.
    enum MainStallMonitor {
        /// Written exactly once (first `start()` call, from the main
        /// actor at app launch); read on the monitor queue afterwards.
        nonisolated(unsafe) private static var timer: DispatchSourceTimer?

        static func start() {
            guard enabled, timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.remotecrab.stall-monitor"))
            t.schedule(deadline: .now() + 1, repeating: 0.5)
            t.setEventHandler {
                let sentAt = Date()
                DispatchQueue.main.async {
                    let stall = Date().timeIntervalSince(sentAt)
                    if stall > 0.3 {
                        Forensic.log("[main-stall] main thread busy \(Int(stall * 1000))ms")
                    }
                }
            }
            t.resume()
            timer = t
        }
    }
}
