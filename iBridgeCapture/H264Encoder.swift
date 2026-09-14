import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import VideoToolbox
import iBridgeCore
import os

/// Hardware H.264 encoder using VideoToolbox. Conforms to
/// `AVCaptureVideoDataOutputSampleBufferDelegate` so it can be plugged
/// straight into an AVCaptureSession.
///
/// On every encoded frame the consumer receives an `IBNalFrame` via
/// the `onFrame` callback. SPS / PPS are emitted the first time they
/// change — the receiver needs them to set up its decoder.
final class H264Encoder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    private static let log = Logger(subsystem: "com.ibridge", category: "H264Encoder")

    // MARK: - Public

    var onFrame: (@Sendable (IBNalFrame) -> Void)?

    private let width: Int32
    private let height: Int32
    private let fps: Int
    private let bitrate: Int

    private var compressionSession: VTCompressionSession?
    private var lastSPS: Data?
    private var lastPPS: Data?
    private var isReady = false
    private let queue = DispatchQueue(label: "com.ibridge.h264-encoder")

    // Session self-healing: iOS invalidates the VTCompressionSession
    // while the app is backgrounded — after an interruption every
    // VTCompressionSessionEncodeFrame returns kVTInvalidSessionErr
    // forever (this was the root cause of "video silently stops").
    // The only recovery is to invalidate + recreate the session.
    private var recreationPending = false
    private var lastRecreationAt = Date.distantPast

    init(width: Int32 = 1920,
         height: Int32 = 1080,
         fps: Int = 30,
         bitrate: Int = 4_000_000) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
    }

    // MARK: - Setup

    func start(onFrame: @escaping @Sendable (IBNalFrame) -> Void) async throws {
        self.onFrame = onFrame
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try createSession()
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func createSession() throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw NSError(domain: "iBridge.H264", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed"])
        }

        // Configure the session for real-time, low-latency H.264.
        // iOS 26 SDK: hardware encoding is the default.
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime:                true,
            kVTCompressionPropertyKey_AllowFrameReordering:    false,
            kVTCompressionPropertyKey_ProfileLevel:            kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate:          bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate:       fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval:     fps,
            kVTCompressionPropertyKey_Quality:                 0.7
        ]

        let setStatus = VTSessionSetProperties(session, propertyDictionary: props as CFDictionary)
        guard setStatus == noErr else {
            throw NSError(domain: "iBridge.H264", code: Int(setStatus),
                          userInfo: [NSLocalizedDescriptionKey: "VTSessionSetProperties failed"])
        }

        VTCompressionSessionPrepareToEncodeFrames(session)

        self.compressionSession = session
        self.isReady = true
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    /// Live-forensics counters (visible via devicectl --console stderr).
    /// Comparing capture-in vs encode-out tells us which stage silently
    /// stopped when video goes black.
    private var captureInCount = 0
    private var encodeOutCount = 0
    private var encodeErrorCount = 0
    private var droppedCount = 0

    private static func forensic(_ message: String) {
        Forensic.log("[video-forensic] \(message)")
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        droppedCount += 1
        if droppedCount % 30 == 1 {
            Self.forensic("capture DID DROP frames: \(droppedCount) total")
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        captureInCount += 1
        if captureInCount % 300 == 0 {
            Self.forensic("capture frames IN: \(captureInCount) (out=\(encodeOutCount) err=\(encodeErrorCount) drop=\(droppedCount))")
            Self.forensic("capture luma probe: \(Self.lumaProbe(sampleBuffer)) (avg 0 = camera delivering black)")
        }
        if Self.dumpFramesEnabled && (captureInCount == 100 || captureInCount % 1800 == 0) {
            Self.dumpFrame(sampleBuffer, tag: "f\(captureInCount)")
        }
        guard isReady, let session = compressionSession else {
            scheduleSessionRecreation()
            return
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMTime(value: 1, timescale: Int32(fps))

        // iOS 26 SDK: encoder callback signature is
        //   (OSStatus, VTEncodeInfoFlags, CMSampleBuffer?) -> Void
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil,
            outputHandler: { [weak self] callbackStatus, _, outputBuffer in
                guard let self else { return }
                if callbackStatus != noErr || outputBuffer == nil {
                    self.encodeErrorCount += 1
                    if self.encodeErrorCount % 30 == 1 {
                        Self.forensic("VT encode callback FAILED status=\(callbackStatus) bufferNil=\(outputBuffer == nil) (err total=\(self.encodeErrorCount), in=\(self.captureInCount))")
                    }
                    if callbackStatus == kVTInvalidSessionErr {
                        self.scheduleSessionRecreation()
                    }
                    return
                }
                self.processSampleBuffer(outputBuffer!)
            }
        )

        if status != noErr {
            Self.log.error("VTCompressionSessionEncodeFrame failed: \(status)")
            encodeErrorCount += 1
            Self.forensic("VTCompressionSessionEncodeFrame returned \(status) (in=\(captureInCount) out=\(encodeOutCount))")
            if status == kVTInvalidSessionErr {
                scheduleSessionRecreation()
            }
        }
    }

    /// Average luma of the Y plane, coarsely sampled (~1/1024 of
    /// pixels). Distinguishes "camera delivers black" from "encoder
    /// produces black from good input" during forensics.
    private static let dumpFramesEnabled =
        ProcessInfo.processInfo.environment["IBRIDGE_DUMP_FRAMES"] == "1"

    /// Write a JPEG of the raw camera frame to Documents so forensics
    /// can SEE what the sensor delivered (numbers lie less than eyes).
    private static func dumpFrame(_ sampleBuffer: CMSampleBuffer, tag: String) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = CIContext().jpegRepresentation(
                of: image, colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
        else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("frame-\(tag).jpg")
        do {
            try data.write(to: url)
            forensic("frame dumped: \(url.lastPathComponent) \(data.count) bytes")
        } catch {
            forensic("frame dump FAILED: \(error.localizedDescription)")
        }
    }

    /// Average luma of the Y plane, coarsely sampled (~1/1024 of
    /// pixels). Distinguishes "camera delivers black" from "encoder
    /// produces black from good input" during forensics.
    private static func lumaProbe(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return "n/a" }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return "n/a \(w)x\(h)" }
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard height > 0, bytesPerRow > 0 else { return "n/a \(w)x\(h)" }
        var sum = 0
        var count = 0
        var row = 0
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        while row < height {
            let rowPtr = ptr.advanced(by: row * bytesPerRow)
            var col = 0
            while col < bytesPerRow {
                sum += Int(rowPtr[col])
                count += 1
                col += 32
            }
            row += 32
        }
        let avg = count > 0 ? sum / count : -1
        return "avg=\(avg) \(w)x\(h)"
    }

    /// Invalidate and rebuild the compression session. Runs on the
    /// encoder queue; throttled to one attempt per second so a session
    /// that can't come up yet (still backgrounded) doesn't spin.
    private func scheduleSessionRecreation() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.recreationPending,
                  Date().timeIntervalSince(self.lastRecreationAt) > 1 else { return }
            self.recreationPending = true
            self.lastRecreationAt = Date()
            defer { self.recreationPending = false }
            Self.forensic("recreating VTCompressionSession (was invalid)")
            if let old = self.compressionSession {
                VTCompressionSessionInvalidate(old)
            }
            self.compressionSession = nil
            self.isReady = false
            // Reset cached parameter sets so the first frame from the new
            // session re-emits SPS/PPS — the Mac reconfigures its decoder.
            self.lastSPS = nil
            self.lastPPS = nil
            do {
                try self.createSession()
                Self.forensic("VTCompressionSession recreated OK (in=\(self.captureInCount) out=\(self.encodeOutCount))")
            } catch {
                Self.forensic("VTCompressionSession recreation FAILED: \(error.localizedDescription)")
            }
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            self?.processSampleBufferSync(sampleBuffer)
        }
    }

    private func processSampleBufferSync(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)

        var data = Data(count: totalLength)
        let copyStatus = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        // Walk the AVCC NAL units (4-byte length prefix).
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = UInt64(CMTimeGetSeconds(pts) * 1_000_000)

        // VideoToolbox in AVCC mode keeps SPS/PPS in the format
        // description, never in the bitstream — the receiver's decoder
        // can't start without them, so pull them out and emit once.
        if lastSPS == nil || lastPPS == nil {
            emitParameterSets(from: sampleBuffer, micros: micros)
        }

        var offset = 0
        while offset + 4 <= totalLength {
            let length = UInt32(data[offset]) << 24 |
                         UInt32(data[offset + 1]) << 16 |
                         UInt32(data[offset + 2]) << 8 |
                         UInt32(data[offset + 3])
            let nalStart = offset + 4
            let nalEnd = nalStart + Int(length)
            guard nalEnd <= totalLength else { break }
            guard nalEnd > nalStart else {
                // Zero-length NAL unit — skip the 4-byte prefix and move on.
                offset = nalStart
                continue
            }

            // Note: `data[nalStart..<nalEnd]` produces a slice whose
            // startIndex is `nalStart`, not 0 — never subscript it with [0].
            let nalUnitType = data[nalStart] & 0x1F
            let nalSlice = data[nalStart..<nalEnd]

            if nalUnitType == 7 {
                lastSPS = Data(nalSlice)
                onFrame?(IBNalFrame(kind: .sps, data: Data(nalSlice), timestampMicros: micros))
            } else if nalUnitType == 8 {
                lastPPS = Data(nalSlice)
                onFrame?(IBNalFrame(kind: .pps, data: Data(nalSlice), timestampMicros: micros))
            } else if nalUnitType == 1 || nalUnitType == 5 {
                encodeOutCount += 1
                if encodeOutCount % 300 == 0 {
                    Self.forensic("encoded frames OUT: \(encodeOutCount) (in=\(captureInCount) err=\(encodeErrorCount))")
                }
                onFrame?(IBNalFrame(kind: .video, data: Data(nalSlice), timestampMicros: micros))
            }
            // SEI (6), AUD (9) and friends are skipped: the receiver feeds
            // each wire frame straight into a VTDecompressionSession, and
            // non-VCL-only samples come back as kVTVideoDecoderBadDataErr.

            offset = nalEnd
        }
    }

    /// Extract SPS/PPS from the compressed sample buffer's format
    /// description and emit them as wire frames. Called only until both
    /// have been seen; `lastSPS`/`lastPPS` cache them for keyframe
    /// re-sends via the in-stream walk above.
    private func emitParameterSets(from sampleBuffer: CMSampleBuffer, micros: UInt64) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        var paramCount = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil
        ) == noErr else { return }

        for index in 0..<paramCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer, size > 0 else { continue }
            let data = Data(bytes: pointer, count: size)
            switch data[data.startIndex] & 0x1F {
            case 7:
                lastSPS = data
                onFrame?(IBNalFrame(kind: .sps, data: data, timestampMicros: micros))
            case 8:
                lastPPS = data
                onFrame?(IBNalFrame(kind: .pps, data: data, timestampMicros: micros))
            default:
                break
            }
        }
        if lastSPS != nil && lastPPS != nil {
            Self.log.info("SPS/PPS extracted from format description")
        }
    }
}