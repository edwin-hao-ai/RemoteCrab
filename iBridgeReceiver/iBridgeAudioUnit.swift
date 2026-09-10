import AVFoundation
import AudioToolbox
import Foundation
import iBridgeCore

/// Real-time safe SPSC (single-producer single-consumer) ring buffer
/// for Float32 PCM samples. The producer is the Mac host
/// (`AudioReceiver` in iBridgeReceiver target); the consumer is the
/// audio render thread in the iBridge virtual microphone.
public final class iBridgeRingBuffer: @unchecked Sendable {
    private var storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let head = AtomicCounter()  // producer writes here
    private let tail = AtomicCounter()  // consumer reads here

    public init(capacityBytes: Int) {
        let count = capacityBytes / MemoryLayout<Float>.size
        let bytes = UnsafeMutablePointer<Float>.allocate(capacity: count)
        self.storage = UnsafeMutableBufferPointer(start: bytes, count: count)
        self.capacity = count
    }

    deinit { storage.baseAddress?.deallocate() }

    public var depth: Int { head.value - tail.value }

    public func write(from src: UnsafePointer<Float>, count: Int) {
        let headVal = head.value
        let tailVal = tail.value
        let available = capacity - (headVal - tailVal)
        let toWrite = min(count, available)
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

    public func read(into dst: UnsafeMutablePointer<Float>, max: Int) -> Int {
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

    public func flush() {
        head.set(0)
        tail.set(0)
    }
}

/// Minimal atomic counter used by the SPSC ring buffer.
public final class AtomicCounter: @unchecked Sendable {
    private var _value: Int = 0
    private let lock = NSLock()
    public init() {}
    public var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    public func set(_ newValue: Int) {
        lock.lock(); _value = newValue; lock.unlock()
    }
}

/// iBridge's virtual microphone — wraps the ring buffer with a small
/// public API the host process can use to enqueue Float32 PCM samples
/// from each decoded iPhone-mic `AudioPacket`.
///
/// In V0.2 we use this directly via `iBridgeAUInstanceProvider` for
/// the in-process path (simulator + dev). When the
/// `iBridgeAudioExtension.appex` is properly code-signed + installed,
/// the extension instantiates an AUv3 class that calls into the same
/// `enqueue` API, sharing the same buffer and therefore the same audio.
public final class iBridgeAudioUnit: @unchecked Sendable {

    /// Canonical bus format: 48 kHz mono Float32.
    public static let processingFormat: AVAudioFormat = {
        guard let f = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ) else { fatalError("AVAudioFormat(48000, 1) failed") }
        return f
    }()

    private let ringBuffer: iBridgeRingBuffer

    public init() {
        // 1 second of 48 kHz mono Float32 = 192 KB. Smooths minor
        // WiFi jitter between the host's enqueue and the render call.
        self.ringBuffer = iBridgeRingBuffer(capacityBytes: 48_000 * MemoryLayout<Float>.size)
    }

    /// Push a batch of Float32 samples into the render queue.
    public func enqueue(samples: UnsafePointer<Float>, count: Int) {
        ringBuffer.write(from: samples, count: count)
    }

    /// Drain the queue into the output buffer. Returns the number of
    /// frames actually written. The `AURenderBlock` in the extension
    /// calls this for every render cycle.
    public func read(into dst: UnsafeMutablePointer<Float>, max: Int) -> Int {
        ringBuffer.read(into: dst, max: max)
    }

    /// Currently-buffered frame count. Useful for diagnostics / UI.
    public var queuedFrames: Int { ringBuffer.depth }
}