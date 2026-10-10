import Foundation
import CryptoKit

/// Transport-level encryption for the wire (F1).
///
/// `PeerAuth` answers "who are you" (HMAC challenge–response) but leaves every
/// frame — keystrokes, clipboard, camera, mic — in the clear on the LAN. This
/// seals each frame with ChaCha20-Poly1305, keyed from the pairing token, so a
/// sniffer on shared WiFi sees ciphertext. The key is per session and derived
/// via HKDF from the token + both handshake nonces (the token is **never**
/// reused as the transport key directly).
///
/// The `kind` byte stays cleartext so the receiver can route without
/// decrypting; it is also the AEAD's additional-authenticated-data, so a
/// tampered kind fails to open.
public enum TransportCipher {

    public static let versionName = "aead-v1"

    public enum Error: Swift.Error, Equatable {
        case malformed
        case replay
        case tooOld
    }

    /// HKDF-SHA256(token, salt = initiatorNonce ‖ responderNonce) → 32-byte key.
    public static func sessionKey(token: String, initiatorNonce: Data, responderNonce: Data) -> SymmetricKey {
        let ikm = SymmetricKey(data: Data(token.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: initiatorNonce + responderNonce,
            info: Data("remotecrab-transport-v1".utf8),
            outputByteCount: 32
        )
    }

    /// A short, non-reversible fingerprint of a key, for logs. Both ends must
    /// print the SAME value for a working seal; a mismatch names the side whose
    /// derivation inputs (token / nonces) differ — the diagnostic that pinned
    /// the "Mac seals, phone cannot open" split (2026-10-11).
    public static func fingerprint(_ key: SymmetricKey) -> String {
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) })
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Seals outgoing frames with a monotonically increasing nonce.
    public struct Sealer {
        private let key: SymmetricKey
        private var counter: UInt64 = 0

        public init(key: SymmetricKey) { self.key = key }

        /// Returns `[12-byte nonce][ciphertext][16-byte tag]`.
        public mutating func seal(_ plaintext: Data, kind: UInt8) -> Data {
            let nonceData = Self.nonce(prefix: counter)
            counter &+= 1
            // `try!` is safe: a 12-byte nonce is always valid and sealing only
            // fails on an invalid key size, which `sessionKey` never produces.
            let box = try! ChaChaPoly.seal(plaintext,
                                           using: key,
                                           nonce: try! ChaChaPoly.Nonce(data: nonceData),
                                           authenticating: Data([kind]))
            return nonceData + box.ciphertext + box.tag
        }

        /// 4 zero bytes ‖ 8-byte big-endian counter.
        private static func nonce(prefix counter: UInt64) -> Data {
            var d = Data(repeating: 0, count: 4)
            var be = counter.bigEndian
            withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
            return d
        }
    }

    /// Opens incoming frames and enforces a replay/age window.
    public struct Opener {
        private let key: SymmetricKey
        private var highest: UInt64 = 0
        private var seen: Set<UInt64> = []
        private let window: UInt64 = 1024

        public init(key: SymmetricKey) { self.key = key }

        public mutating func open(_ sealed: Data, kind: UInt8) throws -> Data {
            guard sealed.count >= 12 + 16 else { throw Error.malformed }
            let nonceData = Data(sealed.prefix(12))
            let body = sealed.dropFirst(12)
            let ciphertext = body.dropLast(16)
            let tag = body.suffix(16)

            let counter = Self.counter(from: nonceData)
            if let counter {
                if seen.contains(counter) { throw Error.replay }
                if counter + window < highest { throw Error.tooOld }
            }

            let box = try ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: nonceData),
                                               ciphertext: ciphertext,
                                               tag: tag)
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: Data([kind]))

            if let counter {
                seen.insert(counter)
                if counter > highest { highest = counter }
                if seen.count > 4096 { seen = seen.filter { $0 + window >= highest } }
            }
            return plaintext
        }

        private static func counter(from nonce: Data) -> UInt64? {
            guard nonce.count == 12, nonce.prefix(4).allSatisfy({ $0 == 0 }) else { return nil }
            var v: UInt64 = 0
            for b in nonce.suffix(8) { v = (v << 8) | UInt64(b) }
            return v
        }
    }
}
