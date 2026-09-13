import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import OSLog
import iBridgeCore

private let logger = Logger(subsystem: "com.ibridge", category: "CameraExtension")

/// One camera device exposed by the provider.
final class CameraExtensionDevice: NSObject {

    /// Stable identifier for the single virtual camera.
    private static let deviceID = UUID(uuidString: "3B7B09B4-2E2A-4C6B-9C0E-1B0E6B0D6A01")!

    /// Currently live stream (one stream per device is enough for V0.1).
    let streamSource: CameraExtensionStream

    /// The CMIO device object registered with the provider.
    private(set) var device: CMIOExtensionDevice!

    override init() {
        self.streamSource = CameraExtensionStream()
        super.init()
        device = CMIOExtensionDevice(
            localizedName: "Familiar Camera",
            deviceID: Self.deviceID,
            legacyDeviceID: "com.ibridge.camera",
            source: self
        )
        do {
            try device.addStream(streamSource.stream)
        } catch {
            logger.error("failed to add stream: \(error.localizedDescription)")
        }
    }
}

// MARK: - CMIOExtensionDeviceSource

extension CameraExtensionDevice: CMIOExtensionDeviceSource {

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceModel, .deviceIsSuspended]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) {
            deviceProperties.setPropertyState(CMIOExtensionPropertyState(value: "iPhone Camera" as NSString), forProperty: .deviceModel)
        }
        if properties.contains(.deviceIsSuspended) {
            deviceProperties.setPropertyState(CMIOExtensionPropertyState(value: NSNumber(value: false)), forProperty: .deviceIsSuspended)
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
    }
}
