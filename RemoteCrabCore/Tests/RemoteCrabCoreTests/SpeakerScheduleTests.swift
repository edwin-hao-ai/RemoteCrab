import XCTest
@testable import RemoteCrabCore

final class SpeakerScheduleTests: XCTestCase {

    private let framesPerPacket = 960
    private let targetPackets = 3
    /// 60 ms of real audio in the ring.
    private let fullCushion = 960 * 3
    private let onePacket = 960

    private func decide(_ buffered: Int, _ pending: Int) -> SpeakerSchedule {
        SpeakerSchedule.decide(bufferedFrames: buffered,
                                pendingPlayback: pending,
                                framesPerPacket: framesPerPacket,
                                targetPackets: targetPackets)
    }

    /// The regression this whole thing exists for: a 20 ms timer scheduled a
    /// silent packet unconditionally, so silence was added at the full packet
    /// rate **on top of** real audio. Production ran at 100 packets/s into a
    /// player that drains 50, the queue grew by 50 packets a second, and the
    /// user heard fragmented, garbled audio that kept playing after the
    /// feature was switched off.
    ///
    /// The invariant: while real audio is waiting, silence must never be
    /// scheduled — not even once, not even when the graph wants feeding.
    func testNeverSchedulesSilenceWhileRealAudioIsWaiting() {
        // Every combination of "the ring has audio" x "the queue is deep",
        // which is exactly the space the old timer ignored.
        for buffered in [onePacket, fullCushion, fullCushion * 4] {
            for pending in [0, 1, 2, 5, 50, 1000] {
                let decision = decide(buffered, pending)
                XCTAssertNotEqual(decision, .scheduleSilence,
                                  "buffered=\(buffered) pending=\(pending): scheduled silence on top of real audio")
            }
        }
    }

/// Simulates a real session against the real consumer: 50 packets a
    /// second of genuine audio arriving, and a player that drains exactly 50 a
    /// second (20 ms of audio per 20 ms of wall clock).
    ///
    /// The assertion that matters is `peakPending`. The old code scheduled a
    /// silent packet on every timer tick *and* a real packet as the ring
    /// allowed, so it produced 100 packets a second into a 50/s player and the
    /// backlog grew by ~50 packets — one second of latency — every second.
    /// That backlog is the whole symptom: the audio the user hears is
    /// interleaved with filler and increasingly stale, and it keeps playing
    /// long after the feature is switched off because there is so much of it.
    func testARealStreamKeepsThePlaybackQueueAtAConstantLowDepth() {
        var buffered = 0
        var pending = 0
        var peakPending = 0
        var silenceScheduled = 0
        var audioScheduled = 0

        // 10 seconds: 500 ticks, each one a 20 ms timer fire.
        for _ in 0..<500 {
            buffered += onePacket                   // one packet arrives
            pending = max(0, pending - 1)           // the player drains one
            switch decide(buffered, pending) {
            case .playAudio:
                audioScheduled += 1
                buffered -= onePacket
                pending += 1
            case .scheduleSilence:
                silenceScheduled += 1
                pending += 1
            case .wait:
                break
            }
            peakPending = max(peakPending, pending)
        }

        XCTAssertGreaterThan(audioScheduled, 400, "the stream should have played continuously")
        XCTAssertEqual(silenceScheduled, 0,
                       "with audio arriving continuously, not one silent packet should be scheduled")
        // A couple of buffers is the start-up cushion. Anything beyond that
        // is latency the user can hear.
        XCTAssertLessThanOrEqual(peakPending, 3,
                                 "playback queue reached \(peakPending) packets — that is the audible backlog")
    }

    /// The direct statement of "it will not turn off": with nothing left to
    /// play, the queue must drain instead of being kept full.
    func testAnIdleStreamDoesNotRearmThePlaybackQueue() {
        // The Mac goes quiet: packets stop arriving.
        var pending = 0
        var buffered = 0
        for _ in 0..<50 {                            // 1 s of silence from the Mac
            pending = max(0, pending - 1)
            switch decide(buffered, pending) {
            case .playAudio:
                pending += 1
            case .scheduleSilence:
                pending += 1
            case .wait:
                break
            }
        }
        // One buffer may legitimately be held to keep the session alive, but
        // it must not be topped up every tick.
        XCTAssertLessThanOrEqual(pending, 2,
                                 "queue kept \(pending) packets busy while the Mac sent nothing")
    }

    /// The queue must be allowed to drain rather than being fed. This is what
    /// turns "will not turn off" into "turns off immediately": with the old
    /// behaviour the backlog kept playing long after the feature was stopped.
    func testADeepQueueIsLeftAloneSoItCanDrain() {
        XCTAssertEqual(decide(fullCushion, 40), .wait)
        XCTAssertEqual(decide(fullCushion * 4, 400), .wait)
    }

    /// The graph still has to be kept alive while the Mac is quiet, or
    /// `isPlaying` goes false and the system reclaims the audio session —
    /// which the original fix was written to prevent.
    func testSilenceStillFlowsWhenThereIsNothingToPlay() {
        XCTAssertEqual(decide(0, 0), .scheduleSilence)
        XCTAssertEqual(decide(onePacket / 2, 0), .scheduleSilence)
    }

    /// But only until there is a packet's worth queued: a deep queue plus an
    /// empty ring is the start of the next session, not a reason to keep
    /// feeding silence.
    func testSilenceStopsOnceOnePacketIsQueued() {
        XCTAssertEqual(decide(0, 2), .wait)
    }

    /// Real audio wins over the graph-feeder even when the graph is bare.
    func testAudioWinsOverSilenceWhenBothWantToRun() {
        // Ring is full and nothing is queued: the audio must go first.
        XCTAssertEqual(decide(fullCushion, 0), .playAudio)
    }
}