# 手机主动连接 v2 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让手机对已配对电脑「点一下 ~1s 连上、随点随切、无再确认」，三端一致且向后兼容。

**Architecture:** 反转 TCP 发起方（手机拨号），但**不反转协议角色**：手机第一帧发新的 `IBPhoneHello` 报稳定 `phoneId`，接收端按它查 token 后仍发 `clientHello`、手机仍回 `sessionReply`；peer-auth 方向/标签不变。接收端从「自动重连」改为「监听 + 能力协商」（对旧手机保留自动拨号）；`current` 门卫退役为自动拨号目标 `lastComputer`。

**Tech Stack:** Swift 6（RemoteCrabCore 包 + iOS app + macOS app）、Network.framework、Bonjour、Rust（`windows/` workspace：rc-protocol / rc-net / rc-app / rc-discovery）、XCTest、bash e2e。

**Spec:** `docs/superpowers/specs/2026-10-08-phone-initiated-connection-v2-design.md`

## Global Constraints

- 三端同一套语义；改一端不得让另一端更难用；线上已发布的 Mac / 手机 / Windows 继续可用。
- **向后兼容是硬要求**：新手机 ↔ 旧接收端、旧手机 ↔ 新接收端必须可用；旧手机 + 新接收端**零降级**。
- **协议语义不变**：电脑发 `clientHello`、手机回 `sessionReply`；`PeerAuth` 方向/label 不变；`IBSessionReplyResult` 不新增值。
- **未知 kind 必须丢弃**（Swift `.unknown`；Rust 绝不能 `_ => Video`，lesson 152）。
- 新持久化字段必须 additive + 有默认值（规则 2）；**不改已有存储键**。
- 先根因后改；Core 纯逻辑走 TDD；连接/UI 真机验证（规则 3/5）。
- 提交用明确 pathspec + `git show --name-status` 核对 + 每次 `git fetch`（lessons 92/134/147）。
- 单测命令：`./scripts/test.sh`（包 + 两 app target）；Windows：`cargo test --workspace`（在 `windows/`）。
- 修改共享工作树前先 `git fetch`；不要 `git stash pop` 别人的 stash。

---

## File Structure

**RemoteCrabCore（纯、可测）**
- `Sources/RemoteCrabCore/Networking/IBEvents.swift` — 加 `IBPhoneHello`。
- `Sources/RemoteCrabCore/Networking/IBWire.swift` — 加 `Kind.phoneHello = 0x27` + `encode/decodePhoneHello`。
- `Sources/RemoteCrabCore/State/MacPairingStore.swift` — `decide` 去 `current`、加 `userInitiated`；`pruned` 只按 id；`forget` 补全。
- `Sources/RemoteCrabCore/State/PeerTokenIndex.swift`（新）— name→id token 迁移（纯）。
- `Tests/RemoteCrabCoreTests/IBEventsTests.swift`、`PairingTests.swift`、`PeerAuthWireTests.swift`、`PhoneTokenIndexTests.swift`（新）、`ComputerRosterTests.swift`（新）。

**RemoteCrabReceiver（macOS app）**
- `PresenceAdvertiser.swift` — 入站连接交给会话。
- `ReceiverSession.swift` — 服务端握手入口、能力协商、去自动重连、文案。
- `CameraExtensionCard.swift` / `SetupStatus.swift` — 统一 `openExtensionSettings` + 分步文案（小事 A）。

**RemoteCrabCapture（iOS app）**
- `CaptureEngine.swift` — `phoneId`、`connect(toComputer:)`、`lastComputer`、`forgetComputer`、候选地址。
- `ComputerPickerView.swift` — 行点击改拨号、逐行删除 + 确认。

**Windows（交接 + 协议登记）**
- `windows/crates/rc-protocol/src/wire.rs`（或等价）— `PhoneHello = 0x27` + guard test。
- `docs/HANDOFF-WINDOWS-PHONE-INITIATED.md`（新）— §8.3 的四项 + 数字。

**e2e**
- `scripts/e2e-current-computer.sh` — 扩展多电脑切换 + 删除 + 旧接收端兼容。

---

## Task 1: 统一相机扩展指引与 `openExtensionSettings`（小事 A，独立、低风险）

**Files:**
- Modify: `RemoteCrabReceiver/SetupStatus.swift`（`openExtensionSettings()`）
- Modify: `RemoteCrabReceiver/CameraExtensionCard.swift`（卡片文案）
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ExtensionSettingsURLTests.swift`（新）

**Interfaces:**
- Produces: `ExtensionSettingsURL.paneCandidates: [URL]`（纯，按可靠度排序，只含受支持 pane，无臆造锚点）；`openExtensionSettings()` 依次尝试直到 `NSWorkspace.open` 成功或列表用尽。

- [ ] **Step 1: 写失败测试**

```swift
// ExtensionSettingsURLTests.swift
import XCTest
@testable import RemoteCrabCore

final class ExtensionSettingsURLTests: XCTestCase {
    func testNoFabricatedAnchors() {
        for url in ExtensionSettingsURL.paneCandidates {
            XCTAssertFalse(url.absoluteString.contains("?CameraExtensions"),
                           "Apple 无受支持深链到某个扩展分类；臆造锚点会让 NSWorkspace.open 假成功")
            XCTAssertTrue(url.absoluteString.contains("LoginItems-Settings")
                          || url.absoluteString.contains("Extensions"),
                          "只允许登录项与扩展相关 pane")
        }
    }
    func testMostSpecificPaneComesFirst() {
        XCTAssertTrue(ExtensionSettingsURL.paneCandidates.first?
            .absoluteString.contains("LoginItems-Settings") ?? false)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter ExtensionSettingsURLTests`
Expected: FAIL（`ExtensionSettingsURL` 未定义）

- [ ] **Step 3: 实现纯类型**

```swift
// RemoteCrabCore/Sources/RemoteCrabCore/State/ExtensionSettingsURL.swift
import Foundation

/// macOS「登录项与扩展」pane 的候选深链，按可靠度排序。
///
/// 只放**受支持**的 pane：Apple 没有深链能跳到某个具体扩展分类
/// （开发者论坛 thread 765970），所以 `CameraExtensions` 这类锚点是臆造——
/// 而 `NSWorkspace.open` 对无效锚点也返回 true，会让 fallback 永不执行
/// （lesson 159）。这里刻意不包含任何锚点。
public enum ExtensionSettingsURL {
    public static var paneCandidates: [URL] {
        var urls: [URL] = []
        // 最精确：登录项与扩展
        urls.append(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        // 旧的扩展 pane（较老系统）
        urls.append(URL(string: "x-apple.systempreferences:com.apple.preferences.Extensions")!)
        return urls
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd RemoteCrabCore && swift test --filter ExtensionSettingsURLTests`
Expected: PASS

- [ ] **Step 5: 在 SetupStatus 里改为使用候选列表**

```swift
// RemoteCrabReceiver/SetupStatus.swift — 替换 openExtensionSettings() 实现
import RemoteCrabCore
@MainActor
func openExtensionSettings() {
    for url in ExtensionSettingsURL.paneCandidates where NSWorkspace.shared.open(url) {
        return
    }
}
```

- [ ] **Step 6: CameraExtensionCard 文案改为明确分步（仅未启用时显示，中英）**

```swift
// CameraExtensionCard.swift —— 状态为「未启用」时：
// zh: 通用 → 登录项与扩展 → 向下滚动到「扩展」→ 相机扩展 → 打开 RemoteCrab Camera
// en: General → Login Items & Extensions → scroll to Extensions → Camera Extensions → turn on RemoteCrab Camera
// 通过 IBLocale 提供，卡片只渲染 string；不放入截图。
```

- [ ] **Step 7: 构建两 app + 提交**

Run: `./scripts/test.sh`
Expected: 全绿
```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/ExtensionSettingsURL.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/ExtensionSettingsURLTests.swift \
        RemoteCrabReceiver/SetupStatus.swift RemoteCrabReceiver/CameraExtensionCard.swift
git commit -m "fix(mac): unify openExtensionSettings + step-by-step camera-extension guidance"
```

---

## Task 2: Core —— `IBPhoneHello` 帧与 wire（TDD）

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift`
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBWire.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/IBEventsTests.swift`

**Interfaces:**
- Produces:
  - `struct IBPhoneHello: Codable, Sendable, Equatable { let phoneId: String; let phoneName: String; let targetPcId: String; let appVersion: String; let nonce: String?; let capabilities: [Capability]? }`
  - `IBPhoneHello.Capability: String`（`.phoneInitiated/.peerAuth/.latencyProbe`）
  - `IBWire.Kind.phoneHello`（raw `0x27`）
  - `IBWire.encode(phoneHello:) -> Data`、`IBWire.decodePhoneHello(_:) throws -> IBPhoneHello`

- [ ] **Step 1: 写失败测试**

```swift
// IBEventsTests.swift
func testPhoneHelloRoundTrips() throws {
    let hello = IBPhoneHello(phoneId: "phone-uuid", phoneName: "Edwin's iPhone",
                             targetPcId: "pc-uuid", appVersion: "1.1",
                             nonce: "AAAA", capabilities: [.phoneInitiated, .peerAuth])
    let data = try IBWire.encode(phoneHello: hello)
    XCTAssertEqual(try IBWire.decodePhoneHello(data), hello)
}

func testPhoneHelloDecodesWithoutOptionalFields() throws {
    // 旧/最小发送者不带 nonce/capabilities —— 必须能解码（前向兼容）
    let json = #"{"phoneId":"p","phoneName":"n","targetPcId":"c","appVersion":"1.0"}"#
    let decoded = try IBWire.decodePhoneHello(Data(json.utf8))
    XCTAssertNil(decoded.nonce)
    XCTAssertNil(decoded.capabilities)
}

func testPhoneHelloKindByteIs0x27() throws {
    let data = try IBWire.encode(phoneHello: IBPhoneHello(phoneId: "p", phoneName: "n",
                                                          targetPcId: "c", appVersion: "1"))
    // 前 4 字节 = 大端长度；第 5 字节 = kind
    XCTAssertEqual(data[4], 0x27)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter testPhoneHello`
Expected: FAIL（`IBPhoneHello` / `encode(phoneHello:)` 未定义）

- [ ] **Step 3: 定义帧（IBEvents.swift，镜像 `IBClientHello` 的写法）**

```swift
// 放在 IBClientHello 附近
public struct IBPhoneHello: Codable, Sendable, Equatable {
    public enum Capability: String, Codable, Sendable {
        case phoneInitiated
        case peerAuth
        case latencyProbe
    }
    public let phoneId: String
    public let phoneName: String
    public let targetPcId: String
    public let appVersion: String
    /// 可选，base64 32B。用于去重/未来扩展，不参与鉴权。
    public let nonce: String?
    /// 用 [String] 解码再 compactMap（前向兼容，同 IBClientHello）。
    public let capabilities: [Capability]?

    public init(phoneId: String, phoneName: String, targetPcId: String,
                appVersion: String, nonce: String? = nil,
                capabilities: [Capability]? = nil) {
        self.phoneId = phoneId; self.phoneName = phoneName
        self.targetPcId = targetPcId; self.appVersion = appVersion
        self.nonce = nonce; self.capabilities = capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phoneId = try c.decode(String.self, forKey: .phoneId)
        phoneName = try c.decode(String.self, forKey: .phoneName)
        targetPcId = try c.decode(String.self, forKey: .targetPcId)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "0"
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities)?
            .compactMap(Capability.init(rawValue:))
    }
}
```

- [ ] **Step 4: 加 Kind + encode/decode（IBWire.swift）**

```swift
// Kind enum 里（0x26 clientProof 之后）
case phoneHello = 0x27

// encode：镜像 encode(clientHello:)
public static func encode(phoneHello: IBPhoneHello) throws -> Data {
    try frame(kind: .phoneHello, payload: JSONEncoder().encode(phoneHello))
}

// decode：镜像 decodeClientHello
public static func decodePhoneHello(_ data: Data) throws -> IBPhoneHello {
    try JSONDecoder().decode(IBPhoneHello.self, from: data)
}
```
> **必须**确认 `Kind(rawValue:)` 对未知值落 `.unknown`（不是 `.video`）。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd RemoteCrabCore && swift test --filter testPhoneHello`
Expected: PASS

- [ ] **Step 6: 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift \
        RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBWire.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/IBEventsTests.swift
git commit -m "feat(core): IBPhoneHello frame (0x27) for phone-initiated connections"
```

---

## Task 3: Core —— `PairingPolicy` 去 `current`、加 `userInitiated`（TDD）

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/State/MacPairingStore.swift`
- Modify: `RemoteCrabCapture/CaptureEngine.swift:1699-1702`（唯一调用点）
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/PairingTests.swift`

**Interfaces:**
- Consumes: `IBClientHello`, `PairedMac`, `PairingDecision`（现有）。
- Produces: `PairingPolicy.decide(hello:paired:owner:preferred:disconnected:userInitiated:) -> PairingDecision`（**去掉 `current:` 参数**，加 `userInitiated: Bool = false`）。

- [ ] **Step 1: 写失败测试（新增语义 + 回归：current 不再锁死）**

```swift
// PairingTests.swift
func testUserInitiatedBypassesAnyOwnerGate() {
    // 手机主动拨的目标，即使 store 里 current/preferred 指向别的电脑，也要 accept
    let hello = IBClientHello(name: "PC", id: "pc-2", token: "t2", appVersion: "1",
                              platform: "windows", capabilities: [], nonce: "n")
    let paired = [PairedMac(id: "pc-2", name: "PC", token: "t2")]
    let decision = PairingPolicy.decide(hello: hello, paired: paired, owner: nil,
                                        preferred: PairedMac(id: "pc-1", name: "Old", token: "t1"),
                                        disconnected: nil, userInitiated: true)
    XCTAssertEqual(decision, .accept)
}

func testUserInitiatedStillNeedsTokenForAccept() {
    let hello = IBClientHello(name: "PC", id: "pc-2", token: nil, appVersion: "1", platform: "windows")
    let paired = [PairedMac(id: "pc-2", name: "PC", token: "t2")]
    let decision = PairingPolicy.decide(hello: hello, paired: paired, owner: nil,
                                        preferred: nil, disconnected: nil, userInitiated: true)
    XCTAssertEqual(decision, .pending)   // 无 token → 需要挑战/审批，不自动接受
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter testUserInitiated`
Expected: FAIL（签名不匹配）

- [ ] **Step 3: 改 `decide`**

```swift
public static func decide(
    hello: IBClientHello,
    paired: [PairedMac],
    owner: PairedMac?,
    preferred: PairedMac? = nil,
    disconnected: PairedMac? = nil,
    userInitiated: Bool = false
) -> PairingDecision {
    if let disconnected, disconnected.id == hello.id {
        return .off(ownerName: disconnected.name)
    }
    // 用户主动拨号：用户已明确选择目标，owner/preferred/current 都不该拦它。
    if !userInitiated {
        if let owner, owner.id != hello.id { return .busy(ownerName: owner.name) }
        if let preferred, preferred.id != hello.id { return .busy(ownerName: preferred.name) }
        // 注意：current 门卫已退役（它是「这台能连那台不能连」的元凶）。
        // 切换期由 CaptureEngine 的瞬态 outboundTarget 负责（见 Task 11）。
    }
    if let match = paired.first(where: { $0.id == hello.id }),
       let token = hello.token, token == match.token {
        return .accept
    }
    return .pending
}
```

- [ ] **Step 4: 更新调用点（CaptureEngine.swift:1699）**

```swift
let decision = PairingPolicy.decide(hello: hello, paired: pairingStore.paired, owner: nil,
                                    preferred: pairingStore.effectivePreferred(),
                                    disconnected: pairingStore.disconnected)
// 出站路径（Task 11）会另传 userInitiated: true
```

- [ ] **Step 5: 更新 `PairingTests` 里依赖 `current:` 参数的既有用例**

把 `current:` 实参删除；受影响的「current 锁死」用例改为断言**不再锁死**（同名改为 `testCurrentNoLongerLocksEveryoneOut`）。保留 owner/preferred 的 busy 用例不变。

- [ ] **Step 6: 跑测试 + 提交**

Run: `cd RemoteCrabCore && swift test` — 全绿
```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/MacPairingStore.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/PairingTests.swift \
        RemoteCrabCapture/CaptureEngine.swift
git commit -m "feat(core): retire the current gate; add userInitiated to PairingPolicy.decide"
```

---

## Task 4: Core —— `pruned` 只按 id（TDD）

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/State/MacPairingStore.swift`（`pruned`）
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/PairingTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
func testSameNameDifferentIdBothSurvive() {
    let now = Date()
    let a = SeenComputer(id: "id-a", name: "EDWIN", platform: "windows", lastSeen: now)
    let b = SeenComputer(id: "id-b", name: "EDWIN", platform: "windows", lastSeen: now)
    let out = MacPairingStore.pruned([a, b], now: now)
    XCTAssertEqual(Set(out.map(\.id)), ["id-a", "id-b"], "同名不同 id 必须都保留，否则无法在它们之间切换")
}

func testTTLStillApplies() {
    let now = Date()
    let old = SeenComputer(id: "id-old", name: "X", platform: "macos",
                           lastSeen: now.addingTimeInterval(-MacPairingStore.staleSeenTTL - 1))
    XCTAssertTrue(MacPairingStore.pruned([old], now: now).isEmpty)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter testSameNameDifferentIdBothSurvive`
Expected: FAIL（当前按名合并，只剩一行）

- [ ] **Step 3: 改 `pruned`（去掉按名合并，保留 TTL）**

```swift
public static func pruned(_ entries: [SeenComputer],
                          now: Date = Date(),
                          ttl: TimeInterval = staleSeenTTL) -> [SeenComputer] {
    var seenIds = Set<String>()
    return entries
        .filter { now.timeIntervalSince($0.lastSeen) < ttl }
        .filter { seenIds.insert($0.id).inserted }   // 只按 id 去重（稳定 id 上线后按名合并已无收益）
        .sorted { $0.lastSeen == $1.lastSeen ? $0.id < $1.id : $0.lastSeen > $1.lastSeen }
}
```

- [ ] **Step 4: 删除/改写既有按名合并测试**

`testTheSameNameCollapsesRegardlessOfCase`、`testASupersededIdentityDoesNotLeaveADuplicateRow`、
`testKnockingUnderANewIdCollapsesTheOldRowOnDisk` 改为「都保留」语义，或删除并在提交说明里写原因。
`pruneStale` 里 dangling-preference 的规则保持（它按 id 判断，不受影响）。

- [ ] **Step 5: 跑测试 + 提交**

Run: `cd RemoteCrabCore && swift test`
```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/MacPairingStore.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/PairingTests.swift
git commit -m "fix(core): prune seen computers by id only (stable identity makes name-merge harmful)"
```

---

## Task 5: Core —— `forget` 补全 + N 台不变量（小事 B，TDD）

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/State/MacPairingStore.swift`（文档/测试；`forget` 已清全，补 `current`/`preferred`/`disconnected` 断言）
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerRosterTests.swift`（新）

**Interfaces:**
- Consumes: `MacPairingStore.forget(id:)`, `PickerRows`, `PairingPolicy.decide`。
- Produces: 不变量测试（纯逻辑）。

- [ ] **Step 1: 写失败/守护测试（N=10）**

```swift
// ComputerRosterTests.swift
import XCTest
@testable import RemoteCrabCore

final class ComputerRosterTests: XCTestCase {
    func testTenComputersAllListed() {
        var store = MacPairingStore(defaults: UserDefaults(suiteName: "roster-\(UUID())")!)
        for i in 0..<10 {
            let hello = IBClientHello(name: "PC\(i)", id: "id-\(i)", token: nil,
                                      appVersion: "1", platform: "windows")
            store.noteSeen(hello)
        }
        XCTAssertEqual(store.seen.count, 10)
    }

    func testOnlyChosenIsAcceptedRestBusy() {
        let chosen = PairedMac(id: "id-3", name: "PC3", token: "t3")
        let others = (0..<10).filter { $0 != 3 }.map {
            PairedMac(id: "id-\($0)", name: "PC\($0)", token: "t\($0)")
        }
        for o in others {
            let hello = IBClientHello(name: o.name, id: o.id, token: o.token, appVersion: "1")
            XCTAssertEqual(PairingPolicy.decide(hello: hello, paired: [chosen] + others,
                                                owner: chosen, preferred: nil, disconnected: nil),
                           .busy(ownerName: chosen.name))
        }
    }

    func testForgetRemovesFromEveryList() {
        let d = UserDefaults(suiteName: "roster-forget-\(UUID())")!
        let store = MacPairingStore(defaults: d)
        store.pair(IBClientHello(name: "PC", id: "id-x", token: nil, appVersion: "1"))
        store.noteSeen(IBClientHello(name: "PC", id: "id-x", token: nil, appVersion: "1"))
        store.setPreferred(id: "id-x", name: "PC")
        store.markDisconnected(id: "id-x", name: "PC")
        store.setCurrent(id: "id-x", name: "PC")
        store.forget(id: "id-x")
        XCTAssertTrue(store.paired.isEmpty)
        XCTAssertFalse(store.seen.contains { $0.id == "id-x" })
        XCTAssertNil(store.preferredId)
        XCTAssertNil(store.disconnected)
        XCTAssertNil(store.currentId)
    }
}
```

- [ ] **Step 2: 跑（可能部分已过）**

Run: `cd RemoteCrabCore && swift test --filter ComputerRosterTests`
Expected: 新测试编译通过；`pruned` 相关项已在 Task 4 变绿。若失败，修实现（`forget` 已清全，主要验证不变量）。

- [ ] **Step 3: 提交**

```bash
git add RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerRosterTests.swift
git commit -m "test(core): pin multi-computer roster invariants (list-all, only-owner-accepted, forget-all)"
```

---

## Task 6: Core —— `PeerTokenIndex` name→id 迁移（TDD，供接收端用）

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/PeerTokenIndex.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/PeerTokenIndexTests.swift`（新）

**Interfaces:**
- Produces:
  - `struct PeerTokenIndex`：
    - `init(byPhoneId: [String: String], byName: [String: String], phoneInitiated: Set<String>)`
    - `mutating func token(phoneId: String, name: String) -> String?`（先 id，miss 后 name，命中即 backfill 到 id）
    - `mutating func set(phoneId: String, name: String, token: String)`
    - `func isPhoneInitiated(phoneId: String) -> Bool`
    - `mutating func markPhoneInitiated(phoneId: String)`
    - `mutating func forget(phoneId: String)`
    - `var byPhoneId/ byName / phoneInitiated`（只读，供持久化）

- [ ] **Step 1: 写失败测试**

```swift
func testNameKeyedLegacyTokenMigratesToId() {
    var idx = PeerTokenIndex(byPhoneId: [:], byName: ["Edwin's iPhone": "old-token"], phoneInitiated: [])
    XCTAssertEqual(idx.token(phoneId: "phone-uuid", name: "Edwin's iPhone"), "old-token")
    XCTAssertEqual(idx.byPhoneId["phone-uuid"], "old-token", "命中后要 backfill 到 id 表")
}

func testPhoneInitiatedFlagPersists() {
    var idx = PeerTokenIndex(byPhoneId: [:], byName: [:], phoneInitiated: [])
    XCTAssertFalse(idx.isPhoneInitiated(phoneId: "p1"))
    idx.markPhoneInitiated(phoneId: "p1")
    XCTAssertTrue(idx.isPhoneInitiated(phoneId: "p1"))
    idx.forget(phoneId: "p1")
    XCTAssertFalse(idx.isPhoneInitiated(phoneId: "p1"))
}
```

- [ ] **Step 2: 跑确认失败** → `swift test --filter PeerTokenIndexTests` FAIL

- [ ] **Step 3: 实现**

```swift
public struct PeerTokenIndex: Equatable, Sendable {
    public private(set) var byPhoneId: [String: String]
    public private(set) var byName: [String: String]
    public private(set) var phoneInitiated: Set<String>

    public init(byPhoneId: [String: String] = [:], byName: [String: String] = [:],
                phoneInitiated: Set<String> = []) {
        self.byPhoneId = byPhoneId; self.byName = byName; self.phoneInitiated = phoneInitiated
    }

    public mutating func token(phoneId: String, name: String) -> String? {
        if let t = byPhoneId[phoneId] { return t }
        guard let t = byName[name] else { return nil }
        byPhoneId[phoneId] = t          // 迁移：旧 name-keyed token 复制到 id 表
        return t
    }

    public mutating func set(phoneId: String, name: String, token: String) {
        byPhoneId[phoneId] = token
        byName[name] = token
    }

    public func isPhoneInitiated(phoneId: String) -> Bool { phoneInitiated.contains(phoneId) }
    public mutating func markPhoneInitiated(phoneId: String) { phoneInitiated.insert(phoneId) }
    public mutating func forget(phoneId: String) {
        byPhoneId.removeValue(forKey: phoneId)
        phoneInitiated.remove(phoneId)
    }
}
```

- [ ] **Step 4: 跑 + 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/Networking/PeerTokenIndex.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/PeerTokenIndexTests.swift
git commit -m "feat(core): PeerTokenIndex (name→id token migration + phone-initiated flag)"
```

---

## Task 7: Mac —— `PresenceAdvertiser` 把入站连接交给会话

**Files:**
- Modify: `RemoteCrabReceiver/PresenceAdvertiser.swift`
- Modify: `RemoteCrabReceiver/ReceiverSession.swift`（init 里的接线）
- Test: 集成（`scripts/e2e-parity.sh` / 新增假手机脚本，见 Task 18）

**Interfaces:**
- Consumes: `NWConnection`。
- Produces: `PresenceAdvertiser.onInbound: ((NWConnection) -> Bool)?`（返回 true = 已作为数据连接接管；false = 当敲门处理）。

- [ ] **Step 1: 读现状并写清影响面**

`PresenceAdvertiser` 现在是 `.tcp` listener + 服务注册，`onKnock` 在 accept 时触发。新增 `onInbound`，accept 时**先**问会话能否接管；不能则走原 knock 路径。

- [ ] **Step 2: 改 `PresenceAdvertiser`**

```swift
// PresenceAdvertiser.swift
var onKnock: (() -> Void)?
/// 新的数据入口：返回 true 表示这条连接已被会话接管（正在做服务端握手），
/// 不应再当作「敲门」。返回 false 则退回原来的 knock → retryNow 行为。
var onInbound: ((NWConnection) -> Bool)?

// accept 回调里（把原来的 onKnock() 调用替换为）：
if let onInbound, onInbound(connection) {
    // 会话接管：不要 cancel，会话负责这条连接的读写与生命周期
} else {
    connection.cancel()
    onKnock?()
}
```

- [ ] **Step 3: 在 `ReceiverSession.init` 接线**

```swift
advertiser.onInbound = { [weak self] conn in
    guard let self else { return false }
    return self.handleInboundData(conn)   // Task 8
}
```
> `retryNow()` 仍由 `onKnock` 保留（用于旧手机/无帧连接）。

- [ ] **Step 4: 构建**

Run: `xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrab -configuration Debug build`
Expected: BUILD SUCCEEDED（`handleInboundData` 在 Task 8 里实现前先用桩返回 `false` 以便本步可编译）

- [ ] **Step 5: 提交**（可与 Task 8 合并提交，视 review 方便）

```bash
git add RemoteCrabReceiver/PresenceAdvertiser.swift RemoteCrabReceiver/ReceiverSession.swift
git commit -m "feat(mac): PresenceAdvertiser can hand an inbound connection to the session"
```

---

## Task 8: Mac —— 服务端握手入口 `handleInboundData`

**Files:**
- Modify: `RemoteCrabReceiver/ReceiverSession.swift`
- Test: `scripts/e2e-parity.sh`（假手机）+ 真机（Task 18）

**Interfaces:**
- Consumes: `IBPhoneHello`, `PeerTokenIndex`, `sendClientHello`、`handleSessionReply`、`answerChallenge`（现有）。
- Produces: `func handleInboundData(_ conn: NWConnection) -> Bool`。

- [ ] **Step 1: 写假手机 e2e 脚本（先让它红）**

在 `windows/crates/rc-phone-sim` 或一个新的 `scripts/fake-phone-hello.swift`（本机 Swift）里：连 `127.0.0.1:<macKnockPort>`，发 `IBPhoneHello{targetPcId=<macId>}`，断言收到 `clientHello`，再发 `sessionReply{accepted}`，断言开始收帧。
先运行，确认**今天失败**（接收端只会 cancel）。

- [ ] **Step 2: 实现 `handleInboundData`**

```swift
// ReceiverSession.swift
/// 一条入站连接的第一帧决定它是数据还是敲门。
/// - phoneHello 且 target 是本机 → 服务端握手（返回 true）
/// - 无帧 / EOF → 敲门（返回 false，交回 PresenceAdvertiser）
func handleInboundData(_ conn: NWConnection) -> Bool {
    var buffer = Data()
    var decided = false
    var handled = false
    conn.stateUpdateHandler = { _ in }
    conn.start(queue: .global())
    func readFirstFrame() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            if let frame = try? IBWire.Parser().parseNext(&buffer) {   // 用现有增量解析器
                decided = true
                if frame.kind == .phoneHello, let hello = try? IBWire.decodePhoneHello(frame.payload),
                   hello.targetPcId == self.macId {
                    handled = true
                    Task { @MainActor in self.beginServerSession(conn, hello: hello) }
                } else {
                    conn.cancel(); Task { @MainActor in self.retryNow() }   // 不是给我们的数据 → 当敲门
                }
                return
            }
            if isComplete || error != nil || buffer.count > 4096 {
                if !decided { conn.cancel(); Task { @MainActor in self.retryNow() } }  // 无帧 = 敲门
                return
            }
            readFirstFrame()
        }
    }
    readFirstFrame()
    return true   // 接管这条连接
}
```
> **注意**：`return true` 表示「已接管」。若判别结果其实是敲门，我们主动 `retryNow()`——与旧行为等价，但避免立刻 cancel 吞掉首帧。

- [ ] **Step 3: `beginServerSession` —— 复用现有握手**

```swift
private func beginServerSession(_ conn: NWConnection, hello: IBPhoneHello) {
    tokenIndex.markPhoneInitiated(phoneId: hello.phoneId)
    if let token = tokenIndex.token(phoneId: hello.phoneId, name: hello.phoneName) {
        // 置 key 后复用现有 answerChallenge：它读 currentTokenKey
    }
    currentTokenKey = tokenIndexKey(phoneId: hello.phoneId, name: hello.phoneName)
    connection = conn
    startReceiving(on: conn)
    state = .handshaking(name: hello.phoneName)
    sendClientHello(on: conn)       // token 必须为 nil（不出示秘密）
    startHandshakeTimeout(on: conn)
}
```
- `sendClientHello` 在服务端路径上必须发 `token: nil`（加参数或分支）。
- `handleSessionReply`/`answerChallenge` 用 `currentTokenKey` 查 `PeerTokenIndex`（把 `tokenStore[...]` 换成 `tokenIndex.token(...)`）。
- `accepted` 分支：把 `reply.token` 存进 `tokenIndex.set(phoneId:name:token:)` 并持久化。

- [ ] **Step 4: 跑假手机 e2e**

Run: `./scripts/e2e-parity.sh --input fake-phone`（或新脚本）
Expected: 断言 `clientHello sent` → `sessionReply accepted` → 收帧。绿。

- [ ] **Step 5: 提交**

```bash
git add RemoteCrabReceiver/ReceiverSession.swift scripts/
git commit -m "feat(mac): server-side handshake for phone-initiated connections (reads IBPhoneHello)"
```

---

## Task 9: Mac —— 去自动重连（能力协商）+ 等待文案

**Files:**
- Modify: `RemoteCrabReceiver/ReceiverSession.swift`（`handleDiscovered`、`scheduleReconnect`、`startFallbackLoop`、等待文案）
- Modify: `RemoteCrabReceiver/MenuBarMenu.swift` / `RemoteCrabReceiver/ReceiverSession.swift` 的 `State` 文案
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift`（新增等待态文案，中英）

**Interfaces:**
- Consumes: `PeerTokenIndex.isPhoneInitiated(phoneId:)`。
- Produces: 自动拨号仅对 `supportsPhoneInitiated == false` 的手机生效。

- [ ] **Step 1: 文案先加（含测试）**

```swift
// IBLocale：新增
// Error.waitingForPhone  en: "Open RemoteCrab on your iPhone and pick this computer."
//                        zh: "请打开手机上的 RemoteCrab，在「选择电脑」里选本机。"
// 测试（PairingTests 或 Locale 测试）：断言 key 中英都存在且非空。
```

- [ ] **Step 2: 改 `handleDiscovered`**

```swift
// 只对「不是手机发起」的手机自动拨；支持手机发起的手机由手机自己拨。
guard let phone = phones.first(where: { tokenStore[$0.name] != nil }) ?? phones.first else { return }
if let id = phoneIdByName[phone.name], tokenIndex.isPhoneInitiated(phoneId: id) {
    // 它自己会拨；保持 ≥60s 的静默安全网（可选）或完全不拨（本迭代：完全不拨）
    return
}
if connection == nil { connect(to: phone) }
```

- [ ] **Step 3: `scheduleReconnect` / `startFallbackLoop` 同样加条件**

断链后的 3s 重连只对 legacy 手机生效；对新手机，等待态显示 §Step 1 文案。手动 `Connect`/`retryNow`（敲门）仍可用。

- [ ] **Step 4: 构建 + 真机（Task 18 一起验）**

Run: `./scripts/test.sh`
Expected: 全绿

- [ ] **Step 5: 提交**

```bash
git add RemoteCrabReceiver/ReceiverSession.swift RemoteCrabReceiver/MenuBarMenu.swift \
        RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift
git commit -m "feat(mac): stop auto-reconnect for phone-initiated phones; explain waiting state"
```

---

## Task 10: iOS —— 稳定 `phoneId`

**Files:**
- Modify: `RemoteCrabCapture/CaptureEngine.swift`

**Interfaces:**
- Produces: `var phoneId: String`（持久化键 `remotecrab.ios.phoneId`，首次生成 UUID）。

- [ ] **Step 1: 实现 + 一个小测试（可放 Core 若抽成纯函数）**

```swift
static func loadPhoneId(defaults: UserDefaults = .standard) -> String {
    let key = "remotecrab.ios.phoneId"
    if let existing = defaults.string(forKey: key) { return existing }
    let fresh = UUID().uuidString
    defaults.set(fresh, forKey: key)
    return fresh
}
```
（抽成 `RemoteCrabCore` 的纯静态函数以便测试「两次调用同值」；或直接在 app 内。）保留 `REMOTECRAB_E2E_PHONE_ID` 环境变量覆盖（e2e 用）。

- [ ] **Step 2: 构建 + 提交**

```bash
git add RemoteCrabCapture/CaptureEngine.swift
git commit -m "feat(ios): stable phoneId for identity-keyed pairing"
```

---

## Task 11: iOS —— 出站拨号 `connect(toComputer:)` + `IBPhoneHello` + 首帧处理 + 回退

**Files:**
- Modify: `RemoteCrabCapture/CaptureEngine.swift`
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEventBroadcaster.swift`（`send(IBPhoneHello)`）
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/EventPipelineEndToEndTests.swift`（客户端侧 round-trip）

**Interfaces:**
- Consumes: `IBPhoneHello`、`computerEndpoints`、`handleHello`。
- Produces:
  - `func connect(toComputer id: String)`
  - `private var outboundTarget: PairedMac?`（瞬态竞态门卫）
  - `sendPhoneHello`、首帧分派（`clientHello` | `sessionReply`）。

- [ ] **Step 1: `IBEventBroadcaster` 加发送**

```swift
// IBEventBroadcaster.swift
func send(_ hello: IBPhoneHello) {
    guard let data = try? IBWire.encode(phoneHello: hello) else { return }
    connection.send(content: data, completion: .contentProcessed { _ in })
}
```

- [ ] **Step 2: `connect(toComputer:)`**

```swift
func connect(toComputer id: String) {
    guard let endpoint = computerEndpoints[id] ?? rememberedEndpoint(id) else {
        // 离线：arm「待上线就拨」
        setPreferredComputer(id: id); return
    }
    pairingStore.clearDisconnected()
    outboundTarget = PairedMac(id: id, name: nameForComputer(id: id) ?? id,
                              pairedAt: .distantPast, token: "")
    let conn = NWConnection(to: endpoint, using: tcpComputerParameters())
    connection = conn
    conn.stateUpdateHandler = { [weak self] st in
        Task { @MainActor in self?.handleOutboundState(st, on: conn, targetId: id) }
    }
    startOutboundReceive(on: conn, targetId: id)
    conn.start(queue: queue)
}

private func handleOutboundState(_ st: NWConnection.State, on conn: NWConnection, targetId: String) {
    guard connection === conn else { return }
    switch st {
    case .ready:
        broadcaster?.send(IBPhoneHello(phoneId: phoneId, phoneName: UIDevice.current.name,
                                       targetPcId: targetId, appVersion: appVersion,
                                       capabilities: [.phoneInitiated, .peerAuth, .latencyProbe]))
        connectionState = .connecting; startOutboundHandshakeWatchdog(conn)
    case .failed, .cancelled:
        outboundTarget = nil
        // 回退：arm + knock + 等旧接收端回拨（沿用现状）
        setPreferredComputer(id: targetId)
    default: break
    }
}
```

- [ ] **Step 3: `startOutboundReceive` 首帧分派**

```swift
private func startOutboundReceive(on conn: NWConnection, targetId: String) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
        guard let self, let data, !data.isEmpty else { return }
        Task { @MainActor in
            if let frame = try? IBWire.Parser().parseNext(data) {
                switch frame.kind {
                case .clientHello:
                    self.handleHello(frame.payload, on: conn, userInitiated: true)   // 现有路径
                case .sessionReply:
                    // 接收端拒绝（busy/off）：如实显示
                    self.handleOutboundRefusal(try? IBWire.decodeSessionReply(frame.payload))
                default:
                    self.handleInboundFrame(frame, on: conn)   // 复用入站分派
                }
            }
        }
        self.startOutboundReceive(on: conn, targetId: targetId)   // 继续读
    }
}
```

- [ ] **Step 4: 握手看门狗（等 clientHello ~4s）与回退**

超时 → 视为旧接收端 → `conn.cancel()` → `setPreferredComputer(id:)`（arm + knock）→ 等入站 `handleHello`。`outboundTarget` 清空。

- [ ] **Step 5: `handleHello` 增加 `userInitiated` 参数**

把现有 `handleHello` 的 `decide(...)` 调用传 `userInitiated: userInitiated`；`outboundTarget` 在 `handleHello` 里作为 `owner` 传入（让别的电脑 busy）。

- [ ] **Step 6: 测试 + 构建**

Run: `./scripts/test.sh`
Expected: 全绿；`EventPipelineEndToEndTests` 新增一条 `phoneHello → clientHello → sessionReply.accepted` 的 TCP round-trip。

- [ ] **Step 7: 提交**

```bash
git add RemoteCrabCapture/CaptureEngine.swift \
        RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEventBroadcaster.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/EventPipelineEndToEndTests.swift
git commit -m "feat(ios): phone-initiated connect(toComputer:) with IBPhoneHello and legacy fallback"
```

---

## Task 12: iOS —— picker 行点击改拨号 + `lastComputer` 启动自动拨

**Files:**
- Modify: `RemoteCrabCapture/ComputerPickerView.swift`
- Modify: `RemoteCrabCapture/CaptureEngine.swift`（启动/回前台自动拨；`setPreferredComputer` 改为先拨）

**Interfaces:**
- Consumes: `connect(toComputer:)`、`pairingStore.current`。
- Produces: 行点击 → `connect(toComputer:)`；启动 → 若 `current` 存在则拨它。

- [ ] **Step 1: 行点击**

```swift
// ComputerPickerView：行 Button 的 action
.onTapGesture { engine.connect(toComputer: row.id); dismiss() }
// 保留「正在切换/等待」UI（onboard 的 preferred 等待卡继续用于离线目标）
```

- [ ] **Step 2: 启动/回前台自动拨**

```swift
// CaptureEngine：投递 lastComputer
private func autoDialLastComputerIfAny() {
    guard connection == nil, let id = pairingStore.currentId else { return }
    connect(toComputer: id)
}
// 在 applicationDidBecomeActive 等价回调里调用（现有 handleDidBecomeActive）
```
> 遵守 lesson 156：保活已让监听活着时，**不要**重建监听；这里只拨号。

- [ ] **Step 3: 构建 + 真机（Task 18）**

- [ ] **Step 4: 提交**

```bash
git add RemoteCrabCapture/ComputerPickerView.swift RemoteCrabCapture/CaptureEngine.swift
git commit -m "feat(ios): tap a computer to dial it; auto-dial the last computer on launch"
```

---

## Task 13: iOS —— 逐行删除 + 确认 + `forgetComputer`

**Files:**
- Modify: `RemoteCrabCapture/ComputerPickerView.swift`
- Modify: `RemoteCrabCapture/CaptureEngine.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerRosterTests.swift`（已覆盖 store 层）

**Interfaces:**
- Produces: `func forgetComputer(id: String)`（断开若 owner + `pairingStore.forget` + 清缓存 + refresh）。

- [ ] **Step 1: `forgetComputer`**

```swift
func forgetComputer(id: String) {
    if ownerMac?.id == id { disconnectCurrentMac() }
    if outboundTarget?.id == id { outboundTarget = nil }
    pairingStore.forget(id: id)          // 已清 paired + seen + preferred + disconnected + current
    forgetComputerAssets(id: id)         // 清图标/缩略图缓存
    refreshPairedMacs()
}
```

- [ ] **Step 2: picker 行加删除 + 确认**

```swift
// 每行：.swipeActions(edge: .trailing) { Button(role: .destructive) { pendingDelete = row } ... }
// .confirmationDialog(Text(IBLocale.Pairing.confirmForget(row.name)), isPresented: ...) {
//     Button(IBLocale.Common.delete, role: .destructive) { engine.forgetComputer(id: row.id) }
// }
```
> 保证删除后行**真的消失**（列表读 `seen`，`forget` 已清 `seen`）——lesson 131 的回归面。

- [ ] **Step 3: 构建 + 真机（Task 18）**

- [ ] **Step 4: 提交**

```bash
git add RemoteCrabCapture/ComputerPickerView.swift RemoteCrabCapture/CaptureEngine.swift \
        RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift
git commit -m "feat(ios): per-row forget with confirmation; removed computers never reconnect on their own"
```

---

## Task 14: iOS —— 候选地址抽象（跨网第一步，不实现中继）

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/ComputerAddress.swift`
- Modify: `RemoteCrabCapture/CaptureEngine.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerAddressTests.swift`（新）

**Interfaces:**
- Produces: `enum ComputerAddress: Sendable, Equatable { case bonjour(NWEndpoint); case host(String, UInt16) }` 与 `func candidates(for id:) -> [ComputerAddress]`（Bonjour 优先，其次最近成功 IP）。

- [ ] **Step 1: 纯类型 + 排序测试**

```swift
func testBonjourBeforeRememberedIP() {
    let out = ComputerAddress.ordered(bonjour: [.host("x.local", 8766)],
                                      remembered: [.host("192.168.1.9", 8766)])
    XCTAssertEqual(out.first, .host("x.local", 8766))
}
```

- [ ] **Step 2: 实现**（本迭代只做「按序试」，`connect(toComputer:)` 遍历 candidates，失败换下一个）

- [ ] **Step 3: 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/Networking/ComputerAddress.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/ComputerAddressTests.swift \
        RemoteCrabCapture/CaptureEngine.swift
git commit -m "feat(core): candidate-address abstraction (bonjour first, remembered IP next)"
```

---

## Task 15: Windows —— `rc-protocol` 登记 `PhoneHello = 0x27` + unknown-kind guard

**Files:**
- Modify: `windows/crates/rc-protocol/src/wire.rs`（或 Actual 常量文件；以现有 `ClientProof` 为准）
- Test: `windows/crates/rc-protocol/tests/wire_keys.rs` 或 `wire.rs` 内 `#[cfg(test)]`

- [ ] **Step 1: 写失败测试**

```rust
#[test]
fn phone_hello_is_0x27_and_does_not_fall_through_to_video() {
    assert_eq!(Kind::from_u8_or_video(0x27), Kind::PhoneHello);
    assert_eq!(Kind::from_u8_or_video(0x25), Kind::RequestKeyframe);
    // 未知 kind 不得变成 Video（lesson 152）
    assert!(matches!(Kind::from_u8_or_video(0xEE), Kind::Unknown));
}
```

- [ ] **Step 2: 跑确认失败** → `cd windows && cargo test -p rc-protocol phone_hello` FAIL

- [ ] **Step 3: 实现 `Kind::PhoneHello = 0x27` + serde 结构 + 解析**

```rust
// 结构镜像 Swift IBPhoneHello（字段名逐字一致）
#[derive(Serialize, Deserialize, ...)]
pub struct PhoneHello {
    pub phone_id: String,   // serde rename "phoneId"
    pub phone_name: String, // "phoneName"
    pub target_pc_id: String, // "targetPcId"
    pub app_version: String,  // "appVersion"
    #[serde(default)] pub nonce: Option<String>,
    #[serde(default)] pub capabilities: Option<Vec<String>>,
}
```

- [ ] **Step 4: 跑 + `cargo build --workspace` + clippy**

Run: `cd windows && cargo test -p rc-protocol && cargo clippy --workspace --all-targets -- -D warnings`
Expected: 全绿

- [ ] **Step 5: 提交**

```bash
git add windows/crates/rc-protocol/
git commit -m "feat(windows): register PhoneHello (0x27) in rc-protocol with unknown-kind guard"
```

---

## Task 16: Windows —— 交接文档（§8.3 四项 + 数字）

**Files:**
- Create: `docs/HANDOFF-WINDOWS-PHONE-INITIATED.md`

内容（每条带可复现命令/数字）：
1. `spawn_knock_listener`（`rc-app/src/main.rs:452`）改成读第一帧分辨 hello/knock；现有两个守卫为数据路径重设计。
2. `rc-net` 服务端握手入口（发 `clientHello`、读 `sessionReply`、`peer_auth`），token 按 phoneId 查（迁移 `PeerTokenIndex` 等价物）。
3. 去自动重连（仅对 `supportsPhoneInitiated` 手机）；保留手动 + 敲门回拨（`connect_bound` 已有）。
4. **VPN 缺口**：`057e1c6` 只钉出站；accepted socket 回程要补 `IP_UNICAST_IF`（或按接收接口绑定），给 `Find-NetRoute` + 假手机的验收步骤与预期数字。
- 写规矩：带数字、`git fetch` 先、写完即提交推送。

- [ ] **Step 1: 写文档**
- [ ] **Step 2: 提交**

```bash
git add docs/HANDOFF-WINDOWS-PHONE-INITIATED.md
git commit -m "docs(windows): handoff for phone-initiated connections + accepted-socket VPN pin"
```

---

## Task 17: 真机 e2e —— 多电脑切换 / 删除 / 旧接收端兼容

**Files:**
- Modify: `scripts/e2e-current-computer.sh`（扩展）
- Modify: `scripts/e2e-device.sh`（可选加 marker）

**Prereqs:** iPhone 14 解锁 + 常亮；Mac 辅助功能已授权；无模拟器广播 `_remotecrab._tcp`。

- [ ] **Step 1: 扩展脚本，加三组断言**

1. **点一下切换 <2s、无再确认、无 busy 锁死**：用 `REMOTECRAB_E2E_MAC_ID` 让同一台 Mac 以两个 id 轮换，模拟 A/B 两台已配对电脑；手机用 `REMOTECRAB_E2E_PICK_ONLINE` 依次拨 A、B；断言 `sessionReply: accepted` 的时间差 < 2s，且没有 `busy`。
2. **删除后不再连**：删除当前电脑 → 断言它不再出现在 picker，且其（旧接收端）拨入走 `pending`（需重新审批），不再自动接受。
3. **旧接收端兼容**：把 Mac 以一个「不发 `IBPhoneHello`」的构建（或直接用 `rc-phone-sim` 的 legacy 模式）运行；断言手机走回退入站路径并连上。

- [ ] **Step 2: 跑（真机）**

Run: `./scripts/e2e-current-computer.sh`
Expected: 全绿；marker 带时间戳（<2s）与原文。

- [ ] **Step 3: 提交**

```bash
git add scripts/e2e-current-computer.sh scripts/e2e-device.sh
git commit -m "test(e2e): multi-computer tap-switch <2s, delete, legacy-receiver fallback"
```

---

## Self-Review

**Spec coverage:**
- §3 角色反转+组合X → Task 2/7/8/11。
- §4 时序（首配/重连/拒绝/旧接收端回退）→ Task 8/11。
- §5 协议+迁移 → Task 2/6/15。
- §6 兼容矩阵（能力协商）→ Task 6/9。
- §7 current 退役/取消按名合并/删除 → Task 3/4/5/13。
- §8 各端改动 → Task 7-13（Mac/iOS）、15/16（Windows）。
- §9 安全 → 由 Task 8 复用 peer-auth 保证；Task 3 的 `userInitiatedStillNeedsTokenForAccept` 钉住。
- §10 失败回退 → Task 11（回退入站）、Task 8（busy 拒绝）。
- §11 A → Task 1；B → Task 5。
- §12 跨网抽象 → Task 14（中继明确不做）。
- §14 测试 → 各 Task 内 + Task 17。

**Placeholder scan:** 无 TBD/TODO；每个 code step 有实际代码。网络/UI task 标注了「读相邻代码」的位置（如 `sendClientHello` 的 token=nil 分支），这是实现细节而非占位。

**Type consistency:** `IBPhoneHello` 字段名（phoneId/phoneName/targetPcId/appVersion/nonce/capabilities）在 Task 2/6/8/11/15 一致；`PeerTokenIndex.token(phoneId:name:)`、`decide(...,userInitiated:)`、`connect(toComputer:)`、`forgetComputer(id:)`、`handleInboundData(_:)`、`onInbound` 全程同名。

**已知依赖顺序：** Task 7 依赖 Task 8 的 `handleInboundData`（先用桩使其可编译）；Task 11 依赖 Task 2/3/6；Task 12/13 依赖 Task 11；Task 17 依赖 8/11/12/13。

---

## Execution Handoff

保存到 `docs/superpowers/plans/2026-10-08-phone-initiated-connection-v2.md` 后，选择执行方式：

1. **Subagent-Driven（推荐）** — 每个 Task 派新 subagent，Task 间 review。
2. **Inline Execution** — 本 session 用 executing-plans 批量执行 + 检查点。
