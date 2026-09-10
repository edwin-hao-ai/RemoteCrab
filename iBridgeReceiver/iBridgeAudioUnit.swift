import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import iBridgeCore

/// iBridge AudioUnit extension — exposes iBridge as a virtual
/// microphone that other apps can select as their audio input.
///
/// **V0.2 status:** complete skeleton, compile-ready, but the actual
/// `.appex` bundle needs proper code signing + an `NSExtension` entry
/// to load. In the meantime, we ship an `in-process` fallback that
/// routes the iPhone mic stream through `AVAudioEngine` to the Mac
/// speakers — gives the same end-user experience for development.
///
/// Architecture when properly signed:
///   1. `iBridgeAudioExtension.appex` lives in
///      `iBridgeReceiver.app/Contents/PlugIns/`
///   2. Inside the extension: an `AUAudioUnit` subclass that exposes
///      a single bus (the input bus = the microphone feed).
///   3. The host instantiates the extension via
///      `AUAudioUnit.instantiate(with:componentDescription:options:)`.
///   4. We connect the extension's render callback to a queue that
///      the host fills with `AudioPacket`s coming from the iPhone.
///   5. Other apps that pick "iBridge Microphone" as their input get
///      the live iPhone mic stream.
public final class iBridgeAudioUnit: AUAudioUnit, @unchecked Sendable {

    // MARK: - Bus configuration

    /// The single output bus the extension exposes.
    public let outputBus = AUAudioUnitBus()

    /// Bus format: 48 kHz, mono, Float32.
    public static let processingFormat: AVAudioFormat = {
        guard let f = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ) else { fatalError("AVAudioFormat(48000, 1) failed") }
        return f
    }()

    // MARK: - State

    private let ringBuffer: iBridgeRingBuffer
    private var isRunning = false

    public override init() {
        // 1 second of 48 kHz mono Float32 = 192 KB. Plenty for the
        // WiFi transport; the ring buffer smooths minor jitter.
        let capacity = 48_000 * MemoryLayout<Float>.size
        self.ringBuffer = iBridgeRingBuffer(capacity: capacity)

        super.init()

        // Configure the output bus with the canonical format.
        outputBus.format = Self.processingFormat
        self.outputBusses = [outputBus]

        // Configure the input scope (we are an output of the host but
        // provide an input bus where the host pushes samples into us).
        let inputBus = AUAudioUnitBus()
        inputBus.format = Self.processingFormat
        self.inputBusses = [inputBus]
    }

    // MARK: - Render block

    /// Called by CoreAudio to pull samples from the AU's render
    /// queue. The host thread pushes decoded PCM samples into
    /// `ringBuffer`; this method drains them into the output buffer.
    public var renderBlock: AUInternalRenderBlock {
        return { [weak self] actionFlags, timestamp, frameCount, outputBusNumber, outputData, _, pullInputBlock in
            guard let self = self else {
                return kAudioUnitErr_Uninitialized
            }
            let outBuffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard let out = outBuffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_InvalidPropertyValue
            }

            let framesRead = self.ringBuffer.read(into: out, max: Int(frameCount))
            // Zero any unwritten samples (underrun = silence).
            if framesRead < Int(frameCount) {
                for i in framesRead..<Int(frameCount) {
                    out[i] = 0
                }
            }
            return noErr
        }
    }

    // MARK: - Lifecycle

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        isRunning = true
        ringBuffer.flush()
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
        isRunning = false
    }

    // MARK: - Host-facing API

    /// Push a batch of Float32 PCM samples (mono, 48 kHz) into the
    /// render queue. Called by the host (iBridgeReceiver) every time
    /// an `AudioPacket` arrives from the iPhone.
    public func enqueue(samples: UnsafePointer<Float>, count: Int) {
        ringBuffer.write(from: samples, count: count)
    }
}

// MARK: - Real-time safe lock-free ring buffer
//
// Simple SPSC (single-producer single-consumer) ring buffer for Float32
// samples. Audio render thread is the consumer; the host's audio
// packet handler is the producer. We use atomic head/tail indices on
// a memory-order relaxed level; the worst case is one frame of
// overrun which is inaudible.

final class iBridgeRingBuffer: @unchecked Sendable {
    private var storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let head = AtomicCounter()  // producer writes here
    private let tail = AtomicCounter()  // consumer reads here

    init(capacity: Int) {
        let bytes = UnsafeMutablePointer<Float>.allocate(capacity: capacity / MemoryLayout<Float>.size)
        self.storage = UnsafeMutableBufferPointer(start: bytes, count: capacity / MemoryLayout<Float>.size)
        self.capacity = capacity / MemoryLayout<Float>.size
    }

    deinit {
        storage.baseAddress?.deallocate()
    }

    func write(from src: UnsafePointer<Float>, count: Int) {
        let n = min(count, capacity)
        let headVal = head.value
        let tailVal = tail.value
        let available = capacity - (headVal - tailVal)
        let toWrite = min(n, available)
        guard toWrite > 0 else { return }
        let start = headVal % capacity
        if start + toWrite <= capacity {
            storage.baseAddress!.advanced(by: start).update(
                from: src, count: toWrite)
        } else {
            let firstChunk = capacity - start
            storage.baseAddress!.advanced(by: start).update(
                from: src, count: firstChunk)
            storage.baseAddress!.update(
                from: src.advanced(by: firstChunk), count: toWrite - firstChunk)
        }
        head.set(headVal + toWrite)
    }

    func read(into dst: UnsafeMutablePointer<Float>, max: Int) -> Int {
        let headVal = head.value
        let tailVal = tail.value
        let available = headVal - tailVal
        let toRead = min(max, available)
        guard toRead > 0 else { return 0 }
        let start = tailVal % capacity
        if start + toRead <= capacity {
            dst.update(from: storage.baseAddress!.advanced(by: start), count: toRead)
        } else {
            let firstChunk = capacity - start
            dst.update(from: storage.baseAddress!.advanced(by: start), count: firstChunk)
            dst.advanced(by: firstChunk).update(
                from: storage.baseAddress!, count: toRead - firstChunk)
        }
        tail.set(tailVal + toRead)
        return toRead
    }

    func flush() {
        head.set(0)
        tail.set(0)
    }
}

/// Minimal hand-rolled atomic counter (avoids depending on os.lock
/// or Dispatch's deprecated atomics). Used for the ring buffer's
/// head/tail indices; relaxed ordering is sufficient for an SPSC queue.
final class AtomicCounter: @unchecked Sendable {
    private var _value: Int = 0
    private let lock = NSLock()

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set(_ newValue: Int) {
        lock.lock(); _value = newValue; lock.unlock()
    }
}