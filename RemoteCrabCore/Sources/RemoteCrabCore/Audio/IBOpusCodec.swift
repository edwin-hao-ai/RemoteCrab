import AudioToolbox
import Foundation

/// Shared sentinel returned by the input proc when the current fill has
/// consumed all the data we handed it.
///
/// Why this exists: returning `noErr` with zero packets signals
/// end-of-stream, and Apple's Opus converter then finalizes itself
/// PERMANENTLY — every later `AudioConverterFillComplexBuffer` comes
/// back empty (verified on macOS 26: one zero-return kills the encoder;
/// the decoder flushes and goes silent too). Returning any real error
/// instead aborts only the current fill; packets already produced are
/// still delivered and the converter keeps working on the next call.
/// So both codec wrappers treat this exact status as success.
private let kIBOpusInputDrained: OSStatus = 0x6E646E77  // 'ndnw'

/// Opus encoder built on Apple's `AudioConverter` (AudioToolbox C API).
///
/// Why AudioConverter and not AVAudioConverter: AVAudioConverter is
/// reported to mis-handle Opus' VBR packet descriptions, and the C API
/// keeps us on the same code path `afconvert` uses. Why 48 kHz only:
/// Opus internally always runs at 48 kHz and Apple's 16 kHz path is
/// known-flaky, so the sender resamples up front instead of trusting
/// the converter. Why 960 frames per packet: the default from
/// `kAudioFormatProperty_FormatInfo` is 120 (2.5 ms) — afconvert-style
/// 20 ms packets only appear when `mFramesPerPacket` is set to 960
/// explicitly before `AudioConverterNew`.
///
/// Why `final class` + `@unchecked Sendable`: `AudioConverterRef` is a
/// C handle with no Swift concurrency annotations. Each instance is
/// used from exactly one queue (the mic tap thread on iOS, the receiver
/// dispatch path on macOS), so confinement is by construction.
public final class IBOpusEncoder: @unchecked Sendable {

    private let converter: AudioConverterRef

    /// - Returns: nil when the host has no Opus encoder or the sample
    ///   rate isn't supported — callers must fall back to raw PCM.
    public init?(sampleRate: Double = 48_000, bitrate: UInt32 = 24_000) {
        guard sampleRate == 48_000 else { return nil }

        var inASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var outASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFormatGetProperty(
            kAudioFormatProperty_FormatInfo, 0, nil, &asbdSize, &outASBD
        ) == noErr else { return nil }
        outASBD.mFramesPerPacket = 960  // 20 ms @ 48 kHz, see header doc

        var ref: AudioConverterRef?
        guard AudioConverterNew(&inASBD, &outASBD, &ref) == noErr, let ref else { return nil }

        var rate = bitrate
        AudioConverterSetProperty(
            ref, kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size), &rate
        )

        self.converter = ref
    }

    deinit { AudioConverterDispose(converter) }

    /// Encodes one chunk of Int16 mono PCM (960 frames = 20 ms is the
    /// steady-state size; larger chunks produce multiple packets, which
    /// are concatenated into the returned data).
    public func encode(pcm: Data) -> Data? {
        let frameCount = UInt32(pcm.count / 2)
        guard frameCount > 0 else { return nil }

        let context = InputContext(pcm: pcm, frameCount: frameCount)
        let contextPtr = Unmanaged.passRetained(context)

        // Worst case measured via kAudioConverterPropertyMaximumOutput-
        // PacketSize is 750 bytes per 960-frame packet.
        let maxPackets = Int(frameCount / 960) + 2
        let outCapacity = 750 * maxPackets
        let outBuffer = UnsafeMutableRawPointer.allocate(byteCount: outCapacity, alignment: 2)
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(outCapacity),
                mData: outBuffer
            )
        )
        var ioPackets = UInt32(maxPackets)
        // The description array must have room for every packet the
        // fill can emit — the converter writes one entry per packet and
        // overflows the stack if the array is short.
        var packetDescriptions = [AudioStreamPacketDescription](
            repeating: AudioStreamPacketDescription(), count: maxPackets
        )

        defer {
            outBuffer.deallocate()
            contextPtr.release()
        }

        let status = packetDescriptions.withUnsafeMutableBufferPointer { descriptions in
            AudioConverterFillComplexBuffer(
                converter,
                { _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
                    let ctx = Unmanaged<InputContext>.fromOpaque(inUserData!).takeUnretainedValue()
                    guard !ctx.consumed else {
                        ioNumberDataPackets.pointee = 0
                        return kIBOpusInputDrained
                    }
                    ctx.consumed = true
                    ioNumberDataPackets.pointee = ctx.frameCount
                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mNumberChannels = 1
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.pcm.count)
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(
                        mutating: (ctx.pcm as NSData).bytes
                    )
                    if let outDataPacketDescription {
                        outDataPacketDescription.pointee = nil
                    }
                    return noErr
                },
                Unmanaged.passUnretained(context).toOpaque(),
                &ioPackets,
                &bufferList,
                descriptions.baseAddress
            )
        }

        guard status == noErr || status == kIBOpusInputDrained else { return nil }
        let byteCount = Int(bufferList.mBuffers.mDataByteSize)
        guard byteCount > 0, ioPackets > 0 else { return Data() }
        return Data(bytes: outBuffer, count: byteCount)
    }

    /// Box for the input-proc userdata; the proc may be called several
    /// times per fill, so consumption state must outlive one call.
    private final class InputContext {
        let pcm: Data
        let frameCount: UInt32
        var consumed = false
        init(pcm: Data, frameCount: UInt32) {
            self.pcm = pcm
            self.frameCount = frameCount
        }
    }
}

/// Opus decoder, mirror of `IBOpusEncoder`. One packet in, Int16 mono
/// PCM at 48 kHz out. The first packet(s) decode short (~840 frames)
/// because Opus trims its encoder pre-skip — playback just starts a
/// couple of milliseconds late, no special handling needed.
public final class IBOpusDecoder: @unchecked Sendable {

    private let converter: AudioConverterRef

    public init?(sampleRate: Double = 48_000) {
        guard sampleRate == 48_000 else { return nil }

        var inASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFormatGetProperty(
            kAudioFormatProperty_FormatInfo, 0, nil, &asbdSize, &inASBD
        ) == noErr else { return nil }
        inASBD.mFramesPerPacket = 960

        var outASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var ref: AudioConverterRef?
        guard AudioConverterNew(&inASBD, &outASBD, &ref) == noErr, let ref else { return nil }

        self.converter = ref
    }

    deinit { AudioConverterDispose(converter) }

    /// Decodes one Opus packet (20 ms). Returns nil on a corrupt
    /// packet — the caller drops it (one 20 ms hole beats a poisoned
    /// converter).
    public func decode(packet: Data) -> Data? {
        guard !packet.isEmpty else { return nil }

        let context = InputContext(packet: packet)
        let contextPtr = Unmanaged.passRetained(context)

        // 960 frames of Int16 mono; the decoder never emits more than
        // one packet's worth per packet fed.
        let outCapacity = 960 * 2
        let outBuffer = UnsafeMutableRawPointer.allocate(byteCount: outCapacity, alignment: 2)
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(outCapacity),
                mData: outBuffer
            )
        )
        var ioFrames: UInt32 = 960

        defer {
            outBuffer.deallocate()
            contextPtr.release()
        }

        let status = AudioConverterFillComplexBuffer(
            converter,
            { _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
                let ctx = Unmanaged<InputContext>.fromOpaque(inUserData!).takeUnretainedValue()
                guard !ctx.consumed else {
                    ioNumberDataPackets.pointee = 0
                    return kIBOpusInputDrained
                }
                ctx.consumed = true
                ioNumberDataPackets.pointee = 1
                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mNumberChannels = 1
                ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.packet.count)
                ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(
                    mutating: (ctx.packet as NSData).bytes
                )
                // Compressed input MUST come with a packet description —
                // without it the converter can't find the packet
                // boundary and decodes nothing.
                if let outDataPacketDescription {
                    withUnsafeMutablePointer(to: &ctx.packetDescription) { ptr in
                        outDataPacketDescription.pointee = ptr
                    }
                }
                return noErr
            },
            Unmanaged.passUnretained(context).toOpaque(),
            &ioFrames,
            &bufferList,
            nil
        )

        guard status == noErr || status == kIBOpusInputDrained else { return nil }
        let byteCount = Int(bufferList.mBuffers.mDataByteSize)
        guard byteCount > 0 else { return Data() }
        return Data(bytes: outBuffer, count: byteCount)
    }

    private final class InputContext {
        let packet: Data
        var consumed = false
        lazy var packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count)
        )
        init(packet: Data) { self.packet = packet }
    }
}
