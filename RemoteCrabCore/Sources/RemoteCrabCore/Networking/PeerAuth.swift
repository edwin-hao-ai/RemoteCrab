import Foundation
import CryptoKit

/// Proving who the other end is, without the secret travelling the wire.
///
/// The hole this closes is impersonation, and the victim is the **computer**.
/// Any machine that answers `sessionReply accepted` on the phone's port used to
/// be taken at its word, and everything it sent afterwards — `touch`, `key`,
/// `systemCommand`, `clipboardSet`, `fileOffer` — was executed. So anyone on the
/// same WiFi could stand up a listener and drive the computer's keyboard.
///
/// The pairing token was the thing that was supposed to prevent that, and it did
/// so by being *presented*: the receiver sent it in the clear in every
/// `clientHello`, and the phone compared it. A secret you hand over is not a
/// proof, it is a badge, and a badge can be copied by anyone who reads the same
/// bytes off the same wireless network.
///
/// So the token stops being sent as a credential and becomes the **key** to a
/// mutual challenge-response. Both sides pick a nonce; both compute an HMAC over
/// both nonces and the machine's id; each verifies the other's. Nothing that
/// would let a listener impersonate either end ever crosses the wire, and a
/// replay of an earlier MAC fails because the nonces are new every time.
///
/// This does **not** encrypt anything. Clipboard text and file contents are
/// still readable by anyone on the path. That is a different property with a
/// different fix (TLS), and conflating the two is how "we authenticate" becomes
/// a claim about confidentiality that was never true.
///
/// ## The shape of it
///
/// ```text
///   receiver                                phone
///   --------                                -----
///   clientHello { id, nonce_c }  ─────────▶
///                                ◀─────────  sessionReply { pending,
///                                              nonce_s, mac_s }
///   verify mac_s                              mac_s = HMAC(token, "server", …)
///   clientProof { mac_c }        ─────────▶
///   mac_c = HMAC(token, "client", …)          verify mac_c
///                                ◀─────────  sessionReply { accepted }
/// ```
///
/// The two MACs are over the *same* four fields but under different labels, so
/// one cannot be replayed as the other. Without that, a phone could bounce a
/// receiver's own proof back at it and be believed.
///
/// The byte layout is mirrored by `rc-protocol/src/peer_auth.rs`; the pinned
/// vectors in `PeerAuthTests` are how the two languages confirm they compute the
/// same string.
public enum PeerAuth {

    /// The capability a phone or receiver names when it can do this.
    ///
    /// Advertised by the receiver in `clientHello.capabilities` and echoed by the
    /// phone in `sessionReply.capabilities`. Absence means an older peer, which
    /// is handled by marking the session unauthenticated rather than by refusing
    /// it — refusing would turn a security improvement into an outage on the day
    /// it shipped, and neither end can update the other.
    public static let capability = "peerAuth"

    /// Domain separation. A MAC computed for one role must never be accepted for
    /// the other, or the phone can be convinced by its own reflection.
    private static let serverLabel = "RemoteCrab/v1/server"
    private static let clientLabel = "RemoteCrab/v1/client"

    /// 32 random bytes, base64. `SymmetricKey(size:)` is a CSPRNG rather than a
    /// time-seeded PRNG: a predictable nonce turns a challenge-response back into
    /// a replayable one, and there is no reason to take that risk for one call.
    public static func newNonce() -> String {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return data.base64EncodedString()
    }

    /// The MAC the phone must return for a given exchange.
    public static func serverMac(token: String, pcID: String,
                                 clientNonce: String, serverNonce: String) -> String {
        compute(label: serverLabel, token: token, pcID: pcID,
                clientNonce: clientNonce, serverNonce: serverNonce)
    }

    /// The MAC the receiver must return for the same exchange.
    public static func clientMac(token: String, pcID: String,
                                 clientNonce: String, serverNonce: String) -> String {
        compute(label: clientLabel, token: token, pcID: pcID,
                clientNonce: clientNonce, serverNonce: serverNonce)
    }

    /// HMAC-SHA256 over the label, the machine id and both nonces.
    ///
    /// Every field is separated by a NUL. The id is a UUID and the nonces are
    /// base64, so none of them contains one — which makes the encoding
    /// unambiguous. Without a separator, `("a", "bc")` and `("ab", "c")` hash the
    /// same bytes, and a value an attacker controls meeting a value they do not
    /// is how concatenation bugs become forgeries.
    private static func compute(label: String, token: String, pcID: String,
                                clientNonce: String, serverNonce: String) -> String {
        var message = Data(label.utf8)
        for field in [pcID, clientNonce, serverNonce] {
            message.append(0)
            message.append(contentsOf: field.utf8)
        }
        let key = SymmetricKey(data: Data(token.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).base64EncodedString()
    }

    /// Is this the MAC we expected?
    ///
    /// Constant time. The comparison is between two base64 strings of a fixed
    /// length, so the length is not a secret and the loop below leaks nothing; a
    /// `==` on `[UInt8]` short-circuits at the first differing byte, and a MAC
    /// that can be guessed one byte at a time is not a MAC.
    public static func matches(expected: String, presented: String) -> Bool {
        let a = Array(expected.utf8)
        let b = Array(presented.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
