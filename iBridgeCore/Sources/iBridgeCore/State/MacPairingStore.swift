import Foundation

/// A Mac the iPhone has explicitly approved to use its streams.
/// Identified by a stable per-Mac UUID and guarded by a shared token.
public struct PairedMac: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public let pairedAt: Date
    public var token: String

    public init(id: String, name: String, pairedAt: Date = Date(), token: String) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.token = token
    }
}

/// The owner decision for an incoming Mac connection.
public enum PairingDecision: Equatable, Sendable {
    /// Known Mac (id + token match) — serve it.
    case accept
    /// Unknown Mac — ask the user on the iPhone.
    case pending
    /// Another Mac owns the session — refuse politely.
    case busy(ownerName: String)
}

/// Pure ownership policy so it can be unit-tested without any network.
public enum PairingPolicy {

    /// Decide what to do with a freshly-connected Mac.
    ///
    /// - Parameters:
    ///   - hello: the Mac's identity handshake.
    ///   - paired: every Mac the user has approved so far.
    ///   - owner: the Mac currently owning the session, if any.
    public static func decide(
        hello: IBClientHello,
        paired: [PairedMac],
        owner: PairedMac?
    ) -> PairingDecision {
        // A different Mac is already being served — even a paired one
        // must wait for the owner to release the session.
        if let owner, owner.id != hello.id {
            return .busy(ownerName: owner.name)
        }
        // Owner reconnecting, or a fresh connection from a known Mac:
        // only auto-accept when the token proves identity.
        if let match = paired.first(where: { $0.id == hello.id }),
           let token = hello.token, token == match.token {
            return .accept
        }
        // Unknown Mac, or a known id without the right token.
        return .pending
    }
}

/// Persisted allow-list of paired Macs, backed by `UserDefaults`.
///
/// Tokens are minted on first approval and handed to the Mac in the
/// `sessionReply`; the Mac echoes its token in every later `clientHello`
/// so a same-LAN impostor cannot claim a paired id.
public final class MacPairingStore {

    private let defaults: UserDefaults
    private let key: String

    public private(set) var paired: [PairedMac]

    public init(defaults: UserDefaults = .standard, key: String = "ibridge.ios.pairedMacs") {
        self.defaults = defaults
        self.key = key
        self.paired = Self.load(from: defaults, key: key)
    }

    /// Approve a Mac. Re-pairing an existing id keeps its token and
    /// refreshes the display name; a new id gets a fresh token.
    @discardableResult
    public func pair(_ hello: IBClientHello) -> PairedMac {
        if let idx = paired.firstIndex(where: { $0.id == hello.id }) {
            paired[idx].name = hello.name
            save()
            return paired[idx]
        }
        let mac = PairedMac(id: hello.id, name: hello.name, token: UUID().uuidString)
        paired.append(mac)
        save()
        return mac
    }

    public func forget(id: String) {
        paired.removeAll { $0.id == id }
        save()
    }

    public func rename(id: String, to name: String) {
        guard let idx = paired.firstIndex(where: { $0.id == id }) else { return }
        paired[idx].name = name
        save()
    }

    public func removeAll() {
        paired = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(paired) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> [PairedMac] {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode([PairedMac].self, from: data) else {
            return []
        }
        return value
    }
}
