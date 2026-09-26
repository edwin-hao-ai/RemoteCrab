import AVFoundation
import Foundation
import Observation
import os
import Speech
import RemoteCrabCore

/// Hold-to-talk speech recognition for the voice feature.
///
/// Wraps SFSpeechRecognizer + a dedicated AVAudioEngine. While a
/// recognition session is live it owns the mic, so CaptureEngine
/// yields the MicrophoneEncoder stream (see `syncMicrophone`).
///
/// SFSpeechRecognizer caps a single task at roughly one minute. Rather
/// than tear the hold down at the cap (which used to lose everything the
/// user said next), `handleRecognition` commits the text so far and
/// **chains a fresh recognition task** onto the still-running audio
/// engine, so a long hold keeps flowing. Interim text is surfaced via
/// `onPartial` so the Mac is typed word-by-word instead of only at the
/// end — a dropped session can no longer lose a whole paragraph.
///
/// The cap is not the only way a task ends mid-hold, though: on-device
/// recognition routinely emits `kAFAssistantErrorDomain` errors — 1110
/// "No speech detected" after a silent stretch, 1101 a transient local
/// hiccup, 203 the quota/timeout that *is* the one-minute cap, 216 our
/// own task cancellation at a rollover. Those are NOT fatal. Every error
/// while the user is still holding goes through `recoverFromError`,
/// which commits the text so far and quietly starts a fresh task on the
/// same engine, so the user never has to release and press again. Only a
/// burst of rapid failures (the recognizer is genuinely down) fires
/// `onInterrupted`. Audio-session interruptions (a call, Siri, another
/// recorder) are held open the same way via `interruptionNotification`.
///
/// The audio tap is installed ONCE, before the engine starts, and appends
/// to whatever request the `requestBox` currently holds — chaining swaps
/// the request instead of reinstalling a tap on a running engine (which
/// crashed). Callbacks are tagged with `sessionGeneration` so a
/// superseded task's late cancellation error can never tear down the
/// fresh task.
@MainActor
@Observable
final class VoiceRecognizer {

    private static let log = Logger(subsystem: "com.remotecrab", category: "VoiceRecognizer")

    /// Device-side forensic trace (`Documents/forensic.log`, pullable via
    /// `devicectl device copy from`) for the voice lifecycle — DEBUG only,
    /// no-op in release. Logs key transitions only, not every partial.
    private func forensic(_ message: String) {
        Forensic.log("[voice] \(message)")
    }

    /// Live transcription for the whole hold (committed segments plus the
    /// current one), bound by the floating UI card.
    private(set) var partialText = ""
    private(set) var isRunning = false

    /// True while a routine mid-session error (or an audio-session
    /// interruption) is being recovered. The hold is still active — the
    /// card shows this instead of appearing frozen, and the user must
    /// NOT release/re-press.
    private(set) var isRecovering = false

    /// Fired on every interim update with the FULL text so far plus the
    /// length of its FINALIZED prefix (`committedText`). The Mac types
    /// only the finalized prefix live (append-only); the volatile tail is
    /// left for the final. The full string drives the on-screen card.
    var onPartial: ((_ full: String, _ committedCount: Int) -> Void)?

    /// Fired exactly once per stop() with the trimmed final text.
    /// Empty results never fire.
    var onFinal: ((String) -> Void)?

    /// Fired when a live session ends on its own for good — a mid-session
    /// error, not the routine ~1 min chaining — instead of via a
    /// user-initiated stop(). The dock uses this to reset its held state.
    var onInterrupted: (() -> Void)?

    /// Set when a mid-session error kills the recognition session;
    /// the voice card flashes it briefly, then `clearError()` resets.
    private(set) var lastError: String?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Recreated on every session start — see `startAudioEngine()`.
    private var audioEngine = AVAudioEngine()

    /// Holds the request the (single) audio tap appends to, so a new
    /// recognition task can take over without touching the tap.
    private let requestBox = RecognitionRequestBox()

    /// Text from recognition tasks already finalized at the ~1 min cap
    /// during THIS hold — the base the current task appends to.
    private var committedText = ""
    /// The current task's own transcription, so a pause-induced reset
    /// (which shrinks it) can be detected and committed.
    private var lastSessionText = ""

    /// Guards against double-firing onFinal between the isFinal
    /// callback and the 1.5 s fallback timer.
    private var finalDelivered = false
    private var finalText = ""
    private var stopRequested = false

    /// True while start() is between entry and a settled outcome, so
    /// a re-entrant start() can't orphan an in-flight recognition task.
    private var isStarting = false

    /// Incremented per recognition task; the stop() fallback timer
    /// compares against it so a stale timer can't tear down a newer task.
    /// Also carried into each task's callback so a superseded task's late
    /// (cancellation) error is ignored instead of killing the live task.
    private var sessionGeneration = 0

    /// Bumped once per hold. A scheduled recovery/resume from a previous
    /// hold must not resurrect a session the user released and re-pressed.
    private var holdToken = 0

    /// Rapid-consecutive-failure guard. Reset whenever the current task
    /// produces text, or when the previous failure was more than
    /// `failureResetInterval` ago — so a healthy long hold is never torn
    /// down by a lone hiccup, but a recognizer that fails instantly every
    /// time gives up after `maxConsecutiveFailures`.
    private var consecutiveFailures = 0
    private var lastFailureAt = Date.distantPast
    private static let maxConsecutiveFailures = 5
    private static let failureResetInterval: TimeInterval = 3
    private static let recoveryDelay: Duration = .milliseconds(200)
    /// Roll the recognition task at a natural boundary once it is this
    /// old, before the on-device recognizer starts dropping results.
    private static let proactiveRolloverInterval: TimeInterval = 20

    /// When the current recognition task was created (for proactive
    /// rollover on long holds).
    private var taskStartedAt = Date.distantPast

    /// Audio-session interruption observer (call / Siri / another recorder).
    private var interruptionObserver: NSObjectProtocol?

    /// Non-nil while an iOS 26 SpeechAnalyzer session drives the hold.
    /// When set, the legacy SFSpeechRecognizer fields below are unused.
    /// Not UI state — kept out of the observation graph.
    @ObservationIgnored private var analyzerEngine: (any VoiceEngine)?

    /// Returns an analyzer engine only when iOS 26 + hardware support it
    /// AND a model for one of our locales is ALREADY installed — we never
    /// trigger a download (`VoiceEngineSelector` encodes that policy).
    private static func makeAnalyzerEngine() async -> (any VoiceEngine)? {
        guard #available(iOS 26.0, *) else {
            Forensic.log("[voice] analyzer: no (iOS < 26)")
            return nil
        }
        guard SpeechTranscriber.isAvailable else {
            Forensic.log("[voice] analyzer: no (SpeechTranscriber.isAvailable = false)")
            return nil
        }
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        // Canonicalize what we want: the device reports `zh-CN` while we
        // ask for `zh-Hans` — equivalent, so resolve through Speech before
        // matching, or we'd wrongly fall back to legacy forever.
        var desired: [String] = []
        for identifier in ["zh-Hans", "en-US"] {
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
                desired.append(locale.identifier(.bcp47))
            }
        }
        let kind = VoiceEngineSelector.choose(
            osSupportsAnalyzer: true,
            analyzerHardwareAvailable: true,
            installedLocales: installed,
            desiredLocales: desired
        )
        Forensic.log("[voice] analyzer: installed=\(installed) desired=\(desired) → \(kind)")
        return kind == .analyzer ? AnalyzerVoiceEngine() : nil
    }

    // MARK: - Recognizer selection

    /// 端侧优先：zh-Hans → en-US → 系统默认。无端侧模型时允许服务端
    /// （SFSpeechRecognizer 默认行为）。
    private func makeRecognizer() -> SFSpeechRecognizer? {
        for identifier in ["zh-Hans", "en-US"] {
            if let candidate = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               candidate.isAvailable,
               candidate.supportsOnDeviceRecognition {
                Self.log.info("recognizer locale: \(identifier, privacy: .public) (on-device)")
                return candidate
            }
        }
        let fallback = SFSpeechRecognizer()
        Self.log.info("recognizer falling back to system default; on-device: \(fallback?.supportsOnDeviceRecognition ?? false, privacy: .public)")
        return fallback
    }

    // MARK: - Session

    /// Requests speech authorization and starts a recognition session.
    /// Returns false when speech recognition is unavailable or denied.
    func start() async -> Bool {
        guard !isRunning, !isStarting else { return true }
        isStarting = true

        // Prefer the iOS 26 SpeechAnalyzer engine when it can run with an
        // already-installed model (never downloads). If it can't or fails,
        // fall through to the legacy SFSpeechRecognizer path below.
        if let engine = await Self.makeAnalyzerEngine() {
            engine.onPartial = { [weak self] full, committed in
                guard let self else { return }
                self.partialText = full
                self.onPartial?(full, committed)
            }
            engine.onFinal = { [weak self] text in
                guard let self else { return }
                self.isRunning = false
                self.onFinal?(text)
            }
            engine.onInterrupted = { [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.isRecovering = false
                self.onInterrupted?()
            }
            engine.onRecoveringChanged = { [weak self] recovering in
                self?.isRecovering = recovering
            }
            if await engine.start() {
                analyzerEngine = engine
                isRunning = true
                isStarting = false
                forensic("engine=analyzer")
                return true
            }
            forensic("engine=analyzer start failed; using legacy")
        }

        let status = await Self.requestAuthorization()
        Self.log.info("speech authorization: \(status.rawValue, privacy: .public)")
        guard status == .authorized else {
            isStarting = false
            return false
        }

        guard let recognizer = makeRecognizer(), recognizer.isAvailable else {
            Self.log.error("no speech recognizer available")
            isStarting = false
            return false
        }
        Self.log.info("on-device recognition: \(recognizer.supportsOnDeviceRecognition, privacy: .public)")

        let session = AVAudioSession.sharedInstance()
        do {
            // `.record` + `options: []` — `.mixWithOthers` is only valid for
            // playback categories; the mic stream uses the same shape.
            try session.setCategory(.record, mode: .measurement, options: [])
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            Self.log.error("audio session setup failed: \(error.localizedDescription, privacy: .public)")
            isStarting = false
            return false
        }

        self.recognizer = recognizer
        partialText = ""
        finalText = ""
        committedText = ""
        lastError = nil
        finalDelivered = false
        stopRequested = false
        consecutiveFailures = 0
        lastFailureAt = .distantPast
        isRecovering = false

        // Install the tap BEFORE the engine runs (installing it after
        // start() traps), and keep it feeding requestBox so chaining never
        // has to reinstall it on a running engine.
        requestBox.reset()
        do {
            try startAudioEngine()
        } catch {
            Self.log.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
            audioEngine.inputNode.removeTap(onBus: 0)
            self.recognizer = nil
            if !BackgroundKeepAlive.shared.restoreAfterRecording() {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            isStarting = false
            return false
        }

        installInterruptionObserver()
        holdToken += 1
        // Mark the session live BEFORE creating the first task — the
        // task-creation guard requires `isRunning`, so the other order
        // silently created no task at all ("Listening…" but deaf).
        isRunning = true
        isStarting = false
        beginRecognitionTask()
        Self.log.info("voice session started (hold)")
        forensic("start ok on-device=\(recognizer.supportsOnDeviceRecognition)")
        return true
    }

    /// Create a fresh recognition task bound to the live audio engine.
    /// Called at start(), at each ~1 min cap, and after every recovered
    /// error so a long hold continues seamlessly. The audio tap keeps
    /// feeding `requestBox`.
    ///
    /// `throttled` inserts a short gap between cancelling the old task and
    /// creating the new one: `SFSpeechRecognizer` only tolerates one live
    /// task, and starting the next immediately (as we did on a pause /
    /// `isFinal` rollover) made it fail and cascade into a teardown —
    /// "said one sentence, paused, it disconnected". The NEW request is
    /// installed in `requestBox` *before* the gap, so the tap keeps
    /// buffering into it and no audio is lost while the recognizer settles.
    private func beginRecognitionTask(throttled: Bool = false) {
        guard let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        requestBox.request = request
        self.request = request

        task?.cancel()
        task = nil
        lastSessionText = ""
        finalDelivered = false
        stopRequested = false
        isRecovering = false
        sessionGeneration += 1
        taskStartedAt = Date()
        let generation = sessionGeneration

        let createTask = { [weak self] in
            guard let self, self.sessionGeneration == generation,
                  self.isRunning, !self.stopRequested else { return }
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    // Drop callbacks from a superseded task — its late
                    // cancellation error must not tear down the live task.
                    guard let self, self.sessionGeneration == generation else { return }
                    self.handleRecognition(result: result, error: error)
                }
            }
            self.forensic("task created (throttled=\(throttled))")
        }

        if throttled {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                createTask()
            }
        } else {
            createTask()
        }
    }

    /// Ends the recognition session. The final text arrives via
    /// `onFinal` once the recognizer settles (or after a 1.5 s
    /// fallback if isFinal never fires).
    func stop() {
        if let analyzerEngine {
            self.analyzerEngine = nil
            isRunning = false
            isRecovering = false
            forensic("stop requested (analyzer)")
            analyzerEngine.stop()
            return
        }
        guard isRunning else { return }
        isRunning = false
        isRecovering = false
        stopRequested = true
        forensic("stop requested")

        let generation = sessionGeneration
        // Let the tail audio reach the recognizer before we close the
        // request: the old order stopped the mic first, so the last
        // syllable never made it and the final dropped 1–2 characters.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.request?.endAudio()
            self.requestBox.markEnded()
            self.stopAudioEngine()
            try? await Task.sleep(for: .milliseconds(1500))
            self.deliverFinalIfCurrent(generation: generation)
        }
    }

    // MARK: - Recognition callbacks

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let sessionText = result.bestTranscription.formattedString
            // The recognizer's `formattedString` is authoritative for the
            // CURRENT utterance — it grows and REVISES (punctuation, word
            // fixes). But the on-device recognizer DISCARDS it on a pause
            // (iOS 18) and starts the next utterance from "". `onPartial`
            // must therefore only ever GROW: when an utterance ends, fold
            // its text into `committedText` so the reset can't make the
            // emitted string shrink.
            let utteranceEnded = result.isFinal || result.speechRecognitionMetadata != nil
            var endedBoundary = false
            if sessionText.isEmpty && !lastSessionText.isEmpty {
                forensic("pause reset (\(lastSessionText.count) chars)")
                appendSegment(lastSessionText)
                lastSessionText = ""
                endedBoundary = true
            } else if utteranceEnded {
                forensic("utterance ended final=\(result.isFinal) meta=\(result.speechRecognitionMetadata != nil) chars=\(sessionText.count)")
                appendSegment(sessionText)
                lastSessionText = ""
                endedBoundary = true
            } else {
                lastSessionText = sessionText
            }
            if !sessionText.isEmpty { consecutiveFailures = 0 }
            let full = committedText + lastSessionText
            partialText = full
            finalText = full
            onPartial?(full, committedText.count)

            if result.isFinal {
                // Either the user released (stopRequested) or Speech hit
                // its ~1 min cap. At the cap while still holding, chain a
                // new task so nothing is lost (text already committed).
                if isRunning && !stopRequested {
                    beginRecognitionTask(throttled: true)
                    return
                }
                deliverFinal()
                return
            }

            // Proactive roll: the on-device recognizer degrades on a long
            // task — sparse/dropped results after ~30-40 s, then a hard cap
            // at ~1 min. At a natural segment boundary (text already
            // committed) start a fresh task before that, so a long hold
            // never reaches the degradation zone.
            if endedBoundary, isRunning, !stopRequested,
               Date().timeIntervalSince(taskStartedAt) > Self.proactiveRolloverInterval {
                forensic("proactive rollover age=\(Int(Date().timeIntervalSince(taskStartedAt)))s")
                beginRecognitionTask(throttled: true)
                return
            }
        }
        if let error {
            if stopRequested {
                deliverFinal()
                return
            }
            guard isRunning else { return }
            // Not fatal: commit what we have and quietly restart on the
            // still-running engine. The user keeps holding, never re-presses.
            recoverFromError(error)
        }
    }

    /// Recover from a routine mid-session error without ending the hold.
    /// Gives up (→ `onInterrupted`) only after a burst of rapid failures,
    /// which means the recognizer is genuinely unavailable.
    private func recoverFromError(_ error: Error) {
        // A second error can land inside the 200 ms recovery window (e.g.
        // the dying task's cancellation). One recovery is already running.
        guard !isRecovering else { return }

        let ns = error as NSError
        let now = Date()
        if now.timeIntervalSince(lastFailureAt) > Self.failureResetInterval {
            consecutiveFailures = 0
        }
        consecutiveFailures += 1
        lastFailureAt = now
        let attempt = consecutiveFailures

        Self.log.error("recognition error (\(ns.domain, privacy: .public) \(ns.code, privacy: .public)); recovery \(attempt, privacy: .public)/\(Self.maxConsecutiveFailures, privacy: .public)")
        forensic("error \(ns.domain)/\(ns.code) recovery \(attempt)/\(Self.maxConsecutiveFailures)")

        guard attempt <= Self.maxConsecutiveFailures else {
            Self.log.error("recognition unavailable after \(Self.maxConsecutiveFailures, privacy: .public) rapid failures")
            interrupt(error.localizedDescription)
            return
        }

        commitCurrent()
        // Invalidate the dying task's late callbacks so it can't append its
        // stale transcript on top of the text we just committed.
        sessionGeneration += 1
        isRecovering = true

        let token = holdToken
        Task { [weak self] in
            try? await Task.sleep(for: Self.recoveryDelay)
            self?.resumeRecognition(token: token)
        }
    }

    /// Restart recognition after a recovered error, bringing the audio
    /// engine back if an interruption took it down.
    private func resumeRecognition(token: Int) {
        guard token == holdToken, isRunning, !stopRequested else { return }
        if !audioEngine.isRunning {
            do {
                try startAudioEngine()
            } catch {
                Self.log.error("engine restart failed: \(error.localizedDescription, privacy: .public)")
                interrupt(error.localizedDescription)
                return
            }
        }
        isRecovering = false
        beginRecognitionTask()
        Self.log.info("recovered — recognition task restarted (hold still active)")
        forensic("restarted after error")
    }

    /// Fatal: the hold is over. Surfaces the reason and lets the UI reset
    /// so the user can press again.
    private func interrupt(_ message: String) {
        isRunning = false
        isRecovering = false
        lastError = message
        stopAudioEngine()
        cleanup()
        Self.log.error("voice session ended: \(message, privacy: .public)")
        forensic("INTERRUPTED: \(message)")
        onInterrupted?()
    }

    // MARK: - Interruptions (call / Siri / another recorder)

    private func installInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self?.handleInterruption(type)
            }
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            guard isRunning, !stopRequested else { return }
            Self.log.info("audio interruption began — holding the session")
            forensic("interruption began")
            isRecovering = true
            stopAudioEngine()

        case .ended:
            guard isRunning, !stopRequested else { return }
            Self.log.info("audio interruption ended — resuming")
            let token = holdToken
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                self?.resumeAfterInterruption(token: token)
            }

        @unknown default:
            break
        }
    }

    private func resumeAfterInterruption(token: Int) {
        guard token == holdToken, isRunning, !stopRequested else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            Self.log.error("session reactivation failed: \(error.localizedDescription, privacy: .public)")
        }
        if !audioEngine.isRunning {
            do {
                try startAudioEngine()
            } catch {
                Self.log.error("engine restart failed: \(error.localizedDescription, privacy: .public)")
                interrupt(error.localizedDescription)
                return
            }
        }
        isRecovering = false
        beginRecognitionTask()
        Self.log.info("resumed after audio interruption (hold still active)")
        forensic("resumed after interruption")
    }

    // MARK: - Audio engine

    /// Install the tap, then start the engine. The tap runs on the
    /// realtime thread and routes through `requestBox`, so it survives
    /// task chaining and interruption restarts.
    private func startAudioEngine() throws {
        // A pooled AVAudioEngine accumulates graph state across start/stop
        // cycles; once that state is dirty, AVFoundation raises an
        // *Objective-C* exception from `AVAudioEngineGraph::Initialize`
        // (usually via `prepare()`) that Swift cannot catch — the app dies
        // with SIGABRT. A fresh engine each session can't inherit it, and
        // `start()` prepares the graph itself, so the separate `prepare()`
        // call (the one on the crash stack) is gone.
        stopAudioEngine()
        audioEngine = AVAudioEngine()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "com.remotecrab.voice", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }
        let box = requestBox
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            if box.ended { return }
            box.request?.append(buffer)
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapBlock)
        try audioEngine.start()
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// Fold the current utterance into `committedText` so a restart
    /// (pause, cap, error, interruption) never loses or repeats words.
    private func commitCurrent() {
        appendSegment(lastSessionText)
        lastSessionText = ""
        partialText = committedText
        finalText = committedText
    }

    /// Append a finished utterance to `committedText`. Inserts a single
    /// space between ASCII word boundaries (English) and nothing between
    /// CJK (Chinese/Japanese), matching how the Mac types the text.
    private func appendSegment(_ text: String) {
        guard !text.isEmpty else { return }
        if committedText.isEmpty {
            committedText = text
        } else if Self.needsSpace(committedText.last, text.first) {
            committedText += " " + text
        } else {
            committedText += text
        }
    }

    private static func needsSpace(_ a: Character?, _ b: Character?) -> Bool {
        guard let a, let b else { return false }
        return a.isASCII && b.isASCII && (a.isLetter || a.isNumber) && (b.isLetter || b.isNumber)
    }

    /// Fallback-timer entry point: delivers only if the task that
    /// scheduled it is still the current one.
    private func deliverFinalIfCurrent(generation: Int) {
        guard generation == sessionGeneration else { return }
        deliverFinal()
    }

    /// Fires onFinal at most once per hold, with non-empty
    /// trimmed text only.
    private func deliverFinal() {
        guard !finalDelivered else { return }
        finalDelivered = true

        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            onFinal?(text)
        }
        cleanup()
    }

    private func cleanup() {
        task?.cancel()
        task = nil
        request = nil
        requestBox.request = nil
        recognizer = nil
        stopRequested = false
        isRecovering = false
        consecutiveFailures = 0
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if !BackgroundKeepAlive.shared.restoreAfterRecording() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Clears the surfaced mid-session error after the UI has shown it.
    func clearError() {
        lastError = nil
    }

    /// TCC answers on a private XPC queue, so this must be
    /// nonisolated — a @MainActor closure would trap in
    /// swift_task_checkIsolated when the reply arrives.
    private nonisolated static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

/// Lets the audio tap reach the current request across the chaining swap.
/// The tap runs on the realtime thread; the swap happens on the main
/// actor, so access is locked (append-only otherwise).
private final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var _ended = false

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }

    /// True once `endAudio()` was called — the tap must stop appending or
    /// the request raises "cannot append after end of audio".
    var ended: Bool {
        lock.lock(); defer { lock.unlock() }; return _ended
    }

    func markEnded() {
        lock.lock(); _ended = true; lock.unlock()
    }

    func reset() {
        lock.lock(); _ended = false; lock.unlock()
    }
}
