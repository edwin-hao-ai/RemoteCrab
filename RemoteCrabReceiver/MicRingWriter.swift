import Foundation
import Network
import os

/// Sends the iPhone's microphone PCM to the `RemoteCrabMicrophone` HAL
/// driver over loopback UDP (127.0.0.1:49182).
///
/// Why not the POSIX shm ring anymore: the sandboxed app can't
/// `shm_open` into coreaudiod's address space (the sandbox denies it),
/// so the shared-memory design only produced silence. Loopback UDP is
/// allowed by the app sandbox (`com.apple.security.network.client`),
/// and the driver side (unsandboxed, inside coreaudiod) runs a small
/// listener that writes each datagram into the ring the IO thread reads.
///
/// Datagrams carry raw mono Int16 host-endian PCM — sender and receiver
/// are always the same machine, so there's no byte-order concern.
///
/// nil (and a silent device) when the driver isn't installed, keeping
/// the "not installed = silence, everything else works" contract.
final class MicRingWriter: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.remotecrab", category: "micring")

    /// All NWConnection access is serialized on this queue, so `write`
    /// is safe from any caller (the audio dispatch path is MainActor).
    private let queue = DispatchQueue(label: "com.remotecrab.micring")
    private var connection: NWConnection?

    init?() {
        // No point opening a socket when nothing is listening: without
        // the HAL device installed the datagrams would go nowhere.
        guard halMicDriverInstalled() else {
            Self.log.info("mic driver not installed — virtual mic feed disabled")
            return nil
        }
        start()
    }

    /// Ship mono Int16 frames; fire-and-forget (a dropped datagram is
    /// just a 20 ms gap, and the ring zero-fills underruns anyway).
    func write(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        queue.async { [weak self] in
            self?.connection?.send(content: pcm, completion: .idempotent)
        }
    }

    // MARK: - Connection lifecycle

    private func start() {
        let params = NWParameters.udp
        // The feed must never leave loopback — it's raw PCM and the
        // driver only binds 127.0.0.1 anyway.
        params.requiredInterfaceType = .loopback
        // Must match IB_MIC_UDP_PORT in RemoteCrabMicDriver/MicSocketListener.h.
        let port = NWEndpoint.Port(rawValue: 49182)!
        let conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                // Typically "connection refused" ICMP when coreaudiod
                // (re)started and the listener isn't bound yet. Retry
                // slowly — sending on a failed connection drops silently.
                Self.log.info("mic feed socket failed: \(error.localizedDescription, privacy: .public); retrying")
                self.connection?.cancel()
                self.connection = nil
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.start()
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        connection = conn
    }
}
