import Foundation
import Network

/// Sends typed events (`TouchEvent`, `KeyEvent`, `AudioPacket`) over an
/// established `NWConnection`. Lives on the iOS side and is shared by
/// the touchpad, keyboard, and microphone components.
public final class IBEventBroadcaster: @unchecked Sendable {

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

    private func send(kind: IBWire.Kind, _ encode: () throws -> Data) {
        guard connection.state == .ready else { return }
        do {
            let data = try encode()
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            print("[iBridge] encode \(kind) failed: \(error)")
        }
    }
}