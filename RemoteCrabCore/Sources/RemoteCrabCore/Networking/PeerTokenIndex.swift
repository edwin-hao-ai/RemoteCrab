import Foundation

/// Pairing tokens, keyed by a phone's **stable id**, with a one-time migration
/// from the legacy **name** key.
///
/// Tokens used to be stored under the phone's display name because the name was
/// the only thing the receiver had. A name is not an identity: two phones can
/// share one, and a user can rename theirs, so a token found by name can belong
/// to the wrong device. The phone-initiated design gives every phone a stable
/// `phoneId`, so lookups are by id.
///
/// A phone that paired before this change has its token under the name key only.
/// Rather than drop it (which would force every existing user through approval
/// again), `token(phoneId:name:)` falls back to the name and, on a hit,
/// **backfills the id entry** so the next lookup needs no name. The name table is
/// kept in sync by `set`, so an older name-only lookup against the same index
/// still resolves.
///
/// Pure value type — no `UserDefaults`, no networking. The receiver owns
/// persistence and wraps this around its stored dictionaries.
public struct PeerTokenIndex: Equatable, Sendable {

    public private(set) var byPhoneId: [String: String]
    public private(set) var byName: [String: String]
    public private(set) var phoneInitiated: Set<String>

    public init(byPhoneId: [String: String] = [:], byName: [String: String] = [:],
                phoneInitiated: Set<String> = []) {
        self.byPhoneId = byPhoneId
        self.byName = byName
        self.phoneInitiated = phoneInitiated
    }

    /// Look the token up by id first; on a miss, fall back to the legacy name
    /// key and migrate the result into the id table.
    public mutating func token(phoneId: String, name: String) -> String? {
        if let t = byPhoneId[phoneId] { return t }
        guard let t = byName[name] else { return nil }
        byPhoneId[phoneId] = t
        return t
    }

    /// Record a token under both keys, so id-keyed and legacy name-keyed
    /// lookups both resolve.
    public mutating func set(phoneId: String, name: String, token: String) {
        byPhoneId[phoneId] = token
        byName[name] = token
    }

    public func isPhoneInitiated(phoneId: String) -> Bool { phoneInitiated.contains(phoneId) }

    public mutating func markPhoneInitiated(phoneId: String) { phoneInitiated.insert(phoneId) }

    /// Drop a phone entirely: its token, any legacy name entry that still
    /// resolves to that token, and its phone-initiated flag. The token is
    /// stashed before removal so the name table cannot resurrect it on the
    /// next `token(phoneId:name:)` lookup.
    public mutating func forget(phoneId: String) {
        if let token = byPhoneId.removeValue(forKey: phoneId) {
            for (name, value) in byName where value == token {
                byName.removeValue(forKey: name)
            }
        }
        phoneInitiated.remove(phoneId)
    }
}
