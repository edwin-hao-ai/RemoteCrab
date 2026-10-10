import Foundation
import CryptoKit

/// Whether a session is sealed, and with what key (F1).
///
/// Pulled out of the two connection paths so the decision is one testable
/// function: a peer that did **not** advertise `aead-v1` — an old build — or a
/// session missing the token/nonces stays **cleartext**, never a half-keyed
/// state. When both ends advertise it, the key is HKDF(token, both nonces).
public enum TransportNegotiation {

    /// The key to seal with, or nil to stay cleartext.
    public static func sessionKey(peerTransport: String?,
                                  token: String?,
                                  clientNonce: String?,
                                  serverNonce: String?) -> SymmetricKey? {
        guard peerTransport == TransportCipher.versionName,
              let token, let clientNonce, let serverNonce else { return nil }
        return TransportCipher.sessionKey(token: token,
                                          initiatorNonce: Data(clientNonce.utf8),
                                          responderNonce: Data(serverNonce.utf8))
    }
}
