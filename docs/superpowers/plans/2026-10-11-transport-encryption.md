# Transport encryption (F1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seal every post-handshake wire frame with ChaCha20-Poly1305, keyed from the existing pairing token, interoperable across Swift (iOS/macOS) and Rust (Windows).

**Architecture:** A new `TransportCipher` in `RemoteCrabCore` does HKDF (token + both handshake nonces → session key) and AEAD (ChaCha20-Poly1305, per-direction nonce counter, replay window). `IBWire` gains a seal/open step over an existing frame's payload; the receiver routes on the cleartext `kind` and AADs it. The handshake carries a `transport` capability so an old peer connects in the clear with a visible "unencrypted" badge. The key is per-session.

**Tech Stack:** Swift `CryptoKit` (built-in, no dependency); Rust `chacha20poly1305` + `hkdf` crates (rc-protocol).

**Spec:** `docs/superpowers/specs/2026-10-11-transport-encryption-design.md`

## Global Constraints

- New wire fields are optional and defaulted (`#[serde(default, skip_serializing_if = "Option::is_none")]` on the Rust side; a Swift `String?` encodes as omitted when nil) — rule 2.
- **No new dependencies** on iOS/macOS: CryptoKit only.
- The **same test vectors** must produce byte-identical ciphertext in Swift and Rust — this is the cross-end correctness gate.
- Old peers: **cleartext allowed**, shown as unencrypted. Never refuse.
- Handshake frames (clientHello / sessionReply / phoneHello / nonce) stay cleartext.
- Key rotation: per session (no rekey).

## Review Focus

1. **Old peer (no `transport` field)** connects and works, and the UI says "unencrypted" — not silently "secure".
2. **Replayed frame** is dropped (the same ciphertext twice).
3. **Out-of-order / dropped frame** does not wedge the stream (window, not a hard equality check).
4. **Token mismatch / different keys** → the peer's frames fail to open and the session is torn down with a human message, not a crash.
5. **A sniffer sees no plaintext** for a known marker (clipboard text).

---

## Phase 1 — Core cipher (Swift, fully testable here)

### Task 1: `TransportCipher` — HKDF + AEAD + replay window

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/TransportCipher.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/TransportCipherTests.swift`

**Interfaces:**
- Consumes: CryptoKit (`HKDF<SHA256>`, `ChaChaPoly`).
- Produces:
  - `public enum TransportCipher {`
  - `public static func sessionKey(token: String, initiatorNonce: Data, responderNonce: Data) -> SymmetricKey`
  - `public struct Sealer { public init(key: SymmetricKey); public mutating func seal(_ plaintext: Data, kind: UInt8) -> Data }` (returns `nonce(12) ‖ ciphertext ‖ tag`)
  - `public struct Opener { public init(key: SymmetricKey); public mutating func open(_ sealed: Data, kind: UInt8) throws -> Data }` (throws on auth failure or replay)
  - `}`

- [ ] **Step 1: Write the failing test** — `testSealOpenRoundTripsAndRejectsReplay`
```swift
func testSealOpenRoundTripsAndRejectsReplay() throws {
    let key = TransportCipher.sessionKey(token: "tok", initiatorNonce: Data([1,2,3]), responderNonce: Data([4,5,6]))
    var sealer = TransportCipher.Sealer(key: key)
    var opener = TransportCipher.Opener(key: key)
    let sealed = sealer.seal(Data("hello".utf8), kind: 0x13)
    XCTAssertEqual(try opener.open(sealed, kind: 0x13), Data("hello".utf8))
    XCTAssertThrowsError(try opener.open(sealed, kind: 0x13))   // replay
}
```
- [ ] **Step 2: Run it, watch it fail** — `swift test --package-path RemoteCrabCore --filter TransportCipherTests` (FAIL: not defined).
- [ ] **Step 3: Implement `TransportCipher.swift`** — HKDF-SHA256 with `salt = initiatorNonce ‖ responderNonce`, `info = Data("remotecrab-transport-v1".utf8)`, 32-byte key. `Sealer` holds a 4-byte big-endian counter and builds a 12-byte nonce (4 zero bytes ‖ 8-byte counter), `ChaChaPoly.seal(_, using: key, nonce:, authenticating: Data([kind]))`. `Opener` keeps a `Set<UInt64>` + a monotonic `highest` and drops any nonce ≤ highest - 1024 or already seen.
- [ ] **Step 4: Run it, watch it pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(core): TransportCipher (HKDF + ChaCha20-Poly1305 + replay window)"`.

### Task 2: Cross-language test vectors

**Files:**
- Create: `RemoteCrabCore/Tests/RemoteCrabCoreTests/Fixtures/transport-vectors.json`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/TransportVectorsTests.swift`

**Interfaces:**
- Produces: a JSON file `[{token, initiatorNonce, responderNonce, kind, plaintextHex, sealedHex}]` that Rust (`rc-protocol/tests`) also reads and asserts. The ciphertext is fixed by this fixture — both ends must produce it.

- [ ] **Step 1: Generate the fixture** from the Task 1 code (a one-off test that prints the vector, run once) and commit the JSON. Include a hex helper.
- [ ] **Step 2: Test** — `testFixtureVectorsMatch`: for each entry, `seal` must equal `sealedHex`.
- [ ] **Step 3: Run it, watch it fail** (before the fixture is committed), then pass.
- [ ] **Step 4: Commit** — `git commit -am "test(core): cross-language transport vectors (fixed ciphertext)"`.

### Task 3: Wire field on the handshake (compat)

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift` (`IBClientHello`, `IBSessionReply`: add `public var transport: String?`)
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/IBEventsTests.swift`

**Interfaces:**
- Produces: `IBClientHello(..., transport: String? = nil)`, `IBSessionReply(..., transport: String? = nil)`; `TransportCipher.version = "aead-v1"`.

- [ ] **Step 1: Test** `testClientHelloWithoutTransportStillDecodes` (a JSON without the key decodes with `transport == nil`) and `testClientHelloWithTransportRoundTrips`.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement** — add the field + init param default nil; ensure the synthesized coder omits it when nil.
- [ ] **Step 4: Run, pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(core): optional transport capability on the handshake"`.

---

## Phase 2 — Wire integration

### Task 4: `IBWire` seal/open of a frame

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBWire.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/IBWireTests.swift`

**Interfaces:**
- Consumes: `TransportCipher.Sealer/Opener`.
- Produces: `public static func seal(frame: Frame, using sealer: inout TransportCipher.Sealer) -> Data` and `public static func open(data: Data, using opener: inout TransportCipher.Opener, parser: inout IBWire.Parser) -> [Frame]`. The kind stays cleartext in the length prefix; the payload is sealed.

- [ ] **Step 1: Test** `testSealedFrameRoutesOnKindAndDecrypts`: encode a `clipboardSet`, seal it, feed the bytes through a fresh parser+opener, assert the decoded frame equals the original.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement** — the frame body becomes `[kind][sealed]`; `open` reads the kind, opens the remainder, and rebuilds a `Frame(kind:payload:)`.
- [ ] **Step 4: Run, pass.**
- [ ] **Step 5: Commit** — `git commit -am "feat(core): IBWire seal/open over the frame payload"`.

### Task 5: Connection integration (iOS + Mac)

**Files:**
- Modify: `RemoteCrabCapture/CaptureEngine.swift` (build a `Sealer` after the grant; seal outgoing; open incoming)
- Modify: `RemoteCrabReceiver/ReceiverSession.swift` (mirror)
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/EventPipelineEndToEndTests.swift` (extend with a sealed round-trip over TCP)

**Interfaces:** produces an in-memory "transport mode" per session: `cleartext` (peer has no `transport`) or `sealed(key)`.

- [ ] **Step 1: Test** `testSealedPipelineOverTCP`: two `NWConnection`s, both sides seal/open, assert a touch event survives.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement** the mode switch at both ends (after `sessionReply`/`clientHello` decide the capability; derive the key from the token + the two nonces already in the handshake).
- [ ] **Step 4: Run, pass** + `./scripts/test.sh`.
- [ ] **Step 5: Commit** — `git commit -am "feat: sealed transport when both peers support it"`.

---

## Phase 3 — Rust parity (hand-off; cannot be verified on this machine)

### Task 6: `rc-protocol` cipher + vectors

**Files:**
- Create: `windows/crates/rc-protocol/src/transport.rs`
- Test: `windows/crates/rc-protocol/tests/transport_vectors.rs`

- [ ] **Step 1: Test** reads `RemoteCrabCore/Tests/.../Fixtures/transport-vectors.json` (path via `CARGO_MANIFEST_DIR` walk-up) and asserts `seal` equals `sealed_hex`.
- [ ] **Step 2: Run, fail.**
- [ ] **Step 3: Implement** with `chacha20poly1305` + `hkdf` (same params).
- [ ] **Step 4: Run `cargo test -p rc-protocol` + `cargo clippy` (host + windows-gnu).**
- [ ] **Step 5: Commit.** **Hand-off:** real Windows interop is a Windows-session task (see `docs/HANDOFF-WINDOWS-2026-10-05.md` conventions).

---

## Phase 4 — Verification

### Task 7: Sniffer + device

- [ ] **Step 1:** Integration test: run a `copyfrontmostselection`/clipboard marker, capture the loopback bytes in-test, assert the known marker is **absent** in the sealed stream (present in the cleartext-fallback case).
- [ ] **Step 2:** Device: `/Applications/RemoteCrab.app` + the phone, sealed session; assert video/audio/touch still work and D2's fps/kbps are unchanged.
- [ ] **Step 3:** Old-peer fallback: a build without `transport` connects in the clear and the UI shows the "unencrypted" badge.

---

## Self-Review

- **Spec coverage:** F1 §4.1→Task 3, §4.2→Task 1, §4.3/4.4→Tasks 1,4, §4.5→Tasks 3,5,7, cross-language→Tasks 2,6, threat-model test→Task 7. §7 open questions were resolved (cleartext+badge, per-session key, plaintext handshake).
- **Types:** `TransportCipher.sessionKey/Sealer/Opener` used consistently across Tasks 1,2,4,5,6.
- **Proportion:** plan is shorter than the spec it implements.
