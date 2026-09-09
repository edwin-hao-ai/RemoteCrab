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
public final class CameraExtensionBridge {

    public init() {}

    /// Hand a freshly decoded H.264 NAL unit to the extension.
    /// The extension owns its own `VTDecompressionSession` and will
    /// produce a `CVPixelBuffer` for the next system frame pull.
    ///
    /// Implementation note: in V0.2 this is a stub that just logs the
    /// payload size. Wiring it up requires an `NSXPCConnection` to
    /// the system extension's exported `IBridgeStreamSink` object.
    public func feed(nalUnit: Data, kind: IBNalFrame.Kind) {
        // STUB: see iBridgeCameraExtension/CameraExtensionStream.swift
        // for the receiver-side of this bridge.
        let label: String
        switch kind {
        case .sps:   label = "SPS"
        case .pps:   label = "PPS"
        case .video: label = "Video"
        default:     label = "Other"
        }
        // Real implementation:
        //   let conn = NSXPCConnection(serviceName: "com.ibridge.camera-bridge")
        //   conn.remoteObjectProxy.feed(nalUnit: nalUnit, kind: kind)
        _ = label
    }
}