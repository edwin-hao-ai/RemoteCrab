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

    /// How long a computer may stay out of touch before its row is dropped.
    ///
    /// Generous on purpose: the cost of keeping a row too long is a stale
    /// line in a picker, and the cost of dropping one too early is a
    /// re-approval. Thirty days means a machine you use weekly never
    /// expires, and one you stopped using a year ago does.
    public static let staleSeenTTL: TimeInterval = 30 * 24 * 60 * 60

    /// Drop the rows the picker should no longer offer, newest-first.
    ///
    /// Two independent reasons, both self-healing rather than a control the
    /// user has to remember to use:
    ///
    /// 1. **Expiry.** A row for a machine that has not knocked in
    ///    `ttl` cannot be acted on — tapping it arms a preference for a
    ///    computer that will never connect under that id.
    /// 2. **Superseded identity.** `seen` is keyed by `id` alone, so every
    ///    time a receiver changes identity it adds a *new* row and the old
    ///    one can never be removed by id. That is exactly what a reinstall
    ///    used to do on Windows (`pc_id` lived in the app-data directory,
    ///    so uninstalling deleted it), and the user's picker filled with
    ///    identical "Windows PC" rows. A machine that has taken a new id
    ///    will never use the old one again, so among rows sharing a
    ///    display name only the most recent is a real choice.
    ///
    /// Names are compared case-insensitively because the same machine
    /// reports itself differently across operating systems ("EDWIN" from
    /// Windows, "Edwin's Mac" aside). The cost of this rule is that two
    /// genuinely different computers with the same hostname collapse into
    /// one row — accepted deliberately, because the alternative is a picker
    /// full of identical rows where picking the wrong one is invisible.
    ///
    /// Pure and static so the rules can be tested without `UserDefaults`.
    /// Output is newest-first, matching how `noteSeen` maintains the list.
    public static func pruned(_ entries: [SeenComputer],
                              now: Date = Date(),
                              ttl: TimeInterval = staleSeenTTL) -> [SeenComputer] {
        let fresh = entries.filter { now.timeIntervalSince($0.lastSeen) < ttl }
        // Best (most recent) entry per display name. Computed from
        // `lastSeen` rather than from position, so the result does not
        // depend on the caller happening to hand over a newest-first list.
        var best: [String: SeenComputer] = [:]
        for entry in fresh {
            let key = entry.name.trimmingCharacters(in: .whitespaces).lowercased()
            if let held = best[key], held.lastSeen >= entry.lastSeen { continue }
            best[key] = entry
        }
        // Sorted with an `id` tiebreaker so the result is a total order.
        // Two entries really can share a `lastSeen` (anything written in
        // the same second, and every fixture that does), and an unstable
        // sort there would make the row order — and therefore the test —
        // depend on hashing.
        return best.values.sorted { $0.lastSeen == $1.lastSeen
            ? $0.id < $1.id
            : $0.lastSeen > $1.lastSeen }
    }

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
        pruneStale()
        saveSeen()
        return entry
    }

    /// Apply `pruned(_:)` to the stored list. Called on every knock, and by
    /// the picker when it opens so an existing phone is cleaned without
    /// waiting for the next connection.
    ///
    /// A preference pointing at a dropped id is cleared for the same reason
    /// `forget` clears one: it names a computer that can no longer connect,
    /// and while it is armed every other computer is answered "in use".
    @discardableResult
    public func pruneStale(now: Date = Date()) -> Bool {
        let before = seen
        seen = Self.pruned(before, now: now)
        // Unconditional, even when nothing was removed. The earlier version
        // returned early on "count unchanged" — sound for *detecting* a
        // removal, but it made the postcondition a lie: a preference could
        // name an id that was never in `seen` at all (`setPreferred` takes
        // any string, and `setPreferredMac` does exactly that) and would
        // then sit armed for a computer with no row, answering every other
        // machine "in use" until the TTL ran out. Cheap to guarantee.
        if let preferred = preferredId, !seen.contains(where: { $0.id == preferred }) {
            clearPreferred()
        }
        guard seen.count != before.count else { return false }
        saveSeen()
        return true
    }

    /// What the chosen computer's most recent attempt produced, so the
    /// waiting banner can say **why** it is still waiting.
    ///
    /// The phone already recorded this for every computer (`SeenComputer
    /// .lastOutcome`) and never used it here, which is why a switch to a
    /// machine that was denied read exactly like a switch to one that is
    /// merely asleep — when one of them will never arrive on its own and the
    /// other will, in fifteen seconds.
    public func lastOutcome(for id: String) -> AttemptOutcome? {
        seen.first { $0.id == id }?.lastOutcome
    }

    /// Which computers "Choose a computer" lists.
    ///
    /// By **id**, and only excluding the one that is currently connected.
    /// The first cut also excluded anything whose *name* matched the pending
    /// computer, which silently hid every machine sharing a hostname — one
    /// user had two computers both named "EDWIN", so the other one was not
    /// in the list to be picked at all. A pending computer has its own
    /// section; leaving it in `seen` is deliberate, since re-picking it is
    /// how you recover from a stuck switch.
    public static func pickerRows(seen: [SeenComputer],
                                  connectedId: String?) -> [SeenComputer] {
        seen.filter { $0.id != connectedId }
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

    /// When the current preference was armed, ignoring `preferredTTL`.
    /// The grace period below is measured from here.
    public var preferredArmedAt: Date? {
        defaults.object(forKey: preferredAtKey) as? Date
    }

    /// How long the door is held open for the chosen computer.
    ///
    /// The 10-minute `preferredTTL` answers "how long until this preference
    /// is meaningless". This answers a different question: "how long should
    /// one computer lock everyone else out while we wait for it?" Ten
    /// minutes is the wrong number for that, because a computer that has not
    /// dialled in after half a minute is not going to — it is asleep, on
    /// another network, was denied, or has auto-reconnect switched off (all
    /// four are real states on the Mac side). Holding the door for the full
    /// TTL after such a computer means **nobody** can connect and the only
    /// way out is a Cancel button the user has to know exists.
    ///
    /// 30 s comfortably covers a Mac in the `busy` state, whose only retry
    /// is `scheduleSlowRetry` every 15 s — and a Mac that is actively trying
    /// connects in a few seconds, so the window is rarely spent.
    public static let preferredGrace: TimeInterval = 30

    /// The preference that should actually hold the door — `nil` once the
    /// grace period is spent, which reopens the door for every computer.
    ///
    /// This is the single point that turns a ten-minute self-inflicted
    /// lockout into a thirty-second wait, and it is where the fix belongs:
    /// `PairingPolicy.decide` already treats a `nil` preferred as "no
    /// preference", so no rule inside the policy needs to know about time.
    public func effectivePreferred(now: Date = Date()) -> PairedMac? {
        guard let preferred else { return nil }
        guard let armedAt = preferredArmedAt else { return preferred }
        return now.timeIntervalSince(armedAt) < Self.preferredGrace ? preferred : nil
    }

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

    /// Drop a computer entirely: its approval, its picker row, and any
    /// preference naming it.
    ///
    /// The picker lists `seen`, not `paired`, so forgetting only the
    /// approval left the machine sitting in "Choose a Computer" as a
    /// "not paired" row — a button labelled Forget that did not make the
    /// computer go away. `forgetSeen` already existed for exactly this and
    /// had no caller.
    ///
    /// Safe because nothing else depends on the row once the computer is
    /// forgotten: `PairingPolicy` reads `paired` for tokens and `preferred`
    /// for the door, and the only two readers of `seen` are the picker's own
    /// icon/label. A forgotten computer has no icon and no name to show.
    public func forget(id: String) {
        paired.removeAll { $0.id == id }
        forgetSeen(id: id)
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
