import XCTest
@testable import RemoteCrabCore

final class SpeakerScheduleTests: XCTestCase {

    private let framesPerPacket = 960
    private let targetPackets = 3
    private let onePacket = 960
    /// 60 ms of real audio in the ring.
    private let fullCushion = 960 * 3

    private func onPacket(_ buffered: Int, _ pending: Int) -> SpeakerSchedule {
        SpeakerSchedule.onPacket(bufferedFrames: buffered,
                                 pendingPlayback: pending,
                                 framesPerPacket: framesPerPacket,
                                 targetPackets: targetPackets)
    }

    private func onTick(_ buffered: Int, _ pending: Int) -> SpeakerSchedule {
        SpeakerSchedule.onTick(bufferedFrames: buffered,
                               pendingPlayback: pending,
                               framesPerPacket: framesPerPacket)
    }

    // MARK: - The regression this exists for

    /// `tick` scheduled a silent packet unconditionally, so filler was added
    /// at the full packet rate **on top of** real audio: 50 real + 50 silent a
    /// second into a player that drains 50. The queue grew ~50 packets — one
    /// second of latency — every second, and the user heard fragmented,
    /// garbled audio that kept playing after the feature was switched off.
    /// Measured on the device before the fix: `silence=916` against
    /// `enqueued=1011`.
    ///
    /// The invariant: while real audio is waiting, the timer must never
    /// schedule silence — not once, not even to "keep the graph fed".
    func testTheTimerNeverSchedulesSilenceWhileRealAudioIsWaiting() {
        for buffered in [onePacket, fullCushion, fullCushion * 4] {
            for pending in [0, 1, 2, 5, 50, 1000] {
                XCTAssertNotEqual(onTick(buffered, pending), .scheduleSilence,
                                  "buffered=\(buffered) pending=\(pending): filler on top of real audio")
            }
        }
    }

    /// The counter-schedule: real audio is scheduled by arrival, never by the
    /// clock. If a timer fed audio, a drifted timer would either double the
    /// rate or starve — both measured on this device, 400 ms of latency and a
    /// ring that overflowed.
    func testTheTimerNeverSchedulesRealAudio() {
        for buffered in [0, onePacket, fullCushion, fullCushion * 8] {
            for pending in [0, 1, 3, 40] {
                XCTAssertNotEqual(onTick(buffered, pending), .playAudio,
                                  "buffered=\(buffered) pending=\(pending): the clock scheduled audio")
            }
        }
    }

    // MARK: - Arrival-driven playback

    /// Audio starts only once the start-up cushion is present, so the player
    /// never begins mid-word.
    func testPlaybackWaitsForTheStartUpCushion() {
        XCTAssertEqual(onPacket(onePacket, 0), .wait)
        XCTAssertEqual(onPacket(fullCushion - 1, 0), .wait)
        XCTAssertEqual(onPacket(fullCushion, 0), .playAudio)
    }

    /// The queue depth is a feedback term: the deeper the player's queue, the
    /// more audio must arrive before another packet goes in. This is what
    /// keeps the two rates locked together instead of relying on a timer.
    func testADeepQueueDemandsMoreAudioBeforeTheNextPacket() {
        // Threshold is always (queued + cushion) packets, so it rises 1:1 with
        // the queue depth. Written in packets to keep that visible.
        func packets(_ n: Int) -> Int { n * framesPerPacket }

        XCTAssertEqual(onPacket(packets(3) - 1, 0), .wait)
        XCTAssertEqual(onPacket(packets(3), 0), .playAudio)

        // 3 queued needs 6 packets buffered.
        XCTAssertEqual(onPacket(packets(6), 3), .playAudio)
        XCTAssertEqual(onPacket(packets(6) - 1, 3), .wait)

        // 7 queued needs 10.
        XCTAssertEqual(onPacket(packets(10), 7), .playAudio)
        XCTAssertEqual(onPacket(packets(10) - 1, 7), .wait)
    }

    /// The invariant as a simulation: a steady real stream must keep both the
    /// queue depth and the ring bounded, and must not discard audio — at any
    /// arrival rate, including one the 20 ms timer could not have matched.
    func testARealStreamKeepsQueueAndRingBoundedAtAnyArrivalRate() {
        for arrivalEveryNTicks in [1, 2, 3] {
            var buffered = 0
            var pending = 0
            var peakPending = 0
            var peakRing = 0
            var silenceScheduled = 0
            var discarded = 0
            var played = 0

            // 20 s at 50 ticks/s.
            for tick in 0..<1000 {
                if tick % arrivalEveryNTicks == 0 { buffered += onePacket }   // arrival
                pending = max(0, pending - 1)                                  // player drains
                switch onPacket(buffered, pending) {
                case .playAudio:
                    buffered -= onePacket; pending += 1; played += 1
                case .scheduleSilence, .wait:
                    break
                }
                switch onTick(buffered, pending) {
                case .scheduleSilence:
                    silenceScheduled += 1; pending += 1
                case .playAudio, .wait:
                    break
                }
                if buffered > fullCushion * 4 {                               // ring overflow
                    discarded += 1
                    buffered = fullCushion * 4
                }
                peakPending = max(peakPending, pending)
                peakRing = max(peakRing, buffered / onePacket)
            }

            let label = "arrival every \(arrivalEveryNTicks) tick(s)"
            XCTAssertGreaterThan(played, 200, "\(label): nothing played")
            XCTAssertEqual(discarded, 0, "\(label): \(discarded) packets discarded — playback cannot keep up")
            XCTAssertLessThanOrEqual(peakPending, 4,
                                     "\(label): queue reached \(peakPending) packets of latency")
            XCTAssertLessThanOrEqual(peakRing, 8,
                                     "\(label): ring reached \(peakRing) packets")
            XCTAssertEqual(silenceScheduled, 0,
                           "\(label): scheduled \(silenceScheduled) filler packets over a real stream")
        }
    }

    /// When the Mac goes quiet the queue must drain, not be kept full. This
    /// is what "will not turn off" looked like: a backlog playing out long
    /// after the toggle.
    func testAnIdleStreamDoesNotRearmThePlaybackQueue() {
        var pending = 3
        var scheduledSilence = 0
        for _ in 0..<100 {
            pending = max(0, pending - 1)
            if onTick(0, pending) == .scheduleSilence { scheduledSilence += 1; pending += 1 }
        }
        XCTAssertLessThanOrEqual(pending, 2, "queue held \(pending) packets while the Mac sent nothing")
        XCTAssertLessThan(scheduledSilence, 100,
                          "silence should stop once one packet is held, not be topped up every tick")
    }

    // MARK: - Keeping the graph alive

    /// The reason the timer exists at all: `isPlaying` must stay true or the
    /// system reclaims the audio session. So silence still has to flow when
    /// there is genuinely nothing to play.
    func testSilenceStillFlowsWhenThereIsNothingToPlay() {
        XCTAssertEqual(onTick(0, 0), .scheduleSilence)
        XCTAssertEqual(onTick(onePacket - 1, 0), .scheduleSilence)
        // ... but only until one buffer is held.
        XCTAssertEqual(onTick(0, 1), .scheduleSilence)
        XCTAssertEqual(onTick(0, 2), .wait)
    }
}