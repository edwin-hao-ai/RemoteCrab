import CoreMedia
import CoreMediaIO
import Foundation
import OSLog
import RemoteCrabCore

private let logger = Logger(subsystem: "com.remotecrab", category: "CameraExtension")

/// The Camera Extension's top-level provider object.
///
/// `CMIOExtensionProvider` is the entry point the system calls when an
/// app (Zoom, Teams, Photo Booth, OBS, …) starts consuming the camera.
/// We expose a single device with a source stream (to clients) and a
/// sink stream (fed by the RemoteCrab receiver app).
final class CameraExtensionProvider: NSObject {

    private let deviceSource: CameraExtensionDevice

    /// The live CMIO provider object handed to
    /// `CMIOExtensionProvider.startService(provider:)`.
    private(set) var provider: CMIOExtensionProvider!

    override init() {
        self.deviceSource = CameraExtensionDevice()
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            logger.error("failed to add device: \(error.localizedDescription)")
        }
    }
}

// MARK: - CMIOExtensionProviderSource

extension CameraExtensionProvider: CMIOExtensionProviderSource {

    func connect(to client: CMIOExtensionClient) throws {
    }

    func disconnect(from client: CMIOExtensionClient) {
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerName]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) {
            providerProperties.setPropertyState(CMIOExtensionPropertyState(value: "RemoteCrab Camera" as NSString), forProperty: .providerName)
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
    }
}
