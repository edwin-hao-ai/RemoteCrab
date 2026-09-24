import Foundation

/// Which speech-to-text backend a voice session should use.
public enum VoiceEngineKind: Sendable, Equatable {
    /// iOS 26+ on-device `SpeechAnalyzer` / `SpeechTranscriber` — newer
    /// long-form model, no ~1 min cap. Used only when the OS and hardware
    /// support it AND a model for one of our locales is ALREADY installed
    /// (we never trigger a download).
    case analyzer
    /// `SFSpeechRecognizer` — the fallback that works everywhere.
    case legacy
}

/// Pure policy for picking the voice backend, kept out of the view layer
/// so it is unit-testable without Speech/AVFoundation.
///
/// The rule is deliberately conservative: the analyzer engine is only
/// chosen when it can run *without asking the user to download anything*.
/// A missing locale asset silently falls back to the legacy engine, which
/// still gives a good experience — it just lacks the long-form model.
public enum VoiceEngineSelector {

    /// - Parameters:
    ///   - osSupportsAnalyzer: `#available(iOS 26, *)`
    ///   - analyzerHardwareAvailable: `SpeechTranscriber.isAvailable`
    ///     (hardware-sensitive — an OS check alone is not enough)
    ///   - installedLocales: BCP-47 ids already on the device
    ///     (`SpeechTranscriber.installedLocales`)
    ///   - desiredLocales: BCP-47 ids we can transcribe, in priority order
    public static func choose(
        osSupportsAnalyzer: Bool,
        analyzerHardwareAvailable: Bool,
        installedLocales: [String],
        desiredLocales: [String]
    ) -> VoiceEngineKind {
        guard osSupportsAnalyzer, analyzerHardwareAvailable else { return .legacy }
        let installed = Set(installedLocales.map(normalize))
        for locale in desiredLocales.map(normalize) where installed.contains(locale) {
            return .analyzer
        }
        return .legacy
    }

    /// BCP-47 ids are compared case-insensitively and treating `_` as `-`
    /// (e.g. `zh_Hans` vs `zh-Hans`) so a regional/formatting difference
    /// never wrongly rejects an installed model.
    private static func normalize(_ identifier: String) -> String {
        identifier.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}
