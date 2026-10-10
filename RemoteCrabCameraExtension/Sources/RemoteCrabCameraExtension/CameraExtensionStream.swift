import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import OSLog
import RemoteCrabCore

private let logger = Logger(subsystem: "com.remotecrab", category: "CameraExtension")

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
    /// Sends since the last `startStream`, so the first few of each session log
    /// even though the extension process (and `sentCount`) outlives a session.
    private var sinceStart = 0
    /// The format index the client selected (default = 1080p).
    private var activeFormatIndex = IBCameraDevice.defaultFormatIndex

    override init() {
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "RemoteCrab Camera",
            streamID: Self.streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    /// Forward one decoded frame (BGRA, `IBCameraDevice.width × height`)
    /// to attached clients.
    ///
    /// **No client-count guard.** It used to early-return unless
    /// `attachedClients > 0`, but that counter could drift to 0 while a client
    /// was watching (a start/stop pair that nets to zero), so every frame was
    /// silently dropped and the camera showed nothing — measured 2026-10-11:
    /// `source stream started (clients=1)` yet no `source sent`, and the client
    /// received zero frames. `CMIOExtensionStream.send` already drops when
    /// nobody is attached, so the guard bought nothing and cost the feature.
    func send(sampleBuffer: CMSampleBuffer) {
        sentCount += 1
        sinceStart += 1
        if sinceStart <= 5 || sentCount % 150 == 0 {
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
        IBCameraDevice.resolutions.map { res in
            CMIOExtensionStreamFormat(
                formatDescription: Self.formatDescription(res),
                maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(IBCameraDevice.frameRate)),
                minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(IBCameraDevice.frameRate)),
                validFrameDurations: nil
            )
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.setPropertyState(CMIOExtensionPropertyState(value: NSNumber(value: activeFormatIndex)), forProperty: .streamActiveFormatIndex)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        // Remember the client's choice so `streamProperties()` reports it back
        // and the host can size its buffers to the same format.
        if let index = streamProperties.activeFormatIndex,
           IBCameraDevice.resolutions.indices.contains(index) {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        attachedClients += 1
        sinceStart = 0
        logger.info("source stream started (clients=\(self.attachedClients))")
    }

    func stopStream() throws {
        attachedClients = max(0, attachedClients - 1)
    }

    /// BGRA at the given resolution — the format the host fills the sink with.
    private static func formatDescription(_ res: IBCameraDevice.Resolution) -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(res.width),
            height: Int32(res.height),
            extensions: nil,
            formatDescriptionOut: &description
        )
        return description!
    }
}
