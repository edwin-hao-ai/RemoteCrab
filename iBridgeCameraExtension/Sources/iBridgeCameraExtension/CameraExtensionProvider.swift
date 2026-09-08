import CoreMediaIO
import Foundation
import IOKit
import iBridgeCore

/// The Camera Extension's top-level provider object.
///
/// `CMIOExtensionProvider` is the entry point the system calls when an
/// app (Zoom, Teams, Photo Booth, OBS, …) starts consuming the camera.
/// We expose a single device backed by a single stream that forwards
/// frames from the connected iPhone.
final class CameraExtensionProvider: NSObject, CMIOExtensionProvider {

    /// Registered by the host (iBridgeReceiver) when a new iPhone is
    /// accepted on the network. The provider hands incoming NAL frames
    /// to the `stream` via this sink.
    weak var frameSink: iBridgeFrameSink?

    private let device: CameraExtensionDevice

    override init() {
        self.device = CameraExtensionDevice()
        super.init()
    }

    func connect(to client: CMIOExtensionClient) throws {
        // No-op: connections are short-lived and we don't keep per-client
        // state beyond what `device` already tracks.
        try device.connect(to: client)
    }

    func disconnect(from client: CMIOExtensionClient) {
        device.disconnect(from: client)
    }

    // MARK: - CMIOExtensionProviderSource

    var devices: [CMIOExtensionDevice] { [device] }

    var providerName: String { "iBridge Camera" }
}

/// Protocol used by `CameraExtensionStream` to receive raw H.264 NAL
/// frames coming from the iPhone over the network. The host
/// (iBridgeReceiver) provides a concrete implementation.
protocol iBridgeFrameSink: AnyObject {
    /// Pull the next decoded video frame as a `CVPixelBuffer`.
    func consumeNextPixelBuffer() -> Unmanaged<CMSampleBuffer>?
}

extension CameraExtensionProvider: CMIOExtensionProviderSource {}
extension CameraExtensionDevice: CMIOExtensionDeviceSource {}
extension CameraExtensionStream: CMIOExtensionStreamSource {}