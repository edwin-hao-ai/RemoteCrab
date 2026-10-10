import Foundation

/// Pure ring-buffer arithmetic for the speaker path, kept out of the realtime
/// callback so it can be reasoned about (and tested) without CoreAudio.
public enum SpeakerRing {

    /// Frames the producer must drop because it lapped the consumer.
    ///
    /// `writeIndex` (producer) and `readIndex` (consumer) are **monotonic**
    /// UInt64 counters, not wrapped indices — the ring index is `% capacity`
    /// at the point of use. `available = writeIndex - readIndex` is therefore
    /// only meaningful while `readIndex <= writeIndex`; the consumer can
    /// briefly read a stale value and appear ahead, and the subtraction then
    /// wraps to a value near `UInt64.max`.
    ///
    /// That wrapped value used to flow straight into `pendingDrops += dropped`
    /// — a **non-wrapping** add on CoreAudio's IO thread — which trapped with
    /// "arithmetic overflow" and killed the entire receiver (SIGTRAP, measured
    /// 2026-10-11). A wrapped difference must yield **0**, never a huge drop.
    public static func dropCount(writeIndex: UInt64, readIndex: UInt64, capacity: UInt64) -> UInt64 {
        guard writeIndex >= readIndex else { return 0 }
        let available = writeIndex - readIndex
        return available > capacity ? available - capacity : 0
    }
}
