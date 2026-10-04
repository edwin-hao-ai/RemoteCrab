import Foundation

/// What the phone's speaker playback should do next, given what it has
/// buffered and how much is already queued in the audio player.
///
/// This exists because the decision was previously implicit in two functions
/// that were both "correct" in isolation:
///
/// * the drain played real audio once the start-up cushion had built
///   (`bufferedFrames >= framesPerPacket * targetPackets`), and
/// * a 20 ms timer **unconditionally** scheduled a silent packet, because
///   `AVAudioPlayerNode.isPlaying` has to stay true or the system reclaims
///   the audio session.
///
/// Neither was wrong on its own, but together they produced **twice** the
/// audio a player can consume: 50 real packets a second plus 50 silent ones,
/// while the player only drains 50 a second. The queue therefore grew without
/// bound — about 50 packets, or one second of latency, every second — which
/// is what made the stream sound chopped and garbled and kept sounding after
/// it was switched off.
///
/// So the invariant is not "keep the graph fed" and not "play the audio"; it
/// is **never schedule silent audio while real audio is waiting to play**.
public enum SpeakerSchedule: Equatable {
    /// Play real audio from the ring.
    case playAudio
    /// Schedule one silent packet to keep the graph alive.
    case scheduleSilence
    /// Nothing to do — there is already audio queued and it must play first.
    case wait

    /// Decides on **arrival of a packet** — the only thing that feeds real
    /// audio.
    ///
    /// Scheduling audio from a timer is the mistake this whole file exists to
    /// correct, and it fails in two separate ways. A timer that fires on
    /// *every* tick doubles the production rate (50 real + 50 silent into a
    /// player that drains 50) and the queue grows forever. A timer that fires
    /// *instead of* on arrival cannot keep up at all: `Task.sleep(20 ms)` on a
    /// loaded device measured ~30 ms, so playback ran at 33 packets/s while
    /// the Mac sent 46, and the ring overflowed (`starved` climbing, `played`
    /// falling further behind `enqueued` every sample).
    ///
    /// So real audio is scheduled by the arrival of real audio, and the
    /// condition is "the ring holds enough to cover what is already queued
    /// plus the start-up cushion". That makes the player's queue depth a
    /// *feedback* term rather than a guess: the deeper the queue, the more
    /// audio has to arrive before another packet is added, so the two rates
    /// cannot drift apart no matter how badly the timer drifts.
    public static func onPacket(bufferedFrames: Int,
                                pendingPlayback: Int,
                                framesPerPacket: Int,
                                targetPackets: Int) -> SpeakerSchedule {
        // Enough buffered to refill the queue to `targetPackets` deep. On a
        // steady stream this fires once per arriving packet, which is exactly
        // the rate the player consumes, so `pendingPlayback` holds steady
        // instead of climbing into latency.
        if bufferedFrames >= framesPerPacket * (pendingPlayback + targetPackets) {
            return .playAudio
        }
        return .wait
    }

    /// Decides on the **20 ms timer**, which now has exactly one job: keeping
    /// the audio graph alive.
    ///
    /// `AVAudioPlayerNode.isPlaying` has to stay true or the system reclaims
    /// the audio session — that requirement is real and is why this exists at
    /// all. But it must not fire while audio is waiting, or it interleaves
    /// filler with real audio (the original "garbled and shrill"), and it must
    /// not fire into a deep queue, or it cannot be turned off promptly.
    public static func onTick(bufferedFrames: Int,
                              pendingPlayback: Int,
                              framesPerPacket: Int) -> SpeakerSchedule {
        // Only when the ring is empty AND the player is about to run dry.
        if bufferedFrames < framesPerPacket && pendingPlayback <= 1 {
            return .scheduleSilence
        }
        return .wait
    }
}