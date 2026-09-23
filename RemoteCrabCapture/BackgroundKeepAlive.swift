import AVFoundation
import os

/// Keeps the app alive while it is backgrounded or the screen is locked.
///
/// iOS suspends a foreground-only app, which tears down the Bonjour
/// listener — the Mac then can't connect until the user reopens the app
/// (the #1 "can't connect" report). Holding an active audio session and
/// playing silence makes iOS treat RemoteCrab as a background-audio app,
/// so the listener and any live session survive backgrounding and lock.
/// Requires `UIBackgroundModes: [audio]` in the Info.plist.
///
/// Uses `.playback` (not `.playAndRecord`) with `.mixWithOthers`: it does
/// NOT suppress the app's haptics (see the mic lesson) and does not
/// interrupt the user's music. It emits no audible sound.
final class BackgroundKeepAlive: @unchecked Sendable {

    static let shared = BackgroundKeepAlive()
    private static let log = Logger(subsystem: "com.remotecrab", category: "keepalive")

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private(set) var isActive = false

    private init() {}

    /// User preference (default on) — the app stays reachable in the
    /// background. Off means iOS suspends the app as before.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "remotecrab.ios.backgroundKeepAlive") as? Bool ?? true
    }

    func start() {
        guard !isActive, Self.enabled else { return }
        Forensic.log("[keepalive] start requested")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            Forensic.log("[keepalive] session playback active")

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
                  let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
                Self.log.error("keep-alive: could not build the silent buffer")
                return
            }
            silence.frameLength = 44_100   // 1 s of silence, looped
            // Guarantee true silence: zero every channel AND mute the
            // mixer, so nothing can ever be audible (a non-silent buffer
            // would come out as a constant hum).
            if let ch = silence.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    memset(ch[c], 0, Int(silence.frameLength) * MemoryLayout<Float>.size)
                }
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: [.loops], completionHandler: nil)
            player.play()

            self.engine = engine
            self.player = player
            isActive = true
            Self.log.info("background keep-alive started")
        } catch {
            Self.log.error("keep-alive failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop(deactivateSession: Bool = true) {
        guard isActive else { return }
        Forensic.log("[keepalive] stop requested (deactivate=\(deactivateSession))")
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        isActive = false
        // When handing the session to the mic/voice engine, leave it
        // active and let them reconfigure — a deactivate → reactivate in
        // the same runloop turn makes their `setActive(true)` fail.
        if deactivateSession {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
        Self.log.info("background keep-alive stopped (deactivate=\(deactivateSession, privacy: .public))")
    }

    /// After the mic/voice engine releases its record session, restore the
    /// non-record `.playback` category the keep-alive needs. Returns true
    /// when it handled the session (so callers skip `setActive(false)`).
    @discardableResult
    func restoreAfterRecording() -> Bool {
        guard isActive else { return false }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        return true
    }
}
