import Foundation

public enum ComputerPresenceState: Equatable, Sendable {
    case online
    case offline(lastSeen: Date?)
}

public struct ComputerRosterEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let platform: String
    public let state: ComputerPresenceState

    public init(id: String, name: String, platform: String, state: ComputerPresenceState) {
        self.id = id
        self.name = name
        self.platform = platform
        self.state = state
    }

    public var isOnline: Bool { state == .online }
    public var isWindows: Bool { platform.lowercased() == "windows" }
}

/// Merges the live Bonjour sightings with the persisted history into the rows
/// the picker renders. Pure, so "which computer is online" is decided in one
/// testable place.
public enum ComputerRoster {
    public static func state(online: [ComputerPresence], seen: SeenComputer?, id: String) -> ComputerPresenceState {
        if online.contains(where: { $0.id == id }) { return .online }
        return .offline(lastSeen: seen?.lastSeen)
    }

    /// The user-visible name for a computer id, from its live announcement
    /// first, then history.
    ///
    /// Presence (`online`) is a second, independent source of "known
    /// computers": a brand-new machine is in the browse results before it has
    /// ever sent a `clientHello`, so it is *not* yet in `seen`. Resolving names
    /// from `seen` alone left such a computer unnameable — which silently broke
    /// arming a switch to it (the 10-07 current-computer design's "pair a new
    /// computer" and "re-pick any online computer" paths).
    public static func name(for id: String,
                            online: [ComputerPresence],
                            seen: [SeenComputer]) -> String? {
        if let live = online.first(where: { $0.id == id }) { return live.name }
        return seen.first(where: { $0.id == id })?.name
    }

    public static func entries(online: [ComputerPresence],
                               seen: [SeenComputer]) -> [ComputerRosterEntry] {
        let liveById = Dictionary(online.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let seenById = Dictionary(seen.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(liveById.keys).union(seenById.keys)

        var entries: [ComputerRosterEntry] = []
        for id in ids {
            if let live = liveById[id] {
                entries.append(ComputerRosterEntry(id: id, name: live.name,
                                                   platform: live.platform, state: .online))
            } else if let s = seenById[id] {
                entries.append(ComputerRosterEntry(id: id, name: s.name,
                                                   platform: s.platform,
                                                   state: .offline(lastSeen: s.lastSeen)))
            }
        }
        entries.sort { a, b in
            if a.isOnline != b.isOnline { return a.isOnline }
            if case let .offline(ad) = a.state, case let .offline(bd) = b.state {
                return (ad ?? .distantPast) > (bd ?? .distantPast)
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return entries
    }
}
