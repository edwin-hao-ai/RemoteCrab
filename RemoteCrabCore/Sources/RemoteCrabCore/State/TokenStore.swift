import Foundation
import Security

/// Where a per-computer pairing token is kept (F2).
///
/// The tokens were stored in cleartext in `UserDefaults` / a JSON file. A
/// pairing token is a bearer credential — whoever reads it can impersonate the
/// paired computer — so it belongs in the Keychain. This is an *opt-in*
/// abstraction: the store keeps its current JSON behaviour until you hand it a
/// token store, which also means tests never touch the real Keychain.
public protocol TokenStoring: Sendable {
    func token(for id: String) -> String?
    /// Returns true only if the write actually landed (so the caller can decide
    /// whether it is safe to drop the cleartext copy).
    @discardableResult func set(_ token: String, for id: String) -> Bool
    func remove(for id: String)
}

/// In-memory store — for tests and previews.
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String] = [:]
    public init() {}
    public func token(for id: String) -> String? { lock.lock(); defer { lock.unlock() }; return map[id] }
    @discardableResult public func set(_ token: String, for id: String) -> Bool {
        lock.lock(); map[id] = token; lock.unlock(); return true
    }
    public func remove(for id: String) { lock.lock(); map[id] = nil; lock.unlock() }
}

/// Keychain-backed store (generic password, one item per computer id).
public struct KeychainTokenStore: TokenStoring {

    public let service: String

    public init(service: String = "com.remotecrab.pairing") {
        self.service = service
    }

    private func baseQuery(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id]
    }

    public func token(for id: String) -> String? {
        var q = baseQuery(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func set(_ token: String, for id: String) -> Bool {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(id) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = baseQuery(id)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    public func remove(for id: String) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }
}
