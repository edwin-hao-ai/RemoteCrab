//! Cross-language proof: this Rust cipher must produce the exact bytes the
//! Swift `TransportCipher` produced, asserted against the shared fixture.

use rc_protocol::transport::{seal, session_key};

fn hex_decode(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn rust_seal_matches_the_swift_vectors() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../RemoteCrabCore/Tests/RemoteCrabCoreTests/Fixtures/transport-vectors.json"
    );
    let data = std::fs::read_to_string(path).expect("read the shared vectors");
    let vectors: Vec<serde_json::Value> = serde_json::from_str(&data).expect("parse vectors");
    assert!(!vectors.is_empty(), "the fixture must not be empty");

    for v in &vectors {
        let token = v["token"].as_str().unwrap();
        let initiator = hex_decode(v["initiatorNonceHex"].as_str().unwrap());
        let responder = hex_decode(v["responderNonceHex"].as_str().unwrap());
        let kind = v["kind"].as_u64().unwrap() as u8;
        let plaintext = hex_decode(v["plaintextHex"].as_str().unwrap());
        let expected = v["sealedHex"].as_str().unwrap();

        let key = session_key(token, &initiator, &responder);
        let sealed = seal(&key, 0, kind, &plaintext);
        assert_eq!(hex_encode(&sealed), expected, "seal mismatch for token {token}");
    }
}
