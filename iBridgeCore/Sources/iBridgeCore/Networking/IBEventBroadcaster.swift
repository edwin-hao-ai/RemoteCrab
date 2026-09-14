import Foundation
import Network
import os

/// Sends typed events (`TouchEvent`, `KeyEvent`, `AudioPacket`) over an
/// established `NWConnection`. Lives on the iOS side and is shared by
/// the touchpad, keyboard, and microphone components.
public final class IBEventBroadcaster: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.ibridge", category: "broadcaster")

    private let queue: DispatchQueue
    private let connection: NWConnection
    private let encoder = JSONEncoder()

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func send(_ event: TouchEvent) {
        send(kind: .touch) { try IBWire.encode(touch: event) }
    }

    public func send(_ event: KeyEvent) {
        send(kind: .key) { try IBWire.encode(key: event) }
    }

    public func send(_ packet: AudioPacket) {
        send(kind: .audio) { try IBWire.encode(audio: packet) }
    }

    public func send(_ snapshot: FeatureStateSnapshot) {
        send(kind: .featureState) { try IBWire.encode(featureState: snapshot) }
    }

    /// iOS → Mac: request the current Mac app list.
    public func send(_ request: IBAppListRequest) {
        send(kind: .appListRequest) { try IBWire.encode(appListRequest: request) }
    }

    /// iOS → Mac: bring an app to the front.
    public func send(_ activate: IBActivateApp) {
        send(kind: .activateApp) { try IBWire.encode(activateApp: activate) }
    }

    /// iOS → Mac: offer a file, then stream chunks, then complete.
    public func send(_ offer: IBFileOffer) {
        send(kind: .fileOffer) { try IBWire.encode(fileOffer: offer) }
    }

    public func sendFileChunk(_ data: Data) {
        send(kind: .fileChunk) { IBWire.encodeFileChunk(data) }
    }

    public func send(_ complete: IBFileComplete) {
        send(kind: .fileComplete) { try IBWire.encode(fileComplete: complete) }
    }

    /// Mac → iOS: file transfer ack.
    public func send(_ ack: IBFileAck) {
        send(kind: .fileAck) { try IBWire.encode(fileAck: ack) }
    }

    /// Either direction: set the peer's clipboard text.
    public func send(_ clipboard: IBClipboard) {
        send(kind: .clipboardSet) { try IBWire.encode(clipboard: clipboard) }
    }

    /// iOS → Mac: transform the Mac's current selection.
    public func send(_ command: IBTextCommandMessage) {
        send(kind: .textCommand) { try IBWire.encode(textCommand: command) }
    }

    /// Mac → iPhone: switch the streaming camera.
    public func send(_ command: IBCameraCommand) {
        send(kind: .cameraCommand) { try IBWire.encode(cameraCommand: command) }
    }

    /// Echo a ping payload back to the Mac verbatim (RTT measurement).
    public func sendPingEcho(_ payload: Data) {
        send(kind: .ping) { IBWire.encodeFrame(kind: .ping, payload: payload) }
    }

    private func send(kind: IBWire.Kind, _ encode: () throws -> Data) {
        guard connection.state == .ready else { return }
        do {
            let data = try encode()
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            Self.log.error("encode \(String(describing: kind), privacy: .public) failed: \(error, privacy: .public)")
        }
    }
}