import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import VideoToolbox
import iBridgeCore

/// One H.264 stream exposed by the camera device. The system asks for
/// new `CMSampleBuffer`s on a timer (via the delegate). We pull the
/// most recent decoded frame from the host process via the
/// `iBridgeFrameSink` callback.
final class CameraExtensionStream: NSObject, CMIOExtensionStream {

    /// Video format advertised to consumers. Uses the same resolution
    /// and codec as what the iPhone is currently streaming.
    var formatDescription: CMVideoFormatDescription?

    private var decompressSession: VTDecompressionSession?
    private let decoder = StreamDecoder()
    private var lastEmitted: Date = .distantPast
    private let minimumInterval: TimeInterval = 1.0 / 30.0

    override init() {
        super.init()
    }

    deinit {
        if let decompressSession {
            VTDecompressionSessionInvalidate(decompressSession)
        }
    }

    // MARK: - CMIOExtensionStreamSource

    var streamFormatDescriptions: [CMIOExtensionStreamFormat] {
        guard let formatDescription else { return [] }
        let format = CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CMTime(value: 1, timescale: 30),
            minFrameDuration: CMTime(value: 1, timescale: 60),
            validFrameDurations: nil
        )
        return [format]
    }

    /// Called by the system on its own dispatch queue when it wants
    /// the next frame. We do not block: return the most recent
    /// decoded pixel buffer if available, else `nil` and try again.
    func consumeSampleBuffer(
        fromConnection connectionID: CMIOExtensionStreamConnectionID,
        callback: @escaping (CMSampleBuffer?, CMIOExtensionStreamDisconnectReason, NSError?) -> Void
    ) {
        // Throttle to ~30 fps regardless of how often the system polls.
        let now = Date()
        if now.timeIntervalSince(lastEmitted) < minimumInterval {
            // System will call again; just return the previous buffer.
            if let cached = decoder.lastBuffer {
                callback(cached, .noDisconnectReason, nil)
                return
            }
        }

        guard let pixelBuffer = decoder.dequeuePixelBuffer() else {
            callback(nil, .noDisconnectReason, nil)
            return
        }

        let sample = decoder.makeSampleBuffer(from: pixelBuffer)
        lastEmitted = now
        callback(sample, .noDisconnectReason, nil)
    }

    // MARK: - Wired up by the host

    /// Called by `iBridgeReceiver` whenever a fresh H.264 NAL arrives
    /// from the iPhone. We feed it through our own VTDecompressionSession
    /// and queue the resulting `CVPixelBuffer`.
    func receive(nalUnit: Data, kind: IBNalFrame.Kind) {
        decoder.feed(nalUnit: nalUnit, kind: kind)
    }
}

// MARK: - Per-stream decoder

/// Wraps VideoToolbox decoding + a small ring buffer of the most
/// recent decoded `CVPixelBuffer`s. Camera extensions are sample-pull
/// based: the system asks for the next frame whenever it needs one, and
/// we always hand back the freshest available pixel buffer.
final class StreamDecoder {

    var lastBuffer: CMSampleBuffer?

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?

    private let lock = NSLock()
    private var pixelBuffers: [CVPixelBuffer] = []
    private let maxBuffers = 2

    func feed(nalUnit: Data, kind: IBNalFrame.Kind) {
        switch kind {
        case .sps:
            sps = nalUnit
            tryMakeSession()
        case .pps:
            pps = nalUnit
            tryMakeSession()
        case .video:
            decode(nalUnit: nalUnit)
        case .metadata:
            break
        }
    }

    private var sps: Data?
    private var pps: Data?

    func dequeuePixelBuffer() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard !pixelBuffers.isEmpty else { return nil }
        return pixelBuffers.removeFirst()
    }

    func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(Date().timeIntervalSince1970 * 1000), timescale: 1000),
            decodeTimeStamp: .invalid
        )
        guard let format else { return nil }
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }

    private func tryMakeSession() {
        guard let sps, let pps else { return }

        var pointers: [UnsafePointer<UInt8>] = [
            sps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) },
            pps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
        ]
        var sizes: [Int] = [sps.count, pps.count]
        var newFormat: CMVideoFormatDescription?

        let status = pointers.withUnsafeMutableBufferPointer { ptr in
            sizes.withUnsafeMutableBufferPointer { sz in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptr.baseAddress!,
                    parameterSetSizes: sz.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormat
                )
            }
        }
        guard status == noErr, let newFormat else { return }
        self.format = newFormat

        var newSession: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormat,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        if let newSession { self.session = newSession }
    }

    private func decode(nalUnit: Data) {
        guard let session, let format else { return }

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: nalUnit.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: nalUnit.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard let blockBuffer else { return }
        nalUnit.withUnsafeBytes { raw in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: nalUnit.count,
                destination: UnsafeMutableRawPointer(mutating: raw.baseAddress)
            )
        }

        var sample: CMSampleBuffer?
        var size = nalUnit.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: 0, timescale: 1000),
            decodeTimeStamp: .invalid
        )
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )

        guard let sample else { return }

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            pixelBufferAttributes as CFDictionary,
            &pool
        )

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _, _ in
            guard status == noErr, let imageBuffer else { return }
            guard let self else { return }
            self.lock.lock()
            self.pixelBuffers.append(imageBuffer)
            if self.pixelBuffers.count > self.maxBuffers {
                self.pixelBuffers.removeFirst()
            }
            self.lock.unlock()
        }
    }
}