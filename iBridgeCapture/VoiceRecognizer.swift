import AVFoundation
import Foundation
import os
import Speech

/// Hold-to-talk speech recognition for the voice feature.
///
/// Wraps SFSpeechRecognizer + a dedicated AVAudioEngine. While a
/// recognition session is live it owns the mic, so CaptureEngine
/// yields the MicrophoneEncoder stream (see `syncMicrophone`).
@MainActor
@Observable
final class VoiceRecognizer {

    private static let log = Logger(subsystem: "com.ibridge", category: "VoiceRecognizer")

    /// Live interim transcription, bound by the floating UI card.
    private(set) var partialText = ""
    private(set) var isRunning = false

    /// Fired exactly once per stop() with the trimmed final text.
    /// Empty results never fire.
    var onFinal: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Guards against double-firing onFinal between the isFinal
    /// callback and the 1.5 s fallback timer.
    private var finalDelivered = false
    private var finalText = ""
    private var stopRequested = false

    /// True while start() is between entry and a settled outcome, so
    /// a re-entrant start() can't orphan an in-flight recognition task.
    private var isStarting = false

    /// Incremented per start(); the stop() fallback timer compares
    /// against it so a stale timer can't tear down a newer session.
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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        self.recognizer = recognizer
        self.request = request
        partialText = ""
        finalText = ""
        finalDelivered = false
        stopRequested = false
        sessionGeneration += 1

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(result: result, error: error)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            Self.log.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
            task?.cancel()
            task = nil
            self.request = nil
            self.recognizer = nil
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            isStarting = false
            return false
        }

        isRunning = true
        isStarting = false
        return true
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
            partialText = result.bestTranscription.formattedString
            finalText = partialText
            if result.isFinal {
                if isRunning {
                    // Recognizer finalized on its own (Speech caps
                    // sessions at ~1 min) while the user is still
                    // holding — tear the audio side down like the
                    // mid-session error path; onFinal still fires.
                    isRunning = false
                    audioEngine.stop()
                    audioEngine.inputNode.removeTap(onBus: 0)
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
                // Session died mid-dictation; tear down without
                // firing onFinal — the user hasn't released yet.
                isRunning = false
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
                cleanup()
            }
        }
    }

    /// Fallback-timer entry point: delivers only if the session that
    /// scheduled it is still the current one.
    private func deliverFinalIfCurrent(generation: Int) {
        guard generation == sessionGeneration else { return }
        deliverFinal()
    }

    /// Fires onFinal at most once per session, with non-empty
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
