import Foundation

/// The set of computer ids the user explicitly forgot, remembered across app
/// launches. Forgetting erases history/pairing; without persistence an online
/// forgotten computer reappears on the next launch (spec §7.3). Re-pairing or
/// explicitly picking a computer removes it again.
public struct ForgottenComputers: Equatable, Sendable {
    public private(set) var ids: Set<String>

    public init(ids: Set<String> = []) {
        self.ids = ids
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Forgetting erases history/pairing; persisted so it survives a relaunch.
    public mutating func forget(_ id: String) { ids.insert(id) }

    /// A computer the user re-paired or explicitly picked is no longer ended.
    public mutating func remember(_ id: String) { ids.remove(id) }
}
