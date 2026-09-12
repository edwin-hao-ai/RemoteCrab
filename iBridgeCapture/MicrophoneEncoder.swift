import AVFoundation
import Foundation
import iBridgeCore
import os

/// Captures audio from the iPhone microphone and ships PCM frames over
/// the wire. Each `AudioPacket` carries one ~20 ms frame.
///
/// V0.2 ships raw PCM (Int16 interleaved) at whatever sample rate the
/// device delivers. The Mac plays it back through AVAudioEngine at the
/// same rate. A future V0.3 can swap in real Opus encoding without
/// changing the wire format — `AudioPacket.opusData` already carries
/// arbitrary bytes.
final class MicrophoneEncoder: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.ibridge", category: "MicrophoneEncoder")

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
            return
        }

        isRunning = true

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        sampleRate = inputFormat.sampleRate
        Self.log.info("mic input format: \(inputFormat.sampleRate) Hz x \(inputFormat.channelCount) ch")

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isRunning, let broadcaster = self.broadcaster else { return }
            self.handlePCM(buffer: buffer, broadcaster: broadcaster)
        }

        do {
            try engine.start()
            Self.log.info("mic engine started")
        } catch {
            Self.log.error("mic start failed: \(error, privacy: .public)")
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

    private func handlePCM(buffer: AVAudioPCMBuffer, broadcaster: IBEventBroadcaster) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // The iPhone input node delivers Float32 non-interleaved, so
        // `int16ChannelData` is nil on real hardware. Convert to mono
        // Int16 (mixing channels down) in that case.
        var outChannels = Int(buffer.format.channelCount)
        if let int16 = buffer.int16ChannelData {
            let frames = UnsafeBufferPointer(start: int16[0], count: frameCount * outChannels)
            pcmAccumulator.append(contentsOf: UnsafeRawBufferPointer(frames))
        } else if let floats = buffer.floatChannelData {
            var mono = [Int16]()
            mono.reserveCapacity(frameCount)
            for i in 0..<frameCount {
                var sum: Float = 0
                for c in 0..<outChannels { sum += floats[c][i] }
                let v = max(-1, min(1, sum / Float(outChannels)))
                mono.append(Int16(v * 32767))
            }
            mono.withUnsafeBytes { pcmAccumulator.append(contentsOf: $0) }
            outChannels = 1
        } else {
            return
        }

        // Ship one packet per ~20 ms (or whatever we have once input
        // format doesn't match our assumed 48 kHz).
        let targetFrameBytes = Int(Double(sampleRate) * 0.020) * 2 * outChannels

        while pcmAccumulator.count >= targetFrameBytes {
            let chunk = pcmAccumulator.prefix(targetFrameBytes)
            pcmAccumulator.removeFirst(targetFrameBytes)

            let packet = AudioPacket(
                opusData: Data(chunk),         // field reused for raw PCM in V0.2
                sampleRate: Int(sampleRate),
                channels: outChannels,
                timestampMicros: frameMicros
            )
            broadcaster.send(packet)
            packetCount += 1
            if packetCount % 100 == 1 {
                Self.log.info("audio packets sent: \(self.packetCount)")
            }
            frameMicros &+= UInt64(Double(targetFrameBytes / 2 / outChannels) / sampleRate * 1_000_000)
        }
    }
}