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

    /// Frame sizes offered to apps, in order. **Index 0 must be 1080p.**
    ///
    /// A single 4K format broke every app that uses the default `.high` preset:
    /// measured 2026-10-11, a `.high` `AVCaptureSession` against a 4K-only
    /// virtual camera starts but delivers **zero frames** — the camera is dead
    /// in Photo Booth, Zoom, QuickTime. 1080p first keeps the camera working for
    /// normal apps; 4K is offered as a second format for a client that asks for
    /// it explicitly.
    ///
    /// (The host still fills the sink at index 0. Making a 4K *client* actually
    /// receive 4K needs the host to follow the client's choice, which needs the
    /// extension to report it — a separate, deeper CMIO fix. Until then 4K is
    /// offered, not delivered.)
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
