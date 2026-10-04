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

    public static func decide(bufferedFrames: Int,
                              pendingPlayback: Int,
                              framesPerPacket: Int,
                              targetPackets: Int) -> SpeakerSchedule {
        // Enough buffered for playback to start, and the queue is not already
        // deep: real audio always wins.
        if bufferedFrames >= framesPerPacket * targetPackets && pendingPlayback < 2 {
            return .playAudio
        }
        // Only silence the graph when it is genuinely about to go dry. `1`
        // rather than `0` so a still-running player always has one buffer.
        if pendingPlayback <= 1 && bufferedFrames < framesPerPacket {
            return .scheduleSilence
        }
        // Anything else — most importantly, a deep queue — must not add more
        // work. This is the case that produced the runaway backlog.
        return .wait
    }
}