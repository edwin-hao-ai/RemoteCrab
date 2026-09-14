import Foundation

/// Unconditional forensic log for live debugging on device.
/// Writes each line to BOTH stderr (visible via
/// `devicectl device process launch --console`, which is flaky) and a
/// file in the app container's Documents dir (reliably pullable via
/// `devicectl device copy from --domain-type appDataContainer`).
/// Created to hunt the silent-video-stop bug; safe to remove afterwards.
enum Forensic {
    // ISO8601DateFormatter isn't Sendable; all access is serialized by
    // `lock` below.
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()
    private static let lock = NSLock()
    static let fileURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("forensic.log")

    /// Start a fresh log (called once at app startup).
    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
        log("=== forensic log start ===")
    }

    static func log(_ message: String) {
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

    /// Watches for main-thread stalls: a background timer pings the main
    /// queue every 500 ms and logs whenever the ping takes >300 ms to be
    /// serviced. Silent when the UI is healthy; turns "app feels frozen"
    /// reports into timestamped evidence.
    enum MainStallMonitor {
        /// Written exactly once (first `start()` call, from the main
        /// actor at app launch); read on the monitor queue afterwards.
        nonisolated(unsafe) private static var timer: DispatchSourceTimer?

        static func start() {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.ibridge.stall-monitor"))
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
