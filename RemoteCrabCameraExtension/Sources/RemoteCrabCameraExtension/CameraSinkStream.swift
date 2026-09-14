import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import OSLog
import RemoteCrabCore

private let logger = Logger(subsystem: "com.remotecrab", category: "CameraExtension")

/// The **sink** stream (host app → device). The RemoteCrab receiver
/// attaches to it with the CoreMediaIO C API and enqueues decoded
/// frames; we consume them and hand each one to `onSampleBuffer`, which
/// the device forwards out the source stream.
///
/// This is the sanctioned host → camera-extension frame channel. Custom
/// XPC does not work: the system only registers the extension's
/// `CMIOExtensionMachServiceName`, so an app can't look the extension up.
final class CameraSinkStream: NSObject {

    private static let streamID = UUID(uuidString: IBCameraDevice.sinkStreamID)!

    private(set) var stream: CMIOExtensionStream!

    /// Called for every frame the host enqueues.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let lock = NSLock()
    private var client: CMIOExtensionClient?
    private var active = false
    private var receivedCount = 0

    override init() {
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "RemoteCrab Camera Input",
            streamID: Self.streamID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    /// Pull one buffer at a time and re-arm. Frames are delivered as the
    /// host enqueues them.
    private func consumeNext() {
        lock.lock()
        let isActive = active
        let currentClient = client
        lock.unlock()

        guard isActive, let currentClient else { return }

        stream.consumeSampleBuffer(from: currentClient) { [weak self] sampleBuffer, sequenceNumber, _, _, _ in
            guard let self else { return }
            if let sampleBuffer {
                self.receivedCount += 1
                if self.receivedCount == 1 || self.receivedCount % 150 == 0 {
                    logger.info("sink received \(self.receivedCount) frames")
                }
                self.onSampleBuffer?(sampleBuffer)
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let output = CMIOExtensionScheduledOutput(
                    sequenceNumber: sequenceNumber,
                    hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC))
                )
                self.stream.notifyScheduledOutputChanged(output)
            }
            self.consumeNext()
        }
    }
}

// MARK: - CMIOExtensionStreamSource

extension CameraSinkStream: CMIOExtensionStreamSource {

    var formats: [CMIOExtensionStreamFormat] {
        [CMIOExtensionStreamFormat(
            formatDescription: Self.formatDescription(),
            maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(IBCameraDevice.frameRate)),
            minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(IBCameraDevice.frameRate)),
            validFrameDurations: nil
        )]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.setPropertyState(CMIOExtensionPropertyState(value: NSNumber(value: 0)), forProperty: .streamActiveFormatIndex)
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CMTimeScale(IBCameraDevice.frameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        lock.lock(); self.client = client; lock.unlock()
        return true
    }

    func startStream() throws {
        lock.lock(); active = true; lock.unlock()
        logger.info("sink stream started")
        consumeNext()
    }

    func stopStream() throws {
        lock.lock(); active = false; lock.unlock()
    }

    private static func formatDescription() -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(IBCameraDevice.width),
            height: Int32(IBCameraDevice.height),
            extensions: nil,
            formatDescriptionOut: &description
        )
        return description!
    }
}
