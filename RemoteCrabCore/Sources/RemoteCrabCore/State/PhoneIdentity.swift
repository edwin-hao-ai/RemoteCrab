import Foundation

/// Stable, persisted identity of this iPhone.
///
/// The receiver keys pairings and tokens by this id, not by the phone's
/// display name, so renaming the device no longer forces a re-pair.
public enum PhoneIdentity {

    /// Persisted key. Additive: an older install that never wrote it simply
    /// generates one on first read.
    public static let key = "remotecrab.ios.phoneId"

    /// The override is E2E-only: it lets a device test relaunch the app under
    /// a known identity. It is never persisted, so a later launch without it
    /// still falls back to the real, stored id.
    public static func loadPhoneId(
        defaults: UserDefaults = .standard,
        override: String? = ProcessInfo.processInfo.environment["REMOTECRAB_E2E_PHONE_ID"]
    ) -> String {
        if let override, !override.isEmpty { return override }
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }
}
