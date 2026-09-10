import Foundation
import os
import iBridgeCore

/// Extension-side XPC listener. The host (iBridgeReceiver) connects
/// to `IBridgeCameraXPC.machServiceName` and pushes H.264 NAL units
/// through the `IBridgeFrameSink` interface.
final class XPCFrameListener: NSObject, NSXPCListenerDelegate {

    private let listener: NSXPCListener
    private let stream: CameraExtensionStream
    private let log = Logger(subsystem: "com.ibridge", category: "camera-xpc")

    init(stream: CameraExtensionStream) {
        self.stream = stream
        self.listener = NSXPCListener(machServiceName: IBridgeCameraXPC.machServiceName)
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
        log.info("XPC listener started on \(IBridgeCameraXPC.machServiceName, privacy: .public)")
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: IBridgeFrameSink.self)
        connection.exportedObject = ExtensionFrameSink(stream: stream)
        connection.remoteObjectInterface = NSXPCInterface(with: IBridgeFrameSource.self)
        connection.invalidationHandler = { [weak self] in
            self?.stream.reset()
            self?.log.info("host disconnected")
        }
        connection.interruptionHandler = { [weak self] in
            self?.log.info("host connection interrupted")
        }
        connection.resume()
        log.info("host connected")
        return true
    }
}

/// Receives NAL units from the host over XPC and forwards them to the
/// stream's VideoToolbox decoder.
final class ExtensionFrameSink: NSObject, IBridgeFrameSink {

    private weak var stream: CameraExtensionStream?

    init(stream: CameraExtensionStream) {
        self.stream = stream
    }

    func feed(nalUnit data: Data, kind: Int) {
        guard let nalKind = IBNalFrame.Kind(rawValue: UInt8(kind)) else { return }
        stream?.receive(nalUnit: data, kind: nalKind)
    }

    func setFormat(width: Int, height: Int, fps: Int) {
        // Format description is rebuilt from the next SPS/PPS pair
        // inside StreamDecoder; drop stale frames from the old format.
        stream?.reset()
    }

    func stop() {
        stream?.reset()
    }
}
