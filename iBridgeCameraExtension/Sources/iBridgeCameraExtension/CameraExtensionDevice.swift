import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import OSLog
import iBridgeCore

private let logger = Logger(subsystem: "com.ibridge", category: "CameraExtension")

/// One camera device exposed by the provider. It owns two streams:
/// a source (device → apps) and a sink (host app → device). Frames the
/// host pushes into the sink are forwarded straight out the source.
final class CameraExtensionDevice: NSObject {

    private static let deviceID = UUID(uuidString: IBCameraDevice.uid)!

    let sourceStream: CameraExtensionStream
    let sinkStream: CameraSinkStream

    /// The CMIO device object registered with the provider.
    private(set) var device: CMIOExtensionDevice!

    override init() {
        self.sourceStream = CameraExtensionStream()
        self.sinkStream = CameraSinkStream()
        super.init()

        device = CMIOExtensionDevice(
            localizedName: "Familiar Camera",
            deviceID: Self.deviceID,
            legacyDeviceID: nil,
            source: self
        )

        // Sink → source passthrough.
        sinkStream.onSampleBuffer = { [weak self] sampleBuffer in
            self?.sourceStream.send(sampleBuffer: sampleBuffer)
        }

        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            logger.error("failed to add stream: \(error.localizedDescription)")
        }
    }
}

// MARK: - CMIOExtensionDeviceSource

extension CameraExtensionDevice: CMIOExtensionDeviceSource {

    /// `.deviceTransportType` is required for the system to publish the
    /// device to `AVCaptureDevice` discovery — without it (and a value in
    /// `deviceProperties`) the camera never shows up.
    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, .deviceIsSuspended]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "iPhone Camera"
        }
        if properties.contains(.deviceIsSuspended) {
            deviceProperties.setPropertyState(CMIOExtensionPropertyState(value: NSNumber(value: false)), forProperty: .deviceIsSuspended)
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
    }
}
