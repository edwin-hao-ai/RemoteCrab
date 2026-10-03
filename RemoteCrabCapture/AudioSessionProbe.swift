//
//  AudioSessionProbe.swift
//
//  E2E hook (gated, zero production cost): answers the one iOS question that
//  decides whether "use the iPhone as the computer's speaker" is possible at
//  all, and if so, whether the mic can be handed back afterwards.
//
//      REMOTECRAB_E2E_AUDIOSESSION=1
//
//  Why this needs a probe rather than a code reading:
//
//  • `Info.plist` declares `UIBackgroundModes: [audio]`.
//  • Lesson 50 recorded that `.playAndRecord` then fails to activate with
//    561017449 — but its two candidate causes (AVCaptureSession's audio
//    input fighting for the session, vs the background mode itself) were
//    changed together and never isolated, so the conclusion is unreliable.
//  • The feature needs exactly three claims to be TRUE simultaneously:
//      1. `.playback` can be claimed (the phone speaker path) while the app
//         keeps streaming — BackgroundKeepAlive already proves this shape.
//      2. `.record` (mic) → `.playback` (speaker) can be handed over.
//      3. `.playback` → `.record` can be handed BACK without a deactivate /
//         reactivate in the same runloop turn, which is the trap lesson 50
//         and BackgroundKeepAlive.stop() both warn about.
//    If (3) is false, the mic breaks every time a user returns from speaker
//    mode, and the whole design needs a different arbitration point.
//
//  Everything is logged with a `state=` line after each step and a BEGIN/END
//  pair, so a run that silently does nothing can never be mistaken for a pass.
//

import AVFoundation
import Foundation

enum AudioSessionProbe {
    private static let logTag = "[audiosession]"
    private static var hasRun = false

    /// True when the app declares `UIBackgroundModes: [audio]` — read from the
    /// real Info.plist rather than assumed, because it is the variable that
    /// makes `.playAndRecord` illegal.
    private static var backgroundAudioDeclared: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
            .contains("audio") ?? false
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["REMOTECRAB_E2E_AUDIOSESSION"] == "1" else { return }
        guard !hasRun else { return }
        hasRun = true
        // Let the app finish claiming whatever it wants at launch before
        // measuring, so step 1 is a real baseline and not a race.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await run()
        }
    }

    // MARK: - reporting

    private static func log(_ message: String) {
        Forensic.log("\(logTag) \(message)")
        print("\(logTag) \(message)")
    }

    private static func describe(_ s: AVAudioSession) -> String {
        let active = (try? s.isOtherAudioPlaying) ?? false
        return "cat=\(s.category.rawValue) mode=\(s.mode.rawValue) "
            + "rate=\(s.sampleRate) outCh=\(s.outputNumberOfChannels) "
            + "outRoute=\(s.outputRoute.portName.rawValue) otherAudioPlaying=\(active)"
    }

    private static func logState(_ name: String, _ s: AVAudioSession) {
        log("state name=\(name) \(describe(s))")
    }

    /// One claim = setCategory then setActive, each reported separately so a
    /// failure names WHICH call failed rather than just "it didn't work".
    @discardableResult
    private static func claim(_ name: String, _ s: AVAudioSession,
                              category: AVAudioSession.Category,
                              mode: AVAudioSession.Mode,
                              options: AVAudioSession.CategoryOptions = []) -> Bool {
        var catOK = false, actOK = false
        var catErr = 0, actErr = 0

        do {
            try s.setCategory(category, mode: mode, options: options)
            catOK = true
        } catch {
            catErr = (error as NSError).code
        }
        if catOK {
            // Exactly what MicrophoneEncoder / BackgroundKeepAlive do.
            try? s.setAllowHapticsAndSystemSoundsDuringRecording(true)
            do {
                try s.setActive(true)
                actOK = true
            } catch {
                actErr = (error as NSError).code
            }
        }
        let ok = catOK && actOK
        log("claim name=\(name) want=\(category.rawValue)/\(mode.rawValue) "
            + "setCat=\(catOK ? "ok" : "FAIL err=\(catErr)") "
            + "setActive=\(actOK ? "ok" : "FAIL err=\(actErr)") ok=\(ok)")
        return ok
    }

    // MARK: - the probe

    @MainActor
    private static func run() async {
        let s = AVAudioSession.sharedInstance()
        var failures = 0

        log("BEGIN bgAudioDeclared=\(backgroundAudioDeclared) steps=0")

        // Start from a clean slate — the product hands the session over
        // exactly this way between modes.
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        try? await Task.sleep(for: .milliseconds(500))
        logState("baseline", s)

        // (1) The mic's claim, verbatim from MicrophoneEncoder. Establishes
        //     that `.record` works at all on this build/device.
        if !claim("record-from-clean", s, category: .record, mode: .default) { failures += 1 }
        logState("after-record", s)
        try? await Task.sleep(for: .milliseconds(400))

        // (2) THE claim this feature lives on: mic is streaming, the phone
        //     speaker asks for the session.
        if !claim("playback-from-record", s, category: .playback, mode: .default,
                  options: [.mixWithOthers]) { failures += 1 }
        logState("after-playback", s)

        // (3) Does a playback graph actually RUN under it, or only activate?
        //     A silent loop is exactly BackgroundKeepAlive's shape, so this is
        //     the real mechanism the feature would use.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: s.sampleRate, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        var playerRunning = false
        do {
            try engine.start()
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.sampleRate / 10))!
            silence.frameLength = silence.frameCapacity
            for c in 0..<Int(format.channelCount) {
                memset(silence.floatChannelData![c], 0, Int(silence.frameLength) * MemoryLayout<Float>.size)
            }
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
            try? await Task.sleep(for: .milliseconds(500))
            playerRunning = player.isPlaying
            player.stop()
            engine.stop()
        } catch {
            log("player name=silent-loop FAIL err=\((error as NSError).code)")
            failures += 1
        }
        if playerRunning { log("player name=silent-loop isPlaying=true") }
        else { log("player name=silent-loop isPlaying=false"); failures += 1 }

        // (4) THE claim that would silently break the mic: hand the session
        //     BACK. BackgroundKeepAlive.stop() warns that a deactivate →
        //     reactivate inside one runloop turn makes the next setActive
        //     fail, so try the handover WITHOUT deactivating first — that is
        //     what the real implementation would do.
        if !claim("record-from-playback", s, category: .record, mode: .default) { failures += 1 }
        logState("after-handover-back", s)

        // (5) Settle lesson 50 in isolation: `.playAndRecord` from a clean
        //     session, with nothing else touching the audio graph. If this
        //     FAILS, the background mode really is the cause. If it SUCCEEDS,
        //     lesson 50's conclusion was wrong and the mic feature can be
        //     reconsidered as coexistence rather than mutual exclusion.
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        try? await Task.sleep(for: .milliseconds(500))
        if !claim("playAndRecord-from-clean", s, category: .playAndRecord, mode: .default,
                  options: [.defaultToSpeaker, .allowBluetooth]) { failures += 1 }
        logState("after-playAndRecord", s)

        // (6) And back to a neutral playback state, so the app is left the way
        //     the probe found it rather than mid-experiment.
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        try? await Task.sleep(for: .milliseconds(300))
        _ = claim("playback-restore", s, category: .playback, mode: .default, options: [.mixWithOthers])
        logState("final", s)

        log("END steps=5 failures=\(failures)")
    }
}