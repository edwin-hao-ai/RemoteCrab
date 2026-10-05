# Computer Presence + Choose-Computer Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The iPhone shows which computers (Mac and Windows) are online right now, tapping an online one connects within ~1 s, failures explain themselves, and the picker/loading use the RemoteCrab mascot.

**Architecture:** The phone stays the TCP server. Each receiver additionally announces a distinct Bonjour service `_remotecrab-computer._tcp` with a TXT record (id/name/platform). The phone adds a second `NWBrowser` for that type and merges live announcements with the persisted `seenComputers` history through a pure `ComputerRoster`. Tapping an online computer reuses the existing `setPreferred` "holding the door" mechanism; because the computer is announcing, its reconnect loop dials within ~1 s. No wire-protocol change.

**Tech Stack:** Swift 6 / SwiftUI / Network.framework (NWListener + NWBrowser), XCTest in `RemoteCrabCore`; Rust `mdns-sd 0.21` for `rc-discovery`.

**Spec:** `docs/superpowers/specs/2026-10-05-computer-presence-design.md`

## Global Constraints

- No new wire kind. Presence travels in Bonjour TXT only.
- The presence service type is exactly `_remotecrab-computer._tcp` (never reuse `_remotecrab._tcp`).
- TXT keys are exactly `id`, `name`, `platform`; platform values `macos` / `windows`. No token, no secret.
- TXT contract must be byte-identical between Mac and Windows.
- Dedupe roster entries by `id`, never by name.
- A new persisted field must be additive + defaulted (rule 2); `seenComputers` is unchanged here.
- No emoji in UI strings; SF Symbols only. Bilingual (en + zh-Hans) strings via `IBLocale`.
- Do not edit `RemoteCrabCapture/CaptureEngine.swift` while another session is editing it; commit frequently with explicit pathspecs and run `git show --name-status HEAD` after each commit.

---

### Task 1: Core — `ComputerPresence`

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/State/ComputerPresence.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerPresenceTests.swift`

**Interfaces:**
- Produces: `ComputerPresence` with `id`, `name`, `platform`, `lastSeen`, `isWindows`, and `init(id:name:platform:lastSeen:)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RemoteCrabCore

final class ComputerPresenceTests: XCTestCase {
    func testCarriesIdentityAndPlatform() {
        let p = ComputerPresence(id: "abc", name: "Edwin's PC", platform: "windows")
        XCTAssertEqual(p.id, "abc")
        XCTAssertEqual(p.name, "Edwin's PC")
        XCTAssertTrue(p.isWindows)
        XCTAssertFalse(ComputerPresence(id: "x", name: "Mac", platform: "macos").isWindows)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd RemoteCrabCore && swift test --filter ComputerPresenceTests`
Expected: FAIL — `cannot find 'ComputerPresence' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// A computer currently announcing its presence on the LAN.
///
/// Deliberately not `SeenComputer`: that type is persisted history and carries
/// `lastOutcome`. This is a live sighting. `ComputerRoster` merges the two.
public struct ComputerPresence: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let platform: String
    public let lastSeen: Date

    public init(id: String, name: String, platform: String, lastSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.platform = platform
        self.lastSeen = lastSeen
    }

    public var isWindows: Bool { platform.lowercased() == "windows" }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd RemoteCrabCore && swift test --filter ComputerPresenceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/ComputerPresence.swift RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerPresenceTests.swift
git commit -m "feat(core): ComputerPresence, a live sighting of a computer"
```

---

### Task 2: Core — `ComputerRoster` merge policy

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/State/ComputerRoster.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerRosterTests.swift`

**Interfaces:**
- Consumes: `ComputerPresence` (Task 1), `SeenComputer` (`MacPairingStore.swift`).
- Produces:
  - `ComputerPresenceState` (`case online`, `case offline(lastSeen: Date?)`)
  - `ComputerRosterEntry` (`id`, `name`, `platform`, `state`, `isOnline`)
  - `ComputerRoster.entries(online:seen:) -> [ComputerRosterEntry]`
  - `ComputerRoster.state(online:seen:id:) -> ComputerPresenceState`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RemoteCrabCore

final class ComputerRosterTests: XCTestCase {
    private func seen(_ id: String, _ name: String, _ platform: String, _ t: TimeInterval) -> SeenComputer {
        SeenComputer(id: id, name: name, platform: platform, lastSeen: Date(timeIntervalSince1970: t))
    }
    private func live(_ id: String, _ name: String, _ platform: String) -> ComputerPresence {
        ComputerPresence(id: id, name: name, platform: platform)
    }

    func testAnOnlineComputerIsOnline() {
        let entries = ComputerRoster.entries(online: [live("a", "iMac", "macos")], seen: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].state, .online)
        XCTAssertTrue(entries[0].isOnline)
    }

    func testKnownButNotAnnouncingIsOfflineWithLastSeen() {
        let s = seen("a", "iMac", "macos", 100)
        let entries = ComputerRoster.entries(online: [], seen: [s])
        XCTAssertEqual(entries[0].state, .offline(lastSeen: s.lastSeen))
        XCTAssertFalse(entries[0].isOnline)
    }

    func testDeduplicatesByIdNotName() {
        // Two computers sharing a name must NOT collapse (lesson 135).
        let entries = ComputerRoster.entries(
            online: [live("a", "EDWIN", "macos"), live("b", "EDWIN", "windows")],
            seen: [seen("a", "EDWIN", "macos", 1), seen("b", "EDWIN", "windows", 2)])
        XCTAssertEqual(entries.count, 2)
    }

    func testLiveBeatsHistoryForTheSameId() {
        let entries = ComputerRoster.entries(
            online: [live("a", "Studio Mac", "macos")],
            seen: [seen("a", "Old Name", "macos", 100)])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Studio Mac")
        XCTAssertEqual(entries[0].state, .online)
    }

    func testOnlineFirstThenMostRecentlySeen() {
        let entries = ComputerRoster.entries(
            online: [live("on1", "Zed", "macos")],
            seen: [seen("off1", "Old", "macos", 100), seen("off2", "Newer", "windows", 200)])
        XCTAssertEqual(entries.map(\.id), ["on1", "off2", "off1"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd RemoteCrabCore && swift test --filter ComputerRosterTests`
Expected: FAIL — `cannot find 'ComputerRoster' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum ComputerPresenceState: Equatable, Sendable {
    case online
    case offline(lastSeen: Date?)
}

public struct ComputerRosterEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let platform: String
    public let state: ComputerPresenceState

    public init(id: String, name: String, platform: String, state: ComputerPresenceState) {
        self.id = id
        self.name = name
        self.platform = platform
        self.state = state
    }

    public var isOnline: Bool { state == .online }
    public var isWindows: Bool { platform.lowercased() == "windows" }
}

/// Merges the live Bonjour sightings with the persisted history into the rows
/// the picker renders. Pure, so "which computer is online" is decided in one
/// testable place.
public enum ComputerRoster {
    public static func state(online: [ComputerPresence], seen: SeenComputer?, id: String) -> ComputerPresenceState {
        if online.contains(where: { $0.id == id }) { return .online }
        return .offline(lastSeen: seen?.lastSeen)
    }

    public static func entries(online: [ComputerPresence],
                               seen: [SeenComputer]) -> [ComputerRosterEntry] {
        let liveById = Dictionary(online.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let seenById = Dictionary(seen.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ids = Set(liveById.keys).union(seenById.keys)

        var entries: [ComputerRosterEntry] = []
        for id in ids {
            if let live = liveById[id] {
                entries.append(ComputerRosterEntry(id: id, name: live.name,
                                                   platform: live.platform, state: .online))
            } else if let s = seenById[id] {
                entries.append(ComputerRosterEntry(id: id, name: s.name,
                                                   platform: s.platform,
                                                   state: .offline(lastSeen: s.lastSeen)))
            }
        }
        entries.sort { a, b in
            if a.isOnline != b.isOnline { return a.isOnline }
            if case let .offline(ad) = a.state, case let .offline(bd) = b.state {
                return (ad ?? .distantPast) > (bd ?? .distantPast)
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return entries
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd RemoteCrabCore && swift test --filter ComputerRosterTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/ComputerRoster.swift RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerRosterTests.swift
git commit -m "feat(core): ComputerRoster merges live presence with seen history by id"
```

---

### Task 3: Core — service type + TXT keys

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBProtocol.swift:6-11`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/IBServiceTypeTests.swift`

**Interfaces:**
- Produces: `IBServiceType.computer`, `IBServiceType.PresenceTXT.{id,name,platform}`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RemoteCrabCore

final class IBServiceTypeTests: XCTestCase {
    func testPresenceServiceIsDistinctFromThePhoneService() {
        XCTAssertEqual(IBServiceType.computer, "_remotecrab-computer._tcp")
        XCTAssertNotEqual(IBServiceType.computer, IBServiceType.tcp)
    }
    func testTXTKeysAreFrozen() {
        XCTAssertEqual(IBServiceType.PresenceTXT.id, "id")
        XCTAssertEqual(IBServiceType.PresenceTXT.name, "name")
        XCTAssertEqual(IBServiceType.PresenceTXT.platform, "platform")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd RemoteCrabCore && swift test --filter IBServiceTypeTests`
Expected: FAIL — no member `computer`.

- [ ] **Step 3: Write minimal implementation**

```swift
public enum IBServiceType {
    /// The DNS-SD service type advertised by RemoteCrabCapture.
    /// Always use this exact string for both publishing and browsing.
    public static let tcp = "_remotecrab._tcp"
    /// The DNS-SD service type a *receiver* (Mac/Windows) advertises so the
    /// phone can see which computers are online. MUST stay distinct from
    /// `.tcp`: the receiver browses `.tcp` for iPhones, and reusing it would
    /// make it dial other computers.
    public static let computer = "_remotecrab-computer._tcp"
    public static let domain = "local."

    /// TXT keys on the presence announcement. Frozen; both platforms agree.
    public enum PresenceTXT {
        public static let id = "id"
        public static let name = "name"
        public static let platform = "platform"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd RemoteCrabCore && swift test --filter IBServiceTypeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBProtocol.swift RemoteCrabCore/Tests/RemoteCrabCoreTests/IBServiceTypeTests.swift
git commit -m "feat(core): a distinct presence service type + frozen TXT keys"
```

---

### Task 4: Core — Bonjour presence end-to-end test (Mac advertiser contract)

**Files:**
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerPresenceBonjourTests.swift`

**Interfaces:**
- Verifies the `IBServiceType.computer` + TXT contract using `NWListener` publish and `NWBrowser` find, inside the package (no app target needed).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Network
@testable import RemoteCrabCore

final class ComputerPresenceBonjourTests: XCTestCase {
    func testABrowserFindsThePresenceAndItsTXT() throws {
        let listener = try NWListener(using: .tcp)
        let txt = NWTXTRecord([IBServiceType.PresenceTXT.id: "id-1",
                               IBServiceType.PresenceTXT.name: "Test Mac",
                               IBServiceType.PresenceTXT.platform: "macos"])
        listener.service = NWListener.Service(name: "presence-test-\(UUID().uuidString)",
                                              type: IBServiceType.computer,
                                              domain: IBServiceType.domain,
                                              txtRecord: txt)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())

        let browser = NWBrowser(for: .bonjour(type: IBServiceType.computer, domain: nil), using: .tcp)
        let found = expectation(description: "browser found it")
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                if case let .bonjour(record) = r.metadata,
                   record[IBServiceType.PresenceTXT.id] == "id-1" {
                    found.fulfill()
                    return
                }
            }
        }
        browser.start(queue: .global())

        wait(for: [ready, found], timeout: 15)
        browser.cancel()
        listener.cancel()
    }
}
```

- [ ] **Step 2: Run the test**

Run: `cd RemoteCrabCore && swift test --filter ComputerPresenceBonjourTests`
Expected: PASS. (If it fails because the local network is unavailable in the test host, mark this test skipped with an explicit reason — never delete it. But run it and record the result.)

- [ ] **Step 3: Commit**

```bash
git add RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerPresenceBonjourTests.swift
git commit -m "test(core): the presence service type is discoverable with its TXT"
```

---

### Task 5: Mac — `PresenceAdvertiser` and wiring

**Files:**
- Create: `RemoteCrabReceiver/PresenceAdvertiser.swift`
- Modify: `RemoteCrabReceiver/ReceiverSession.swift` (`init`, around lines 244-260; add start/stop)

**Interfaces:**
- Consumes: `IBServiceType.computer`, `IBServiceType.PresenceTXT`, `macId`, `macName`.
- Produces: `PresenceAdvertiser(id:name:platform:)`, `start()`, `stop()`.

- [ ] **Step 1: Implement `PresenceAdvertiser`**

```swift
import Foundation
import Network
import os
import RemoteCrabCore

/// Announces this receiver on `_remotecrab-computer._tcp` so an iPhone can see
/// which computers are online. The phone does not connect to this listener —
/// it only reads the TXT record — so a new connection is accepted and
/// immediately cancelled.
final class PresenceAdvertiser: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.remotecrab", category: "presence")
    private let id: String
    private let name: String
    private let platform: String
    private let queue = DispatchQueue(label: "com.remotecrab.presence")
    private var listener: NWListener?

    init(id: String, name: String, platform: String = "macos") {
        self.id = id
        self.name = name
        self.platform = platform
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            let txt = NWTXTRecord([
                IBServiceType.PresenceTXT.id: id,
                IBServiceType.PresenceTXT.name: name,
                IBServiceType.PresenceTXT.platform: platform,
            ])
            listener.service = NWListener.Service(name: name,
                                                  type: IBServiceType.computer,
                                                  domain: IBServiceType.domain,
                                                  txtRecord: txt)
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Self.log.error("presence advertise failed: \(error, privacy: .public)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            Self.log.info("advertising presence for \(self.name, privacy: .public)")
        } catch {
            // Never block a session because we could not announce.
            Self.log.error("presence advertise could not start: \(error, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
```

- [ ] **Step 2: Wire it into `ReceiverSession`**

Find `private var macId: String = ReceiverSession.loadMacId()` and add below the stored properties:

```swift
    private var presenceAdvertiser: PresenceAdvertiser?
```

In `init`, after `macId`/`macName` are available, add:

```swift
        let advertiser = PresenceAdvertiser(id: macId, name: macName)
        advertiser.start()
        self.presenceAdvertiser = advertiser
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrabReceiver -configuration Debug -derivedDataPath .build/ci-derived-data/mac build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify on the device by browsing**

Run a temporary `dns-sd -B _remotecrab-computer._tcp` (or the Task 4 browser) while the Mac receiver runs.
Expected: the Mac's instance appears within a few seconds; quitting the receiver removes it.

- [ ] **Step 5: Commit**

```bash
git add RemoteCrabReceiver/PresenceAdvertiser.swift RemoteCrabReceiver/ReceiverSession.swift
git commit -m "feat(mac): advertise the receiver on _remotecrab-computer._tcp"
```

---

### Task 6: Windows — advertise presence in `rc-discovery`

**Files:**
- Modify: `windows/crates/rc-discovery/src/lib.rs` (add `SERVICE_TYPE_COMPUTER`, `advertise`, `PresenceAdvertiser`)
- Test: `windows/crates/rc-discovery/src/lib.rs` `#[cfg(test)]`

**Interfaces:**
- Produces: `pub const SERVICE_TYPE_COMPUTER: &str`, `pub struct PresenceAdvertiser`, `pub fn advertise(instance:&str, id:&str, name:&str, platform:&str) -> Result<PresenceAdvertiser, DiscoveryError>`.

- [ ] **Step 1: Write the failing test**

```rust
#[cfg(test)]
mod presence_tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn presence_service_type_is_distinct() {
        assert_eq!(SERVICE_TYPE_COMPUTER, "_remotecrab-computer._tcp.local.");
        assert_ne!(SERVICE_TYPE_COMPUTER, "_remotecrab._tcp.local.");
    }

    #[tokio::test]
    async fn an_advertised_computer_is_found_by_a_browser() {
        let adv = advertise("rc-presence-test", "id-9", "Test PC", "windows").unwrap();
        let mut rx = browse(SERVICE_TYPE_COMPUTER).unwrap();
        let found = tokio::time::timeout(Duration::from_secs(15), async {
            while let Some(ev) = rx.recv().await {
                if let DiscoveryEvent::Found(p) = ev {
                    if p.name == "Test PC" { return; }
                }
            }
        }).await;
        assert!(found.is_ok(), "browser never found the advertised computer");
        adv.stop();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd windows && cargo test -p rc-discovery presence_tests`
Expected: FAIL — `cannot find function advertise`.

- [ ] **Step 3: Implement**

```rust
/// The service type a receiver advertises so the phone can see it online.
pub const SERVICE_TYPE_COMPUTER: &str = "_remotecrab-computer._tcp.local.";

/// A running presence announcement. Drop or `stop()` to remove it.
pub struct PresenceAdvertiser {
    daemon: ServiceDaemon,
    fullname: String,
}

impl PresenceAdvertiser {
    pub fn stop(self) {
        let _ = self.daemon.unregister(&self.fullname);
    }
}

/// Announce this computer on the LAN. Port is 0: the phone reads the TXT
/// record, it never connects here.
pub fn advertise(instance: &str, id: &str, name: &str, platform: &str)
    -> Result<PresenceAdvertiser, DiscoveryError> {
    let daemon = ServiceDaemon::new()?;
    let host = format!("{}.local.", instance.replace(' ', "-"));
    let ip = local_ipv4_addresses().into_iter().next().unwrap_or_default();
    let ip_arg = if ip.is_empty() { () } else { ip.as_str() };
    let props = [("id", id), ("name", name), ("platform", platform)];
    let info = mdns_sd::ServiceInfo::new(
        SERVICE_TYPE_COMPUTER, instance, &host, ip_arg, 0u16, &props[..],
    )?;
    let fullname = info.get_fullname().to_string();
    daemon.register(info)?;
    Ok(PresenceAdvertiser { daemon, fullname })
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd windows && cargo test -p rc-discovery`
Expected: PASS.

- [ ] **Step 5: Wire into `rc-app` startup** (same commit)

Find where the app starts its discovery/browse loop in `windows/crates/rc-app/src/main.rs`; create `let _presence = rc_discovery::advertise(pc_id, machine_id, machine_name, "windows")?;` next to it and keep the value alive for the process. (If `mdns_sd::ServiceInfo::new`'s IP argument signature differs on this version, use the host-name-only overload — the test pins the outcome, not the overload.)

- [ ] **Step 6: Commit**

```bash
git add windows/crates/rc-discovery/src/lib.rs windows/crates/rc-app/src/main.rs windows/Cargo.lock
git commit -m "feat(windows): advertise the receiver on _remotecrab-computer._tcp"
```

---

### Task 7: iOS — browse computers in `CaptureEngine`

**Files:**
- Modify: `RemoteCrabCapture/CaptureEngine.swift` (add published prop, browser, start/stop; near the listener 1330-1400)
- Test: covered by Task 4's contract + device e2e (Task 9). Pure logic is in `ComputerRoster`.

**Interfaces:**
- Consumes: `ComputerPresence`, `IBServiceType.computer`, `IBServiceType.PresenceTXT`.
- Produces: `@Published private(set) var onlineComputers: [ComputerPresence]`.

- [ ] **Step 1: Add the published property and browser**

```swift
    /// Computers currently announcing themselves on `_remotecrab-computer._tcp`.
    @Published private(set) var onlineComputers: [ComputerPresence] = []
    private var computerBrowser: NWBrowser?
```

- [ ] **Step 2: Start/stop the browser alongside the listener**

Add:

```swift
    private func startComputerBrowser() {
        guard computerBrowser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: IBServiceType.computer, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [ComputerPresence] = []
            for result in results {
                guard case let .bonjour(record) = result.metadata else { continue }
                guard let id = record[IBServiceType.PresenceTXT.id], !id.isEmpty else { continue }
                let name = record[IBServiceType.PresenceTXT.name] ?? id
                let platform = record[IBServiceType.PresenceTXT.platform] ?? "macos"
                found.append(ComputerPresence(id: id, name: name, platform: platform))
            }
            Task { @MainActor [weak self] in
                self?.onlineComputers = found
            }
        }
        browser.start(queue: queue)
        computerBrowser = browser
    }

    private func stopComputerBrowser() {
        computerBrowser?.cancel()
        computerBrowser = nil
    }
```

Call `startComputerBrowser()` where the listener starts (in `startStreaming`/listener setup) and `stopComputerBrowser()` on teardown. Use `Task { @MainActor in self.onlineComputers = found }` so the `@Published` write is on the main actor.

- [ ] **Step 3: Build**

Run: `xcodebuild -project RemoteCrabCapture.xcodeproj -scheme RemoteCrabCapture -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath .build/ci-derived-data/ios build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add RemoteCrabCapture/CaptureEngine.swift
git commit -m "feat(ios): browse _remotecrab-computer._tcp into onlineComputers"
```

---

### Task 8: iOS — the picker UI (online/offline, tap-to-connect, reasons) + crab loading

**Files:**
- Create: `RemoteCrabCapture/ComputerPickerView.swift` (move `MacPickerView`'s existing sections in; add online/offline rendering)
- Modify: `RemoteCrabCapture/ContentView.swift:191` (`MacPickerView()` → `ComputerPickerView()`)
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift` (add new keys, en + zh-Hans)
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Components/CrabMascot.swift` (inline variant if needed)

**Interfaces:**
- Consumes: `ComputerRoster.entries`, `engine.onlineComputers`, `engine.seenComputers`, `engine.setPreferredComputer(id:)`, `CrabLoading`.

- [ ] **Step 1: Add the roster-backed section**

In `ComputerPickerView`, replace `seenSection` with a roster that shows **online** rows first (green dot + OS icon: `desktopcomputer` / `pc`), then **offline** rows (grey, "last seen <relative>"). Tap online → `engine.setPreferredComputer(id: entry.id)`; tap offline → same, but the row states it will connect when it returns. Keep the existing `preferredSection`, `gaveUpSection`, `sessionSection` unchanged.

- [ ] **Step 2: Use `CrabLoading` for the wait, not a stock spinner**

When a preference is armed for an online computer, render `CrabLoading(message: IBLocale.Pairing.connectingTo(name))` instead of the current bare text/spinner. When offline, keep it a sentence with the last-seen time.

- [ ] **Step 3: Add the new localized strings (en + zh-Hans)**

Add to `IBLocale.Pairing`: `computersOnlineSection`, `computersOfflineSection`, `computersLastSeen(_ name: String, _ when: String)`, `connectingTo(_ name: String)`, `computerOnline`, `computerOffline`, `computerWillConnectWhenBack(_ name: String)`. Provide both languages (grep the existing `Pairing` enum and mirror its shape).

- [ ] **Step 4: Audit remaining user-facing `ProgressView`s**

Run: `grep -rn 'ProgressView' RemoteCrabCapture/*.swift`
Replace every indeterminate wait (not a determinate progress bar / file-transfer progress) with `CrabLoading`. Leave `ProgressView(value:)` and `fileTransferProgress` bars alone.

- [ ] **Step 5: Build + screenshot**

Run the iOS build (Task 7 Step 3), then capture the picker with a Mac online and a Mac offline using the existing screenshot tooling.
Expected: online dot visible, offline shows last-seen, crab loading shows while connecting.

- [ ] **Step 6: Commit**

```bash
git add RemoteCrabCapture/ComputerPickerView.swift RemoteCrabCapture/ContentView.swift RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift RemoteCrabCore/Sources/RemoteCrabCore/Components/CrabMascot.swift RemoteCrabCapture/*.swift
git commit -m "feat(ios): choose-computer shows who is online, taps connect, crab loading"
```

---

### Task 9: Real-device verification (rule 5)

**Files:** none (verification only).

- [ ] **Step 1:** Unlock the iPhone, screen-lock never. Confirm `xcrun devicectl list devices` shows it available.
- [ ] **Step 2:** Run the Mac receiver (dev build from Task 5). Open the picker on the phone. Record a screenshot: the Mac must show **Online**.
- [ ] **Step 3:** Quit the Mac receiver. Within the browse TTL the Mac row must flip to **Offline** with a last-seen time.
- [ ] **Step 4:** Relaunch the Mac receiver; the row returns to Online within a few seconds.
- [ ] **Step 5:** With a second computer (or the Windows build), confirm two rows, correct OS icons, dedupe by id even when names match.
- [ ] **Step 6:** Tap the online Mac; confirm it connects within ~1–2 s and the connection shows the crab loading while it does.
- [ ] **Step 7:** Run `./scripts/e2e-device.sh` once for the regression suite; expect the same 25/0/2 baseline.
- [ ] **Step 8: Commit any doc/screenshot artifacts**

```bash
git add docs/ screenshots/ 2>/dev/null || true
git commit -m "docs: computer-presence device verification"
```

---

### Task 10: Docs + handoff

**Files:**
- Modify: `AGENTS.md` (wire/feature notes: the new presence service; move the iOS-initiated-selection item to "partially done — presence + tap-to-prefer")
- Modify: `docs/WINDOWS_TODO.md` (the Windows advertise item is now implemented; the remaining Windows work is only the real-device A/B)
- Modify: `docs/HANDOFF-WINDOWS-2026-10-05.md` (add the presence TXT contract the Windows side must match byte-for-byte)

- [ ] **Step 1:** Write the three doc updates with the exact TXT contract and what was device-verified.
- [ ] **Step 2:** `git add AGENTS.md docs/` and commit `docs: computer presence — contract, verification, and what Windows still owns`.

---

## Self-Review

**Spec coverage:** presence model → T1; roster/online decision → T2; service type/TXT → T3; discoverability contract → T4; Mac announce → T5; Windows announce → T6; iOS browse → T7; picker + loading → T8; device verification → T9; docs/handoff → T10. Spec's "no new wire kind", "dedupe by id", "offline keeps history", "crab loading reuses mascot" are all covered by T2/T5/T8.

**Placeholder scan:** no TBD/TODO; each code step has code. Task 8's UI steps reference exact files and existing APIs (`setPreferredComputer`, `CrabLoading`); the localized-key step names the exact keys to add.

**Type consistency:** `ComputerPresence(id:name:platform:lastSeen:)` (T1) is used identically in T2/T3/T4/T5/T7; `ComputerRoster.entries(online:seen:)` and `.state(...)` (T2) are used in T8; `IBServiceType.computer` / `PresenceTXT` (T3) are used in T4/T5/T6/T7. Rust `SERVICE_TYPE_COMPUTER` matches the Swift string.

**Known risk:** Task 6's `ServiceInfo::new` IP overload — the plan pins the outcome with a test, not the overload. Task 4/6's multicast may be blocked on the build network; both tests assert the outcome and fail honestly rather than skipping silently.
