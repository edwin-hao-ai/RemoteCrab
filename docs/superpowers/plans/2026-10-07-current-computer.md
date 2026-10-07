# Current computer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One iPhone, many computers — the phone serves one remembered computer, everyone else stands by, and switching is one tap.

**Architecture:** Persist a `current` computer on the phone (`MacPairingStore`); `PairingPolicy.decide` answers every other computer `busy`; receivers treat `busy`/`off` as standby (long safety-net retry, instant on knock). No new wire kind.

**Tech Stack:** Swift 6, `RemoteCrabCore` (SwiftPM, unit-tested), `RemoteCrabCapture` / `RemoteCrabReceiver` (xcodebuild), Windows `rc-net` (Rust, handed off).

**Spec:** `docs/superpowers/specs/2026-10-07-current-computer-design.md`

## Global Constraints

- **No new wire kind.** Reuse `IBSessionReplyResult.busy` / `.off`.
- **Additive, defaulted persistence** (AGENTS rule 2): a blob written without the new keys must load with nothing lost.
- **No comments** in new code unless a non-obvious *why* is load-bearing.
- Copy must state what happened AND what to do (AGENTS rule 1).
- Tests: `swift test --package-path RemoteCrabCore`; apps via `xcodebuild`; device e2e by hand.
- The Mac receiver is **not sandboxed**; its tokens/prefs live in `~/Library/Preferences/com.remotecrab.RemoteCrabReceiver.plist`.

---

### Task 1: Persist the current computer in `MacPairingStore`

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/State/MacPairingStore.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/CurrentComputerStoreTests.swift` (create)

**Interfaces:**
- Produces:
  - `MacPairingStore.current: PairedMac?`
  - `MacPairingStore.currentId: String?`
  - `MacPairingStore.setCurrent(id: String, name: String)`
  - `MacPairingStore.clearCurrent()`
  - `forget(id:)` and `removeAll()` clear `current` when it matches.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RemoteCrabCore

final class CurrentComputerStoreTests: XCTestCase {

    private func store(_ name: String = #function) -> (MacPairingStore, UserDefaults) {
        let d = UserDefaults(suiteName: "test.current.\(name)")!
        d.removePersistentDomain(forName: "test.current.\(name)")
        return (MacPairingStore(defaults: d, key: "k"), d)
    }

    func testCurrentDefaultsToNil() {
        let (s, _) = store()
        XCTAssertNil(s.current)
        XCTAssertNil(s.currentId)
    }

    func testSetCurrentPersistsAcrossReload() {
        let (s, d) = store()
        s.setCurrent(id: "pc-1", name: "Living room PC")
        let reloaded = MacPairingStore(defaults: d, key: "k")
        XCTAssertEqual(reloaded.currentId, "pc-1")
        XCTAssertEqual(reloaded.current?.name, "Living room PC")
    }

    func testCurrentResolvesToThePairedRecordWhenPresent() {
        let (s, _) = store()
        var hello = IBClientHello(name: "MacBook", id: "mac-1", token: "t")
        hello.token = "t"
        let mac = s.pair(hello)
        s.setCurrent(id: mac.id, name: mac.name)
        XCTAssertEqual(s.current?.token, mac.token)
    }

    func testForgetClearsCurrent() {
        let (s, _) = store()
        s.setCurrent(id: "pc-1", name: "PC")
        s.forget(id: "pc-1")
        XCTAssertNil(s.current)
    }

    func testRemoveAllClearsCurrent() {
        let (s, _) = store()
        s.setCurrent(id: "pc-1", name: "PC")
        s.removeAll()
        XCTAssertNil(s.current)
    }

    /// Rule 2: a blob from a build without these keys loads unchanged.
    func testOldBlobWithoutCurrentStillLoadsThePairing() {
        let (s, d) = store()
        var hello = IBClientHello(name: "MacBook", id: "mac-1", token: "t")
        hello.token = "t"
        let mac = s.pair(hello)
        // Simulate an old write: no current keys present at all.
        d.removeObject(forKey: "k.currentId")
        d.removeObject(forKey: "k.currentName")
        let reloaded = MacPairingStore(defaults: d, key: "k")
        XCTAssertEqual(reloaded.paired.first?.id, mac.id)
        XCTAssertNil(reloaded.current)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path RemoteCrabCore --filter CurrentComputerStoreTests`
Expected: FAIL — `value of type 'MacPairingStore' has no member 'setCurrent'` / `'current'`.

- [ ] **Step 3: Write minimal implementation**

In `MacPairingStore`, add the key fields next to the others:

```swift
    private let currentIdKey: String
    private let currentNameKey: String
```

In `init`, after `self.disconnectedNameKey = ...`:

```swift
        self.currentIdKey = key + ".currentId"
        self.currentNameKey = key + ".currentName"
```

Add the API (near `preferred`):

```swift
    /// The computer this iPhone is set to serve ("the current computer").
    ///
    /// Persisted, so the choice survives a relaunch and ownership stops being
    /// decided by who dialled first. Synthesised from id + name like
    /// `preferred`, so it can name a computer that is not in the allow-list.
    public var current: PairedMac? {
        guard let id = defaults.string(forKey: currentIdKey) else { return nil }
        if let paired = paired.first(where: { $0.id == id }) { return paired }
        let name = defaults.string(forKey: currentNameKey) ?? id
        return PairedMac(id: id, name: name, pairedAt: .distantPast, token: "")
    }

    public var currentId: String? { defaults.string(forKey: currentIdKey) }

    public func setCurrent(id: String, name: String) {
        defaults.set(id, forKey: currentIdKey)
        defaults.set(name, forKey: currentNameKey)
    }

    public func clearCurrent() {
        defaults.removeObject(forKey: currentIdKey)
        defaults.removeObject(forKey: currentNameKey)
    }
```

In `forget(id:)`, add before `save()`:

```swift
        if currentId == id { clearCurrent() }
```

In `removeAll()`, add:

```swift
        clearCurrent()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path RemoteCrabCore --filter CurrentComputerStoreTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/MacPairingStore.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/CurrentComputerStoreTests.swift
git commit -m "feat(pairing): persist the current computer on the phone"
```

---

### Task 2: `PairingPolicy.decide` prefers the current computer

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/State/MacPairingStore.swift` (the `PairingPolicy` enum)
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/CurrentComputerPolicyTests.swift` (create)

**Interfaces:**
- Consumes: `MacPairingStore.current` (Task 1) as a `PairedMac?`.
- Produces: `PairingPolicy.decide(hello:paired:owner:preferred:disconnected:current:)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RemoteCrabCore

final class CurrentComputerPolicyTests: XCTestCase {

    private func mac(_ id: String, token: String = "t") -> PairedMac {
        PairedMac(id: id, name: id, token: token)
    }
    private func hello(_ id: String, token: String? = "t") -> IBClientHello {
        IBClientHello(name: id, id: id, token: token)
    }

    func testTheCurrentComputerIsAccepted() {
        let d = PairingPolicy.decide(hello: hello("A"), paired: [mac("A")],
                                     owner: nil, current: mac("A"))
        XCTAssertEqual(d, .accept)
    }

    func testANonCurrentPairedComputerStandsBy() {
        let d = PairingPolicy.decide(hello: hello("B"), paired: [mac("A"), mac("B")],
                                     owner: nil, current: mac("A"))
        XCTAssertEqual(d, .busy(ownerName: "A"))
    }

    func testThePreferredComputerOverridesCurrent() {
        let d = PairingPolicy.decide(hello: hello("B"), paired: [mac("A"), mac("B")],
                                     owner: nil, preferred: mac("B"), current: mac("A"))
        XCTAssertEqual(d, .accept)
    }

    func testWithoutACurrentComputerAPairedComputerIsStillAccepted() {
        let d = PairingPolicy.decide(hello: hello("B"), paired: [mac("B")],
                                     owner: nil, current: nil)
        XCTAssertEqual(d, .accept)
    }

    func testAStrangerGetsBusyWhenACurrentComputerExists() {
        let d = PairingPolicy.decide(hello: hello("C", token: nil), paired: [mac("A")],
                                     owner: nil, current: mac("A"))
        XCTAssertEqual(d, .busy(ownerName: "A"))
    }

    func testDisconnectedBeatsCurrent() {
        let d = PairingPolicy.decide(hello: hello("A"), paired: [mac("A")],
                                     owner: nil, disconnected: mac("A"), current: mac("A"))
        XCTAssertEqual(d, .off(ownerName: "A"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path RemoteCrabCore --filter CurrentComputerPolicyTests`
Expected: FAIL — `extra argument 'current' in call`.

- [ ] **Step 3: Write minimal implementation**

Change the signature and insert the branch in `PairingPolicy.decide`:

```swift
    public static func decide(
        hello: IBClientHello,
        paired: [PairedMac],
        owner: PairedMac?,
        preferred: PairedMac? = nil,
        disconnected: PairedMac? = nil,
        current: PairedMac? = nil
    ) -> PairingDecision {
```

After the `preferred` branch and before the token-match `if`, insert:

```swift
        // The phone is set to serve one computer. Any other computer — even a
        // paired one with a valid token — stands by, so ownership is decided by
        // the persisted choice instead of by who dialled first. Skipped when
        // this connection IS the freshly chosen `preferred` one, or the switch
        // could never complete.
        if let current, current.id != hello.id, preferred?.id != hello.id {
            return .busy(ownerName: current.name)
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path RemoteCrabCore`
Expected: PASS — new tests plus the existing `PairingTests` (no call site passes `current`, so it defaults to `nil` and behaviour is unchanged).

- [ ] **Step 5: Commit**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/MacPairingStore.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/CurrentComputerPolicyTests.swift
git commit -m "feat(pairing): only the current computer is accepted; others stand by"
```

---

### Task 3: iOS — wire `current` into `CaptureEngine`

**Files:**
- Modify: `RemoteCrabCapture/CaptureEngine.swift`

**Interfaces:**
- Consumes: `MacPairingStore.current` / `.setCurrent` / `.clearCurrent` (Tasks 1–2).
- Produces: `CaptureEngine.releaseCurrentComputer()`; `grant` promotes the chosen computer to `current`.

No unit test (the app target is not in the test suite); verified by build + the device e2e in Task 7.

- [ ] **Step 1: Pass `current` to the policy**

At the `PairingPolicy.decide(...)` call (~line 1652) add the argument:

```swift
        let decision = PairingPolicy.decide(hello: hello, paired: pairingStore.paired, owner: nil,
                                            preferred: pairingStore.effectivePreferred(),
                                            disconnected: pairingStore.disconnected,
                                            current: pairingStore.current)
```

- [ ] **Step 2: Promote the granted computer to `current`**

In `grant(connection:mac:platform:)`, inside the existing "preferred arrived" block (~line 1832), persist it:

```swift
        // The preferred Mac arrived — the switch is done, open the door, and
        // remember it: the phone now serves this computer until the user says
        // otherwise.
        if let mac, mac.id == pairingStore.preferredId {
            Forensic.log("[gv] granted: clearing preferred for \(mac.id.prefix(8))")
            pairingStore.clearPreferred()
        }
        if let mac {
            pairingStore.setCurrent(id: mac.id, name: mac.name)
        }
        refreshPairedMacs()
```

(Remove the old `refreshPairedMacs()` that was inside the `if`.)

This also covers first approval, because `approvePendingMac()` calls `pair()` then `grant`.

- [ ] **Step 3: Add the release action**

Next to `clearPreferredMac()`:

```swift
    /// Forget which computer this iPhone is set to, so the next computer to
    /// connect becomes current again (the picker's "Release this iPhone").
    func releaseCurrentComputer() {
        pairingStore.clearCurrent()
        refreshPairedMacs()
    }
```

- [ ] **Step 4: Build**

Run:
```bash
xcodebuild -project RemoteCrabCapture.xcodeproj -scheme RemoteCrabCapture \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  -derivedDataPath .build/ci-derived-data/ios build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add RemoteCrabCapture/CaptureEngine.swift
git commit -m "feat(ios): the granted computer becomes the persisted current computer"
```

---

### Task 4: iOS — the picker shows the current computer and offers Release

**Files:**
- Modify: `RemoteCrabCapture/ComputerPickerView.swift`
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift`
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/LocalizationCatalogTests.swift` (extend)

**Interfaces:**
- Consumes: `CaptureEngine.releaseCurrentComputer()` (Task 3), `MacPairingStore.current`.

- [ ] **Step 1: Add the strings (en source + zh-Hans)**

In `IBLocale.Pairing` add:

```swift
        public static let currentComputer = IBL("This iPhone")
        public static let releaseCurrent = IBL("Release this iPhone")
        public static let releaseCurrentHint = IBL("Let the next computer that connects become the one this iPhone serves.")
```

Add the same three English strings as keys in `Localizable.xcstrings`, each with an `en` unit and a `zh-Hans` unit:
- `"This iPhone"` → `"本机 iPhone"`
- `"Release this iPhone"` → `"释放此 iPhone"`
- `"Let the next computer that connects become the one this iPhone serves."` → `"让下一台连上的电脑成为此 iPhone 服务的对象。"`

- [ ] **Step 2: Extend the catalog test**

In `LocalizationCatalogTests`, add a test asserting the three new keys have `zh-Hans` (copy the shape of `testUpdateKeysAreBilingual`, using the literal English strings as keys).

- [ ] **Step 3: Run the catalog test**

Run: `swift test --package-path RemoteCrabCore --filter LocalizationCatalogTests`
Expected: PASS.

- [ ] **Step 4: Show the current marker and the Release row**

In `ComputerPickerView`, in the row's top `HStack`, when `entry.id == engine.currentComputerId` render a badge (alongside the online dot):

```swift
                                if entry.id == engine.currentComputerId {
                                    Text(IBLocale.Pairing.currentComputer)
                                        .font(IBFont.caption)
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background {
                                            Capsule().fill(Color.accentColor.opacity(0.15))
                                        }
                                }
```

Add a `Section` at the bottom of the list:

```swift
            if engine.currentComputerId != nil {
                Section {
                    Button(role: .destructive) {
                        engine.releaseCurrentComputer()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(IBLocale.Pairing.releaseCurrent)
                            Text(IBLocale.Pairing.releaseCurrentHint)
                                .font(IBFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
```

Expose `currentComputerId` on `CaptureEngine` (Task 3 file), near `preferredMac`:

```swift
    var currentComputerId: String? { pairingStore.currentId }
```

- [ ] **Step 5: Build**

Run the same `xcodebuild` command as Task 3, Step 4.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add RemoteCrabCapture/ComputerPickerView.swift RemoteCrabCapture/CaptureEngine.swift \
        RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift \
        RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/LocalizationCatalogTests.swift
git commit -m "feat(ios): mark the current computer and add Release this iPhone"
```

---

### Task 5: Mac — stand by on `busy` / `off`

**Files:**
- Modify: `RemoteCrabReceiver/ReceiverSession.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: a non-current Mac stops the fast reconnect loop and only re-dials on the 60 s safety net or a knock.

- [ ] **Step 1: Change the retry intervals**

In `handleSessionReply`, the `.busy` case currently ends with `scheduleSlowRetry()` (15 s) and the `.off` case with `scheduleSlowRetry(interval: 5)`. Change both to the standby interval:

```swift
        case .busy:
            ...
            scheduleSlowRetry(interval: 60)

        case .off:
            ...
            scheduleSlowRetry(interval: 60)
```

Add a named constant next to the method so the intent is explicit:

```swift
    /// How often a non-current computer quietly re-checks after being told
    /// `busy`/`off`. It is a safety net, not a race: the phone always answers
    /// `busy` to a computer that is not the current one, so this can never
    /// steal the session — it only stops a blocked knock from stranding us.
    private static let standbyRetry: Double = 60
```

and use `scheduleSlowRetry(interval: Self.standbyRetry)` in both cases.

- [ ] **Step 2: Build**

Run:
```bash
xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrabReceiver \
  -configuration Debug -derivedDataPath .build/ci-derived-data/mac build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add RemoteCrabReceiver/ReceiverSession.swift
git commit -m "feat(mac): a non-current computer stands by instead of racing"
```

---

### Task 6: Windows — mirror the standby behaviour (handoff)

**Files:**
- Create: `docs/HANDOFF-WINDOWS-CURRENT-COMPUTER-2026-10-07.md`

**Why a handoff, not code:** the Windows receiver cannot be built or verified from macOS (AGENTS cross-side rule).

- [ ] **Step 1: Write the handoff**

Contents (with exact locations to find):
- The phone now serves one persisted `current` computer; every other computer is answered `busy` (or `off` when paused).
- Change `rc-net`'s `busy`/`off` handling so a non-current computer **stands by**: stop the fast reconnect loop and only re-dial on a ~60 s safety net, and immediately on a knock (the existing knock listener already calls the dial path).
- The status line must state what happened and what to do, matching the Mac's shipped `IBLocale.Error.iphoneBusy` string ("This iPhone is being used by <X> — pick this computer in the iPhone's Choose a Computer list. Retry on its own will keep failing.") in both en and zh.
- Test plan: two receivers against one phone; the non-current one dials once, is refused `busy`, and stays quiet; a knock re-dials it.
- Note: no wire change; the behaviour is entirely on the receiver side.

- [ ] **Step 2: Commit**

```bash
git add docs/HANDOFF-WINDOWS-CURRENT-COMPUTER-2026-10-07.md
git commit -m "docs(windows): hand off current-computer standby behaviour"
```

---

### Task 7: Device e2e — two computers, one phone

**Files:** none (manual verification; record results in the spec or a note).

- [ ] **Step 1: Run the two-computer scenario**

With an iPhone and two computers (Mac + Windows) on one WiFi:
1. Pair one computer; confirm it becomes the current one.
2. Start the other: it must show the "being used by <X> … pick this computer …" line and **not** take the session.
3. On the iPhone, Choose a Computer → tap the other: connected within ~2 s.
4. Disconnect on the iPhone: stays disconnected; neither computer reconnects.
5. Re-pick a computer: reconnects.
6. Relaunch the iPhone app: the current computer reconnects; the other stays quiet.

- [ ] **Step 2: Record the evidence**

Append the observed log markers (`sessionReply: busy`, `clientProof sent — identity verified`, `[gv] granted`) and the phone forensic lines to the spec's verification section.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-10-07-current-computer-design.md
git commit -m "docs: record the two-computer device verification"
```

---

## Self-Review

**Spec coverage:** persist current (Task 1) · policy prefers current (Task 2) · grant sets current + release (Task 3) · picker UI + i18n (Task 4) · Mac standby (Task 5) · Windows handoff (Task 6) · device e2e (Task 7). Disconnect = pause is already the existing `off`/`disconnected` path, unchanged by this plan (Task 3 leaves `disconnectCurrentMac` as is). Covered.

**Placeholder scan:** none — every code step shows the code.

**Type consistency:** `current`/`currentId`/`setCurrent`/`clearCurrent` are defined in Task 1 and used identically in Tasks 2–4; `PairingPolicy.decide`'s new `current:` parameter matches its use in Task 3; `releaseCurrentComputer()` is defined in Task 3 and called in Task 4.

**Known gap (deliberate):** Tasks 3–5 have no unit tests because the app targets are not in the SwiftPM test suite; they are verified by build + Task 7's device run. This matches the repo's existing practice.
