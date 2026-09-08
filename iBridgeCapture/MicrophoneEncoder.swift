import AVFoundation
import Foundation
import iBridgeCore

/// Captures audio from the iPhone microphone and ships PCM frames over
/// the wire. Each `AudioPacket` carries one ~20 ms frame.
///
/// V0.2 ships raw PCM (Int16 interleaved) at whatever sample rate the
/// device delivers. The Mac plays it back through AVAudioEngine at the
/// same rate. A future V0.3 can swap in real Opus encoding without
/// changing the wire format — `AudioPacket.opusData` already carries
/// arbitrary bytes.
final class MicrophoneEncoder: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var broadcaster: IBEventBroadcaster?
    private var isRunning = false
    private var sampleRate: Double = 48_000

    func start(broadcaster: IBEventBroadcaster) {
        guard !isRunning else { return }
        self.broadcaster = broadcaster
        isRunning = true

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        sampleRate = inputFormat.sampleRate
        print("[iBridge] mic input format: \(inputFormat)")

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.isRunning, let broadcaster = self.broadcaster else { return }
            self.handlePCM(buffer: buffer, broadcaster: broadcaster)
        }

        do {
            try engine.start()
        } catch {
            print("[iBridge] mic start failed: \(error)")
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

    private func handlePCM(buffer: AVAudioPCMBuffer, broadcaster: IBEventBroadcaster) {
        guard let int16 = buffer.int16ChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let frames = UnsafeBufferPointer(start: int16[0], count: frameCount * channelCount)
        pcmAccumulator.append(contentsOf: UnsafeRawBufferPointer(frames))

        // Ship one packet per ~20 ms (or whatever we have once input
        // format doesn't match our assumed 48 kHz).
        let targetFrameBytes = Int(Double(sampleRate) * 0.020) * 2

        while pcmAccumulator.count >= targetFrameBytes {
            let chunk = pcmAccumulator.prefix(targetFrameBytes)
            pcmAccumulator.removeFirst(targetFrameBytes)

            let packet = AudioPacket(
                opusData: Data(chunk),         // field reused for raw PCM in V0.2
                sampleRate: Int(sampleRate),
                channels: channelCount,
                timestampMicros: frameMicros
            )
            broadcaster.send(packet)
            frameMicros &+= UInt64(Double(targetFrameBytes / 2) / sampleRate * 1_000_000)
        }
    }
}