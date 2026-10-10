import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import RemoteCrabCore
import os

/// Feeds decoded camera frames into the camera extension's CMIO **sink**
/// stream.
///
/// The extension exposes one device with two streams: a `.source` stream
/// (device → apps like Zoom) and a `.sink` stream (host → device). An app
/// cannot reach a CMIO extension over custom XPC, so the sink is the
/// sanctioned host → extension channel — this class is a CoreMediaIO
/// client that locates the sink stream and enqueues `CMSampleBuffer`s.
///
/// The extension only accepts a new buffer once it has consumed the
/// previous one (`readyToEnqueue`), which keeps the pipeline in lockstep
/// and bounds memory.
final class CameraSinkFeeder: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.remotecrab", category: "camera-sink")

    /// CoreMediaIO reports an extension's `.sink` (host → device) stream
    /// as direction 0 and its `.source` stream as direction 1 — the
    /// opposite of the raw `kCMIOStreamPropertyDirection` doc wording.
    /// Verified against the running extension; OBS likewise feeds the
    /// second stream. Don't "fix" this to 1 without re-testing.
    private static let sinkDirection: UInt32 = 0

    private let queue = DispatchQueue(label: "com.remotecrab.camera-sink")

    private var running = false
    private var deviceID: CMIODeviceID?
    private var sinkStream: CMIOStreamID?
    /// The **source** stream (device → apps). The client (Zoom, …) picks its
    /// format here; we read it so we can fill the sink at the *same* size — a
    /// mismatch between what we enqueue and what the source advertises breaks
    /// the picture (the extension forwards the buffer straight out).
    private var sourceStream: CMIOStreamID?
    private var sinkQueue: Unmanaged<CMSimpleQueue>?
    private var bufferPool: CVPixelBufferPool?
    private var formatDescription: CMFormatDescription?

    /// Set by the CMIO buffer-queue callback when the extension has
    /// consumed a buffer and can take another.
    private let stateLock = NSLock()
    private var readyToEnqueue = false

    private var attempts = 0
    private var lastFailure = "starting"
    private var enqueueCount = 0
    private var readyCallbackCount = 0
    private var enqueueTick = 0

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = true
            Self.log.info("camera sink feeder started")
            self.makeDevicesVisible()
            self.connectWithRetry()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.teardown()
        }
    }

    /// Enqueue one decoded frame. Cheap no-op while the extension isn't
    /// attached (no device, or no client watching the source stream).
    func feed(image: CGImage) {
        queue.async { [weak self] in
            self?.enqueue(image: image)
        }
    }

    // MARK: - Connection

    private func connectWithRetry() {
        guard running else { return }
        if connect() { return }
        attempts += 1
        if attempts == 1 || attempts % 15 == 0 {
            Self.log.info("camera sink not attached yet (attempt \(self.attempts)) — \(self.lastFailure, privacy: .public)")
        }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.connectWithRetry()
        }
    }

    private func connect() -> Bool {
        guard let device = cmioDevice(uid: IBCameraDevice.uid) else {
            lastFailure = "device not found"
            return false
        }
        let all = streams(of: device)
        guard let sink = all.first(where: { streamDirection($0) == Self.sinkDirection }) else {
            lastFailure = "sink stream not found"
            return false
        }
        // The source stream is the other one (the DAL reports the sink as 0, the
        // source as 1). Read the client's chosen format from it so the buffers
        // we enqueue match what it advertises.
        sourceStream = all.first(where: { streamDirection($0) != Self.sinkDirection })
        syncResolutionFromSource()
        guard prepareBufferPool(), let queue = makeBufferQueue(for: sink) else {
            lastFailure = "buffer queue failed"
            return false
        }

        let status = CMIODeviceStartStream(device, sink)
        guard status == 0 else {
            lastFailure = "CMIODeviceStartStream \(status)"
            Self.log.error("CMIODeviceStartStream failed: \(status)")
            return false
        }

        deviceID = device
        sinkStream = sink
        sinkQueue = queue
        enqueueCount = 0
        readyCallbackCount = 0
        // Allow the very first buffer through; afterwards the extension's
        // consume callback re-arms us one frame at a time.
        setReady(true)
        Self.log.info("attached to RemoteCrab Camera sink stream")
        return true
    }

    private func teardown() {
        if let deviceID, let sinkStream {
            _ = CMIODeviceStopStream(deviceID, sinkStream)
            var ignored: Unmanaged<CMSimpleQueue>?
            _ = CMIOStreamCopyBufferQueue(sinkStream, nil, nil, &ignored)
        }
        deviceID = nil
        sinkStream = nil
        sinkQueue = nil
    }

    // MARK: - Enqueue

    private func enqueue(image: CGImage) {
        guard running else { return }
        // Follow the client's format (it can change at runtime, e.g. a user
        // switching the camera resolution in Zoom). Cheap: ~1 Hz, not per frame.
        enqueueTick += 1
        if enqueueTick % 30 == 0 { syncResolutionFromSource() }
        guard isReady, let sinkQueue, let bufferPool, let formatDescription else { return }
        let queue = sinkQueue.takeUnretainedValue()
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }

        let w = currentResolution.width
        let h = currentResolution.height
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer),
           let context = CGContext(
                data: base,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
            // Aspect-fit into the selected landscape sink: a portrait
            // iPhone stream (e.g. 1080×1920) gets black pillarbox bars instead
            // of being stretched wide.
            let canvas = CGRect(x: 0, y: 0, width: w, height: h)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(canvas)
            let scale = min(canvas.width / CGFloat(image.width),
                            canvas.height / CGFloat(image.height))
            let dest = CGRect(
                x: canvas.midX - CGFloat(image.width) * scale / 2,
                y: canvas.midY - CGFloat(image.height) * scale / 2,
                width: CGFloat(image.width) * scale,
                height: CGFloat(image.height) * scale)
            context.draw(image, in: dest)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(IBCameraDevice.frameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }

        // The buffer queue is a raw-pointer queue: hand over a +1
        // reference; the extension releases it when it consumes the
        // buffer.
        setReady(false)
        let element = UnsafeMutableRawPointer(Unmanaged.passRetained(sampleBuffer).toOpaque())
        CMSimpleQueueEnqueue(queue, element: element)
        enqueueCount += 1
        if enqueueCount == 1 || enqueueCount % 150 == 0 {
            Self.log.info("feeding virtual camera: \(self.enqueueCount) frames")
        }
        if enqueueCount == 1 { scheduleStallWatchdog() }
    }

    /// The extension process is launched on demand when a client starts
    /// the source stream — which can happen *after* we first start the
    /// sink. A `CMIODeviceStartStream` issued before then is silently
    /// ineffective, so if we're pushing frames but the extension never
    /// consumes one, tear the sink down and start it again.
    private func scheduleStallWatchdog() {
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.running, self.sinkQueue != nil else { return }
            guard self.readyCallbackCount == 0 else { return }
            Self.log.info("sink never consumed a frame — restarting sink stream")
            self.teardown()
            self.connectWithRetry()
        }
    }

    // MARK: - Buffer pool

    /// The size the client (app) selected, read from the source stream's active
    /// format (`syncResolutionFromSource`). The host must fill the sink with
    /// **exactly** this: the extension forwards the buffer out the source, so a
    /// mismatch breaks the picture. Defaults to 1080p, so if the read fails the
    /// camera behaves exactly as before.
    private var currentResolution = IBCameraDevice.resolutions[0]

    /// Match our buffer size to the format the client selected on the source
    /// stream. The extension forwards the sink buffer straight out the source,
    /// so enqueuing 1080p while the source advertises 4K (or vice versa) makes
    /// the client render garbage. Only sizes we advertise are accepted, and any
    /// read failure leaves the size untouched — so the default 1080p path
    /// behaves exactly as before.
    private func syncResolutionFromSource() {
        guard let sourceStream, let desc = sourceFormatDescription(sourceStream) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        guard dims.width > 0, dims.height > 0 else { return }
        let wanted = IBCameraDevice.Resolution(width: Int(dims.width), height: Int(dims.height))
        guard wanted != currentResolution, IBCameraDevice.resolutions.contains(wanted) else { return }
        currentResolution = wanted
        bufferPool = nil
        formatDescription = nil
        _ = prepareBufferPool()
        Self.log.info("camera sink following client format: \(wanted.width)x\(wanted.height)")
    }

    /// Read a CMIO stream's active format (the client's choice, on the source).
    /// `kCMIOStreamPropertyFormatDescription` returns a +1 CFType.
    private func sourceFormatDescription(_ stream: CMIOStreamID) -> CMFormatDescription? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(stream, &address, 0, nil, &dataSize) == 0 else { return nil }
        var desc: Unmanaged<CMFormatDescription>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &desc) { ptr -> OSStatus in
            CMIOObjectGetPropertyData(stream, &address, 0, nil, dataSize, &used,
                                      UnsafeMutableRawPointer(ptr))
        }
        guard status == 0, let unmanaged = desc else { return nil }
        return unmanaged.takeRetainedValue()
    }

    private func prepareBufferPool() -> Bool {
        if bufferPool != nil { return true }

        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(currentResolution.width),
            height: Int32(currentResolution.height),
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard let description else { return false }
        formatDescription = description

        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: currentResolution.width,
            kCVPixelBufferHeightKey: currentResolution.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool) == kCVReturnSuccess, pool != nil else {
            Self.log.error("failed to create pixel buffer pool")
            return false
        }
        bufferPool = pool
        return true
    }

    private func makeBufferQueue(for stream: CMIOStreamID) -> Unmanaged<CMSimpleQueue>? {
        let queuePointer = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 1)
        queuePointer.initialize(to: nil)
        defer { queuePointer.deallocate() }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = CMIOStreamCopyBufferQueue(stream, { _, _, refcon in
            guard let refcon else { return }
            let feeder = Unmanaged<CameraSinkFeeder>.fromOpaque(refcon).takeUnretainedValue()
            feeder.noteReadyCallback()
        }, refcon, queuePointer)

        guard status == 0, let queue = queuePointer.pointee else {
            Self.log.error("CMIOStreamCopyBufferQueue failed: \(status)")
            return nil
        }
        return queue
    }

    // MARK: - Ready flag

    private var isReady: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return readyToEnqueue
    }

    private func setReady(_ value: Bool) {
        stateLock.lock(); readyToEnqueue = value; stateLock.unlock()
    }

    private func noteReadyCallback() {
        readyCallbackCount += 1
        setReady(true)
    }

    // MARK: - CMIO helpers

    private func makeDevicesVisible() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        _ = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    // Device lookup lives in SetupStatus.swift (`cmioDevice(uid:)`) so
    // the setup assistant can share the exact same query.

    private func streams(of device: CMIODeviceID) -> [CMIOStreamID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        guard count > 0 else { return [] }
        var ids = [CMIOStreamID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &used, &ids) == 0 else { return [] }
        return ids
    }

    /// 0 = output (source), 1 = input (sink).
    private func streamDirection(_ stream: CMIOStreamID) -> UInt32? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(stream, &address, 0, nil, size, &used, &value) == 0 else { return nil }
        return value
    }
}
