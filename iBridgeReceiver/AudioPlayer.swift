import AVFoundation
import Foundation
import iBridgeCore

/// Plays PCM frames received over the wire through `AVAudioEngine`.
///
/// The first packet we see sets the audio format. Subsequent packets
/// are queued and rendered through a source node connected to the
/// output.
final class AudioPlayer {

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private let queue = DispatchQueue(label: "com.ibridge.audio-player")
    private var pcmBuffer = Data()
    private var isStarted = false
    private var targetSampleRate: Double = 48_000
    private var targetChannels: AVAudioChannelCount = 1

    func start() {
        guard !isStarted else { return }
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        // We feed 16-bit interleaved PCM at our rate/channels; AVAudioEngine
        // re-samples to whatever the output hardware needs.
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        )!

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            return self.fill(audioBufferList: audioBufferList, frameCount: frameCount)
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: inputFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)

        do {
            try engine.start()
            sourceNode = node
            isStarted = true
            print("[iBridge] audio player started (output format: \(outputFormat))")
        } catch {
            print("[iBridge] audio player start failed: \(error)")
        }
    }

    func stop() {
        guard isStarted else { return }
        engine.stop()
        if let node = sourceNode { engine.detach(node) }
        sourceNode = nil
        isStarted = false
    }

    /// Hand the player a fresh PCM packet from the wire.
    func consume(_ packet: AudioPacket) {
        queue.async { [weak self] in
            guard let self else { return }
            // First packet establishes the format.
            if self.targetSampleRate == 48_000 && packet.sampleRate != 48_000 {
                self.targetSampleRate = Double(packet.sampleRate)
            }
            if self.targetChannels == 1 && packet.channels > 1 {
                self.targetChannels = AVAudioChannelCount(packet.channels)
            }
            self.pcmBuffer.append(packet.opusData)
        }
    }

    // MARK: - Source node pull

    private func fill(audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                      frameCount: AVAudioFrameCount) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let bytesNeeded = Int(frameCount) * Int(targetChannels) * 2

        // Copy bytes out of our queue under the lock, then write them
        // into the caller's buffer outside the lock (so we don't hold
        // it across the memcpy).
        let snapshot: Data = queue.sync { pcmBuffer }
        var remaining = bytesNeeded
        var snapshotOffset = 0
        for buffer in abl {
            guard let mData = buffer.mData else { continue }
            let take = min(Int(buffer.mDataByteSize), remaining)
            guard take > 0 else { break }
            let availableInSnapshot = snapshot.count - snapshotOffset
            let toCopy = min(take, availableInSnapshot)
            memcpy(mData,
                   snapshot.withUnsafeBytes { $0.baseAddress!.advanced(by: snapshotOffset) },
                   toCopy)
            snapshotOffset += toCopy
            remaining -= toCopy
            if toCopy < take {
                // Underrun — fill the rest with silence.
                memset(mData.advanced(by: toCopy), 0, take - toCopy)
            }
        }
        // Drop what we consumed.
        queue.async { [weak self] in
            self?.pcmBuffer.removeFirst(snapshotOffset)
        }
        return noErr
    }
}