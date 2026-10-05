//! Auto-update: a signed feed, a verified download, and a silent install.
//!
//! The design is deliberately the same shape the Mac already uses for Sparkle:
//! an **Ed25519 public key pinned in the binary**, and an update that is not
//! signed by its private half is not an update. No certificate authority, no
//! trust chain, nothing that can expire — and nothing that has to be re-bought
//! before this feature can ship, which is what a "code signing certificate"
//! would have meant.
//!
//! What that buys and what it does not:
//!
//! * **Integrity and authenticity**: yes. An attacker who controls the feed
//!   host, the DNS, or the wire cannot produce a valid signature, so they cannot
//!   push an executable to every install.
//! * **SmartScreen reputation**: no. A manually downloaded installer still says
//!   "unknown publisher" until the binary carries a trusted Authenticode
//!   signature. That is a *first-install* polish problem, and it is separate
//!   from whether updates can be trusted.
//!
//! The private key never exists in this program. It is used at release time by
//! `scripts/release-windows.sh`, which signs the MSI with `openssl`; see
//! `secrets/README.md`.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The key every update must be signed with.
///
/// Regenerating this key is a **breaking change for the whole fleet**: an
/// install that carries the old key cannot verify anything signed by the new
/// one, so the transition needs a build that trusts both, shipped before the
/// key is switched. Written down because it is the kind of thing that looks
/// harmless in a diff.
pub const UPDATE_PUBLIC_KEY: [u8; 32] = [
    0x02, 0x95, 0x65, 0xb9, 0x0e, 0x70, 0x52, 0xa0, 0xf5, 0x83, 0x7a, 0x40, 0xec, 0x89, 0x05,
    0x2c, 0xda, 0x91, 0xc2, 0xae, 0x35, 0x11, 0x70, 0x47, 0x43, 0x44, 0x0b, 0xbf, 0x33, 0x3d,
    0xa4, 0x0c,
];

/// Where the release feed lives.
///
/// Overridable at build time, because staging needs to point somewhere else and
/// a test needs to point at localhost. The default is the same host the Mac's
/// Sparkle feed already uses, so publishing a Windows release means putting two
/// files next to an existing one rather than standing up anything new.
pub fn feed_url() -> &'static str {
    option_env!("RC_UPDATE_FEED")
        .filter(|s| !s.is_empty())
        .unwrap_or("https://vgoapp.com/downloads/windows/manifest.json")
}

/// What the feed says is available.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
pub struct Manifest {
    pub version: String,
    /// Absolute URL of the `.msi`.
    pub msi: String,
    /// Absolute URL of the detached Ed25519 signature over the `.msi` bytes.
    pub sig: String,
    /// Shown in the update prompt. Optional so a release script that has nothing
    /// to say does not have to invent something.
    #[serde(default)]
    pub notes: Option<String>,
}

/// The largest thing we will read into memory. The real MSI is ~2 MB; the bound
/// exists so a hostile or broken feed cannot exhaust the process before the
/// signature check — which is the only thing that ever decides.
const MAX_DOWNLOAD: u64 = 256 * 1024 * 1024;

fn fetch(url: &str) -> Result<Vec<u8>, String> {
    let response = ureq::get(url)
        .timeout(Duration::from_secs(30))
        .call()
        .map_err(|e| format!("{url}: {e}"))?;
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(MAX_DOWNLOAD)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("{url}: {e}"))?;
    Ok(bytes)
}

pub fn parse_manifest(bytes: &[u8]) -> Result<Manifest, String> {
    let manifest: Manifest =
        serde_json::from_slice(bytes).map_err(|e| format!("the feed is not a manifest: {e}"))?;
    if manifest.version.trim().is_empty() {
        return Err("the feed names no version".to_string());
    }
    for (what, url) in [("msi", &manifest.msi), ("sig", &manifest.sig)] {
        if !url.starts_with("https://") {
            // Plain http would let anyone on the path swap the bytes. The
            // signature would still catch it, but refusing here means the
            // failure is a sentence rather than a confusing verification error.
            return Err(format!("the feed's {what} URL is not https: {url}"));
        }
    }
    Ok(manifest)
}

/// Whether `candidate` is a later release than `current`.
///
/// Numeric per component, because `"1.10.0" < "1.9.0"` as strings and that is
/// the release where someone notices. Anything unparseable compares as equal, so
/// a malformed feed cannot talk an install into "upgrading" to something older.
pub fn is_newer(candidate: &str, current: &str) -> bool {
    let parse = |s: &str| -> Option<Vec<u64>> {
        s.trim()
            .split('.')
            .map(|part| part.parse::<u64>().ok())
            .collect()
    };
    match (parse(candidate), parse(current)) {
        (Some(a), Some(b)) => a > b,
        _ => false,
    }
}

/// Whether `signature` is a valid Ed25519 signature over `bytes` by `key`.
pub fn verify(bytes: &[u8], signature: &[u8], key: &[u8; 32]) -> bool {
    let Ok(verifying) = ed25519_dalek::VerifyingKey::from_bytes(key) else {
        return false;
    };
    let Ok(signature) = ed25519_dalek::Signature::from_slice(signature) else {
        return false;
    };
    // `verify_strict` rather than `verify`: it rejects small-order and
    // non-canonical keys, which is the difference that matters when the thing
    // being verified is an executable.
    verifying.verify_strict(bytes, &signature).is_ok()
}

/// Check the feed. `Ok(None)` means "up to date"; it is not an error.
/// Check the feed. `Ok(None)` means "up to date"; it is not an error.
///
/// No key, deliberately. The *manifest* is not signed — only the MSI it points
/// at is — so there is nothing to verify here and no reason to pretend
/// otherwise. A manifest cannot do harm on its own: it can name a version and a
/// URL, and the URL's contents still have to survive [`verify`] before anything
/// is written to disk.
pub fn check(current_version: &str) -> Result<Option<Manifest>, String> {
    check_from(feed_url(), current_version)
}

pub fn check_from(url: &str, current_version: &str) -> Result<Option<Manifest>, String> {
    let manifest = parse_manifest(&fetch(url)?)?;
    if is_newer(&manifest.version, current_version) {
        Ok(Some(manifest))
    } else {
        Ok(None)
    }
}

/// Download the MSI and its signature, verify, and leave the file on disk.
///
/// Verification happens **before** anything is written to the update directory:
/// a file that failed the check must never be somewhere a later code path might
/// mistake for staged and ready.
pub fn stage(manifest: &Manifest, dir: &Path, key: &[u8; 32]) -> Result<PathBuf, String> {
    let bytes = fetch(&manifest.msi)?;
    let signature = fetch(&manifest.sig)?;
    if !verify(&bytes, &signature, key) {
        return Err(format!(
            "the update is not signed by this build's key — refusing to install {}",
            manifest.version
        ));
    }
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let path = dir.join(format!("RemoteCrab-{}.msi", manifest.version));
    std::fs::write(&path, &bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(path)
}

/// Run the installer silently and let it replace us.
///
/// `/qb` rather than `/qn`: a silent install that fails leaves no trace anywhere
/// a user would look, and this is the one moment they are watching for
/// something to happen. A progress bar is honest.
///
/// The caller should exit immediately afterwards — Windows will not replace a
/// running executable, so staying alive makes the upgrade fail with a sharing
/// violation that reads as "the update is broken".
pub fn install(msi: &Path) -> Result<(), String> {
    let status = std::process::Command::new("msiexec")
        .arg("/i")
        .arg(msi)
        .arg("/qb")
        .status()
        .map_err(|e| format!("could not start msiexec: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("the installer exited with {status}"))
    }
}

/// Where a staged download waits between "verified" and "the user agreed".
pub fn update_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("RemoteCrab").join("update")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole path, over a real socket: fetch the MSI and its signature, check
    /// the signature, and only then write anything.
    ///
    /// The manifest URLs here are `http://` because the server is a thread on
    /// localhost — tighter than that is `parse_manifest`'s job, and it is tested
    /// above. What this covers is the part a unit test cannot: that the bytes
    /// fetched over a socket are the bytes that get verified, and that a failed
    /// check leaves nothing behind for a later run to mistake for staged.
    #[test]
    fn staging_verifies_over_the_wire_and_leaves_nothing_on_failure() {
        let good = local_server(vec![
            ("/x.msi".to_string(), SIGNED.to_vec()),
            ("/x.sig".to_string(), SIGNATURE.to_vec()),
        ]);
        let manifest = Manifest {
            version: "9.9.9".to_string(),
            msi: format!("{good}/x.msi"),
            sig: format!("{good}/x.sig"),
            notes: None,
        };
        let dir = temp_dir("verified");
        let path = stage(&manifest, &dir, &TEST_KEY).expect("the genuine pair must stage");
        assert_eq!(std::fs::read(&path).unwrap(), SIGNED, "the bytes on disk are the ones verified");
        let _ = std::fs::remove_dir_all(&dir);

        // Same signature, different installer: the classic swap.
        let bad = local_server(vec![
            ("/x.msi".to_string(), b"a different, unsigned installer".to_vec()),
            ("/x.sig".to_string(), SIGNATURE.to_vec()),
        ]);
        let manifest = Manifest {
            version: "9.9.9".to_string(),
            msi: format!("{bad}/x.msi"),
            sig: format!("{bad}/x.sig"),
            notes: None,
        };
        let dir = temp_dir("rejected");
        assert!(stage(&manifest, &dir, &TEST_KEY).is_err());
        assert!(
            !dir.exists() || std::fs::read_dir(&dir).unwrap().next().is_none(),
            "a rejected update must not be left where a later run could pick it up"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rc-updater-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    /// The smallest HTTP/1.1 server that will satisfy `ureq`: one request per
    /// connection, `200` with a length, or `404`. Runs until the test process
    /// ends, which is fine — it holds nothing.
    fn local_server(files: Vec<(String, Vec<u8>)>) -> String {
        use std::io::{Read, Write};

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let mut buf = [0u8; 2048];
                let read = stream.read(&mut buf).unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..read]).to_string();
                let path = request.split_whitespace().nth(1).unwrap_or("/").to_string();
                let response = match files.iter().find(|(p, _)| *p == path) {
                    Some((_, body)) => {
                        let mut r = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        )
                        .into_bytes();
                        r.extend_from_slice(body);
                        r
                    }
                    None => b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        .to_vec(),
                };
                let _ = stream.write_all(&response);
            }
        });
        format!("http://{addr}")
    }
    /// A throwaway key and a real signature, so the verifier is tested from both
    /// sides. Generated with `openssl genpkey -algorithm ed25519` over the exact
    /// bytes in `SIGNED`, and reproduced here rather than loaded from a fixture
    /// file whose provenance nobody would remember. Ed25519 is deterministic, so
    /// this vector cannot drift.
    const TEST_KEY: [u8; 32] = [
        0xc0, 0x41, 0x86, 0xe8, 0xac, 0x45, 0x76, 0x01, 0xe3, 0x97, 0x75, 0xcd, 0x2a, 0xb1, 0x13,
        0xc3, 0x7d, 0x50, 0xdd, 0x51, 0x5e, 0xd9, 0x32, 0x07, 0x21, 0x52, 0xc5, 0x6e, 0x64, 0xe7,
        0x49, 0x48,
    ];
    const SIGNED: &[u8] = b"RemoteCrab updater test vector";
    const SIGNATURE: [u8; 64] = [
        0x35, 0x23, 0xf4, 0x96, 0x44, 0x3d, 0x9f, 0xb0, 0x6e, 0x1d, 0xde, 0xb0, 0xef, 0x40, 0x3f,
        0x1c, 0x58, 0x33, 0x2b, 0xfd, 0xd0, 0x71, 0x80, 0x38, 0xf5, 0xa8, 0xa9, 0xf5, 0x60, 0xfc,
        0x81, 0x58, 0x44, 0xb2, 0x0d, 0x6c, 0x00, 0xdc, 0x33, 0xf5, 0x62, 0xac, 0x74, 0x36, 0xc5,
        0xfa, 0xcd, 0xc5, 0xa4, 0x82, 0xb7, 0xad, 0xa4, 0x2b, 0x01, 0x30, 0x47, 0xa0, 0x64, 0x58,
        0xba, 0x5f, 0x1c, 0x01,
    ];

    #[test]
    fn versions_compare_numerically_not_as_strings() {
        assert!(is_newer("1.10.0", "1.9.0"), "the release everyone notices");
        assert!(is_newer("1.0.1", "1.0.0"));
        assert!(is_newer("2.0.0", "1.99.99"));
        assert!(!is_newer("1.0.0", "1.0.0"));
        assert!(!is_newer("1.9.0", "1.10.0"));
    }

    /// A malformed version must not be read as an upgrade. "Newer" is the
    /// dangerous direction: it sets an install on a path to replacing itself.
    #[test]
    fn a_version_it_cannot_parse_is_not_an_upgrade() {
        assert!(!is_newer("banana", "1.0.0"));
        assert!(!is_newer("1.0.0", "banana"));
        assert!(!is_newer("", "1.0.0"));
    }

    #[test]
    fn the_manifest_needs_a_version_and_https() {
        let ok = br#"{"version":"1.0.1","msi":"https://x/y.msi","sig":"https://x/y.sig"}"#;
        assert_eq!(parse_manifest(ok).unwrap().version, "1.0.1");

        let no_version = br#"{"version":"","msi":"https://x/y.msi","sig":"https://x/y.sig"}"#;
        assert!(parse_manifest(no_version).is_err());

        let plain_http = br#"{"version":"1.0.1","msi":"http://x/y.msi","sig":"https://x/y.sig"}"#;
        assert!(
            parse_manifest(plain_http).is_err(),
            "plain http lets the bytes be swapped in flight"
        );

        assert!(parse_manifest(b"not json").is_err());
    }

    #[test]
    fn notes_are_optional() {
        let m = parse_manifest(br#"{"version":"1.0.1","msi":"https://x/a","sig":"https://x/b"}"#)
            .unwrap();
        assert_eq!(m.notes, None);
    }

    /// The signature is the only thing standing between a feed and every
    /// install, so it gets the hostile cases: wrong key, tampered bytes, and a
    /// signature that is simply not a signature.
    #[test]
    fn a_signature_that_does_not_match_is_rejected() {
        // First the case that must pass, or the rejections below prove nothing
        // about a verifier that always says no.
        assert!(
            verify(SIGNED, &SIGNATURE, &TEST_KEY),
            "the genuine signature must verify"
        );

        // One byte different in the signed content.
        let mut tampered = SIGNED.to_vec();
        tampered[0] ^= 0x01;
        assert!(!verify(&tampered, &SIGNATURE, &TEST_KEY));

        // The right signature under a different key.
        let mut other_key = TEST_KEY;
        other_key[0] ^= 0xFF;
        assert!(!verify(SIGNED, &SIGNATURE, &other_key));

        // Structurally a signature, cryptographically nothing.
        assert!(!verify(SIGNED, &[0u8; 64], &TEST_KEY));

        // Not even the right length.
        assert!(!verify(SIGNED, &SIGNATURE[..63], &TEST_KEY));
    }
}
