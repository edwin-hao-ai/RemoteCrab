import AVFoundation
import Foundation
import os
import Speech

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
@MainActor
@Observable
final class VoiceRecognizer {

    private static let log = Logger(subsystem: "com.remotecrab", category: "VoiceRecognizer")

    /// Live transcription for the whole hold (committed segments plus the
    /// current one), bound by the floating UI card.
    private(set) var partialText = ""
    private(set) var isRunning = false

    /// Fired on every interim update with the FULL text so far. The Mac
    /// is typed incrementally from this.
    var onPartial: ((String) -> Void)?

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
    private let audioEngine = AVAudioEngine()

    /// Text from recognition tasks already finalized at the ~1 min cap
    /// during THIS hold — the base the current task appends to.
    private var committedText = ""

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
    private var sessionGeneration = 0

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
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
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

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            Self.log.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
            self.recognizer = nil
            if !BackgroundKeepAlive.shared.restoreAfterRecording() {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            isStarting = false
            return false
        }

        beginRecognitionTask()
        isRunning = true
        isStarting = false
        return true
    }

    /// Create a fresh recognition task bound to the (already running)
    /// audio engine. Called at start() and again at each ~1 min cap so a
    /// long hold continues seamlessly.
    private func beginRecognitionTask() {
        guard let recognizer else { return }

        task?.cancel()
        task = nil
        request = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        finalDelivered = false
        stopRequested = false
        sessionGeneration += 1

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        // The tap block runs on the audio realtime thread. Without an
        // explicit @Sendable type it inherits @MainActor isolation from
        // the enclosing type and traps in swift_task_checkIsolated on the
        // first buffer. `request` isn't Sendable, so box it — appending
        // from the tap callback is the documented Speech pattern.
        let requestBox = UnsafeSendableBox(value: request)
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            requestBox.value.append(buffer)
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapBlock)

        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(result: result, error: error)
            }
        }
    }

    /// Ends the recognition session. The final text arrives via
    /// `onFinal` once the recognizer settles (or after a 1.5 s
    /// fallback if isFinal never fires).
    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopRequested = true

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()

        let generation = sessionGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.deliverFinalIfCurrent(generation: generation)
        }
    }

    // MARK: - Recognition callbacks

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let sessionText = result.bestTranscription.formattedString
            let full = committedText + sessionText
            partialText = full
            finalText = full
            onPartial?(full)

            if result.isFinal {
                // Either the user released (stopRequested) or Speech hit
                // its ~1 min cap. At the cap while still holding, commit
                // and chain a new task so nothing is lost.
                committedText = full
                if isRunning && !stopRequested {
                    beginRecognitionTask()
                    return
                }
                deliverFinal()
                return
            }
        }
        if let error {
            Self.log.error("recognition error: \(error.localizedDescription, privacy: .public)")
            if stopRequested {
                deliverFinal()
            } else if isRunning {
                // Session died mid-dictation; tear down without firing
                // onFinal — the user hasn't released yet. Surface the
                // error so the dock can un-stick itself.
                isRunning = false
                lastError = error.localizedDescription
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
                cleanup()
                onInterrupted?()
            }
        }
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
        recognizer = nil
        stopRequested = false
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

/// Lets a value cross into a `@Sendable` tap block when the type
/// isn't Sendable but the usage pattern (single realtime thread,
/// append-only) is safe by construction.
private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}
