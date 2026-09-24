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
    private var isRunning = false
    private var stopRequested = false
    private var finalDelivered = false

    // MARK: - Start / stop

    func start() async -> Bool {
        guard !isRunning else { return true }

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

        stopAudioEngine()
        inputContinuation?.finish()
        inputContinuation = nil

        let analyzer = self.analyzer
        let resultsTask = self.resultsTask
        Task { @MainActor [weak self] in
            if let analyzer {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            await resultsTask?.value
            self?.deliverFinal()
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
                    self.onPartial?(self.committedText + self.volatileText, self.committedText.count)
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
        for identifier in ["zh-Hans", "en-US"] {
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
        let text = (committedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
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
