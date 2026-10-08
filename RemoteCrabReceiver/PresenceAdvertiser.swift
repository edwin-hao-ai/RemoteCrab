import Foundation
import Network
import os
import RemoteCrabCore

/// Announces this receiver on `_remotecrab-computer._tcp` so an iPhone can see
/// which computers are online. The phone does not connect to this listener — it
/// only reads the TXT record — so a new connection is accepted and immediately
/// cancelled. Failure to advertise is logged and never blocks a session.
final class PresenceAdvertiser: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.remotecrab", category: "presence")
    private let id: String
    private let name: String
    private let platform: String
    private let queue = DispatchQueue(label: "com.remotecrab.presence")
    private var listener: NWListener?
    /// Called when the phone "knocks" (a short connection to the knock port).
    /// The receiver then dials the phone immediately, so "tap a computer"
    /// connects at once instead of waiting for the retry poll. Set on the main
    /// actor; invoked on a background queue, so it must hop.
    var onKnock: (@Sendable () -> Void)?
    /// First look at every inbound connection. Returning `true` means the
    /// session has taken it over (it is reading a phone-initiated handshake);
    /// the advertiser must not cancel it or treat it as a knock. Returning
    /// `false`/nil keeps the legacy knock behaviour.
    ///
    /// A `Bool` cannot carry the real answer — only the first bytes can, and
    /// they have not arrived yet — so a session that wants to classify always
    /// returns `true` and cancels the connection itself if it turns out to be
    /// a knock. Invoked on a background queue.
    var onInbound: (@Sendable (NWConnection) -> Bool)?

    init(id: String, name: String, platform: String = "macos") {
        self.id = id
        self.name = name
        self.platform = platform
    }

    func start() {
        guard listener == nil else { return }
        do {
            // Fixed port so the phone can knock without resolving us.
            guard let port = NWEndpoint.Port(rawValue: IBServiceType.knockPort) else { return }
            let listener = try NWListener(using: .tcp, on: port)
            let txt = NWTXTRecord(IBServiceType.PresenceTXT.record(id: id, name: name,
                                                                  platform: platform))
            listener.service = NWListener.Service(name: name,
                                                  type: IBServiceType.computer,
                                                  domain: IBServiceType.domain,
                                                  txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in
                // A phone-initiated session's first frame tells the session what
                // this is; only fall back to the legacy knock when no session
                // takes the connection.
                if let onInbound = self?.onInbound, onInbound(connection) {
                    return
                }
                self?.onKnock?()
                connection.cancel()
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Self.log.error("presence advertise failed: \(error, privacy: .public)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            Self.log.info("advertising presence for \(self.name, privacy: .public)")
        } catch {
            Self.log.error("presence advertise could not start: \(error, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
