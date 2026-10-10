import Foundation

/// Pure PCM helpers shared by the speaker paths on both ends.
public enum SpeakerSample {

    /// Convert a normalized Float sample to Int16, saturating and **never
    /// trapping**.
    ///
    /// A non-finite sample must not reach `Int16(_:)`: that conversion traps,
    /// and in the Mac's realtime system-audio tap the trap runs on CoreAudio's
    /// IO thread, so the whole receiver dies with SIGTRAP and no recovery —
    /// measured crash 2026-10-11 (`SystemAudioTap.ingest` →
    /// "arithmetic overflow" on the IOWorkLoop). Silence a NaN; saturate ±∞.
    @inline(__always)
    public static func clampToInt16(_ value: Float) -> Int16 {
        if value.isNaN { return 0 }
        if value >= 1 { return Int16.max }
        if value <= -1 { return Int16.min }
        return Int16(value * 32_767)
    }
}
