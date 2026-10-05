// Does the SHIPPING encoder configuration produce B-frames?
//
// Why this exists. `docs/HANDOFF-MAC-SIDE-2026-10-04.md` §1 concluded that the
// Windows receiver's corruption is because "the phone emits B-frames and
// OpenH264's DecodeFrameNoDelay cannot reorder them", on the evidence of
// `docs/demo/remotecrab-demo.mp4`. That file is produced by
// `scripts/demo-video.sh:99` with `-c:v libx264` from a macOS screen capture,
// so its `has_b_frames=2` is libx264's, not the phone's.
//
// So the question is open, and it decides whether iOS needs
// `kVTCompressionPropertyKey_NumberOfBFramesBetweenReferenceFrames: 0`. It is
// answerable without a phone: the encoder is configured entirely by keys, and
// this runs the same keys through the same VideoToolbox encoder and hands the
// output to ffprobe.
//
// WHAT THIS DOES AND DOES NOT PROVE. Same key names and same SDK, on macOS
// rather than iOS, so it can falsify the hypothesis — if B-frames appear under
// these exact keys, the bug is live — but it cannot prove an iPhone emits none.
// The device check is still the one in the handoff.
//
// It also refuses to run if `H264Encoder.createSession` no longer sets the keys
// it reads, because a probe that silently keeps measuring last month's
// configuration is exactly the "inherited number" trap (AGENTS.md rule 3).
//
// Run:  swift scripts/vt-bframe-probe.swift [out.h264]
// Then: ffprobe -v error -select_streams v:0 -show_entries stream=profile,has_b_frames,refs -of default=nw=1 out.h264

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

let width = 1920, height = 1080, fps = 30, frames = 150
let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.temporaryDirectory.appendingPathComponent("vt-bframes.h264").path

/// `shipping` is the configuration `H264Encoder.createSession` applies.
/// `reorder` is the control: the same encode with frame reordering ENABLED.
///
/// The control is the point of this file. A probe that reads `has_b_frames=0`
/// from a configuration it cannot see B-frames in proves nothing, so the same
/// code must be shown to report `> 0` when reordering is on. If both runs print
/// 0, the probe is blind and its verdict is worthless.
enum Mode: String {
    case shipping
    case reorder
}

let mode = Mode(rawValue: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "shipping") ?? .shipping
let allowReordering = (mode == .reorder)

// MARK: - Read the shipping configuration instead of repeating it

let encoderSource = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("RemoteCrabCapture/H264Encoder.swift")
guard let source = try? String(contentsOf: encoderSource, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read H264Encoder.swift\n".utf8))
    exit(2)
}

/// The keys the phone sets, as (source substring, the value this probe uses).
/// If a key is renamed or removed from `createSession`, the substring stops
/// matching and the probe fails instead of measuring something stale.
let shippingKeys: [(needle: String, applied: String)] = [
    ("kVTCompressionPropertyKey_RealTime", "true"),
    ("kVTCompressionPropertyKey_AllowFrameReordering", "false"),
    ("kVTCompressionPropertyKey_ProfileLevel", "kVTProfileLevel_H264_Main_AutoLevel"),
    ("kVTCompressionPropertyKey_AverageBitRate", "bitrate"),
    ("kVTCompressionPropertyKey_ExpectedFrameRate", "fps"),
    ("kVTCompressionPropertyKey_MaxKeyFrameInterval", "VideoEncodingPolicy"),
    ("kVTCompressionPropertyKey_Quality", "VideoEncodingPolicy.quality"),
]
var missing: [String] = []
for key in shippingKeys where !source.contains(key.needle) {
    missing.append(key.needle)
}
if !missing.isEmpty {
    FileHandle.standardError.write(Data("""
    H264Encoder.createSession no longer sets:
      \(missing.joined(separator: "\n  "))

    This probe measures the keys listed above, so it would now be measuring a
    configuration the app does not use. Update it, or delete it if the encoder
    moved to an explicit frame-properties path.

    """.utf8))
    exit(2)
}
print("H264Encoder.createSession still sets all \(shippingKeys.count) keys this probe applies.")
print("mode: \(mode.rawValue) (AllowFrameReordering = \(allowReordering))\n")

// MARK: - A scene that is hard to compress

func makePixelBuffer() -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }

    // Deterministic noise. A flat frame encodes tiny under ANY settings and
    // would make the experiment vacuous — the encoder could drop B-frames on a
    // static scene and we would read that as "no B-frames ever".
    var seed: UInt64 = 0x9E3779B97F4A7C15
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let yPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<CVPixelBufferGetHeightOfPlane(pb, 0) {
        for col in 0..<yStride {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            yPlane[row * yStride + col] = UInt8(truncatingIfNeeded: seed >> 24)
        }
    }
    // 420 biplanar has TWO planes: Y, then interleaved CbCr. There is no
    // plane 2 — reaching for one is an unwrap crash, not a chroma plane.
    for plane in 1..<2 {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        let rows = CVPixelBufferGetHeightOfPlane(pb, plane)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<rows {
            for col in 0..<stride {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                base[row * stride + col] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
    }
    return pb
}

// MARK: - Encode with the shipping keys, collecting Annex-B


var out = Data()
var slices: [Int: Int] = [:]   // NAL type -> count
var parameterSets = Data()     // SPS + PPS, prepended once
var failed = false

var session: VTCompressionSession?
let props: [CFString: Any] = [
    kVTCompressionPropertyKey_RealTime: true,
    kVTCompressionPropertyKey_AllowFrameReordering: allowReordering,
    kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
    // `VideoEncodingPolicy.bitrate(width:height:fps:)` = 1920*1080*30*0.15
    kVTCompressionPropertyKey_AverageBitRate: 9_331_200,
    kVTCompressionPropertyKey_ExpectedFrameRate: fps,
    // maxKeyFrameInterval(fps:) = fps * keyframeIntervalSeconds = 30 * 2
    kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
    kVTCompressionPropertyKey_Quality: Float(0.75),
]

let created = VTCompressionSessionCreate(
    allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
    codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
    imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: nil, refcon: nil, compressionSessionOut: &session)
guard created == noErr, let session else {
    FileHandle.standardError.write(Data("VTCompressionSessionCreate failed: \(created)\n".utf8))
    exit(1)
}
guard VTSessionSetProperties(session, propertyDictionary: props as CFDictionary) == noErr else {
    FileHandle.standardError.write(Data("VTSessionSetProperties failed\n".utf8))
    exit(1)
}
VTCompressionSessionPrepareToEncodeFrames(session)

for index in 0..<frames {
    guard let pb = makePixelBuffer() else { failed = true; break }
    var flags = VTEncodeInfoFlags()
    let status = VTCompressionSessionEncodeFrame(
        session, imageBuffer: pb,
        presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)),
        duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
        frameProperties: nil, infoFlagsOut: &flags,
        outputHandler: { cbStatus, _, buffer in
            guard cbStatus == noErr, let buffer,
                  let block = CMSampleBufferGetDataBuffer(buffer) else {
                failed = true; return
            }

            // VideoToolbox does NOT put SPS/PPS in the callback output when the
            // session was created without an explicit format description — the
            // first run of this probe produced 3 IDRs and no parameter sets at
            // all, and ffprobe's answer was "non-existing PPS 0 referenced",
            // profile=unknown, width=0. The app reads them off the format
            // description instead (`H264Encoder.emitParameterSets`), and so does
            // this, or every downstream number is read off an undecodable file.
            if parameterSets.isEmpty,
               let format = CMSampleBufferGetFormatDescription(buffer) {
                var count = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: nil)
                for index in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                        let pointer, size > 0 else { continue }
                    parameterSets.append(contentsOf: [0, 0, 0, 1])
                    parameterSets.append(contentsOf: UnsafeBufferPointer(start: pointer, count: size))
                    slices[Int(pointer[0]) & 0x1F, default: 0] += 1
                }
            }

            let length = CMBlockBufferGetDataLength(block)
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block,
                                              atOffset: 0,
                                              lengthAtOffsetOut: nil,
                                              totalLengthOut: nil,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { failed = true; return }
            let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)

            // VideoToolbox hands back length-prefixed AVCC, which is NOT a
            // stream ffprobe can read — the first version of this probe wrote
            // it out unchanged and ffprobe reported "missing picture in access
            // unit", profile=unknown, width=0. It has to be converted to
            // Annex-B (start code + payload) or every downstream number is
            // read off a file nothing can parse.
            //
            // Both framings are handled because which one arrives depends on
            // the encoder, and guessing wrong is silent.
            let isAnnexB = length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 1
            if isAnnexB {
                out.append(contentsOf: UnsafeBufferPointer(start: bytes, count: length))
                if length >= 5 {
                    let type = Int(bytes[4]) & 0x1F
                    slices[type, default: 0] += 1
                }
                return
            }
            var at = 0
            while at + 4 <= length {
                let nalLength = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16
                    | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
                at += 4
                // A length that cannot fit the rest means this is not AVCC after
                // all; stop rather than emit a corrupt stream.
                guard nalLength > 0, at + nalLength <= length else { break }
                out.append(contentsOf: [0, 0, 0, 1])
                out.append(contentsOf: UnsafeBufferPointer(start: bytes + at, count: nalLength))
                slices[Int(bytes[at]) & 0x1F, default: 0] += 1
                at += nalLength
            }
        })
    if status != noErr { failed = true; break }
}
VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
VTCompressionSessionInvalidate(session)

if failed || out.isEmpty {
    FileHandle.standardError.write(Data("encode produced nothing usable\n".utf8))
    exit(1)
}
guard !parameterSets.isEmpty else {
    FileHandle.standardError.write(Data("""
    no SPS/PPS in the format description, so the file would be undecodable.
    VideoToolbox is expected to describe its own parameter sets here; if this
    fires, the probe and H264Encoder.emitParameterSets need the same fix.

    """.utf8))
    exit(1)
}

try? (parameterSets + out).write(to: URL(fileURLWithPath: outPath))

print("mode \(mode.rawValue): encoded \(frames) frames, \(out.count) bytes -> \(outPath)")
print("NAL types present (type: count):")
for type in slices.keys.sorted() {
    let name: String
    switch type {
    case 1: name = "non-IDR slice"
    case 5: name = "IDR slice"
    case 6: name = "SEI"
    case 7: name = "SPS"
    case 8: name = "PPS"
    default: name = "other"
    }
    print(String(format: "  %2d: %-5d %@", type, slices[type]!, name))
}
print("")
if slices[5] != nil, slices[5]! > 0 {
    print("VERDICT: IDR frames present (\(slices[5]!)). Now ask ffprobe for has_b_frames —")
    print("         has_b_frames > 0 means the Windows B-frame hypothesis is LIVE.")
} else {
    print("VERDICT: no IDR in this run — the encode is suspect, do not read anything into it.")
}
print("")
print("Run ffprobe on it for the authoritative answer:")
print("  ffprobe -v error -select_streams v:0 -show_entries stream=profile,has_b_frames,refs \\")
print("          -of default=nw=1 \(outPath)")