#if os(macOS)
import Foundation

/// Shared identifiers for the RemoteCrab virtual camera.
///
/// The camera extension publishes one `CMIOExtensionDevice` with two
/// `CMIOExtensionStream`s:
///
/// - a **source** stream (device → apps) that Zoom / FaceTime /
///   Photo Booth read from, and
/// - a **sink** stream (host app → device) that `RemoteCrab`'s receiver
///   feeds decoded frames into.
///
/// Custom XPC from an app to a CMIO extension is not supported (the
/// extension only vends the `CMIOExtensionMachServiceName`), so the sink
/// stream is the sanctioned host → extension frame channel — the same
/// design OBS and Apple's sample use.
public enum IBCameraDevice {

    /// `CMIOExtensionDevice` UUID. Exposed to AVFoundation as
    /// `AVCaptureDevice.uniqueID` and to CoreMediaIO as
    /// `kCMIODevicePropertyDeviceUID`, so the host can locate the
    /// device and its sink stream.
    public static let uid = "3B7B09B4-2E2A-4C6B-9C0E-1B0E6B0D6A01"

    /// Source (device → apps) stream UUID.
    public static let sourceStreamID = "3B7B09B4-2E2A-4C6B-9C0E-1B0E6B0D6A02"

    /// Sink (host → device) stream UUID.
    public static let sinkStreamID = "3B7B09B4-2E2A-4C6B-9C0E-1B0E6B0D6A03"

    /// Frame size the camera advertises to apps. The host scales every
    /// decoded frame into this size so a client never sees a format
    /// change mid-stream.
    public static let width = 1920
    public static let height = 1080
    public static let frameRate = 30
}
#endif
