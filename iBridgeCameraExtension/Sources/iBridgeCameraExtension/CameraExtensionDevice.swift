import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import iBridgeCore

/// One camera device exposed by the provider.
final class CameraExtensionDevice: NSObject, CMIOExtensionDevice {

    /// Whether consumers (Zoom, etc.) may currently open this device.
    /// Set to `false` while we don't have a connected iPhone.
    var isAvailable: Bool = false

    /// Currently live stream (one stream per device is enough for V0.1).
    let stream: CameraExtensionStream

    override init() {
        self.stream = CameraExtensionStream()
        super.init()
    }

    // CMIOExtensionDeviceSource
    var deviceName: String { "iBridge Camera" }
    var deviceManufacturer: String { "iBridge" }
    var deviceUID: String { "com.ibridge.camera" }
    var modelName: String { "iPhone Camera" }

    var streams: [CMIOExtensionStream] { [stream] }

    var suspended: Bool { false }

    func connect(to client: CMIOExtensionClient) throws {
        // No device-level state to set up; the stream handles wiring.
    }

    func disconnect(from client: CMIOExtensionClient) {
        // No device-level state to tear down.
    }

    func authorize(_ client: CMIOExtensionClient, then completion: CMIOExtensionDeviceAuthorizationHandler) {
        // V0.1: anyone running the extension may use the camera. Production
        // should enforce that the host app is currently streaming from
        // a paired iPhone.
        completion(true, nil)
    }
}