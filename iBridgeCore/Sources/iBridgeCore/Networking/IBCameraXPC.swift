#if os(macOS)
import Foundation

/// XPC contract between `iBridgeReceiver` (host) and
/// `iBridgeCameraExtension` (system camera extension).
///
/// The extension runs an `NSXPCListener` on
/// `IBridgeCameraXPC.machServiceName`. The host connects and pushes
/// compressed H.264 NAL units; the extension decodes them itself via
/// VideoToolbox (`StreamDecoder`) and serves frames to CMIO clients
/// (Zoom, FaceTime, Photo Booth, …).

/// Implemented by the extension, called by the host.
@objc public protocol IBridgeFrameSink {
    /// Push one H.264 NAL unit. `kind` is an `IBNalFrame.Kind` raw
    /// value: 1 = video, 2 = SPS, 3 = PPS.
    func feed(nalUnit data: Data, kind: Int)

    /// Stream format changed; the extension should expect a fresh
    /// SPS/PPS pair and rebuild its decoder state.
    func setFormat(width: Int, height: Int, fps: Int)

    /// iPhone disconnected. Release buffered frames and stop emitting.
    func stop()
}

/// Implemented by the host, called by the extension.
@objc public protocol IBridgeFrameSource {
    /// Current stream config, e.g. `["width": 1920, "height": 1080, "fps": 30]`.
    /// nil when no iPhone is connected.
    func currentFormat() -> [String: Int]?

    /// Name of the connected iPhone, used to label the camera.
    func deviceName() -> String?
}

/// Shared constants for the camera-extension XPC channel.
public enum IBridgeCameraXPC {
    /// Mach service name the extension's `NSXPCListener` registers.
    /// Team-ID-prefixed because a system extension's sandbox can only
    /// register team-prefixed mach services (and a sandboxed host can
    /// only look those up). The `.frames` suffix keeps it distinct from
    /// the CMIOExtensionMachServiceName in the extension's Info.plist.
    public static let machServiceName = "5XNDF727Y6.com.ibridge.iBridgeReceiver.Camera.frames"
}
#endif
