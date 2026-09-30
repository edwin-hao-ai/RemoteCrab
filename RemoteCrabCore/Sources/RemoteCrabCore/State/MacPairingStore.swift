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

/// How the last attempt from a computer we have seen turned out.
///
/// This is the whole point of `SeenComputer`: a computer that *found* us but
/// was turned away is a completely different problem from one that never
/// found us, and from the outside they look identical — both are just "not
/// connected". The phone already sees the difference (the `clientHello`
/// arrives before any decision is made), so it is worth recording.
///
/// Optional so that a `seenComputers` blob written by an older build decodes
/// without losing the history: Swift's synthesized `Decodable` reads an
/// optional property as `nil` when the key is absent.
public enum AttemptOutcome: Codable, Sendable, Equatable {
    /// It is the one streaming right now.
    case streaming
    /// Knocked, and is waiting for the user to tap Allow.
    case waitingApproval
    /// Knocked, and was told someone else already owns the iPhone.
    case refusedBusy(owner: String)
    /// Knocked, and the user said no.
    case denied

    /// A short, user-facing label. No raw enum names, no error codes.
    public var summary: String {
        switch self {
        case .streaming: return IBLocale.Pairing.Attempt.streaming
        case .waitingApproval: return IBLocale.Pairing.Attempt.waitingApproval
        case .refusedBusy: return IBLocale.Pairing.Attempt.refusedBusyShort
        case .denied: return IBLocale.Pairing.Attempt.denied
        }
    }
}

/// A computer this iPhone has *seen* connect, whether or not it was ever
/// approved. Powers the "Choose a Computer" picker so a brand-new machine
/// (e.g. a Windows PC that has never paired) is still selectable — the
/// user shouldn't have to know the difference between "seen" and "paired".
public struct SeenComputer: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    /// `"macos"` | `"windows"` | `"linux"`. Defaults to `"macos"` for
    /// older senders that omit the field.
    public var platform: String
    public var lastSeen: Date
    /// What its most recent attempt produced, or `nil` for a computer that
    /// has been seen but has not knocked since this field existed.
    public var lastOutcome: AttemptOutcome?

    public init(id: String, name: String, platform: String, lastSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.platform = platform
        self.lastSeen = lastSeen
        self.lastOutcome = nil
    }

    /// A display-ready label that says which OS it is, so a user with both
    /// a Mac and a PC on the network can tell them apart at a glance.
    public var isWindows: Bool { platform.lowercased() == "windows" }
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
    ///   - preferred: the Mac the user just picked on the iPhone, if
    ///     any. While a preference is outstanding, every *other* Mac —
    ///     paired or not — is answered `busy` so the preferred Mac can
    ///     take over on its next connect ("holding the door").
    public static func decide(
        hello: IBClientHello,
        paired: [PairedMac],
        owner: PairedMac?,
        preferred: PairedMac? = nil
    ) -> PairingDecision {
        // A different Mac is already being served — even a paired one
        // must wait for the owner to release the session.
        if let owner, owner.id != hello.id {
            return .busy(ownerName: owner.name)
        }
        // A preference is outstanding and this isn't the chosen Mac —
        // hold the door (even for a paired Mac with a valid token) so
        // the preferred Mac can take over on its next connect.
        //
        // The preferred record may be synthetic (a computer that has knocked
        // but has never been approved), which is precisely the case this
        // branch exists for: without it, "switch to my Windows PC" stores an
        // id that resolves to nothing and the switch silently reverts.
        if let preferred, preferred.id != hello.id {
            return .busy(ownerName: preferred.name)
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
    private let preferredIdKey: String
    private let preferredAtKey: String
    /// The name of the preferred computer, kept so a preference can be armed
    /// for a computer that is not paired *yet*.
    ///
    /// This is the fix for a door that did not open. `preferred` used to be
    /// `paired.first { $0.id == id }`, so picking a brand-new machine (which is
    /// the whole reason the picker's list is `seen`, not `paired`) stored an
    /// id that resolved to `nil` — and a `nil` preferred means
    /// `PairingPolicy.decide`'s "hold the door" branch never ran, so the other
    /// computer took the session back three seconds later and the user's
    /// switch silently reverted. Storing the name lets us synthesise the
    /// record. An empty token is correct here: the computer has to be approved
    /// once, which routes it through `pending` exactly as it should.
    private let preferredNameKey: String
    private let seenKey: String

    /// Every computer that has ever connected (paired or not), newest
    /// first. Capped so a long-lived install can't grow it without bound.
    public private(set) var seen: [SeenComputer]

    /// How many entries `seen` keeps. Enough to cover a home/office LAN
    /// without hoarding stale machines forever.
    public static let seenLimit = 20

    /// The allow-list of approved computers.
    public private(set) var paired: [PairedMac]

    public init(defaults: UserDefaults = .standard, key: String = "remotecrab.ios.pairedMacs") {
        self.defaults = defaults
        self.key = key
        self.preferredIdKey = key + ".preferredId"
        self.preferredAtKey = key + ".preferredAt"
        self.preferredNameKey = key + ".preferredName"
        self.seenKey = key + ".seenComputers"
        self.paired = Self.load(from: defaults, key: key)
        self.seen = Self.loadSeen(from: defaults, key: key + ".seenComputers")
    }

    /// Record/refresh a computer in the seen list. Called on every
    /// `clientHello` — before any approval — so the picker can list a
    /// machine the user has never paired.
    @discardableResult
    public func noteSeen(_ hello: IBClientHello) -> SeenComputer {
        let platform = hello.platform ?? "macos"
        let entry = SeenComputer(
            id: hello.id,
            name: hello.name,
            platform: platform,
            lastSeen: Date()
        )
        seen.removeAll { $0.id == hello.id }
        seen.insert(entry, at: 0)
        if seen.count > Self.seenLimit {
            seen = Array(seen.prefix(Self.seenLimit))
        }
        saveSeen()
        return entry
    }

    /// The platform we last saw for a given computer id.
    public func platform(for id: String) -> String? {
        seen.first(where: { $0.id == id })?.platform
    }

    public func forgetSeen(id: String) {
        seen.removeAll { $0.id == id }
        saveSeen()
    }

    /// How long a "switch to this Mac" preference stays armed. After
    /// that the door opens again — the user may have changed their mind
    /// or the preferred Mac may simply be off.
    public static let preferredTTL: TimeInterval = 10 * 60

    /// The id of the Mac the user picked in the iOS Mac picker, if the
    /// preference is still fresh.
    public var preferredId: String? {
        guard let id = defaults.string(forKey: preferredIdKey) else { return nil }
        let at = defaults.object(forKey: preferredAtKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(at) < Self.preferredTTL else { return nil }
        return id
    }

    /// The preferred computer's record, so the policy can name it in `busy`.
    ///
    /// Falls back to a synthetic record built from `preferredName` when the
    /// computer is not in the allow-list yet. Backward compatible: a blob
    /// written before `preferredName` existed always named a *paired* Mac, so
    /// the first lookup still resolves it.
    public var preferred: PairedMac? {
        guard let id = preferredId else { return nil }
        if let paired = paired.first(where: { $0.id == id }) { return paired }
        guard let name = defaults.string(forKey: preferredNameKey), !name.isEmpty else {
            return nil
        }
        // Never paired, so it has no token yet — which is exactly why it will
        // be answered `pending` and the user gets one approval card. That is
        // the correct first-contact behaviour, not a bug.
        return PairedMac(id: id, name: name, pairedAt: .distantPast, token: "")
    }

    public func setPreferred(id: String, name: String? = nil, at: Date = Date()) {
        defaults.set(id, forKey: preferredIdKey)
        defaults.set(at, forKey: preferredAtKey)
        if let name { defaults.set(name, forKey: preferredNameKey) }
    }

    public func clearPreferred() {
        defaults.removeObject(forKey: preferredIdKey)
        defaults.removeObject(forKey: preferredAtKey)
        defaults.removeObject(forKey: preferredNameKey)
    }

    /// Record what a computer's latest attempt produced, so the picker can say
    /// "found you, was turned away" instead of leaving the user to guess.
    @discardableResult
    public func noteOutcome(_ outcome: AttemptOutcome, for id: String) -> SeenComputer? {
        guard let idx = seen.firstIndex(where: { $0.id == id }) else { return nil }
        seen[idx].lastOutcome = outcome
        seen[idx].lastSeen = Date()
        saveSeen()
        return seen[idx]
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
        if preferredId == id { clearPreferred() }
        save()
    }

    public func rename(id: String, to name: String) {
        guard let idx = paired.firstIndex(where: { $0.id == id }) else { return }
        paired[idx].name = name
        save()
    }

    public func removeAll() {
        paired = []
        clearPreferred()
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

    private func saveSeen() {
        if let data = try? JSONEncoder().encode(seen) {
            defaults.set(data, forKey: seenKey)
        }
    }

    private static func loadSeen(from defaults: UserDefaults, key: String) -> [SeenComputer] {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode([SeenComputer].self, from: data) else {
            return []
        }
        return value
    }
}
