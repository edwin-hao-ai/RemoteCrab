import Foundation
import os

/// Writes the iPhone's microphone PCM into the POSIX shared-memory ring
/// that `iBridgeMicrophone.driver` (running inside coreaudiod) reads.
/// Thin wrapper over the C ring in `iBridgeMicDriver/` (Swift can't call
/// the variadic `shm_open` directly).
///
/// No-op (nil) if the ring can't be opened — the driver then sees
/// silence, and every other iBridge feature keeps working.
final class MicRingWriter {
    private static let log = Logger(subsystem: "com.ibridge", category: "micring")

    private let ring: UnsafeMutableRawPointer?

    init?() {
        guard let ring = IBMicRingOpen() else {
            Self.log.error("mic ring unavailable (shm_open failed)")
            return nil
        }
        self.ring = ring
    }

    /// Append mono Int16 frames; overwrites the oldest once full.
    func write(_ pcm: Data) {
        guard let ring else { return }
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0 else { return }
        pcm.withUnsafeBytes { raw in
            IBMicRingWrite(ring, raw.bindMemory(to: Int16.self).baseAddress, Int64(frames))
        }
    }
}
