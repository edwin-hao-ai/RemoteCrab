import Foundation
import iBridgeCore

/// Protocol between the host process (`iBridgeReceiver`) and the
/// `iBridgeCameraExtension` (system extension). The host acts as the
/// "service" that exposes frame feeds to extensions; the extension
/// connects via `NSXPCConnection` and pulls decoded frames.
///
/// Two protocol directions:
///  - `IBridgeFrameSink` — extension implements, host calls. Pushes
///    decoded NAL units into the system camera's video pipeline.
///  - `IBridgeFrameSource` — host implements, extension calls.
///    Extension requests stream format / latency updates from the host.
@objc public protocol IBridgeFrameSink {
    /// Push one decoded NAL unit into the extension's pipeline.
    /// `kind`: 1 = video, 2 = SPS, 3 = PPS (see IBNalFrame.Kind raw values)
    func feed(nalUnit data: Data, kind: Int)

    /// Notify the extension that the stream format changed. The
    /// extension should rebuild its format description.
    func setFormat(width: Int, height: Int, fps: Int)

    /// Tell the extension to release any buffered frames and stop
    /// emitting. Called on disconnect.
    func stop()
}

@objc public protocol IBridgeFrameSource {
    /// Extension asks for the current stream's canonical config.
    /// Returns nil if no stream is active yet.
    func currentFormat() -> [String: Int]?

    /// Extension asks the host for the iPhone device name. The
    /// extension uses this to label the camera in the macOS UI.
    func deviceName() -> String?
}

/// The macOS-side bridge. Owns either:
///   • a real `NSXPCConnection` to `iBridgeCameraExtension.appex`
///     (production path with code signing), or
///   • a direct in-process sink (simulator + dev path).
public final class CameraExtensionBridge {

    // MARK: - Mode selection

    public enum Mode: Equatable {
        /// In-process mode: the bridge feeds the host's `ControlPanelView`
        /// preview window directly. Works without code signing.
        case inProcess

        /// XPC mode: the bridge hands frames to a real
        /// `iBridgeCameraExtension` system extension. Requires a
        /// signed build + a properly-installed extension.
        case xpc(machServiceName: String)
    }

    public private(set) var mode: Mode

    // MARK: - State

    private weak var sink: IBridgeFrameSink?
    private var connection: NSXPCConnection?
    private let sinkQueue = DispatchQueue(label: "com.ibridge.camera-bridge.sink")
    private let xpcQueue = DispatchQueue(label: "com.ibridge.camera-bridge.xpc")

    /// Latest decoded format description from the iPhone stream. Used
    /// so the XPC side knows what format description to build.
    public private(set) var lastWidth: Int = 1920
    public private(set) var lastHeight: Int = 1080
    public private(set) var lastFPS: Int = 30

    public init(mode: Mode) {
        self.mode = mode
    }

    // MARK: - Connection management

    /// Start the bridge. In XPC mode, this sets up an
    /// `NSXPCConnection` and validates the connection. In in-process
    /// mode, it just stores the sink for direct calls.
    public func start(sink: IBridgeFrameSink) async throws {
        self.sink = sink
        switch mode {
        case .inProcess:
            // Nothing to set up — direct calls into `sink`.
            return
        case .xpc(let machServiceName):
            try await connectXPC(serviceName: machServiceName)
        }
    }

    public func stop() {
        sink?.stop()
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Public API used by the receiver

    /// Called every time a fresh SPS/PPS pair arrives so the extension
    /// can rebuild its format description.
    public func updateFormat(width: Int, height: Int, fps: Int) {
        sinkQueue.async { [weak self] in
            guard let self else { return }
            self.lastWidth = width
            self.lastHeight = height
            self.lastFPS = fps
            self.sink?.setFormat(width: width, height: height, fps: fps)
        }
    }

    /// Push a single decoded NAL unit into the extension / preview.
    /// `kind`: 1 = video, 2 = SPS, 3 = PPS (IBNalFrame.Kind raw values).
    public func feed(nalUnit: Data, kind: Int) {
        sinkQueue.async { [weak self] in
            guard let self else { return }
            self.sink?.feed(nalUnit: nalUnit, kind: kind)
        }
    }

    // MARK: - XPC wiring

    private func connectXPC(serviceName: String) async throws {
        // The extension registers its NSXPCListener under the given
        // Mach service name. We connect and validate the interface
        // before declaring success — if any of these steps fail, we
        // fall back to in-process mode.
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: IBridgeFrameSink.self)
        connection.exportedInterface = NSXPCInterface(with: IBridgeFrameSource.self)
        connection.exportedObject = HostSourceProvider { [weak self] in
            self?.lastWidth ?? 0
        }
        connection.invalidationHandler = { [weak self] in
            self?.mode = .inProcess
        }
        connection.resume()

        let proxy = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<IBridgeFrameSink, Error>) in
            connection.remoteObjectProxy = { remote in
                guard let remote = remote as? IBridgeFrameSink else {
                    cont.resume(throwing: CameraExtensionError.badProxy)
                    return
                }
                cont.resume(returning: remote)
            }
        }
        self.connection = connection
        self.sink = proxy
        // Push our current format right away so the extension builds
        // its CMSampleBufferStreamFormat correctly on first frame.
        proxy.setFormat(width: lastWidth, height: lastHeight, fps: lastFPS)
    }
}

// MARK: - Host side of the XPC channel

/// Implementation of `IBridgeFrameSource` that the extension calls to
/// ask about the current stream config.
final class HostSourceProvider: NSObject, IBridgeFrameSource, @unchecked Sendable {
    let dimensionsProvider: () -> (width: Int, height: Int, fps: Int)

    init(dimensionsProvider: @escaping () -> (width: Int, height: Int, fps: Int)) {
        self.dimensionsProvider = dimensionsProvider
    }

    func currentFormat() -> [String: Int]? {
        let d = dimensionsProvider()
        return [
            "width": d.width,
            "height": d.height,
            "fps": d.fps
        ]
    }

    func deviceName() -> String? {
        // Future: look up the connected iPhone's name.
        nil
    }
}

// MARK: - Errors

public enum CameraExtensionError: Error {
    case badProxy
    case notInstalled
}