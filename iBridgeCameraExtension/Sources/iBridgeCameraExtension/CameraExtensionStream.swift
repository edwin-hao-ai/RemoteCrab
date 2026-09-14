import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import OSLog
import iBridgeCore

private let logger = Logger(subsystem: "com.ibridge", category: "CameraExtension")

/// The **source** stream (device → apps). Frames the host pushes into the
/// sink stream are forwarded here to every attached client (Zoom,
/// FaceTime, Photo Booth, …).
final class CameraExtensionStream: NSObject {

    private static let streamID = UUID(uuidString: IBCameraDevice.sourceStreamID)!

    private(set) var stream: CMIOExtensionStream!

    /// How many clients currently have the stream open. Frames are only
    /// pushed while someone is watching, so the host isn't decoding and
    /// feeding video into the void.
    private var attachedClients = 0
    private var sentCount = 0

    override init() {
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "Familiar Camera",
            streamID: Self.streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    /// Forward one decoded frame (BGRA, `IBCameraDevice.width × height`)
    /// to attached clients.
    func send(sampleBuffer: CMSampleBuffer) {
        guard attachedClients > 0 else { return }
        sentCount += 1
        if sentCount == 1 || sentCount % 150 == 0 {
            logger.info("source sent \(self.sentCount) frames (clients=\(self.attachedClients))")
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC))
        )
    }
}

// MARK: - CMIOExtensionStreamSource

extension CameraExtensionStream: CMIOExtensionStreamSource {

    var formats: [CMIOExtensionStreamFormat] {
        [CMIOExtensionStreamFormat(
            formatDescription: Self.formatDescription(),
            maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(IBCameraDevice.frameRate)),
            minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(IBCameraDevice.frameRate)),
            validFrameDurations: nil
        )]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.setPropertyState(CMIOExtensionPropertyState(value: NSNumber(value: 0)), forProperty: .streamActiveFormatIndex)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        attachedClients += 1
        logger.info("source stream started (clients=\(self.attachedClients))")
    }

    func stopStream() throws {
        attachedClients = max(0, attachedClients - 1)
    }

    /// 1080p BGRA — the format the host fills the sink stream with.
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
