//! Transport encryption (F1) — the Rust half of `TransportCipher`.
//!
//! This MUST produce byte-identical ciphertext to the Swift side. The proof is
//! the shared fixture `RemoteCrabCore/Tests/RemoteCrabCoreTests/Fixtures/
//! transport-vectors.json`, asserted by `tests/transport_vectors.rs`. The
//! `kind` byte is cleartext on the wire and is the AEAD's additional data.

use std::collections::HashSet;

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;

/// The capability string the handshake advertises.
pub const VERSION: &str = "aead-v1";

const INFO: &[u8] = b"remotecrab-transport-v1";

/// Replay/age window and the cap on remembered nonces, matching the Swift
/// `TransportCipher.Opener` (1024 / 4096). They decide which counter values are
/// "too old" and when the seen-set is pruned; both sides must agree on the
/// window or a fast sender's frames would be rejected as stale.
const WINDOW: u64 = 1024;
const MAX_SEEN: usize = 4096;

/// Why an incoming frame could not be opened. Mirrors the Swift
/// `TransportCipher.Error` so the two ends report the same four cases.
#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// Shorter than a nonce + tag, or the nonce is not the 12-byte shape.
    Malformed,
    /// This counter value was already opened (a replay).
    Replay,
    /// The counter is older than the window allows.
    TooOld,
    /// The AEAD tag did not verify (wrong key, wrong kind, or tampering).
    Auth,
}

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

/// Stateful sealer: a per-session monotonic counter that must never repeat.
/// Mirrors Swift's `TransportCipher.Sealer` (`counter &+= 1` after each seal).
pub struct Sealer {
    key: [u8; 32],
    counter: u64,
}

impl Sealer {
    pub fn new(key: [u8; 32]) -> Self {
        Sealer { key, counter: 0 }
    }

    /// Returns `nonce(12) ‖ ciphertext ‖ tag`, exactly like the free [`seal`].
    pub fn seal(&mut self, plaintext: &[u8], kind: u8) -> Vec<u8> {
        let out = seal(&self.key, self.counter, kind, plaintext);
        self.counter = self.counter.wrapping_add(1);
        out
    }
}

/// Stateful opener with a replay/age window. Mirrors Swift's
/// `TransportCipher.Opener`.
pub struct Opener {
    key: [u8; 32],
    highest: u64,
    seen: HashSet<u64>,
}

impl Opener {
    pub fn new(key: [u8; 32]) -> Self {
        Opener {
            key,
            highest: 0,
            seen: HashSet::new(),
        }
    }

    pub fn open(&mut self, sealed: &[u8], kind: u8) -> Result<Vec<u8>, Error> {
        if sealed.len() < 12 + 16 {
            return Err(Error::Malformed);
        }
        let nonce = &sealed[..12];
        let body = &sealed[12..];

        let counter = counter_from_nonce(nonce);
        if let Some(c) = counter {
            if self.seen.contains(&c) {
                return Err(Error::Replay);
            }
            // `counter + WINDOW < highest` — the same asymmetry the Swift side
            // uses (a frame exactly `WINDOW` old is still accepted).
            if c + WINDOW < self.highest {
                return Err(Error::TooOld);
            }
        }

        let cipher = ChaCha20Poly1305::new((&self.key).into());
        let plaintext = cipher
            .decrypt(Nonce::from_slice(nonce), Payload { msg: body, aad: &[kind] })
            .map_err(|_| Error::Auth)?;

        if let Some(c) = counter {
            self.seen.insert(c);
            if c > self.highest {
                self.highest = c;
            }
            if self.seen.len() > MAX_SEEN {
                let highest = self.highest;
                self.seen.retain(|&x| x + WINDOW >= highest);
            }
        }
        Ok(plaintext)
    }
}

/// The counter a nonce encodes, or `None` when it is not the 12-byte
/// `[4 zero][8 BE counter]` shape (in which case the replay window is skipped,
/// matching Swift's optional `counter(from:)`).
fn counter_from_nonce(nonce: &[u8]) -> Option<u64> {
    if nonce.len() != 12 || nonce[..4].iter().any(|&b| b != 0) {
        return None;
    }
    let mut v: u64 = 0;
    for &b in &nonce[8..] {
        v = (v << 8) | u64::from(b);
    }
    Some(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> [u8; 32] {
        session_key("tok", b"init", b"resp")
    }

    #[test]
    fn round_trips_and_is_kind_bound() {
        let k = key();
        let mut s = Sealer::new(k);
        let sealed = s.seal(b"hello", 0x13);
        // Fresh openers, because a successful open consumes the counter and a
        // second attempt on the same opener is a replay, not an auth failure.
        assert_eq!(Opener::new(k).open(&sealed, 0x13).unwrap(), b"hello".to_vec());
        // A different kind fails the AEAD (the kind is the AAD).
        assert_eq!(Opener::new(k).open(&sealed, 0x04), Err(Error::Auth));
    }

    #[test]
    fn rejects_a_replay() {
        let k = key();
        let mut s = Sealer::new(k);
        let mut o = Opener::new(k);
        let sealed = s.seal(b"once", 0x04);
        assert_eq!(o.open(&sealed, 0x04).unwrap(), b"once".to_vec());
        assert_eq!(o.open(&sealed, 0x04), Err(Error::Replay));
    }

    #[test]
    fn rejects_a_too_old_frame_but_allows_out_of_order() {
        let k = key();
        let mut s = Sealer::new(k);
        let mut o = Opener::new(k);
        // 1 + WINDOW frames: the first is now more than WINDOW behind.
        let first = s.seal(b"old", 0x04);
        for _ in 0..(WINDOW + 1) {
            let _ = s.seal(b"x", 0x04);
        }
        let newest = s.seal(b"new", 0x04);
        assert_eq!(o.open(&newest, 0x04).unwrap(), b"new".to_vec());
        assert_eq!(o.open(&first, 0x04), Err(Error::TooOld));
    }

    #[test]
    fn accepts_a_later_frame_before_an_earlier_one() {
        let k = key();
        let mut s = Sealer::new(k);
        let mut o = Opener::new(k);
        let a = s.seal(b"a", 0x04);
        let b = s.seal(b"b", 0x04);
        // Out of order must not wedge: b arrives first.
        assert_eq!(o.open(&b, 0x04).unwrap(), b"b".to_vec());
        assert_eq!(o.open(&a, 0x04).unwrap(), b"a".to_vec());
    }

    #[test]
    fn a_truncated_frame_is_malformed() {
        let k = key();
        let mut o = Opener::new(k);
        assert_eq!(o.open(&[0u8; 27], 0x04), Err(Error::Malformed));
    }

    #[test]
    fn the_first_counter_is_zero() {
        let k = key();
        let mut s = Sealer::new(k);
        let sealed = s.seal(b"x", 0x04);
        assert_eq!(&sealed[..12], &[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    }
}
