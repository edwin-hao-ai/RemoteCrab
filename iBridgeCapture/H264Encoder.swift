import AVFoundation
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

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isReady, let session = compressionSession else { return }
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
            outputHandler: { [weak self] _, _, outputBuffer in
                guard let self, let outputBuffer else { return }
                self.processSampleBuffer(outputBuffer)
            }
        )

        if status != noErr {
            Self.log.error("VTCompressionSessionEncodeFrame failed: \(status)")
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