import AVFoundation
import Combine
import CoreAudio
import Foundation
import SwiftUI
import VideoToolbox
import iBridgeCore

/// Receiver-side audio routing. Pulls PCM packets received from
/// the iPhone, pushes them into either:
///   • the system audio output (speakers / headphones), or
///   • the iBridgeAudioUnit (virtual microphone selected by other apps).
///
/// In V0.2 the default sink is the speakers. When the iBridgeAudio
/// extension is installed + signed + approved by the user, other apps
/// (Zoom, Slack, OBS) can select "iBridge Microphone" as their mic
/// input and we feed them the same iPhone mic stream.
@MainActor
final class AudioReceiver {

    /// Backend mode: speakers (always available) or virtual mic
    /// (when the system extension is installed and approved).
    enum Sink: Equatable {
        case speakers
        case virtualMic
    }

    private let speakerEngine = AVAudioEngine()
    private let speakerMixer: AVAudioMixerNode
    private var speakerConnected = false

    /// Pushed to by the wire-protocol receive loop. The AU pulls
    /// from the same buffer via its render block.
    private weak var sharedAU: iBridgeAudioUnit?

    var sink: Sink = .speakers {
        didSet { applySink() }
    }

    init() {
        speakerMixer = speakerEngine.mainMixerNode
    }

    /// Start the speaker route so we can hear iPhone mic immediately.
    func start() throws {
        if !speakerConnected {
            try speakerEngine.start()
            speakerConnected = true
        }
    }

    /// Stop and release audio resources.
    func stop() {
        if speakerEngine.isRunning {
            speakerEngine.stop()
        }
        speakerConnected = false
    }

    /// Register the AU instance so we can ship samples to it via the
    /// shared ring buffer. Called by the Mac app at startup.
    func register(audioUnit: iBridgeAudioUnit) {
        sharedAU = audioUnit
    }

    /// Called for each `AudioPacket` arriving over the wire.
    func feed(_ packet: AudioPacket) {
        // Convert Int16 PCM samples to Float32 (the AU + speaker both
        // want Float32) and hand off to the active sink.
        let floats = packet.opusData.withUnsafeBytes { ptr -> [Float] in
            let count = ptr.count / 2
            var out = [Float](repeating: 0, count: count)
            let i16Ptr = ptr.bindMemory(to: Int16.self)
            for i in 0..<count {
                out[i] = Float(i16Ptr[i]) / Float(Int16.max)
            }
            return out
        }
        switch sink {
        case .speakers:
            feedSpeakers(samples: floats)
        case .virtualMic:
            feedVirtualMic(samples: floats)
        }
    }

    // MARK: - Speakers path

    private func feedSpeakers(samples: [Float]) {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        )!
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        let dst = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            dst[i] = samples[i]
        }
        buffer.frameLength = frameCount
        // Hand to the main mixer node, which routes to speakers.
        // Use the existing engine mainMixerNode input via a player node
        // so we don't have to plumb a separate engine instance.
        scheduleOnEngine(buffer: buffer)
    }

    /// Reuses an internal player node attached to the engine main
    /// mixer. We keep one player around and schedule buffers onto it.
    private let player = AVAudioPlayerNode()
    private var playerAttached = false

    private func scheduleOnEngine(buffer: AVAudioPCMBuffer) {
        if !playerAttached {
            speakerEngine.attach(player)
            speakerEngine.connect(player, to: speakerMixer, format: buffer.format)
            playerAttached = true
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts) { /* ignore */ }
        if !speakerEngine.isRunning {
            try? speakerEngine.start()
            speakerConnected = true
        }
    }

    // MARK: - Virtual mic path

    private func feedVirtualMic(samples: [Float]) {
        guard let au = sharedAU else { return }
        samples.withUnsafeBufferPointer { ptr in
            au.enqueue(samples: ptr.baseAddress!, count: samples.count)
        }
    }

    // MARK: - Sink routing

    private func applySink() {
        switch sink {
        case .speakers:
            if !speakerConnected { try? start() }
        case .virtualMic:
            stop()
        }
    }
}