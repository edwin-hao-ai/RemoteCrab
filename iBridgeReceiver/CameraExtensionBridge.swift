import Foundation
import iBridgeCore

/// The macOS-side bridge between `ReceiverSession` and the system
/// camera extension. The `IBridgeFrameSink` / `IBridgeFrameSource`
/// XPC protocols live in iBridgeCore (`IBCameraXPC.swift`) so both
/// processes share one definition.
///
/// Owns either:
///   • a real `NSXPCConnection` to
///     `com.ibridge.iBridgeReceiver.Camera.systemextension`
///     (production path with code signing), or
///   • a direct in-process sink (simulator + dev path).
public final class CameraExtensionBridge: @unchecked Sendable {

    // MARK: - Mode selection

    public enum Mode: Equatable {
        /// In-process mode: fallback tombstone for when the XPC
        /// connection is unreachable (extension not installed yet or
        /// crashed). The sink becomes a no-op until the bridge
        /// reconnects; preview frames in the host UI flow via
        /// `decoder.onDecoded`, not through this bridge.
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

    /// When true (set by `start` in XPC mode, cleared by `stop`), a
    /// dropped XPC connection is retried every 5 seconds.
    private var shouldReconnect = false

    /// Mach service name of the extension, kept so a dropped XPC
    /// connection can be re-established.
    private var xpcServiceName: String?

    /// Latest decoded format description from the iPhone stream. Used
    /// so the XPC side knows what format description to build.
    public private(set) var lastWidth: Int = 1920
    public private(set) var lastHeight: Int = 1080
    public private(set) var lastFPS: Int = 30

    /// Name of the connected iPhone, mirrored from stream metadata.
    public private(set) var lastDeviceName: String?

    public init(mode: Mode) {
        self.mode = mode
    }

    // MARK: - Connection management

    /// Start the bridge. In XPC mode, this sets up an
    /// `NSXPCConnection` and keeps retrying every 5 seconds if it
    /// drops (until `stop()` is called). In in-process mode, it just
    /// stores the sink for direct calls.
    public func start(sink: IBridgeFrameSink) async throws {
        self.sink = sink
        switch mode {
        case .inProcess:
            // Nothing to set up — direct calls into `sink`.
            return
        case .xpc(let machServiceName):
            xpcServiceName = machServiceName
            shouldReconnect = true
            attemptConnect(serviceName: machServiceName)
        }
    }

    public func stop() {
        shouldReconnect = false
        sink?.stop()
        connection?.invalidate()
        connection = nil
    }

    /// Called when the iPhone stream ends (connection failed or
    /// cancelled). Notifies the sink so the extension can stop its
    /// stream; does NOT tear down the XPC connection.
    public func streamStopped() {
        sinkQueue.async { [weak self] in
            self?.sink?.stop()
        }
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

    /// Called when stream metadata arrives so the extension can label
    /// the camera after the connected iPhone.
    public func updateDeviceName(_ name: String) {
        sinkQueue.async { [weak self] in
            self?.lastDeviceName = name
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

    /// (Re)establish the XPC connection to the extension. Any previous
    /// connection is invalidated first so we never hold two live
    /// connections to the same service.
    private func attemptConnect(serviceName: String) {
        if let old = connection {
            // Clear handlers so invalidating the old connection doesn't
            // schedule a duplicate reconnect.
            old.invalidationHandler = nil
            old.interruptionHandler = nil
            old.invalidate()
            connection = nil
        }

        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: IBridgeFrameSink.self)
        connection.exportedInterface = NSXPCInterface(with: IBridgeFrameSource.self)
        let source = HostSourceProvider { [weak self] in
            (width: self?.lastWidth ?? 0,
             height: self?.lastHeight ?? 0,
             fps: self?.lastFPS ?? 0)
        }
        source.nameProvider = { [weak self] in self?.lastDeviceName }
        connection.exportedObject = source
        connection.invalidationHandler = { [weak self] in
            self?.handleConnectionDrop()
        }
        connection.interruptionHandler = { [weak self] in
            self?.handleConnectionDrop()
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.handleConnectionDrop()
        }) as? IBridgeFrameSink else {
            connection.invalidate()
            handleConnectionDrop()
            return
        }
        self.connection = connection
        self.sink = proxy
        self.mode = .xpc(machServiceName: serviceName)
        proxy.setFormat(width: lastWidth, height: lastHeight, fps: lastFPS)
    }

    /// The XPC connection dropped (interruption, invalidation, or a
    /// remote-proxy error). Fall back to the in-process tombstone and,
    /// unless `stop()` was called, try again in 5 seconds — the
    /// extension may simply have started after the host.
    private func handleConnectionDrop() {
        mode = .inProcess
        guard shouldReconnect, let serviceName = xpcServiceName else { return }
        xpcQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.attemptConnect(serviceName: serviceName)
        }
    }
}

// MARK: - Host side of the XPC channel

/// Implementation of `IBridgeFrameSource` that the extension calls to
/// ask about the current stream config.
final class HostSourceProvider: NSObject, IBridgeFrameSource, @unchecked Sendable {
    let dimensionsProvider: () -> (width: Int, height: Int, fps: Int)
    var nameProvider: () -> String? = { nil }

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
        nameProvider()
    }
}

/// No-op sink used as a placeholder while the XPC connection is being
/// established (or after it falls back to in-process mode).
final class NullFrameSink: NSObject, IBridgeFrameSink {
    func feed(nalUnit data: Data, kind: Int) {}
    func setFormat(width: Int, height: Int, fps: Int) {}
    func stop() {}
}

// MARK: - Errors

public enum CameraExtensionError: Error {
    case badProxy
    case notInstalled
}
