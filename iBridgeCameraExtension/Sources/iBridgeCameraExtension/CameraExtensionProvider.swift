import CoreMedia
import CoreMediaIO
import Foundation
import IOKit
import OSLog
import iBridgeCore

private let logger = Logger(subsystem: "com.ibridge", category: "CameraExtension")

/// The Camera Extension's top-level provider object.
///
/// `CMIOExtensionProvider` is the entry point the system calls when an
/// app (Zoom, Teams, Photo Booth, OBS, …) starts consuming the camera.
/// We expose a single device backed by a single stream that forwards
/// frames from the connected iPhone.
final class CameraExtensionProvider: NSObject {

    private let deviceSource: CameraExtensionDevice
    private let xpcListener: XPCFrameListener

    /// The live CMIO provider object handed to
    /// `CMIOExtensionProvider.startService(provider:)`.
    private(set) var provider: CMIOExtensionProvider!

    override init() {
        self.deviceSource = CameraExtensionDevice()
        self.xpcListener = XPCFrameListener(stream: deviceSource.streamSource)
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            logger.error("failed to add device: \(error.localizedDescription)")
        }
        xpcListener.start()
    }
}

// MARK: - CMIOExtensionProviderSource

extension CameraExtensionProvider: CMIOExtensionProviderSource {

    func connect(to client: CMIOExtensionClient) throws {
        // Connections are short-lived and we don't keep per-client
        // state beyond what the device already tracks.
    }

    func disconnect(from client: CMIOExtensionClient) {
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerName]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) {
            providerProperties.setPropertyState(CMIOExtensionPropertyState(value: "Familiar Camera" as NSString), forProperty: .providerName)
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
    }
}
