import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import VideoToolbox
import iBridgeCore

/// Bridges the main `iBridgeReceiver` process to the `iBridgeCameraExtension` system
/// extension. On macOS 14+, the camera extension runs in a separate process;
/// we marshal decoded frames into the extension via an `XPC` connection
/// or a Mach port.
///
/// **V0.2 status:** the bridge compiles and ships frames through `XPC` to a
/// system extension target. Wiring the extension into the host app
/// (`iBridgeReceiver.app/Contents/PlugIns/iBridgeCameraExtension.appex`)
/// requires:
///   1. Adding the `iBridgeCameraExtension` target as an `Embed App
///      Extensions` build phase on `iBridgeReceiver`.
///   2. Real Apple Developer Program signing (`$99/yr`) — system
///      extensions cannot be ad-hoc signed.
///   3. macOS user approval in **System Settings → Privacy & Security**
///      after first launch.
public final class CameraExtensionBridge: @unchecked Sendable {

    private let stream: CameraExtensionStream
    private let queue = DispatchQueue(label: "com.ibridge.camera-bridge")

    public init(stream: CameraExtensionStream) {
        self.stream = stream
    }

    /// Hand a freshly decoded H.264 NAL unit to the extension.
    /// The extension owns its own `VTDecompressionSession` and will
    /// produce a `CVPixelBuffer` for the next system frame pull.
    public func feed(nalUnit: Data, kind: IBNalFrame.Kind) {
        queue.async { [stream] in
            stream.receive(nalUnit: nalUnit, kind: kind)
        }
    }
}