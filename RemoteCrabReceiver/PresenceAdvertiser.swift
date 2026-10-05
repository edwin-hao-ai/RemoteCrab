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

    init(id: String, name: String, platform: String = "macos") {
        self.id = id
        self.name = name
        self.platform = platform
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            let txt = NWTXTRecord(IBServiceType.PresenceTXT.record(id: id, name: name, platform: platform))
            listener.service = NWListener.Service(name: name,
                                                  type: IBServiceType.computer,
                                                  domain: IBServiceType.domain,
                                                  txtRecord: txt)
            listener.newConnectionHandler = { $0.cancel() }
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
