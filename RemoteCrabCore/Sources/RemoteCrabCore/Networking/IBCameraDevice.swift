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

    /// One frame size the virtual camera can present to apps.
    public struct Resolution: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// Frame sizes offered to apps, in order. **Index 0 is the default** an
    /// app gets without choosing one: it is 1080p, so existing behaviour is
    /// unchanged — and a client that does not ask for 4K gets *true* 1080p
    /// instead of an upscale. 4K is opt-in through the client's own camera
    /// settings (Zoom, OBS, QuickTime).
    ///
    /// The host fills the sink with the size the client selected (see
    /// `CameraSinkFeeder`), and the extension forwards it out the source, so
    /// the advertised format and the fed buffer always match.
    public static let resolutions: [Resolution] = [
        Resolution(width: 1920, height: 1080),
        Resolution(width: 3840, height: 2160),
    ]

    /// Index into `resolutions` a client gets by default.
    public static let defaultFormatIndex = 0

    public static let frameRate = 30

    /// The default size, kept for call sites that only need one.
    public static var defaultWidth: Int { resolutions[defaultFormatIndex].width }
    public static var defaultHeight: Int { resolutions[defaultFormatIndex].height }
}
#endif
