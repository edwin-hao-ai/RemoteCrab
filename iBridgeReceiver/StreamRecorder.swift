import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import os

/// Paths in the user's **real** home directory. A sandboxed app's
/// `FileManager` otherwise redirects `~/Downloads` / `~/Movies` into
/// `~/Library/Containers/…`, which is useless to the user. The
/// `files.downloads` / `assets.movies` entitlements grant access to the
/// real folders; `getpwuid` gives us the real home to point at.
enum MacPaths {
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Create (if needed) and return a directory under the real home.
    static func directory(_ relative: String) -> URL {
        let url = realHome.appendingPathComponent(relative, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Records the live iPhone stream to a **single** `.mov` while the
/// session is live: decoded video (H.264) + microphone audio (AAC),
/// muxed by `AVAssetWriter`.
@MainActor
final class StreamRecorder {
    private static let log = Logger(subsystem: "com.ibridge", category: "recorder")

    private(set) var isRecording = false
    private(set) var lastRecordingURL: URL?

    private var outputURL: URL?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioFormat: CMAudioFormatDescription?
    private var videoFrameIndex: Int64 = 0
    private var audioFrameIndex: Int64 = 0
    private let sampleRate: Double = 48_000

    func start() {
        guard !isRecording else { return }
        outputURL = Self.recordingsDirectory()
            .appendingPathComponent("recording-\(Self.stamp()).mov")
        videoFrameIndex = 0
        audioFrameIndex = 0
        audioFormat = Self.makeLPCMFormat(sampleRate: sampleRate)
        isRecording = true
        Self.log.info("recording armed: \(self.outputURL?.lastPathComponent ?? "-", privacy: .public)")
    }

    /// Append one decoded frame; lazily creates the writer (video size is
    /// only known once the first frame arrives) and starts the session.
    func appendVideo(_ image: CGImage) {
        guard isRecording else { return }
        if writer == nil { ensureWriter(width: image.width, height: image.height) }
        guard let adaptor = pixelBufferAdaptor,
              let pool = adaptor.pixelBufferPool,
              adaptor.assetWriterInput.isReadyForMoreMediaData else { return }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        // ~30 fps synthetic constant-rate timeline keeps the file smooth.
        let pts = CMTime(value: videoFrameIndex, timescale: 30)
        if adaptor.append(buffer, withPresentationTime: pts) {
            videoFrameIndex += 1
        }
    }

    /// Append 16-bit mono PCM (`AudioPacket.opusData`) into the muxed movie.
    func appendAudio(_ pcm: Data) {
        guard isRecording,
              let input = audioInput, input.isReadyForMoreMediaData,
              let format = audioFormat,
              let sample = Self.makeSampleBuffer(pcm, format: format, startFrame: audioFrameIndex, sampleRate: sampleRate)
        else { return }
        if input.append(sample) {
            audioFrameIndex += Int64(pcm.count / 2)
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        if writer == nil {
            // No frames ever arrived — nothing to save.
            writer = nil
            return
        }
        lastRecordingURL = outputURL
        let finished = outputURL
        writer?.finishWriting { [weak self] in
            guard self != nil else { return }
            Self.log.info("recording saved: \(finished?.path ?? "-", privacy: .public)")
            if let url = finished {
                Task { @MainActor in
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        writer = nil
        videoInput = nil
        audioInput = nil
        pixelBufferAdaptor = nil
    }

    private func ensureWriter(width: Int, height: Int) {
        guard writer == nil, let url = outputURL,
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else { return }
        writer.add(vInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aInput) { writer.add(aInput) }

        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.videoInput = vInput
        self.audioInput = aInput
    }

    // MARK: - PCM → CMSampleBuffer

    private static func makeLPCMFormat(sampleRate: Double) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    private static func makeSampleBuffer(_ pcm: Data,
                                         format: CMAudioFormatDescription,
                                         startFrame: Int64,
                                         sampleRate: Double) -> CMSampleBuffer? {
        let frames = pcm.count / 2
        guard frames > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pcm.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: pcm.count, flags: 0,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let bb = blockBuffer else { return nil }

        let copied = pcm.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb,
                                                 offsetIntoDestination: 0, dataLength: pcm.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: startFrame, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        return status == noErr ? sampleBuffer : nil
    }

    private static func recordingsDirectory() -> URL {
        MacPaths.directory("Movies/iBridge")
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
