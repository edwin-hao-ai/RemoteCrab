import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox
import os
import RemoteCrabCore

/// Streams a live H.264 mirror of the Mac's **frontmost application
/// window** to the iPhone.
///
/// It follows the frontmost app (debounced) unless a window is pinned via
/// `select(windowId:)`. Frames are hardware-encoded with VideoToolbox and
/// handed to the injected `send` closure as fully-encoded wire frames, so
/// this type has no dependency on `IBEventBroadcaster` / `NWConnection`.
///
/// Threading: the public entry points are `@MainActor` (the receiver is
/// main-actor). The ScreenCaptureKit sample handler and the VideoToolbox
/// output callback run on the private serial `queue`; all mutable state
/// that crosses those boundaries is guarded by `lock`.
final class ScreenStreamer: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    private static let log = Logger(subsystem: "com.remotecrab", category: "screenstreamer")

    /// Sends one fully-encoded wire frame. Thread-safe (the receiver
    /// hands us the live `NWConnection.send`).
    private let send: @Sendable (Data) -> Void

    /// Optional out-of-band callbacks. Invoked on the main queue.
    var onStatusChange: ((IBScreenStatus) -> Void)?
    /// Fires for every `IBScreenInfo` we send, so the receiver can cache
    /// the last geometry and translate `IBScreenInput` coordinates.
    var onInfo: ((IBScreenInfo) -> Void)?

    private let lock = NSLock()
    /// Serial queue for capture + encode work. `SCStreamOutput` delivers
    /// here and VideoToolbox output callbacks are re-dispatched here, so
    /// encoder state is effectively single-threaded.
    private let queue = DispatchQueue(label: "com.remotecrab.screenstreamer.capture",
                                      qos: .userInteractive)

    // MARK: - Lifecycle / target state (lock-guarded)

    private var stream: SCStream?
    private var isRunning = false
    private var didRequestPermission = false
    private var observers: [NSObjectProtocol] = []
    private var debounceWork: DispatchWorkItem?
    private var restartAttempts = 0

    private var pinnedWindowNumber: Int?
    private var previous: ScreenWindowDescriptor?
    private var currentTarget: ScreenWindowDescriptor?

    // MARK: - Geometry (lock-guarded)

    private var lastContentRect: CGRect?
    private var originX: Double = 0
    private var originY: Double = 0
    private var pointWidth: Double = 0
    private var pointHeight: Double = 0
    private var pixelWidth: Int = 0
    private var pixelHeight: Int = 0
    private var targetWindowId: String?
    private var targetAppId: String?
    private var targetAppName: String?
    private var targetTitle: String?

    // MARK: - Encoder (lock-guarded)

    private var encoder: VTCompressionSession?
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var lastSPS: Data?
    private var lastPPS: Data?
    private var encodingBusy = false
    private var generation = 0
    private var lastRecreationAt = Date.distantPast

    init(send: @escaping @Sendable (Data) -> Void) {
        self.send = send
        super.init()
    }

    deinit {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        let center = NSWorkspace.shared.notificationCenter
        for token in observers { center.removeObserver(token) }
    }

    /// Scoped lock access. `NSLock.lock()` is unavailable from async
    /// contexts, so async methods go through this synchronous helper.
    @inline(__always)
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Public API

    /// Resolve the target, create + start the capture stream and encoder,
    /// and send the first `IBScreenInfo`. Idempotent enough to be called
    /// again after a permission grant.
    @MainActor
    func start() {
        guard CGPreflightScreenCaptureAccess() else {
            if !didRequestPermission {
                didRequestPermission = true
                _ = CGRequestScreenCaptureAccess()
                Self.log.info("screen recording not granted — requested access")
            }
            sendInfo(IBScreenInfo(status: .permissionDenied))
            return
        }
        restartAttempts = 0
        installObserversIfNeeded()
        Task { @MainActor in await resolveAndStart(reason: "start") }
    }

    /// Stop the stream, tear down the encoder and remove observers.
    @MainActor
    func stop() {
        removeObservers()
        debounceWork?.cancel()
        debounceWork = nil
        let oldStream: SCStream? = withLock { () -> SCStream? in
            isRunning = false
            let running = stream
            stream = nil
            previous = nil
            currentTarget = nil
            pinnedWindowNumber = nil
            lastContentRect = nil
            return running
        }
        teardownEncoder()
        if let oldStream {
            Task { try? await oldStream.stopCapture() }
        }
    }

    /// Pin a window (by `IBWindowInfo.id`, `"<pid>:<windowNumber>"`),
    /// keeping it until `stop()`. Falls back to following the frontmost
    /// app again if the pinned window disappears.
    @MainActor
    func select(windowId: String) {
        let number = windowId.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        withLock { pinnedWindowNumber = number }
        guard number != nil else {
            Self.log.info("select ignored (unparseable windowId \(windowId, privacy: .public))")
            return
        }
        Self.log.info("pinned window \(number!, privacy: .public)")
        Task { @MainActor in await resolveAndStart(reason: "select") }
    }

    // MARK: - Observers / follow frontmost

    @MainActor
    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleTargetRecheck() }
            }
            observers.append(token)
        }
    }

    @MainActor
    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    @MainActor
    private func scheduleTargetRecheck() {
        guard withLock({ isRunning }) else { return }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.recheckFrontmost() }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @MainActor
    private func recheckFrontmost() async {
        guard withLock({ isRunning }) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let myPID = ProcessInfo.processInfo.processIdentifier
        // Ignore our own app and non-regular (accessory/background) apps —
        // keep the previous target rather than blanking the mirror.
        guard let front,
              front.processIdentifier != myPID,
              front.activationPolicy == .regular else { return }
        await resolveAndStart(reason: "frontmost")
    }

    // MARK: - Target resolution

    @MainActor
    private func resolveAndStart(reason: String) async {
        let snapshot = Self.windowSnapshot()
        let descriptors = snapshot.descriptors
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        let (pin, prev) = withLock { (pinnedWindowNumber, previous) }

        var target: ScreenWindowDescriptor?
        if let pin {
            target = descriptors.first {
                $0.windowNumber == pin
                    && $0.isOnScreen
                    && $0.layer == 0
                    && $0.hasAlpha
                    && $0.width >= ScreenTargetResolver.minWidth
                    && $0.height >= ScreenTargetResolver.minHeight
            }
            if target == nil {
                // The pinned window went away — resume following.
                withLock { pinnedWindowNumber = nil }
                Self.log.info("pinned window \(pin, privacy: .public) gone — resuming frontmost follow")
            }
        }
        if target == nil {
            target = ScreenTargetResolver.resolveKeepingPrevious(
                frontmostPID: frontPID, windows: descriptors, previous: prev)
        }
        // If the "kept previous" window itself vanished (app quit / window
        // closed) re-resolve without it so we don't stream a dead target.
        if let kept = target,
           !descriptors.contains(where: { $0.windowNumber == kept.windowNumber && $0.isOnScreen }) {
            target = ScreenTargetResolver.resolve(frontmostPID: frontPID, windows: descriptors)
        }

        guard let target else {
            withLock {
                previous = nil
                currentTarget = nil
            }
            sendInfo(IBScreenInfo(status: .noWindow))
            return
        }
        let same = withLock { () -> Bool in
            previous = target
            return isRunning && currentTarget?.windowNumber == target.windowNumber
        }
        if same { return }

        await configureStream(for: target, reason: reason)
    }

    @MainActor
    private func configureStream(for target: ScreenWindowDescriptor, reason: String) async {
        await stopStreamOnly()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            Self.log.error("SCShareableContent failed: \(String(describing: error), privacy: .public)")
            sendInfo(IBScreenInfo(status: .noWindow))
            return
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == target.windowNumber }) else {
            Self.log.info("window \(target.windowNumber, privacy: .public) not found in SC content (\(reason, privacy: .public))")
            sendInfo(IBScreenInfo(status: .noWindow))
            return
        }

        let frame = scWindow.frame
        let scale = Self.backingScale(for: frame)
        var pixelW = Int((frame.width * scale).rounded())
        var pixelH = Int((frame.height * scale).rounded())
        Self.capAndEven(&pixelW, &pixelH)

        let config = SCStreamConfiguration()
        config.width = pixelW
        config.height = pixelH
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 2
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = false

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            Self.log.error("addStreamOutput failed: \(String(describing: error), privacy: .public)")
            sendInfo(IBScreenInfo(status: .noWindow))
            return
        }

        let appId = scWindow.owningApplication?.bundleIdentifier ?? "pid:\(target.pid)"
        let appName = scWindow.owningApplication?.applicationName ?? ""
        let title = scWindow.title ?? ""
        withLock {
            self.stream = stream
            currentTarget = target
            originX = Double(frame.origin.x)
            originY = Double(frame.origin.y)
            pointWidth = Double(frame.width)
            pointHeight = Double(frame.height)
            pixelWidth = pixelW
            pixelHeight = pixelH
            lastContentRect = frame
            targetWindowId = "\(target.pid):\(target.windowNumber)"
            targetAppId = appId
            targetAppName = appName
            targetTitle = title
        }

        createEncoder(width: pixelW, height: pixelH)

        do {
            try await stream.startCapture()
        } catch {
            Self.log.error("startCapture failed: \(String(describing: error), privacy: .public)")
            await stopStreamOnly()
            sendInfo(IBScreenInfo(status: .noWindow))
            return
        }
        withLock {
            isRunning = true
            restartAttempts = 0
        }
        Self.log.info("streaming window \(target.windowNumber, privacy: .public) (\(appName, privacy: .public)) \(pixelW)x\(pixelH) reason=\(reason, privacy: .public)")
        buildAndSendOKInfo()
    }

    /// Stop the running capture stream and encoder, keeping the resolved
    /// target so a reconfigure can resume it.
    @MainActor
    private func stopStreamOnly() async {
        let oldStream: SCStream? = withLock { () -> SCStream? in
            isRunning = false
            let running = stream
            stream = nil
            return running
        }
        teardownEncoder()
        if let oldStream {
            try? await oldStream.stopCapture()
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard withLock({ isRunning }) else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        let changed = withLock { () -> Bool in
            var changed = false
            if let (rect, _) = Self.contentRect(from: sampleBuffer),
               !Self.approxEqual(rect, lastContentRect) {
                lastContentRect = rect
                originX = Double(rect.origin.x)
                originY = Double(rect.origin.y)
                pointWidth = Double(rect.size.width)
                pointHeight = Double(rect.size.height)
                changed = true
            }
            if pixelWidth != width || pixelHeight != height {
                pixelWidth = width
                pixelHeight = height
                changed = true
            }
            return changed
        }
        if changed { buildAndSendOKInfo() }

        encode(sampleBuffer, imageBuffer: imageBuffer, width: width, height: height)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Self.log.error("SCStream stopped with error: \(String(describing: error), privacy: .public)")
        // `stream` is not Sendable, so decide identity here (lock-guarded,
        // nonisolated) rather than capturing it into the MainActor task.
        guard withLock({ self.stream === stream }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopStreamOnly()
            let attempts = self.withLock { () -> Int in
                self.restartAttempts += 1
                return self.restartAttempts
            }
            if attempts <= 2 {
                await self.resolveAndStart(reason: "stream-error")
            } else {
                self.sendInfo(IBScreenInfo(status: .noWindow))
            }
        }
    }

    // MARK: - Encoding

    private func encode(_ sampleBuffer: CMSampleBuffer,
                        imageBuffer: CVPixelBuffer,
                        width: Int,
                        height: Int) {
        if withLock({ encodingBusy }) { return }
        let needsRebuild = withLock { encoder == nil || encoderWidth != width || encoderHeight != height }
        if needsRebuild {
            teardownEncoder()
            createEncoder(width: width, height: height)
        }

        guard let session = withLock({ encoder }) else { return }
        if withLock({ encodingBusy }) { return }
        let gen = withLock { () -> Int in
            encodingBusy = true
            return generation
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMTime(value: 1, timescale: 30)
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] callbackStatus, _, outputBuffer in
            guard let self else { return }
            self.withLock {
                if self.generation == gen { self.encodingBusy = false }
            }
            if callbackStatus != noErr || outputBuffer == nil {
                if callbackStatus == kVTInvalidSessionErr { self.scheduleEncoderRecreation() }
                return
            }
            guard let outputBuffer else { return }
            let boxed = SendableSampleBuffer(buffer: outputBuffer)
            self.queue.async { [weak self] in
                guard let self else { return }
                guard self.withLock({ self.generation == gen }) else { return }
                self.processEncoded(boxed.buffer)
            }
        }

        if status != noErr {
            withLock {
                if generation == gen { encodingBusy = false }
            }
            if status == kVTInvalidSessionErr { scheduleEncoderRecreation() }
            else { Self.log.error("VTCompressionSessionEncodeFrame failed: \(status, privacy: .public)") }
        }
    }

    private func createEncoder(width: Int, height: Int) {
        var session: VTCompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            Self.log.error("VTCompressionSessionCreate failed: \(status, privacy: .public)")
            return
        }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AverageBitRate: 4_000_000,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 120,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
        ]
        VTSessionSetProperties(session, propertyDictionary: props as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)

        withLock {
            encoder = session
            encoderWidth = width
            encoderHeight = height
            lastSPS = nil
            lastPPS = nil
        }
    }

    private func teardownEncoder() {
        let old: VTCompressionSession? = withLock { () -> VTCompressionSession? in
            let current = encoder
            encoder = nil
            encoderWidth = 0
            encoderHeight = 0
            lastSPS = nil
            lastPPS = nil
            encodingBusy = false
            generation += 1
            return current
        }
        if let old { VTCompressionSessionInvalidate(old) }
    }

    /// Rebuild the compression session after `kVTInvalidSessionErr`,
    /// throttled to one attempt per second. Cleared parameter sets make
    /// the first frame from the new session re-emit SPS/PPS.
    private func scheduleEncoderRecreation() {
        queue.async { [weak self] in
            guard let self else { return }
            let size: (Int, Int)? = self.withLock { () -> (Int, Int)? in
                guard Date().timeIntervalSince(self.lastRecreationAt) > 1.0 else { return nil }
                self.lastRecreationAt = Date()
                return (self.encoderWidth, self.encoderHeight)
            }
            guard let (width, height) = size else { return }
            Self.log.info("rebuilding encoder after invalidation (\(width)x\(height), privacy: .public)")
            self.teardownEncoder()
            guard width > 0, height > 0 else { return }
            self.createEncoder(width: width, height: height)
        }
    }

    private func processEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > 0 else { return }

        var data = Data(count: totalLength)
        let copyStatus = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0,
                                              dataLength: totalLength,
                                              destination: baseAddress)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000)

        if withLock({ lastSPS == nil || lastPPS == nil }) {
            emitParameterSets(from: sampleBuffer, micros: micros)
        }

        var offset = 0
        while offset + 4 <= totalLength {
            let length = UInt32(data[offset]) << 24
                | UInt32(data[offset + 1]) << 16
                | UInt32(data[offset + 2]) << 8
                | UInt32(data[offset + 3])
            let nalStart = offset + 4
            let nalEnd = nalStart + Int(length)
            guard nalEnd <= totalLength else { break }
            guard nalEnd > nalStart else {
                offset = nalStart
                continue
            }
            let nalUnitType = data[nalStart] & 0x1F
            let slice = Data(data[nalStart..<nalEnd])
            if nalUnitType == 7 {
                withLock { lastSPS = slice }
            } else if nalUnitType == 8 {
                withLock { lastPPS = slice }
            } else if nalUnitType == 1 || nalUnitType == 5 {
                send(IBWire.encodeScreen(frame: IBNalFrame(kind: .video,
                                                           data: slice,
                                                           timestampMicros: micros)))
            }
            offset = nalEnd
        }
    }

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
                withLock { lastSPS = data }
                send(IBWire.encodeScreen(frame: IBNalFrame(kind: .sps, data: data, timestampMicros: micros)))
            case 8:
                withLock { lastPPS = data }
                send(IBWire.encodeScreen(frame: IBNalFrame(kind: .pps, data: data, timestampMicros: micros)))
            default:
                break
            }
        }
    }

    // MARK: - Info

    private func buildAndSendOKInfo() {
        let info = withLock {
            IBScreenInfo(
                status: .ok,
                windowId: targetWindowId,
                appId: targetAppId,
                appName: targetAppName,
                title: targetTitle,
                originX: originX,
                originY: originY,
                width: pointWidth,
                height: pointHeight,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                showsCursor: true
            )
        }
        sendInfo(info)
    }

    private func sendInfo(_ info: IBScreenInfo) {
        if let data = try? IBWire.encode(screenInfo: info) { send(data) }
        DispatchQueue.main.async { [weak self] in
            self?.onInfo?(info)
            self?.onStatusChange?(info.status)
        }
        Self.log.info("screenInfo status=\(info.status.rawValue, privacy: .public) window=\(info.windowId ?? "-", privacy: .public) \(Int(info.width), privacy: .public)x\(Int(info.height), privacy: .public)pt@\(info.pixelWidth, privacy: .public)x\(info.pixelHeight, privacy: .public)px")
    }

    // MARK: - Helpers

    private static func windowSnapshot() -> (descriptors: [ScreenWindowDescriptor], frames: [Int: CGRect]) {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return ([], [:])
        }
        var descriptors: [ScreenWindowDescriptor] = []
        var frames: [Int: CGRect] = [:]
        for info in list {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            descriptors.append(ScreenWindowDescriptor(
                windowNumber: number,
                pid: pid,
                layer: layer,
                width: Double(frame.width),
                height: Double(frame.height),
                isOnScreen: onScreen,
                hasAlpha: alpha > 0
            ))
            frames[number] = frame
        }
        return (descriptors, frames)
    }

    private static func contentRect(from sampleBuffer: CMSampleBuffer) -> (CGRect, Double)? {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachment = array.first else { return nil }
        let rawRect = attachment[SCStreamFrameInfo.contentRect.rawValue]
        var rect: CGRect?
        if let value = rawRect as? CGRect {
            rect = value
        } else if let value = rawRect as? NSValue {
            rect = value.rectValue
        } else if let dict = rawRect as? NSDictionary {
            rect = CGRect(dictionaryRepresentation: dict as CFDictionary)
        }
        guard let rect else { return nil }
        let scale = (attachment[SCStreamFrameInfo.scaleFactor.rawValue] as? NSNumber)?.doubleValue ?? 1.0
        return (rect, scale)
    }

    private static func approxEqual(_ a: CGRect, _ b: CGRect?) -> Bool {
        guard let b else { return false }
        return abs(a.origin.x - b.origin.x) < 1
            && abs(a.origin.y - b.origin.y) < 1
            && abs(a.size.width - b.size.width) < 1
            && abs(a.size.height - b.size.height) < 1
    }

    private static func backingScale(for frame: CGRect) -> CGFloat {
        NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
    }

    private static func capAndEven(_ width: inout Int, _ height: inout Int) {
        let longEdge = max(width, height)
        if longEdge > 2560 {
            let factor = 2560.0 / Double(longEdge)
            width = Int((Double(width) * factor).rounded())
            height = Int((Double(height) * factor).rounded())
        }
        width = max(2, width) & ~1
        height = max(2, height) & ~1
    }
}

/// Boxes the non-Sendable `CMSampleBuffer` handed back by VideoToolbox so
/// it can cross into the capture queue. The buffer is only read there.
private struct SendableSampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}
