//! Proving who the other end is, without the secret travelling the wire.
//!
//! The hole this closes is impersonation, and the victim is the **computer**.
//! Any machine that answers `sessionReply accepted` on the phone's port is taken
//! at its word, and everything it sends afterwards — `touch`, `key`,
//! `systemCommand`, `clipboardSet`, `fileOffer` — is executed. So anyone on the
//! same WiFi can stand up a listener and drive this PC's keyboard.
//!
//! The pairing token was the thing that was supposed to prevent that, and it did
//! so by being *presented*: the receiver sent it in the clear in every
//! `clientHello`, and the phone compared it. A secret you hand over is not a
//! proof, it is a badge, and a badge can be copied by anyone who reads the same
//! bytes off the same wireless network.
//!
//! So the token stops being sent as a credential and becomes the **key** to a
//! mutual challenge-response. Both sides pick a nonce; both compute an HMAC over
//! both nonces and the machine's id; each verifies the other's. Nothing that
//! would let a listener impersonate either end ever crosses the wire, and a
//! replay of an earlier MAC fails because the nonces are new every time.
//!
//! What this does **not** do is encrypt anything. Clipboard text and file
//! contents are still readable by anyone on the path. That is a different
//! property with a different fix (TLS), and conflating the two is how "we
//! authenticate" becomes a claim about confidentiality that was never true.
//!
//! ## The shape of it
//!
//! ```text
//!   receiver                                phone
//!   --------                                -----
//!   clientHello { id, nonce_c }  ─────────▶
//!                                ◀─────────  sessionReply { pending,
//!                                              nonce_s, mac_s }
//!   verify mac_s                              mac_s = HMAC(token, "server", …)
//!   clientProof { mac_c }        ─────────▶
//!   mac_c = HMAC(token, "client", …)          verify mac_c
//!                                ◀─────────  sessionReply { accepted }
//! ```
//!
//! The two MACs are over the *same* four fields but under different labels, so
//! one cannot be replayed as the other. Without that, a phone could bounce a
//! receiver's own proof back at it and be believed.

use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use subtle::ConstantTimeEq;

/// The capability a phone names when it can do this.
///
/// Advertised by **this** side in `clientHello.capabilities` and answered by the
/// phone in `sessionReply.capabilities`. Absence means an older app, which is
/// handled by marking the session unauthenticated rather than by refusing it —
/// refusing would turn a security improvement into an outage on the day it
/// shipped, and the receiver has no way to update the phone.
pub const CAPABILITY: &str = "peerAuth";

/// Domain separation. A MAC computed for one role must never be accepted for the
/// other, or the phone can be convinced by its own reflection.
const SERVER_LABEL: &[u8] = b"RemoteCrab/v1/server";
const CLIENT_LABEL: &[u8] = b"RemoteCrab/v1/client";

/// 256 bits. The nonce only has to be unpredictable to a listener, so its length
/// is about how long a guesser would have to work, not about key strength.
const NONCE_BYTES: usize = 32;

type HmacSha256 = Hmac<Sha256>;

/// A fresh nonce, base64.
///
/// `getrandom` rather than a time-seeded PRNG: a predictable nonce turns a
/// challenge-response back into a replayable one, and there is no reason to take
/// that risk for one function call.
pub fn new_nonce() -> String {
    let mut bytes = [0u8; NONCE_BYTES];
    // A failure here means the OS has no entropy, which is not a state this can
    // recover from and not one to paper over with a weaker source.
    getrandom::getrandom(&mut bytes).expect("the OS entropy pool");
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// The MAC the phone must return for a given exchange.
pub fn server_mac(token: &str, pc_id: &str, client_nonce: &str, server_nonce: &str) -> String {
    compute(SERVER_LABEL, token, pc_id, client_nonce, server_nonce)
}

/// The MAC this receiver returns for the same exchange.
pub fn client_mac(token: &str, pc_id: &str, client_nonce: &str, server_nonce: &str) -> String {
    compute(CLIENT_LABEL, token, pc_id, client_nonce, server_nonce)
}

/// HMAC-SHA256 over the label, the machine id and both nonces.
///
/// Every field is separated by a NUL. The id is a UUID and the nonces are
/// base64, so none of them contains one — which makes the encoding unambiguous.
/// Without a separator, `("a", "bc")` and `("ab", "c")` hash the same bytes, and
/// a value an attacker controls meeting a value they do not is how concatenation
/// bugs become forgeries.
fn compute(
    label: &[u8],
    token: &str,
    pc_id: &str,
    client_nonce: &str,
    server_nonce: &str,
) -> String {
    // `new_from_slice` cannot fail: HMAC accepts a key of any length, and it is
    // an error type rather than a panic only because the trait is shared with
    // fixed-key constructions.
    let mut mac = HmacSha256::new_from_slice(token.as_bytes()).expect("HMAC accepts any key length");
    mac.update(label);
    for field in [pc_id, client_nonce, server_nonce] {
        mac.update(&[0]);
        mac.update(field.as_bytes());
    }
    base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes())
}

/// Is this the MAC we expected?
///
/// Constant time. The comparison is between two base64 strings of a fixed length,
/// so the length is not a secret and the loop below leaks nothing; `subtle` is
/// used rather than a `==` because `==` on `[u8]` short-circuits at the first
/// differing byte, and a MAC that can be guessed one byte at a time is not a MAC.
pub fn matches(expected: &str, presented: &str) -> bool {
    let (a, b) = (expected.as_bytes(), presented.as_bytes());
    a.len() == b.len() && bool::from(a.ct_eq(b))
}

#[cfg(test)]
mod tests {
    use super::{client_mac, matches, new_nonce, server_mac, CAPABILITY};

    const TOKEN: &str = "AZ3f-partner-token";
    const PC: &str = "fe3a662f-fb85-41d4-9950-dafdf75124fc";

    #[test]
    fn both_ends_compute_the_same_server_mac() {
        let mac = server_mac(TOKEN, PC, "nonce-c", "nonce-s");
        assert_eq!(mac, server_mac(TOKEN, PC, "nonce-c", "nonce-s"));
        assert!(matches(&mac, &server_mac(TOKEN, PC, "nonce-c", "nonce-s")));
    }

    /// The property the whole module exists for: a listener who saw every byte
    /// of a previous exchange still cannot produce the next one, because the
    /// nonces are new.
    #[test]
    fn the_nonce_changes_the_mac() {
        let first = server_mac(TOKEN, PC, "nonce-c", "nonce-s-1");
        let second = server_mac(TOKEN, PC, "nonce-c", "nonce-s-2");
        assert_ne!(first, second);
        assert!(!matches(&first, &second));
    }

    /// Without the separate labels a phone could bounce the receiver's own proof
    /// back and be believed. This is that attack, asserted against.
    #[test]
    fn a_client_mac_is_not_accepted_as_a_server_mac() {
        let as_client = client_mac(TOKEN, PC, "nonce-c", "nonce-s");
        let expected_server = server_mac(TOKEN, PC, "nonce-c", "nonce-s");
        assert_ne!(as_client, expected_server);
        assert!(!matches(&expected_server, &as_client));
    }

    /// The token is the key, so the wrong one must not verify — this is the
    /// impostor case, and it is the difference between the feature working and
    /// the feature being decorative.
    #[test]
    fn the_wrong_token_does_not_verify() {
        let mine = server_mac(TOKEN, PC, "nonce-c", "nonce-s");
        let theirs = server_mac("a-different-token", PC, "nonce-c", "nonce-s");
        assert!(!matches(&mine, &theirs));
    }

    /// A MAC is bound to the machine it was computed for, so an attacker cannot
    /// take a proof collected from one paired phone and use it to be a different
    /// one.
    #[test]
    fn the_machine_id_is_part_of_the_mac() {
        assert_ne!(
            server_mac(TOKEN, PC, "nonce-c", "nonce-s"),
            server_mac(TOKEN, "some-other-pc", "nonce-c", "nonce-s")
        );
    }

    /// The separator is load-bearing, and this is the case that proves it.
    #[test]
    fn fields_cannot_be_shifted_across_the_boundary() {
        // One byte moves from the id to the nonce. With separators these are
        // different messages; concatenated without them they would be identical.
        assert_ne!(
            server_mac(TOKEN, "ab", "c", "s"),
            server_mac(TOKEN, "a", "bc", "s")
        );
    }

    /// A nonce is unusable if it repeats.
    #[test]
    fn nonces_do_not_repeat() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..1000 {
            assert!(seen.insert(new_nonce()), "a nonce came up twice");
        }
    }

    /// Base64 of 32 bytes is 44 characters, and the compare must not be fooled
    /// by a length difference (nor panic on one).
    #[test]
    fn a_different_length_is_not_a_match() {
        let mac = server_mac(TOKEN, PC, "a", "b");
        assert_eq!(mac.len(), 44);
        assert!(!matches(&mac, &mac[..40]));
        assert!(!matches(&mac, ""));
        assert!(!matches("", &mac));
    }

    /// The capability string is a wire value shared with the phone. Spelled out
    /// because a rename that stopped on one side would silently disable the
    /// whole exchange — both ends would simply see an unknown capability.
    #[test]
    fn the_capability_is_the_agreed_string() {
        assert_eq!(CAPABILITY, "peerAuth");
    }

    /// Print the vectors for fixed inputs, so they can be baked in below.
    #[test]
    #[ignore = "a generator, run by hand to refresh the pinned vectors"]
    fn print_vectors() {
        println!(
            "server {}",
            server_mac("pin-token", "pin-pc", "pin-c", "pin-s")
        );
        println!(
            "client {}",
            client_mac("pin-token", "pin-pc", "pin-c", "pin-s")
        );
    }

    /// The cross-language contract, pinned.
    ///
    /// These four inputs are fixed so that the iOS side can compute the same two
    /// strings and assert against them. Nothing else in this file would catch a
    /// change that both Rust ends agreed on and the Swift decoder did not — the
    /// receiver and the phone would simply stop authenticating each other, and it
    /// would look like a network fault. If these values move, the iOS test in
    /// `docs/HANDOFF-IOS-PEER-AUTH.md` moves with them, in the same change.
    #[test]
    fn the_wire_format_is_pinned_for_the_other_language() {
        assert_eq!(
            server_mac("pin-token", "pin-pc", "pin-c", "pin-s"),
            "mk6oqPyEKo9XCtvvvYQhTx1jDlC62M2JOi974PubYRA="
        );
        assert_eq!(
            client_mac("pin-token", "pin-pc", "pin-c", "pin-s"),
            "8DT4HKeN9V5qqo+lrkRYhCTXeFVfpqcQLY0CBFj3WFg="
        );
    }
}
