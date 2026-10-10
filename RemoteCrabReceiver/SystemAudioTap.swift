//
//  SystemAudioTap.swift
//
//  Captures the Mac's own audio so the iPhone can play it — the "use the
//  iPhone as the speaker" feature.
//
//  How it works, and why this and not a virtual output device: a CoreAudio
//  *process tap* is a user-mode tap on every audio process. Nothing is
//  installed, no output device is added, and — the part that makes it feel
//  like AirPlay rather than a hack — the tap's mute behaviour silences the
//  Mac's own hardware while we read it, and the moment we stop reading, the
//  audio goes back to the speakers. So a phone disconnect restores sound by
//  itself instead of stranding the user in silence.
//
//  Measured on macOS 26 while building this (a throwaway harness, not a
//  guess):
//    * the tap hands back 48 kHz / 2ch / float32 interleaved, ready-made
//    * 512 frames per callback = 10.67 ms, so two callbacks make one 20 ms
//      Opus-shaped packet
//    * it captures the mix REGARDLESS of which output device apps play to —
//      a tone sent to an unrelated virtual output device was captured at the
//      same level as one sent to the built-in speakers
//
//  Everything here runs on the CoreAudio real-time thread except the packet
//  drain, so the IOProc allocates nothing, takes no lock, and logs nothing.
//

import AVFoundation
import CoreAudio
import CoreGraphics
import RemoteCrabCore
import Foundation
import os.log

// MARK: - Errors

/// Every case carries what to DO, not just what went wrong. A status line
/// that reports a failure without an action leaves the user stuck (rule 1).
public enum SystemAudioTapError: LocalizedError, Equatable {
    /// Screen Recording was not granted. Required to create a process tap.
    case screenRecordingNotGranted
    /// The host has no Opus/PCM tap support, or the tap object was refused.
    case tapUnavailable(OSStatus)
    /// The tap exists but could not be hosted in a readable device.
    case noReadableDevice(OSStatus)
    /// Already running — callers should treat this as success.
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .screenRecordingNotGranted:
            // Localized, and short. This string is drawn as a menu-bar subtitle:
            // it used to be a three-sentence English paragraph, so a Chinese menu
            // showed English, and two rows rendering it at once overlapped into
            // an unreadable block. The action it names — "Finish Setup…" — is a
            // row of its own at the top of the same menu.
            return String(IBLocale.Speaker.tapNeedsScreenRecording)
        case .tapUnavailable(let status):
            return String(format: IBLocale.Speaker.tapUnavailable, Int(status))
        case .noReadableDevice(let status):
            return String(format: IBLocale.Speaker.tapNotReadable, Int(status))
        case .alreadyRunning:
            return String(IBLocale.Speaker.tapAlreadyRunning)
        }
    }
}

// MARK: - Mute behaviour

/// What happens to the Mac's own speakers while the phone is playing.
public enum SystemAudioTapMute: String, Sendable, CaseIterable {
    /// AirPlay semantics: the Mac goes quiet while the phone plays, and the
    /// sound comes back by itself the moment the phone stops or disconnects.
    case muteWhileTapped
    /// The Mac keeps playing as well as sending. Correct when the Mac has
    /// no speakers to silence, or when the user wants both.
    case keepLocalAudio
}

// MARK: - The tap

/// Thread-safe facade over the CoreAudio tap. All CoreAudio calls are made
/// here; the realtime callback only touches the ring.
public final class SystemAudioTap: @unchecked Sendable {

    /// One 20 ms packet at 48 kHz stereo Int16.
    public static let framesPerPacket: Int = 960
    public static let channels = 2
    public static let sampleRate = 48_000.0
    private static let bytesPerFrame = MemoryLayout<Int16>.size * channels
    public static let packetByteCount = framesPerPacket * bytesPerFrame

    /// 500 ms of slack. Sized so a GC pause or a slow drain does not lose
    /// audio; overflow drops the OLDEST frames, because for live audio a
    /// late packet is worth less than a fresh one.
    private static let ringFrames = 24_000

    private static let log = OSLog(subsystem: "com.remotecrab", category: "speaker-tap")

    private let lock = NSLock()
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var isRunning = false

    // Lock-free single-producer/single-consumer ring. `writeIndex` is only
    // touched by the realtime IOProc, `readIndex` only by the drain.
    private let ring: UnsafeMutablePointer<Int16>
    private var writeIndex: UInt64 = 0
    private var readIndex: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var receivedFrames: UInt64 = 0
    private var energySum: Double = 0
    private var energyCount: Int = 0
    private var peakSeen: Int = 0
    /// Frames the callback had to discard. Written by the callback, drained
    /// by the pump — never applied to `readIndex` from the realtime thread.
    private var pendingDrops: UInt64 = 0
    /// A probe of the most recently written ring slot, so a run can tell
    /// "the ring holds zeros" from "the ring holds audio and the reader is
    /// looking in the wrong place".
    public private(set) var newestRingSample: Int = 0
    public private(set) var lastAvailableFrames: UInt64 = 0

    /// Signal level of everything the tap has delivered. This is the only way
    /// to tell "the tap is not running" from "the tap is running and the
    /// system is silent" from "the tap is running and carrying audio" — three
    /// states that look identical in the packet counts alone.
    public private(set) var capturedRms: Double = 0
    public private(set) var capturedPeak: Int = 0

    public init() {
        ring = .allocate(capacity: Self.ringFrames * Self.channels)
        ring.initialize(repeating: 0, count: Self.ringFrames * Self.channels)
    }

    deinit {
        stop()
        ring.deinitialize(count: Self.ringFrames * Self.channels)
        ring.deallocate()
    }

    public var running: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunning
    }

    /// Frames the tap delivered that the drain did not keep up with. Surfaced
    /// so an e2e run can assert on audio actually arriving rather than on the
    /// feature merely reporting itself on.
    public var droppedFrameCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return droppedFrames
    }

    public var capturedFrameCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return receivedFrames
    }

    // MARK: - Start / stop

    /// Start capturing. Idempotent by design: the feature can be toggled from
    /// the menu bar, from the phone, and from a `featureControl` echo in any
    /// order, so "already running" must be a no-op rather than an error.
    @discardableResult
    public func start(mute: SystemAudioTapMute = .muteWhileTapped) throws -> Bool {
        lock.lock()
        if isRunning {
            lock.unlock()
            return false
        }
        lock.unlock()

        // A tap is an audio *capture* surface, so it needs Screen Recording.
        // Checked up front so the failure names the thing the user can fix
        // instead of surfacing as an opaque CoreAudio status.
        guard CGPreflightScreenCaptureAccess() else {
            throw SystemAudioTapError.screenRecordingNotGranted
        }

        let sys = AudioHardwareSystem.shared

        // Exclude our own process: anything this app plays must not be fed
        // back into the stream we are sending to the phone.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let excluded: [AudioObjectID]
        if let me = (try? sys.processes)?.first(where: { (try? $0.pid) == myPID }) {
            excluded = [me.id]
        } else {
            excluded = []
        }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "RemoteCrab Speaker Tap"
        desc.isPrivate = true
        // `mutedWhenTapped` = captured by us AND not sent to the hardware
        // while we are reading; the hardware resumes the moment we stop.
        desc.muteBehavior = (mute == .muteWhileTapped)
            ? CATapMuteBehavior.mutedWhenTapped
            : CATapMuteBehavior.unmuted

        guard let tap = try? sys.makeProcessTap(description: desc) else {
            throw SystemAudioTapError.tapUnavailable(0)
        }
        let tapUID = (try? tap.uid) ?? ""

        // A tap is not a device, so it has to be hosted in an aggregate
        // device to be read through an IOProc.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "RemoteCrab Speaker Tap",
            kAudioAggregateDeviceUIDKey as String: "com.remotecrab.speakertap.\(myPID)",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapListKey as String: [[kAudioSubTapUIDKey as String: tapUID]],
        ]
        guard let aggregate = try? sys.makeAggregateDevice(description: aggregateDescription) else {
            try? sys.destroyProcessTap(tap)
            throw SystemAudioTapError.noReadableDevice(0)
        }

        guard let inputStream = ((try? aggregate.streams) ?? []).first(where: { stream in
            ((try? stream.direction) == .input)
        }) else {
            try? sys.destroyAggregateDevice(aggregate)
            try? sys.destroyProcessTap(tap)
            throw SystemAudioTapError.noReadableDevice(0)
        }

        // Ask for the format the packet format wants. The tap already
        // defaults to 48 kHz stereo float32, but being explicit means a
        // future default change cannot silently halve the frame size.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * Self.channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * Self.channels),
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var status = withUnsafePointer(to: &asbd) { pointer in
            pointer.withMemoryRebound(to: UInt8.self,
                                      capacity: MemoryLayout<AudioStreamBasicDescription>.size) {
                AudioObjectSetPropertyData(inputStream.id, &inputAddress, 0, nil,
                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size), $0)
            }
        }
        guard status == noErr else {
            try? sys.destroyAggregateDevice(aggregate)
            try? sys.destroyProcessTap(tap)
            throw SystemAudioTapError.noReadableDevice(status)
        }

        var procID: AudioDeviceIOProcID!
        // The IOProc must be a NON-capturing closure (a C function pointer),
        // so the instance travels through CoreAudio's own `inRefCon` slot
        // rather than a Swift capture — a `[weak self]` capture here does not
        // compile, and a strong one would keep the tap alive forever and make
        // `deinit` unreachable. `passUnretained` is safe because `deinit`
        // stops IO before releasing anything.
        // The 7th parameter is `inClientData` — CoreAudio's refCon slot for
        // a client IOProc. (There is no refCon in slot 1; that is inDevice.)
        status = AudioDeviceCreateIOProcID(aggregate.id, { _, _, inData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let tap = Unmanaged<SystemAudioTap>.fromOpaque(clientData).takeUnretainedValue()
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            // `ingest` treats every buffer as INTERLEAVED stereo (it reads
            // (L,R) pairs). A live tap was measured doing exactly that — one
            // 2-channel interleaved buffer — and CoreAudio holds to it, but
            // if it ever hands back two planar 1-channel buffers, pairs read
            // out of the left buffer play that channel at twice its rate. The
            // packet would still be exactly 3840 bytes and the ring would
            // still drain on time, so nothing else here would notice; the
            // symptom would be pitch, on the phone, with a clean log.
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard sampleCount > 0 else { continue }
                // Straight into the ring: this is the realtime thread, so no
                // allocation, no Array, no copy through a scratch buffer.
                data.assumingMemoryBound(to: Float.self)
                    .withMemoryRebound(to: Float.self, capacity: sampleCount) { pointer in
                        tap.ingest(UnsafeBufferPointer(start: pointer, count: sampleCount))
                    }
            }
            return noErr
        }, Unmanaged.passUnretained(self).toOpaque(), &procID)
        guard status == noErr else {
            try? sys.destroyAggregateDevice(aggregate)
            try? sys.destroyProcessTap(tap)
            throw SystemAudioTapError.noReadableDevice(status)
        }

        status = AudioDeviceStart(aggregate.id, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
            try? sys.destroyAggregateDevice(aggregate)
            try? sys.destroyProcessTap(tap)
            throw SystemAudioTapError.noReadableDevice(status)
        }

        lock.lock()
        self.tapID = tap.id
        self.aggregateID = aggregate.id
        self.ioProcID = procID
        self.description = desc
        self.isRunning = true
        writeIndex = 0
        readIndex = 0
        droppedFrames = 0
        receivedFrames = 0
        energySum = 0
        energyCount = 0
        peakSeen = 0
        capturedRms = 0
        capturedPeak = 0
        pendingDrops = 0
        newestRingSample = 0
        lastAvailableFrames = 0
        lock.unlock()

        os_log("tap started: mute=%{public}@ aggregate=%u", Self.log,
               mute == .muteWhileTapped ? "yes" : "no", aggregate.id)
        return true
    }

    private var inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// Public stop. Safe to call when not running (the feature can be toggled
    /// from two sides at once).
    public func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        let aggregate = aggregateID
        let proc = ioProcID
        let tap = tapID
        isRunning = false
        ioProcID = nil
        aggregateID = 0
        tapID = 0
        description = nil
        lock.unlock()

        let sys = AudioHardwareSystem.shared
        if let proc { AudioDeviceStop(aggregate, proc) }
        if let proc { AudioDeviceDestroyIOProcID(aggregate, proc) }
        try? sys.destroyAggregateDevice(AudioHardwareAggregateDevice(id: aggregate))
        if tap != 0 { try? sys.destroyProcessTap(AudioHardwareTap(id: tap)) }
        os_log("tap stopped", Self.log)
    }

    // MARK: - Realtime ingest

    /// Called on the CoreAudio realtime thread. No allocation, no locks, no
    /// logging. Converts to Int16 and appends into the ring, dropping the
    /// oldest frames if the drain has fallen behind.
    private func ingest(_ interleaved: UnsafeBufferPointer<Float>) {
        let capacity = UInt64(Self.ringFrames)
        var w = writeIndex
        let count = interleaved.count
        var i = 0

        // The tap is configured for interleaved stereo, so a whole frame is
        // an (L, R) pair. Copying one value into both slots instead would
        // silently downmix stereo to mono, which is the exact defect this
        // feature exists to avoid — so a short (odd) buffer is handled as
        // mono explicitly and visibly, not smeared across both channels.
        //
        // MEASURED, not assumed: a standalone probe of a live tap (asking for
        // exactly the format above) reported `buffers=1 channels=2 flags=0x9`
        // — one interleaved 2-channel buffer, `IsNonInterleaved` clear — and
        // 48,213 frames/s against a wanted 48,000, unchanged while playing
        // both 44.1 kHz and 48 kHz sources. CoreAudio resamples to the
        // requested rate, so this pairing holds whatever the system output
        // is doing. A planar reply would read the left channel at twice its
        // rate here, which is the symptom the phone side had instead.
        while i + 1 < count {
            let slot = Int(w % capacity) * Self.channels
            ring[slot] = Self.clampToInt16(interleaved[i])
            ring[slot + 1] = Self.clampToInt16(interleaved[i + 1])
            w &+= 1
            i &+= 2
        }
        if i < count {
            // Odd trailing sample: the stream is mono, so mirror it.
            let slot = Int(w % capacity) * Self.channels
            let value = Self.clampToInt16(interleaved[i])
            ring[slot] = value
            ring[slot + 1] = value
            w &+= 1
            receivedFrames &+= 1
        }
        writeIndex = w
        receivedFrames &+= UInt64(i / 2 * 2)

        // Realtime-safe: no allocation, no locks. Sum of squares over the
        // window, reported by the drain.
        var sum = 0.0
        var peak = 0
        var j = 0
        while j + 1 < count {
            let l = Self.clampToInt16(interleaved[j])
            let r = Self.clampToInt16(interleaved[j + 1])
            sum += Double(l) * Double(l) + Double(r) * Double(r)
            let al = abs(Int(l)), ar = abs(Int(r))
            if al > peak { peak = al }
            if ar > peak { peak = ar }
            j &+= 2
        }
        energySum += sum
        energyCount += count
        if peak > peakSeen { peakSeen = peak }
        newestRingSample = peak

        var dropped: UInt64 = 0

        // Two threads writing one index is the bug (lesson 125): the pump
        // advances `readIndex` to consume, and the callback used to reset it
        // here on overflow. Two writers means the unsigned
        // `writeIndex &- readIndex` can wrap, so the "do we have a packet"
        // guard passes on garbage and the pump reads slots that are not the
        // ones it thinks. So the callback only *counts* what must go and the
        // PUMP is the sole owner of `readIndex`.
        let gap = w &- readIndex
        if gap > capacity {
            dropped = gap - capacity
            pendingDrops += dropped
        }
    }

    @inline(__always)
    private static func clampToInt16(_ value: Float) -> Int16 {
        SpeakerSample.clampToInt16(value)
    }

    // MARK: - Drain (not realtime)

    /// Pull one 20 ms stereo Int16 packet, or nil if not enough audio has
    /// arrived yet. Returns the raw PCM for `IBWire.encode(speakerAudio:)`.
    public func takePacket() -> Data? {
        lock.lock()
        let running = isRunning
        lock.unlock()
        guard running else { return nil }

        // Apply whatever the callback had to discard, first — otherwise the
        // gap keeps growing and every read is of data older than the ring.
        let toDrop = pendingDrops
        pendingDrops = 0
        if toDrop > 0 {
            readIndex &+= toDrop
            droppedFrames &+= toDrop
        }

        let available = writeIndex &- readIndex
        lastAvailableFrames = available
        guard available >= UInt64(Self.framesPerPacket) else { return nil }

        var samples = [Int16](repeating: 0, count: Self.framesPerPacket * Self.channels)
        let start = readIndex
        samples.withUnsafeMutableBufferPointer { out in
            for frame in 0..<Self.framesPerPacket {
                let ringIndex = Int((start &+ UInt64(frame)) % UInt64(Self.ringFrames))
                out[frame * Self.channels] = ring[ringIndex * Self.channels]
                out[frame * Self.channels + 1] = ring[ringIndex * Self.channels + 1]
            }
        }
        readIndex &+= UInt64(Self.framesPerPacket)
        capturedRms = energyCount > 0 ? (energySum / Double(energyCount)).squareRoot() : 0
        capturedPeak = peakSeen
        return samples.withUnsafeBytes { Data($0) }
    }
}