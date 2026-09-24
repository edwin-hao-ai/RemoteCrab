import Foundation

/// Common surface for a hold-to-talk transcription backend.
///
/// `VoiceRecognizer` owns the public, UI-observed state and the legacy
/// `SFSpeechRecognizer` implementation; on iOS 26 it can instead delegate
/// to `AnalyzerVoiceEngine` (SpeechAnalyzer) which conforms to this.
@MainActor
protocol VoiceEngine: AnyObject {
    /// Full text so far, plus the length of its finalized prefix.
    var onPartial: ((_ full: String, _ committedCount: Int) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onInterrupted: (() -> Void)? { get set }
    /// True while a routine hiccup is being recovered (hold still active).
    var onRecoveringChanged: ((Bool) -> Void)? { get set }

    func start() async -> Bool
    func stop()
}
