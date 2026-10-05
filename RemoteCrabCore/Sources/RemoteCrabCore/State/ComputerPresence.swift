import Foundation

/// A computer currently announcing its presence on the LAN.
///
/// Deliberately not `SeenComputer`: that type is persisted history and carries
/// `lastOutcome`. This is a live sighting from Bonjour. `ComputerRoster` merges
/// the two into the rows the picker renders.
public struct ComputerPresence: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let platform: String
    public let lastSeen: Date

    public init(id: String, name: String, platform: String, lastSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.platform = platform
        self.lastSeen = lastSeen
    }

    public var isWindows: Bool { platform.lowercased() == "windows" }
}
