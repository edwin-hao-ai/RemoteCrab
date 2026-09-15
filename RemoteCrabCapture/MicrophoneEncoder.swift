import AVFoundation
import Foundation
import RemoteCrabCore
import os

/// Captures audio from the iPhone microphone and ships Opus frames over
/// the wire. Each `AudioPacket` carries one ~20 ms frame.
///
/// The mic PCM is encoded with `IBOpusEncoder` (Apple's AudioConverter
/// Opus codec) at 48 kHz mono, cutting wire bandwidth from ~1 Mbps of
/// base64 PCM to ~35 kbps. If the host lacks an Opus encoder (or it
/// fails persistently) we fall back to raw Int16 PCM with
/// `codec == "pcm"` — a silent mic is worse than a fat one. Input that
/// isn't 48 kHz is resampled first, because Opus internally always runs
/// at 48 kHz and Apple's 16 kHz path is known-flaky.
final class MicrophoneEncoder: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.remotecrab", category: "MicrophoneEncoder")

    private let engine = AVAudioEngine()
    private var broadcaster: IBEventBroadcaster?
    private var isRunning = false
    private var sampleRate: Double = 48_000

    func start(broadcaster: IBEventBroadcaster) {
        guard !isRunning else { return }
        self.broadcaster = broadcaster

        // AVAudioEngine's input node only delivers real samples once the
        // shared session is in a record-capable category and active —
        // without this the tap sees silence (or the engine fails).
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            Self.log.error("audio session setup failed: \(error, privacy: .public)")
            Forensic.log("[e2e] mic session setup FAILED: \(error)")
            return
        }

        isRunning = true

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        sampleRate = inputFormat.sampleRate
        Self.log.info("mic input format: \(inputFormat.sampleRate) Hz x \(inputFormat.channelCount) ch")
        Forensic.log("[e2e] mic format: \(inputFormat.sampleRate) Hz x \(inputFormat.channelCount) ch")

        opusEncoder = IBOpusEncoder(sampleRate: 48_000, bitrate: 24_000)
        if opusEncoder == nil {
            Self.log.error("opus encoder unavailable — mic falls back to raw PCM")
            Forensic.log("[e2e] opus encoder unavailable, PCM fallback")
        } else {
            Self.log.info("opus encoder ready (48 kHz mono, 24 kbps)")
            Forensic.log("[e2e] opus encoder ready")
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isRunning, let broadcaster = self.broadcaster else { return }
            if self.packetCount == 0 && self.pcmAccumulator.isEmpty {
                Forensic.log("[e2e] mic tap first buffer: \(buffer.frameLength) frames, int16=\(buffer.int16ChannelData != nil)")
            }
            self.handlePCM(buffer: buffer, broadcaster: broadcaster)
        }

        do {
            try engine.start()
            Self.log.info("mic engine started")
            Forensic.log("[e2e] mic engine started OK")
        } catch {
            Self.log.error("mic start failed: \(error, privacy: .public)")
            Forensic.log("[e2e] mic engine start FAILED: \(error)")
            stop()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - PCM framing

    private var pcmAccumulator = Data()
    private let frameBytes = 960 * 2          // 20 ms @ 48 kHz mono 16-bit
    private var frameMicros: UInt64 = 0
    private var packetCount = 0
    private var opusEncoder: IBOpusEncoder?
    /// Consecutive empty/failed encodes. A few are normal (the codec
    /// holds priming frames on startup); a persistent streak means the
    /// encoder is broken and we drop to PCM for the rest of the run.
    private var opusFailureCount = 0
    /// Native-rate Int16 PCM → 48 kHz, created lazily on first buffer
    /// when the mic delivers something other than 48 kHz.
    private var resampler: AVAudioConverter?
    private var resamplerInputFormat: AVAudioFormat?

    private func handlePCM(buffer: AVAudioPCMBuffer, broadcaster: IBEventBroadcaster) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // The iPhone input node delivers Float32 non-interleaved, so
        // `int16ChannelData` is nil on real hardware. Convert to mono
        // Int16 (mixing channels down) in that case.
        var nativePCM = Data()
        var outChannels = Int(buffer.format.channelCount)
        if let int16 = buffer.int16ChannelData {
            let frames = UnsafeBufferPointer(start: int16[0], count: frameCount * outChannels)
            nativePCM.append(contentsOf: UnsafeRawBufferPointer(frames))
        } else if let floats = buffer.floatChannelData {
            var mono = [Int16]()
            mono.reserveCapacity(frameCount)
            for i in 0..<frameCount {
                var sum: Float = 0
                for c in 0..<outChannels { sum += floats[c][i] }
                let v = max(-1, min(1, sum / Float(outChannels)))
                mono.append(Int16(v * 32767))
            }
            mono.withUnsafeBytes { nativePCM.append(contentsOf: $0) }
            outChannels = 1
        } else {
            return
        }

        // Opus only exists at 48 kHz on this path; anything else is
        // resampled before encoding (and before PCM fallback, so the
        // receiver always sees a stable rate).
        var streamRate = sampleRate
        if sampleRate != 48_000, let converted = resampleTo48k(nativePCM, channels: outChannels) {
            pcmAccumulator.append(converted)
            streamRate = 48_000
        } else {
            pcmAccumulator.append(nativePCM)
        }

        // Ship one packet per ~20 ms (or whatever we have once input
        // format doesn't match our assumed 48 kHz).
        let targetFrameBytes = Int(streamRate * 0.020) * 2 * outChannels

        while pcmAccumulator.count >= targetFrameBytes {
            let chunk = Data(pcmAccumulator.prefix(targetFrameBytes))
            pcmAccumulator.removeFirst(targetFrameBytes)
            let chunkTimestamp = frameMicros
            frameMicros &+= UInt64(Double(targetFrameBytes / 2 / outChannels) / streamRate * 1_000_000)

            var payload = chunk
            var codec = AudioPacket.codecPCM
            if outChannels == 1, let encoder = opusEncoder {
                if let opus = encoder.encode(pcm: chunk), !opus.isEmpty {
                    payload = opus
                    codec = AudioPacket.codecOpus
                    opusFailureCount = 0
                } else {
                    opusFailureCount += 1
                    if opusFailureCount > 10 {
                        Self.log.error("opus encoder failing persistently — switching to raw PCM")
                        Forensic.log("[e2e] opus encoder failed x\(self.opusFailureCount), PCM fallback")
                        opusEncoder = nil
                    } else {
                        // Priming: the codec holds the first frame(s).
                        // Skip rather than ship an empty packet.
                        continue
                    }
                }
            }

            let packet = AudioPacket(
                opusData: payload,
                sampleRate: Int(streamRate),
                channels: outChannels,
                timestampMicros: chunkTimestamp,
                codec: codec
            )
            broadcaster.send(packet)
            packetCount += 1
            if packetCount % 100 == 1 {
                Self.log.info("audio packets sent: \(self.packetCount) (codec=\(codec, privacy: .public))")
            }
        }
    }

    /// Resamples one chunk of native-rate Int16 PCM to 48 kHz, keeping
    /// the channel count. The converter persists across calls so the
    /// resampler's filter state stays continuous between buffers.
    private func resampleTo48k(_ pcm: Data, channels: Int) -> Data? {
        if resampler == nil {
            guard let inFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: sampleRate,
                    channels: AVAudioChannelCount(channels),
                    interleaved: true),
                  let outFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: 48_000,
                    channels: AVAudioChannelCount(channels),
                    interleaved: true),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat)
            else { return nil }
            resamplerInputFormat = inFormat
            resampler = converter
        }
        guard let resampler, let inFormat = resamplerInputFormat else { return nil }

        let inFrames = AVAudioFrameCount(pcm.count / 2 / channels)
        guard inFrames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inFrames)
        else { return nil }
        inBuf.frameLength = inFrames
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(inBuf.int16ChannelData![0], base, pcm.count)
            }
        }

        let outCapacity = AVAudioFrameCount(Double(inFrames) * 48_000.0 / sampleRate) + 96
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: resampler.outputFormat, frameCapacity: outCapacity)
        else { return nil }

        var provided = false
        var error: NSError?
        let status = resampler.convert(to: outBuf, error: &error) { _, outStatus in
            // `.noDataNow` (not end-of-stream) keeps the converter's
            // stream open so the next chunk continues seamlessly.
            if !provided {
                provided = true
                outStatus.pointee = .haveData
                return inBuf
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error, error == nil, outBuf.frameLength > 0 else { return nil }
        return Data(
            bytes: outBuf.int16ChannelData![0],
            count: Int(outBuf.frameLength) * channels * 2
        )
    }
}
