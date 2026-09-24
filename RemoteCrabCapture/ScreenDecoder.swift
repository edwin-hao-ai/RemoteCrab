import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import RemoteCrabCore
import os

/// Decodes the Mac→iPhone screen-mirror H.264 stream into display-ready
/// `CMSampleBuffer`s that can be enqueued straight into an
/// `AVSampleBufferDisplayLayer`.
///
/// Mirrors `RemoteCrabReceiver/H264Decoder.swift` (SPS/PPS →
/// `CMVideoFormatDescription`, AVCC length-prefixed NALs → VideoToolbox),
/// but emits `CMSampleBuffer`s wrapping the decoded `CVPixelBuffer`
/// instead of `CGImage`s — the display layer wants sample buffers with a
/// presentation timestamp.
///
/// The mirror can switch windows or resolution at any time, which means a
/// brand-new SPS/PPS pair. Whenever the parameter sets change the session
/// is torn down and rebuilt on the next video frame.
final class ScreenDecoder: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.remotecrab", category: "screendecoder")

    /// Called on the decoder's serial queue with every decoded frame
    /// wrapped in a `CMSampleBuffer` (valid PTS + image format
    /// description) ready for `AVSampleBufferDisplayLayer.enqueue(_:)`.
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    /// Set when SPS/PPS change so the next video frame rebuilds the
    /// format description + session instead of using a stale one.
    private var needsRebuild = false
    private let queue = DispatchQueue(label: "com.remotecrab.screen-decoder")

    init() {}

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    // MARK: - Public

    /// Feed one wire NAL (SPS / PPS / video). Mirrors the camera decoder's
    /// `feedSPS`/`feedPPS`/`feedVideo`, folded into one entry point.
    func feed(_ frame: IBNalFrame) {
        let data = frame.data
        switch frame.kind {
        case .sps:
            queue.async { [weak self] in self?.storeSPS(data) }
        case .pps:
            queue.async { [weak self] in self?.storePPS(data) }
        case .video:
            let ptsMicros = frame.timestampMicros
            queue.async { [weak self] in self?.decode(data: data, ptsMicros: ptsMicros) }
        }
    }

    /// Clear all state on disconnect / a new mirror target. The next
    /// SPS/PPS pair rebuilds the session from scratch.
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            if let session = self.session {
                VTDecompressionSessionInvalidate(session)
            }
            self.session = nil
            self.formatDescription = nil
            self.sps = nil
            self.pps = nil
            self.needsRebuild = false
            Self.log.info("screen decoder reset")
        }
    }

    // MARK: - Parameter sets

    private func storeSPS(_ data: Data) {
        guard sps != data else { return }
        sps = data
        invalidateForParameterChange()
    }

    private func storePPS(_ data: Data) {
        guard pps != data else { return }
        pps = data
        invalidateForParameterChange()
    }

    /// A new parameter set means a new window/resolution — drop the old
    /// format description + decoder session. Rebuilt lazily by
    /// `decode(data:ptsMicros:)`.
    private func invalidateForParameterChange() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        needsRebuild = true
        Self.log.info("parameter sets changed — decoder will rebuild")
    }

    // MARK: - Session

    /// Build the format description + decoder session from the cached
    /// SPS/PPS. Returns true when a usable session is ready.
    private func buildSessionIfNeeded() -> Bool {
        if let session, formatDescription != nil, !needsRebuild {
            return true
        }
        guard let sps, let pps else { return false }

        needsRebuild = false

        var format: CMVideoFormatDescription?
        // Pointers must stay valid for the whole create call — keep both
        // inside the nested `withUnsafeBytes` scopes (an escaped pointer
        // to small inline `Data` storage is use-after-free).
        let status = sps.withUnsafeBytes { spsBuf -> OSStatus in
            pps.withUnsafeBytes { ppsBuf -> OSStatus in
                guard let spsBase = spsBuf.baseAddress, let ppsBase = ppsBuf.baseAddress else {
                    return -1
                }
                var naluPointers: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self)
                ]
                var naluSizes: [Int] = [sps.count, pps.count]
                return naluPointers.withUnsafeMutableBufferPointer { pointers in
                    naluSizes.withUnsafeMutableBufferPointer { sizes in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointers.baseAddress!,
                            parameterSetSizes: sizes.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }
        guard status == noErr, let format else {
            Self.log.error("format desc create failed: \(status, privacy: .public)")
            return false
        }
        formatDescription = format

        let attrs: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]
        let imageBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        var newSession: VTDecompressionSession?
        let decoderStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: attrs as CFDictionary,
            imageBufferAttributes: imageBufferAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard decoderStatus == noErr, let newSession else {
            Self.log.error("decoder session create failed: \(decoderStatus, privacy: .public)")
            return false
        }
        VTSessionSetProperty(newSession,
                             key: kVTDecompressionPropertyKey_RealTime,
                             value: true as CFBoolean)
        session = newSession
        Self.log.info("screen decoder session created")
        return true
    }

    // MARK: - Decode

    private func decode(data: Data, ptsMicros: UInt64) {
        guard buildSessionIfNeeded(), let session, let formatDescription else { return }

        // The wire carries a raw NAL unit, but the format description
        // declares nalUnitHeaderLength = 4 — re-wrap it with its 4-byte
        // big-endian length before handing it to VideoToolbox.
        let totalLength = data.count + 4
        var avcc = Data(capacity: totalLength)
        var nalLength = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &nalLength) { avcc.append(contentsOf: $0) }
        avcc.append(data)

        guard let mem = malloc(totalLength) else { return }
        avcc.withUnsafeBytes { rawBuffer in
            if let base = rawBuffer.baseAddress {
                memcpy(mem, base, totalLength)
            }
        }
        var blockSource = CMBlockBufferCustomBlockSource()
        blockSource.version = kCMBlockBufferCustomBlockSourceVersion
        blockSource.refCon = nil
        blockSource.FreeBlock = { _, doomedBlock, _ in free(doomedBlock) }

        var blockBuffer: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: mem,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &blockSource,
            offsetToData: 0,
            dataLength: totalLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard allocStatus == kCMBlockBufferNoErr, let blockBuffer else {
            free(mem)
            return
        }

        // A valid, monotonic PTS: use the wire timestamp when present,
        // else the host clock (the mirror NALs carry 0).
        let ptsValue = ptsMicros > 0
            ? CMTimeValue(ptsMicros)
            : CMTimeValue(Date().timeIntervalSince1970 * 1_000_000)
        let pts = CMTime(value: ptsValue, timescale: 1_000_000)
        let timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = totalLength
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
        guard sampleStatus == noErr, let sampleBuffer else {
            Self.log.error("input sample buffer create failed: \(sampleStatus, privacy: .public)")
            return
        }

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _, _ in
            guard status == noErr, let imageBuffer else {
                if status != noErr {
                    Self.log.error("screen decode callback error: \(status, privacy: .public)")
                }
                return
            }
            self?.emit(imageBuffer: imageBuffer, pts: pts)
        }
        if decodeStatus != noErr {
            Self.log.error("screen decode frame failed: \(decodeStatus, privacy: .public)")
        }
    }

    private var emittedAny = false

    /// Wrap the decoded pixel buffer in a `CMSampleBuffer` carrying the
    /// input frame's PTS, then hand it to `onSampleBuffer` on our serial
    /// queue. `AVSampleBufferDisplayLayer.enqueue` accepts exactly this.
    private func emit(imageBuffer: CVImageBuffer, pts: CMTime) {
        let pixelBuffer = imageBuffer

        var imageFormat: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &imageFormat
        )
        guard formatStatus == noErr, let imageFormat else {
            Self.log.error("image format desc failed: \(formatStatus, privacy: .public)")
            return
        }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: imageFormat,
            sampleTiming: &timing,
            sampleBufferOut: &output
        )
        guard status == noErr, let output else {
            Self.log.error("output sample buffer failed: \(status, privacy: .public)")
            return
        }

        // Show each frame as soon as it arrives instead of letting the
        // display layer schedule it against its own timebase — our PTS is
        // wall-clock, not a media timeline, so time-scheduling can stall
        // the mirror.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(output, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately as String] = kCFBooleanTrue
        }

        if !emittedAny {
            emittedAny = true
            Self.log.info("first screen frame decoded OK")
        }
        let box = ScreenSendableBox(value: output)
        queue.async { [weak self] in
            self?.onSampleBuffer?(box.value)
        }
    }
}

/// `CMSampleBuffer` isn't `Sendable`; the decode callback hands it to the
/// serial queue (and, from the engine, to the main actor to enqueue into
/// the display layer) unchanged, so the unchecked box is safe.
struct ScreenSendableBox<T>: @unchecked Sendable {
    let value: T
}
