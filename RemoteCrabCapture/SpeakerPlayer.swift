//
//  SpeakerPlayer.swift
//
//  Plays the computer's audio out of the iPhone speaker — the receiving end
//  of kind 0x24.
//
//  This is the FIRST playback code in the iOS app: until now the only thing
//  that ever made sound was `BackgroundKeepAlive`, a deliberately silent
//  loop whose whole job was to hold an `AVAudioSession` open. So the shape
//  here is borrowed from that file on purpose — it is the one thing in this
//  app known to keep a session (and therefore the connection) alive with the
//  screen locked.
//
//  Payload is uncompressed 48 kHz stereo Int16 (see
//  `IBWire.encode(speakerAudio:)` for why this path is PCM and not Opus), so
//  there is no decoder here at all: the bytes go straight into the ring.
//
//  The one thing this has to get right is Jitter. Packets are 20 ms; the
//  network delivers them at 20 ms ± jitter, and a player that schedules
//  exactly what has arrived will click audibly on every late packet. So the
//  ring keeps a small cushion and schedules silence when it runs dry, which
//  keeps `isPlaying` true and avoids start/stop churn on the audio thread.
//

import AVFoundation
import Foundation
import RemoteCrabCore
import os.log

@MainActor
final class SpeakerPlayer {

    /// Packet length on the wire: 20 ms at 48 kHz.
    private static let framesPerPacket = 960
    private static let channels = 2
    static let sampleRate = 48_000.0

    /// How much audio to keep queued before starting to play, and the most
    /// we will ever hold. 3 packets ≈ 60 ms of cushion, which absorbs
    /// ordinary WiFi jitter without adding a latency a viewer would notice.
    private static let targetPackets = 3
    private static let maxPackets = 12

    private static let log = OSLog(subsystem: "com.remotecrab", category: "speaker-player")

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat
    private var isRunning = false

    /// Counters for the e2e run and the test window: a player that reports
    /// itself as playing while emitting nothing is worse than one that fails.
    private(set) var packetsEnqueued = 0
    private(set) var packetsScheduled = 0
    private(set) var silencePacketsScheduled = 0
    private(set) var starvedDrops = 0
    /// Signal energy of everything received, and the peak sample. Without
    /// these, "packets arrived" and "audible sound arrived" look identical —
    /// a run where the Mac's system output is digital silence passes every
    /// packet-count assertion while the user hears nothing.
    private(set) var receivedRms: Double = 0
    /// One character per packet: the level, mapped to 0-9. Drawn as a string
    /// it is the SHAPE of the audio that arrived — so a run that received a
    /// melody prints a waveform, and one that received a flat tone prints a
    /// straight line. An energy number alone cannot tell those apart, and
    /// "did the whole piece arrive, or a fragment" is the question that
    /// matters.
    nonisolated(unsafe) private var envelope: [Character] = []
    private static let envelopeLength = 240

    var envelopeText: String { String(envelope) }
    private(set) var receivedPeak: Int = 0
    private var energySum: Double = 0
    private var energyCount: Int = 0
    private var diagnosticPackets = 0

    /// **PLANAR**, and that is not a preference.
    ///
    /// This was declared `interleaved: true`, which is wrong twice over.
    /// `AVAudioPlayerNode` renders in the planar layout natively and converts
    /// from whatever it is handed, so an interleaved format bought nothing and
    /// cost measurable latency — the device sat at `queued=9` (≈200 ms) with
    /// `starved` still climbing. And it invited the bug this file's tests now
    /// pin: on an interleaved buffer `int16ChannelData[0]` and
    /// `int16ChannelData[1]` are 2 bytes apart, so the natural-looking
    /// `planes[ch][frame]` write has each right-channel sample overwritten by
    /// the next left-channel one — one channel at double speed, the other
    /// gone. `SpeakerPCMWriter` handles either layout, so nothing here has to
    /// remember which is which.
    init() {
        format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                               sampleRate: Self.sampleRate,
                               channels: AVAudioChannelCount(Self.channels),
                               interleaved: false)
            ?? AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate,
                             channels: AVAudioChannelCount(Self.channels))!
    }

    var running: Bool { isRunning }

    /// Packets handed to the player and not yet played, for the diagnostics
    /// that assert the queue stays shallow. A large value is audible latency
    /// and it is the first thing to look at when the stream sounds fragmented
    /// or will not stop.
    var queuedPackets: Int { pendingPlayback }
    private var bufferedFrames: Int { writeFrame - readFrame }

    // MARK: - Session

    /// Claim `.playback`. Deliberately the SAME category and options the
    /// keep-alive uses: it is the only playback claim in this app, it is
    /// known to survive backgrounding with the screen locked, and it mixes
    /// rather than interrupting so turning the speaker on does not stop the
    /// music the user was already listening to on their phone.
    ///
    /// The caller must already have stood the microphone down: `.record` and
    /// `.playback` cannot both be active, and `BackgroundKeepAlive.stop()`
    /// has to run first or its own `.playback` session makes this one fail
    /// with '!pri' (see `CaptureEngine.syncMicrophone`).
    func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        // An active session suppresses ALL app haptics unless this is set —
        // the bug behind lesson 56, where the trackpad stopped vibrating.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        try activateSession()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()

        resetRing()
        lastVerifiedPair = nil
        packetsEnqueued = 0
        packetsScheduled = 0
        silencePacketsScheduled = 0
        starvedDrops = 0
        receivedRms = 0
        receivedPeak = 0
        energySum = 0
        energyCount = 0
        envelope.removeAll()
        isRunning = true
        os_log("speaker player started", Self.log)
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        ring = []
        writeFrame = 0
        readFrame = 0
        // `player.stop()` drops everything already queued, so the completion
        // callbacks for those buffers will never run — leaving this non-zero
        // would make the next session think its queue was already full and
        // refuse to schedule anything.
        pendingPlayback = 0
        isRunning = false
        // Hand the session back rather than deactivating it: the keep-alive
        // may already want it, and a deactivate/reactivate in the same turn
        // makes the next `setActive` fail (BackgroundKeepAlive's warning).
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        os_log("speaker player stopped", Self.log)
    }

    // MARK: - Data in

    /// Frames the ring can hold. Fixed so the index arithmetic below is a
    /// plain modulo instead of depending on `ring.count` (which grows in
    /// chunks and would silently shift every sample).
    private let capacityFrames = SpeakerPlayer.maxPackets * SpeakerPlayer.framesPerPacket
    private var ring: [Int16] = []
    private var writeFrame = 0
    private var readFrame = 0

    private func resetRing() {
        ring = [Int16](repeating: 0, count: capacityFrames * SpeakerPlayer.channels)
        writeFrame = 0
        readFrame = 0
    }

    /// Accept one 20 ms stereo Int16 packet.
    func enqueue(_ pcm: Data) {
        guard isRunning else { return }
        let needed = SpeakerPlayer.framesPerPacket * SpeakerPlayer.channels * 2
        guard pcm.count >= needed else { return }
        // Measure what ARRIVED, not just how much. A packet count cannot tell
        // "sound arrived" from "3840 bytes of silence arrived", and the
        // difference is the whole feature: the user either hears the
        // computer or they do not.
        var sum = 0.0
        var count = 0
        var peak = 0
        pcm.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Int16.self)
            append(source)
            for v in source {
                sum += Double(v) * Double(v)
                count += 1
                let a = abs(Int(v))
                if a > peak { peak = a }
            }
        }
        // The first packets in full. Every counter between here and the
        // speaker has already said "fine", so when it comes out silent these
        // are the only numbers that locate it.
        if diagnosticPackets < 2 {
            diagnosticPackets += 1
            var head: [Int] = []
            pcm.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: Int16.self)
                for i in 0..<min(6, b.count) { head.append(Int(b[i])) }
            }
            Forensic.log("[speaker-diag] bytes=\(pcm.count) head=\(head) sumsq=\(Int(sum)) n=\(count)")
        }

        energySum += sum
        energyCount += count
        if peak > receivedPeak { receivedPeak = peak }
        receivedRms = energyCount > 0 ? (energySum / Double(energyCount)).squareRoot() : 0
        // Log scale, and NORMALISED FIRST: `receivedRms` is in Int16 units,
        // so 20*log10(1958) is +66 dB and every audible packet saturates the
        // digit at 9 — which reads as a flat line, i.e. exactly the "tone or
        // fragment" verdict the envelope exists to catch. Divide by full
        // scale before taking the log, then span -60..0 dBFS.
        let db = 20 * log10(max(receivedRms / 32_768.0, 1e-6))
        let digit = max(0, min(9, Int((db + 60) / 6)))
        envelope.append(Character(String(digit)))
        if envelope.count > Self.envelopeLength { envelope.removeFirst() }
        packetsEnqueued += 1
        pumpOnArrival()
    }

    private func append(_ source: UnsafeBufferPointer<Int16>) {
        var i = 0
        while i + 1 < source.count {
            let frame = Int(writeFrame % capacityFrames)
            ring[frame * SpeakerPlayer.channels] = source[i]
            ring[frame * SpeakerPlayer.channels + 1] = source[i + 1]
            writeFrame += 1
            i += 2
        }
        // Drop the oldest audio if playback fell behind: for live audio a
        // stale buffer is worse than a hole, and a hole is what silence is
        // for.
        if bufferedFrames > capacityFrames {
            let excess = bufferedFrames - capacityFrames
            readFrame += excess
            starvedDrops += excess / SpeakerPlayer.framesPerPacket
        }
    }

    /// How many packets have been handed to the player and not yet played.
    ///
    /// This is the number that was missing, and it is why the stream sounded
    /// broken. `drain` played real audio as fast as it arrived, and `tick`
    /// added a silent packet on every 20 ms fire *regardless*, so the player
    /// was handed twice the audio it could consume and the queue grew by
    /// ~50 packets — one second of latency — every second. The audio the user
    /// heard was real samples interleaved with filler and increasingly stale,
    /// and it kept playing after the feature was switched off because there
    /// was a backlog of it.
    ///
    /// Written from both the caller (MainActor) and the player's completion
    /// callback (an audio queue), hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private var pendingPlayback = 0

    /// The single scheduling decision, shared by the timer and the ingest path
    /// so they can never disagree.
    ///
    /// `SpeakerSchedule` holds the rule and its reasons; this is only the
    /// plumbing.
    private func pump(_ decision: SpeakerSchedule) {
        switch decision {
        case .playAudio:
            schedule(silence: false)
        case .scheduleSilence:
            schedule(silence: true)
        case .wait:
            break
        }
    }

    /// Arrival is what feeds real audio — see `SpeakerSchedule.onPacket` for
    /// why this cannot hang off a timer. Called on every packet received.
    private func pumpOnArrival() {
        guard isRunning else { return }
        pump(SpeakerSchedule.onPacket(bufferedFrames: bufferedFrames,
                                      pendingPlayback: pendingPlayback,
                                      framesPerPacket: SpeakerPlayer.framesPerPacket,
                                      targetPackets: SpeakerPlayer.targetPackets))
    }

    private func schedule(silence: Bool) {
        guard !ring.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(SpeakerPlayer.framesPerPacket))
        else { return }
        buffer.frameLength = AVAudioFrameCount(SpeakerPlayer.framesPerPacket)

        let frameCount = SpeakerPlayer.framesPerPacket
        // The format is INTERLEAVED (see `init`), so `int16ChannelData[ch][f]`
        // is the planar idiom and the two channel pointers sit 2 bytes apart:
        // writing L and R through them overwrites one with the other. That
        // was the sharp, thin, noisy sound — one channel at double speed and
        // the other gone. `SpeakerPCMWriter` is layout-correct; this is the
        // only place samples reach the player.
        let interleaved = format.isInterleaved

        if silence || bufferedFrames < frameCount {
            SpeakerPCMWriter.silence(buffer, frames: frameCount, interleaved: interleaved)
            silencePacketsScheduled += 1
        } else {
            let available = min(bufferedFrames, frameCount)
            var left = [Int16](repeating: 0, count: frameCount)
            var right = [Int16](repeating: 0, count: frameCount)
            for frame in 0..<available {
                let ringFrame = Int((readFrame + frame) % capacityFrames)
                left[frame] = ring[ringFrame * SpeakerPlayer.channels]
                right[frame] = ring[ringFrame * SpeakerPlayer.channels + 1]
            }
            SpeakerPCMWriter.fill(buffer, frames: frameCount,
                                  interleaved: interleaved,
                                  left: left, right: right)
            // Read the first frame back out of the buffer we just filled. This
            // is the check the receive-side energy counter cannot make: it
            // proves the two channels landed in two places, in the layout the
            // engine actually gave us, rather than one overwriting the other.
            if let planes = buffer.int16ChannelData, available > 0 {
                lastVerifiedPair = interleaved
                    ? (planes[0][0], planes[0][1])
                    : (planes[0][0], planes[1][0])
            }
            if available < frameCount { starvedDrops += 1 }
            readFrame += available
            packetsScheduled += 1
        }

        // NO options: `.interrupts` stops the player when the buffer ends,
        // which would make every 20 ms buffer cut the sound off. The loop is
        // driven by re-scheduling, not by `.loops`.
        //
        // The completion callback is the ONLY way to learn the queue actually
        // drained, and it is what keeps `pendingPlayback` honest. Without it
        // the count could only ever grow, and the scheduling decision would
        // have no way to tell "the player is backed up" from "nothing has
        // been scheduled yet".
        pendingPlayback += 1
        player.scheduleBuffer(buffer, at: nil) { [weak self] in
            // Runs on an audio-adjacent queue: touch the counter and nothing
            // else.
            self?.pendingPlayback -= 1
        }
    }

    /// Keeps the audio graph alive, and nothing else.
    ///
    /// It used to schedule real audio as well, which is the mistake this file
    /// exists to correct — and it failed in both directions. Scheduling
    /// unconditionally put a silent packet in on top of real audio, so filler
    /// ran at the full packet rate and the queue grew a second of latency per
    /// second. Then, once that was fixed, scheduling audio *only* here could
    /// not keep up at all: `Task.sleep(20 ms)` measured ~30 ms on the device,
    /// so playback ran at 33 packets/s against 46 arriving, and the ring
    /// overflowed (`starved` climbing, `played` falling further behind every
    /// sample).
    ///
    /// Real audio is now scheduled by arrival (`pumpOnArrival`); the timer's
    /// sole remaining job is the one it cannot delegate, because
    /// `AVAudioPlayerNode.isPlaying` has to stay true or the system reclaims
    /// the audio session. It must never run while audio is waiting.
    func tick() {
        guard isRunning, !ring.isEmpty else { return }
        pump(SpeakerSchedule.onTick(bufferedFrames: bufferedFrames,
                                    pendingPlayback: pendingPlayback,
                                    framesPerPacket: SpeakerPlayer.framesPerPacket))
    }

    /// What the last packet put into the buffer, read back from the buffer.
    ///
    /// The receive-side `receivedRms` cannot see this class of bug: the
    /// packets arriving from the Mac are correct interleaved stereo and the
    /// corruption happened on the way into the audio buffer.
    ///
    /// Reading it back is enough, and it is done on the calling (main) thread
    /// rather than through an `installTap` — a tap on the audio thread crashed
    /// the app with SIGTRAP here, and a diagnostic that can take the feature
    /// down has no business existing for a temporary measurement.
    private var lastWrittenL: Int16 = 0
    private var lastWrittenR: Int16 = 0
    private var lastVerifiedPair: (Int16, Int16)?

    /// A one-line, human-readable verdict on the channel layout actually used.
    var playbackQualityText: String {
        guard let pair = lastVerifiedPair else { return "outL=0 outR=0 skew=0.000 NOT-YET-WRITTEN" }
        // A real source differs between channels; identical channels mean the
        // "left at double speed, right discarded" shape, whatever the level.
        let identical = pair.0 == pair.1 ? "MONO-OR-SCRAMBLED" : "STEREO-OK"
        return "outL=\(Int(pair.0)) outR=\(Int(pair.1)) \(identical)"
    }

    /// Play a short two-tone confirmation through the phone's speaker.
    ///
    /// This exists because the most common way for this feature to look
    /// broken is the phone being on silent or at zero volume: the toggle
    /// says "on", the Mac has stopped playing through its own speakers
    /// (`muteWhileTapped`), and the user hears NOTHING and concludes the
    /// feature is dead. A confirmation tone both proves the path works and
    /// nudges the volume up — the same reasoning as the volume-step sound
    /// elsewhere in the system.
    func playConfirmationTone() {
        guard isRunning,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(Self.toneFrames)),
              let dst = buffer.int16ChannelData else { return }
        let total = Self.toneFrames
        buffer.frameLength = AVAudioFrameCount(total)

        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<total {
                // A rising two-tone chirp, short enough not to be intrusive
                // and loud enough to hear over a room.
                let t = Double(frame) / Self.sampleRate
                let firstHalf = frame < total / 2
                let frequency = firstHalf ? 880.0 : 1320.0
                let localT = firstHalf ? t : t - (Double(total / 2) / Self.sampleRate)
                let envelope = min(1.0, localT / 0.01) * min(1.0, (0.08 - localT) / 0.03)
                let value = Double(Int16.max) * 0.35 * envelope
                dst[channel][frame] = Int16(max(-32_768, min(32_767, value * sin(2 * .pi * frequency * t))))
            }
        }
        // Inserted rather than appended: the confirmation should be heard
        // now, not after whatever the Mac has already sent.
        player.scheduleBuffer(buffer, at: nil) { }
    }

    /// 180 ms: two 90 ms tones.
    private static let toneFrames = 8_640
}