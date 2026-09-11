import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import iBridgeCore
import os

/// Hardware H.264 decoder using VideoToolbox. Receives raw Annex-B
/// NAL units (without start codes) from the wire protocol and emits
/// decoded `CGImage`s through `onDecoded`.
final class H264Decoder: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.ibridge", category: "H264Decoder")

    var onDecoded: (@Sendable (CGImage) -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private let queue = DispatchQueue(label: "com.ibridge.h264-decoder")

    init() {}

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    // MARK: - Public

    func feedSPS(_ data: Data) {
        queue.async { [weak self] in
            self?.sps = data
            self?.tryCreateSession()
        }
    }

    func feedPPS(_ data: Data) {
        queue.async { [weak self] in
            self?.pps = data
            self?.tryCreateSession()
        }
    }

    func feedVideo(_ data: Data) {
        queue.async { [weak self] in
            self?.decode(data: data)
        }
    }

    // MARK: - Session

    private func tryCreateSession() {
        guard let sps, let pps else { return }

        // Build a temporary block buffer containing SPS + PPS NAL units
        // (length-prefixed) for CMVideoFormatDescription creation.
        var naluPointers: [UnsafePointer<UInt8>] = [
            sps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) },
            pps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
        ]
        var naluSizes: [Int] = [sps.count, pps.count]

        let status = naluPointers.withUnsafeMutableBufferPointer { pointers in
            naluSizes.withUnsafeMutableBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers.baseAddress!,
                    parameterSetSizes: sizes.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }

        guard status == noErr, let format = formatDescription else {
            Self.log.error("format desc create failed: \(status)")
            return
        }
        self.formatDescription = format

        // Build decoder session.
        let attrs: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]

        var newSession: VTDecompressionSession?
        let decoderStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: attrs as CFDictionary,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard decoderStatus == noErr, let newSession else {
            Self.log.error("decoder session create failed: \(decoderStatus)")
            return
        }

        VTSessionSetProperty(newSession,
                             key: kVTDecompressionPropertyKey_RealTime,
                             value: true as CFBoolean)

        if let old = session {
            VTDecompressionSessionInvalidate(old)
        }
        session = newSession
    }

    // MARK: - Decode

    private func decode(data: Data) {
        guard let session, let formatDescription else { return }

        // The wire carries a raw NAL unit (the iOS encoder strips the
        // AVCC length prefix), but the format description declares
        // nalUnitHeaderLength = 4 — so re-wrap the NAL with its 4-byte
        // big-endian length before handing it to VideoToolbox.
        let totalLength = data.count + 4
        var avcc = Data(capacity: totalLength)
        var nalLength = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &nalLength) { avcc.append(contentsOf: $0) }
        avcc.append(data)

        var blockBuffer: CMBlockBuffer?

        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard allocStatus == kCMBlockBufferNoErr, let blockBuffer else { return }

        let copyStatus = avcc.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: UnsafeMutableRawPointer(mutating: baseAddress)
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = totalLength
        let timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(Date().timeIntervalSince1970 * 1000), timescale: 1000),
            decodeTimeStamp: .invalid
        )
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: [timing],
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }

        // Decode and emit.
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _, _ in
            guard status == noErr, let imageBuffer else { return }
            self?.emit(imageBuffer: imageBuffer)
        }

        if decodeStatus != noErr {
            Self.log.error("decode frame failed: \(decodeStatus) (nal \(data.count, privacy: .public) bytes)")
        }
    }

    private func emit(imageBuffer: CVImageBuffer) {
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        onDecoded?(cgImage)
    }
}