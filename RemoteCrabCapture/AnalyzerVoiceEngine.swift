import AVFoundation
import Foundation
import os
import Speech

/// iOS 26+ hold-to-talk backend built on `SpeechAnalyzer` /
/// `SpeechTranscriber` — the new on-device long-form model (the one Notes
/// and call transcription use). No ~1 min cap, better accuracy on long
/// holds, fully offline.
///
/// Selected only when the OS + hardware support it AND a model for one of
/// our locales is ALREADY installed (see `VoiceEngineSelector`). We never
/// trigger a download; if the asset is absent, `start()` returns false and
/// `VoiceRecognizer` falls back to the legacy engine.
///
/// Result model maps 1:1 onto what the app already expects:
/// finalized results are append-only committed text; the volatile result
/// is the still-revisable tail.
@available(iOS 26.0, *)
@MainActor
final class AnalyzerVoiceEngine: VoiceEngine {

    private static let log = Logger(subsystem: "com.remotecrab", category: "VoiceAnalyzer")

    var onPartial: ((_ full: String, _ committedCount: Int) -> Void)?
    var onFinal: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    var onRecoveringChanged: ((Bool) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    private var committedText = ""
    private var volatileText = ""
    /// Longest `committed + volatile` ever seen this session (see the results
    /// loop) — the finalizer can truncate the tail, so the final must not
    /// shrink below this.
    private var longestSeen = ""
    private var isRunning = false
    private var isStarting = false
    private var stopRequested = false
    private var finalDelivered = false
    /// The in-flight teardown from the last `stop()`; `start()` awaits it so a
    /// rapid re-press can't race (or skip) the previous session's release.
    private var teardownTask: Task<Void, Never>?

    // MARK: - Start / stop

    /// Awaits the in-flight teardown (if any). `VoiceRecognizer` awaits this
    /// before starting a new engine, so an old session is fully released and
    /// can never touch the new one.
    func waitForTeardown() async {
        if let teardown = teardownTask { await teardown.value }
    }

    func start() async -> Bool {
        guard !isRunning else { return true }
        guard !isStarting else { return true }
        isStarting = true
        defer { isStarting = false }

        // Serialize with the previous session's teardown. `stop()` tore the
        // session down on a 300 ms delay; when the user pressed again sooner,
        // the old `guard stopRequested` skipped that teardown entirely (the
        // new start resets `stopRequested`), leaking the analyzer, its
        // results task and the installed mic tap — after a few uses `start()`
        // simply failed ("用几次就不能说话了"). Waiting for it here keeps the
        // shared state safe AND guarantees the old session is released.
        if let teardown = teardownTask {
            await teardown.value
            teardownTask = nil
        }

        guard SpeechTranscriber.isAvailable,
              let locale = await Self.resolveInstalledLocale() else {
            Self.log.info("SpeechAnalyzer unavailable (hw off or no installed locale)")
            return false
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .mixWithOthers)
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            Self.log.error("audio session setup failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            Self.log.error("no compatible analyzer audio format")
            return false
        }

        committedText = ""
        volatileText = ""
        stopRequested = false
        finalDelivered = false

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        startResultsTask(transcriber)

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            Self.log.error("analyzer start failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        do {
            try startAudioEngine(analyzerFormat: analyzerFormat)
        } catch {
            Self.log.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
            stopAudioEngine()
            return false
        }

        installInterruptionObserver()
        isRunning = true
        Self.log.info("analyzer session started (locale \(locale.identifier, privacy: .public))")
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopRequested = true

        // Let the tail audio reach the transcriber before we close the
        // input (releasing the PTT used to stop the mic first, so the last
        // syllable never reached the recognizer). The teardown ALWAYS runs —
        // it releases this session's own objects; `start()` awaits
        // `teardownTask`, so the shared state cannot be clobbered.
        teardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.stopAudioEngine()
            self.inputContinuation?.finish()
            self.inputContinuation = nil

            let analyzer = self.analyzer
            let resultsTask = self.resultsTask
            if let analyzer {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            await resultsTask?.value
            self.deliverFinal()
        }
    }

    // MARK: - Results

    private func startResultsTask(_ transcriber: SpeechTranscriber) {
        resultsTask?.cancel()
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.appendSegment(text)
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    let full = self.committedText + self.volatileText
                    // The finalizer can emit a SHORTER last segment than the
                    // volatile text the phone already showed, which is how the
                    // trailing 1-2 characters got lost. Keep the longest text
                    // seen and never deliver less than that.
                    if full.count > self.longestSeen.count { self.longestSeen = full }
                    self.onPartial?(full, self.committedText.count)
                }
            } catch {
                guard let self, self.isRunning, !self.stopRequested else { return }
                Self.log.error("analyzer results error: \(error.localizedDescription, privacy: .public)")
                self.interrupt()
            }
        }
    }

    // MARK: - Audio

    private func startAudioEngine(analyzerFormat: AVAudioFormat) throws {
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else {
            throw NSError(domain: "com.remotecrab.voice", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }

        // When the analyzer already wants the mic's format, skip conversion.
        let converter: AVAudioConverter? = micFormat == analyzerFormat
            ? nil
            : AVAudioConverter(from: micFormat, to: analyzerFormat)

        let continuation = inputContinuation
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            guard let continuation else { return }
            guard let converter else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = analyzerFormat.sampleRate / micFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            var provided = false
            converter.convert(to: out, error: &error) { _, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: micFormat, block: tapBlock)
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Interruptions

    private func installInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let raw,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                guard let self, self.isRunning, !self.stopRequested else { return }
                switch type {
                case .began:
                    // The system took the mic. Rolling a fresh analyzer
                    // session mid-hold is not worth the risk yet — end the
                    // hold so the user can press again.
                    self.interrupt()
                case .ended:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Helpers

    private static func resolveInstalledLocale() async -> Locale? {
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47).lowercased() }
        for identifier in ["zh-Hans", "zh-CN", "en-US"] {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else { continue }
            if installed.contains(locale.identifier(.bcp47).lowercased()) { return locale }
        }
        return nil
    }

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

    private func interrupt() {
        isRunning = false
        stopAudioEngine()
        onRecoveringChanged?(false)
        cleanup()
        onInterrupted?()
    }

    private func deliverFinal() {
        guard !finalDelivered else { return }
        finalDelivered = true
        cleanup()
        let current = (committedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
        let seen = longestSeen.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = current.count >= seen.count ? current : seen
        if !text.isEmpty { onFinal?(text) }
    }

    private func cleanup() {
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        inputContinuation = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if !BackgroundKeepAlive.shared.restoreAfterRecording() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
