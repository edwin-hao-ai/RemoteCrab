import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import RemoteCrabCore
import os

/// Hardware H.264 decoder using VideoToolbox. Receives raw Annex-B
/// NAL units (without start codes) from the wire protocol and emits
/// decoded `CGImage`s through `onDecoded`.
final class H264Decoder: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.remotecrab", category: "H264Decoder")
    private static let frameProbeEnabled =
        ProcessInfo.processInfo.environment["REMOTECRAB_DEBUG_FRAME_PROBE"] == "1"

    var onDecoded: (@Sendable (CGImage) -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private let queue = DispatchQueue(label: "com.remotecrab.h264-decoder")
    /// When VideoToolbox reports a session malfunction (`-12909`) we tear
    /// the session down and rebuild it from the cached SPS/PPS. The video
    /// stream is driving a live preview, so we throttle rebuilds and give
    /// up for a moment if it keeps failing rather than spinning.
    private var lastSessionRebuildAt = Date.distantPast
    private var malfunctionCount = 0

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

        // Pointers must stay valid for the duration of the create call —
        // keep everything nested inside the withUnsafeBytes scopes (an
        // escaped pointer to small inline Data storage is use-after-free).
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
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }
            }
        }

        guard status == noErr, let format = formatDescription else {
            Self.log.error("format desc create failed: \(status) (sps \(sps.count, privacy: .public)pps \(self.pps?.count ?? 0, privacy: .public))")
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
        malfunctionCount = 0
        Self.log.info("decoder session created")
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

        // Own the memory ourselves and hand it over with a custom block
        // source that frees it when the block buffer dies — creating with
        // a nil memory block leaves the buffer unallocated and every
        // copy fails with kCMBlockBufferUnallocatedBlockErr.
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
            Self.log.error("block buffer alloc failed: \(allocStatus)")
            return
        }

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
        guard sampleStatus == noErr, let sampleBuffer else {
            Self.log.error("sample buffer create failed: \(sampleStatus)")
            return
        }

        // Decode and emit.
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _, _ in
            guard status == noErr, let imageBuffer else {
                if status != noErr {
                    let head = data.prefix(8).map { String(format: "%02x", $0) }.joined()
                    Self.log.error("decode callback error: \(status) nalType=\(data.first.map { $0 & 0x1F } ?? 0, privacy: .public) len=\(data.count, privacy: .public) head=\(head, privacy: .public)")
                    // -12909 (kVTVideoDecoderMalfunctionErr): the session is
                    // dead. It arrives as a burst at stream start and would
                    // otherwise leave the preview/recording black forever.
                    if status == -12909 {
                        self?.handleMalfunction()
                    }
                }
                return
            }
            self?.emit(imageBuffer: imageBuffer)
        }

        if decodeStatus != noErr {
            Self.log.error("decode frame failed: \(decodeStatus) (nal \(data.count, privacy: .public) bytes)")
            if decodeStatus == -12909 { handleMalfunction() }
        }
    }

    /// Rebuild the decoder session after a `kVTVideoDecoderMalfunctionErr`
    /// (`-12909`). Throttled to once per second and bounded to 5 rapid
    /// attempts, so a genuinely undecodable stream can't spin the CPU.
    private func handleMalfunction() {
        let now = Date()
        guard now.timeIntervalSince(lastSessionRebuildAt) > 1.0 else { return }
        lastSessionRebuildAt = now
        malfunctionCount += 1
        guard malfunctionCount <= 5 else {
            Self.log.error("decoder malfunction persisted — giving up on this stream")
            return
        }
        Self.log.info("decoder malfunction — rebuilding session (\(self.malfunctionCount, privacy: .public))")
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        // Keep sps/pps so `tryCreateSession` can rebuild immediately.
        tryCreateSession()
    }

    private var emittedAny = false
    private var emitCount = 0

    /// Creating a `CIContext` is expensive (it spins up a render
    /// pipeline); doing it per frame at 30 fps stalls the decode queue
    /// and shows up as visible stutter. One context per decoder.
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    private func emit(imageBuffer: CVImageBuffer) {
        if !emittedAny {
            emittedAny = true
            Self.log.info("first frame decoded OK")
        }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        // Optional scene-luminance probe (every 5 s) that separates a
        // covered/dark camera from a decoder emitting black frames —
        // that ambiguity cost a full debugging session once. Read
        // straight from CoreGraphics: CI's PNG writer is blocked by the
        // sandbox, and a failed CI render silently reads back as 0.
        // Off unless REMOTECRAB_DEBUG_FRAME_PROBE=1.
        emitCount += 1
        if Self.frameProbeEnabled, emitCount % 150 == 0 {
            var px = [UInt8](repeating: 0, count: 16 * 16 * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            px.withUnsafeMutableBytes { buf in
                if let ctx = CGContext(data: buf.baseAddress, width: 16, height: 16,
                                       bitsPerComponent: 8, bytesPerRow: 16 * 4, space: cs,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 16, height: 16))
                }
            }
            var mn = 255, mx = 0, sum = 0
            for i in stride(from: 0, to: px.count, by: 4) {
                let lum = (Int(px[i]) * 299 + Int(px[i + 1]) * 587 + Int(px[i + 2]) * 114) / 1000
                mn = min(mn, lum); mx = max(mx, lum); sum += lum
            }
            Self.log.info("frame probe: min=\(mn) max=\(mx) avg=\(sum / (px.count / 4)) w=\(cgImage.width) h=\(cgImage.height)")
        }
        onDecoded?(cgImage)
    }
}