import Foundation
import Network
import os

/// Sends typed events over an established `NWConnection`. Shared by both
/// sides of the link: the iOS capture app (touch/key/audio/…) and the Mac
/// receiver (file acks, camera control, mirrored video, notifications, …).
public final class IBEventBroadcaster: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.remotecrab", category: "broadcaster")

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

    /// Ask for the receiver's launch-able applications (launcher sheet).
    public func send(_ request: IBInstalledAppsRequest) {
        send(kind: .installedAppsRequest) { try IBWire.encode(installedAppsRequest: request) }
    }

    /// iOS → Mac: request the current Mac window list.
    public func send(_ request: IBWindowListRequest) {
        send(kind: .windowListRequest) { try IBWire.encode(windowListRequest: request) }
    }

    /// iOS → Mac: bring an app to the front.
    public func send(_ activate: IBActivateApp) {
        send(kind: .activateApp) { try IBWire.encode(activateApp: activate) }
    }

    /// iOS → Mac: quit an app (graceful, or forced when `force` is true).
    public func send(_ quit: IBQuitApp) {
        send(kind: .quitApp) { try IBWire.encode(quitApp: quit) }
    }

    /// iOS → Mac: a system-level action (volume / brightness / media / launch).
    public func send(_ command: IBSystemCommand) {
        send(kind: .systemCommand) { try IBWire.encode(systemCommand: command) }
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

    /// Send a latency probe stamped with OUR clock.
    ///
    /// Deliberately takes microseconds rather than bytes:
    /// `IBWire.encodePing` returns a *complete frame* (4-byte length +
    /// kind + payload), and handing that to `sendPingEcho` produces a
    /// 13-byte "ping" that the receiver rejects as malformed — which is
    /// exactly the bug this happened to have, so the payload/frame
    /// distinction is now impossible to get wrong at the call site.
    public func sendLatencyProbe(_ micros: UInt64) {
        send(kind: .ping) { IBWire.encodePing(sentMicros: micros) }
    }

    // MARK: - App screen mirror

    /// Mac → iPhone: one H.264 NAL of the mirrored window.
    public func sendScreen(frame: IBNalFrame) {
        send(kind: .screenVideo) { IBWire.encodeScreen(frame: frame) }
    }

    /// iPhone → Mac: start / stop / select the mirror target.
    public func send(_ control: IBScreenControl) {
        send(kind: .screenControl) { try IBWire.encode(screenControl: control) }
    }

    /// iPhone → Mac: one direct-manipulation input event.
    public func send(_ input: IBScreenInput) {
        send(kind: .screenInput) { try IBWire.encode(screenInput: input) }
    }

    /// Mac → iPhone: current mirror target + geometry.
    public func send(_ info: IBScreenInfo) {
        send(kind: .screenInfo) { try IBWire.encode(screenInfo: info) }
    }

    /// Receiver → iPhone: the outcome of a command the phone asked for.
    public func send(_ result: IBCommandResult) {
        send(kind: .commandResult) { try IBWire.encode(commandResult: result) }
    }

    /// Mac → iPhone: one captured notification banner.
    public func send(_ notification: IBNotification) {
        send(kind: .notification) { try IBWire.encode(notification: notification) }
    }

    /// Whether a frame handed to `send` right now would actually leave the
    /// device.
    ///
    /// `send(kind:_:)` silently drops anything whose connection isn't
    /// `.ready`. That is the right behaviour for the data plane (touch, key,
    /// video — dropping one is better than stalling), but useless for a
    /// *command* the user just asked for and is now watching for: the tap
    /// is acknowledged by a haptic and then nothing happens, ever. Callers
    /// that need honest feedback check this first.
    public var isReady: Bool { connection.state == .ready }

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