//! Transport encryption (F1) — the Rust half of `TransportCipher`.
//!
//! This MUST produce byte-identical ciphertext to the Swift side. The proof is
//! the shared fixture `RemoteCrabCore/Tests/RemoteCrabCoreTests/Fixtures/
//! transport-vectors.json`, asserted by `tests/transport_vectors.rs`. The
//! `kind` byte is cleartext on the wire and is the AEAD's additional data.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;

/// The capability string the handshake advertises.
pub const VERSION: &str = "aead-v1";

const INFO: &[u8] = b"remotecrab-transport-v1";

/// HKDF-SHA256(token, salt = initiatorNonce ‖ responderNonce) → 32-byte key.
/// The token is never used as the key directly.
pub fn session_key(token: &str, initiator_nonce: &[u8], responder_nonce: &[u8]) -> [u8; 32] {
    let mut salt = Vec::with_capacity(initiator_nonce.len() + responder_nonce.len());
    salt.extend_from_slice(initiator_nonce);
    salt.extend_from_slice(responder_nonce);
    let hk = Hkdf::<Sha256>::new(Some(&salt), token.as_bytes());
    let mut okm = [0u8; 32];
    hk.expand(INFO, &mut okm)
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    okm
}

/// Seal `plaintext` with `kind` as AAD. Returns `nonce(12) ‖ ciphertext ‖ tag`.
/// The nonce is 4 zero bytes ‖ the 8-byte big-endian counter.
pub fn seal(key: &[u8; 32], counter: u64, kind: u8, plaintext: &[u8]) -> Vec<u8> {
    let cipher = ChaCha20Poly1305::new(key.into());
    let mut nonce = [0u8; 12];
    nonce[4..].copy_from_slice(&counter.to_be_bytes());
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(&nonce), Payload { msg: plaintext, aad: &[kind] })
        .expect("ChaCha20-Poly1305 encryption cannot fail for valid inputs");
    let mut out = Vec::with_capacity(12 + ciphertext.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);
    out
}
