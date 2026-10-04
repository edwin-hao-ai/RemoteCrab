// Does kVTCompressionPropertyKey_AverageBitRate or kVTCompressionPropertyKey_Quality
// decide how many bits this encoder actually emits?
//
// The phone sets BOTH. The SDK header documents neither as taking precedence, and
// the phone reports its *requested* rate in IBStreamMetadata — so a bigger number
// there is not evidence of a sharper picture. This runs the real encoder over a
// synthetic scene and prints the achieved rate for each combination.
//
// Run: swift scripts/vt-bitrate-probe.swift
// (2x2: requested rate x quality present/absent. If the achieved rate tracks
//  AverageBitRate only when Quality is absent, Quality wins and the coefficient
//  in VideoEncodingPolicy is decorative.)

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

let width = 1920, height = 1080, fps = 30, frames = 90
let vtWidth = Int32(width), vtHeight = Int32(height)

/// A noisy, high-detail scene. A flat frame encodes tiny at ANY bitrate, which
/// would make every combination look identical and the experiment vacuous —
/// so the content has to be hard to compress or it proves nothing.
func makePixelBuffer() -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     attrs as CFDictionary, &pb)
    guard status == kCVReturnSuccess, let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }

    let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let yPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    var seed: UInt64 = 0x2545F4914F6CDD1D
    for row in 0..<CVPixelBufferGetHeightOfPlane(pb, 0) {
        for col in 0..<yBytesPerRow {
            // xorshift64 — deterministic, so runs are comparable.
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            yPlane[row * yBytesPerRow + col] = UInt8(truncatingIfNeeded: seed >> 33)
        }
    }
    for plane in 1..<2 {
        let w = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(w * h) { base[i] = 128 }
    }
    return pb
}

func measure(requested: Int, quality: Float?) -> Double {
    var session: VTCompressionSession?
    var props: [CFString: Any] = [
        kVTCompressionPropertyKey_RealTime: true,
        kVTCompressionPropertyKey_AllowFrameReordering: false,
        kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
        kVTCompressionPropertyKey_AverageBitRate: requested,
        kVTCompressionPropertyKey_ExpectedFrameRate: fps,
        kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
    ]
    if let quality { props[kVTCompressionPropertyKey_Quality] = quality }

    let created = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: vtWidth, height: vtHeight,
        codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
        imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard created == noErr, let session else { return -1 }
    guard VTSessionSetProperties(session, propertyDictionary: props as CFDictionary) == noErr else {
        return -2
    }
    VTCompressionSessionPrepareToEncodeFrames(session)

    var totalBytes = 0
    var failed = false

    for index in 0..<frames {
        guard let pb = makePixelBuffer() else { return -3 }
        let forceKey = index % 60 == 0
        let opts = forceKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil as CFDictionary?
        var outFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb,
            presentationTimeStamp: CMTime(value: CMTimeValue(index),
                                         timescale: CMTimeScale(fps)),
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: opts, infoFlagsOut: &outFlags,
            outputHandler: { cbStatus, _, buffer in
                guard cbStatus == noErr, let buffer,
                      let dataBuffer = CMSampleBufferGetDataBuffer(buffer) else {
                    failed = true; return
                }
                totalBytes += CMBlockBufferGetDataLength(dataBuffer)
            })
        if status != noErr { failed = true; break }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(session)

    if failed || totalBytes == 0 { return -1 }
    let seconds = Double(frames) / Double(fps)
    print(String(format: "    frames=%d bytes=%d", frames, totalBytes))
    return Double(totalBytes) * 8.0 / seconds
}

print("VTCompressionSession \(width)x\(height) @ \(fps)fps, \(frames) frames of noise")
print("requested = kVTCompressionPropertyKey_AverageBitRate")
print("")

print("  A. Quality present, AverageBitRate held at 9,331,200")
for q in [Float(0.5), 0.7, 0.75, 0.8, 0.9] {
    let achieved = measure(requested: 9_331_200, quality: q)
    print(String(format: "     quality=%.2f -> achieved=%9.0f kbps", q, achieved / 1000.0))
}
print("")

print("  B. Quality absent, AverageBitRate swept")
for requested in [6_220_800, 9_331_200, 16_000_000] {
    let achieved = measure(requested: requested, quality: nil)
    print(String(format: "     requested=%7d kbps -> achieved=%9.0f kbps  ratio=%.2f",
                 requested / 1000, achieved / 1000.0, achieved / Double(requested)))
}
print("")

print("Read: if section A is flat in AverageBitRate, Quality is what sets the rate,")
print("and the phone's reported bitrate is decorative. Section B ratio ~1.00 means")
print("AverageBitRate is honoured once Quality is out of the property list.")