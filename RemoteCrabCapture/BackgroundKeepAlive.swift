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
    private var audioObservers: [NSObjectProtocol] = []
    /// Logs every few seconds while active. If it stops while the app is
    /// backgrounded, iOS suspended the process despite the audio session — the
    /// open C1b question, made observable instead of guessed.
    private var heartbeat: DispatchSourceTimer?

    private init() {}

    /// User preference (default on) — the app stays reachable in the
    /// background. Off means iOS suspends the app as before.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "remotecrab.ios.backgroundKeepAlive") as? Bool ?? true
    }

    func start() {
        observeAudioEvents()
        guard !isActive, Self.enabled else { return }
        Forensic.log("[keepalive] start requested")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // Without this, an active audio session suppresses ALL app
            // haptics — the reported "buzz/no vibration". Documented since
            // iOS 13.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
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
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { Forensic.log("[keepalive] heartbeat") }
            t.resume()
            heartbeat = t
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
        heartbeat?.cancel()
        heartbeat = nil
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

    /// Recover the session after an interruption (a call, Siri, another app
    /// taking audio) or a media-services reset (C2). Nothing observed these
    /// before, so after a phone call the keep-alive — and with it the
    /// background listener — stayed dead until a relaunch. Recovery rebuilds
    /// the engine WITHOUT deactivating the session first: a
    /// deactivate→reactivate in one runloop turn makes `setActive(true)` fail
    /// (lesson 161).
    private func observeAudioEvents() {
        guard audioObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        let handler: @Sendable (Notification) -> Void = { [weak self] note in
            // Copy the Sendable bits out before hopping (a bare Notification
            // is not Sendable under Swift 6).
            let name = note.name
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            Task { @MainActor in self?.handleAudioEvent(name: name, interruptionRaw: raw) }
        }
        audioObservers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: .main, using: handler))
        audioObservers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                             object: nil, queue: .main, using: handler))
    }

    private func handleAudioEvent(name: Notification.Name, interruptionRaw: UInt) {
        guard Self.enabled else { return }
        if name == AVAudioSession.interruptionNotification {
            switch AVAudioSession.InterruptionType(rawValue: interruptionRaw) {
            case .began:
                Forensic.log("[audio] interruption began")
                return   // iOS deactivated the session; recover when it ends
            case .ended:
                Forensic.log("[audio] interruption ended — recovering keep-alive")
            default:
                return
            }
        } else {
            Forensic.log("[audio] media services reset — rebuilding keep-alive")
        }
        guard isActive else { return }
        stop(deactivateSession: false)
        start()
    }
}
