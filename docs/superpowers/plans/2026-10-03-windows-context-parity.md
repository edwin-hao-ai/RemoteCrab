# Windows 情景模式对齐 + ⊞ 键 + 套件格式 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Windows 上的情景模式不再为空且没有错按钮；加入 ⊞ 键行；把套件格式做成可版本化、可标注来源、可本地装载。

**Architecture:** 给 `ContextProfile` 加**可选**字段（`schemaVersion` / `source` / `windowsProcessNames` / `windowsActions`），并给 `ContextProfiles.profile(for:)` 加一个**带默认值的** `platform:` 参数——所以 Mac 的代码路径和 25 个现有测试一字不改。Windows 端**绝不回退**到 Mac 动作（那个回退就是 bug 本身）。新增 `META = 16` 修饰键位，让 ⊞ 组合键能发出去。

**Tech Stack:** Swift 6 / SwiftUI（RemoteCrabCore 共享包 + RemoteCrabCapture iOS）、Rust（windows/ workspace）、XCTest、XCTest(cargo)

**Spec:** `docs/superpowers/specs/2026-10-03-windows-context-parity-design.md`

## Global Constraints

- **不要改 Mac 的行为。** 现有 25 个 `ContextProfilesTests` 必须一字不改全绿。
- **协议只加不改。** 新字段一律可选 / 带默认值；旧数据必须能解码（AGENTS.md 规则 2）。
- **不做死按钮。** Windows 上不支持的动作**不显示**，而不是显示一个点了没反应的（AGENTS.md 规则 1）。
- **无 emoji，用 SF Symbols。** 新文案必须同时进 `Localizable.xcstrings` 的 en + zh-Hans。
- **只写有据可依的 Windows 按键。** 没依据的不写，列进 `docs/WINDOWS-GAPS-2026-10-03.md` 的勾选清单。
- 每个 task 结束提交一次。

---

## File Structure

| 文件 | 责任 |
|---|---|
| `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift` | `TouchEvent.Modifier` 位掩码（加 `meta = 16`） |
| `RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift` | 纯数据 + 纯匹配/解析（**不碰磁盘**） |
| `RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfileStore.swift` | **新建**。本地文件装载 + 校验 + 合并，唯一碰磁盘的地方 |
| `RemoteCrabCore/Sources/RemoteCrabCore/Components/IBModifierBar.swift` | 修饰键 UI 枚举 + 按平台筛选/替换 |
| `RemoteCrabCapture/KeyboardScreen.swift` | 修饰键行（硬编码四个）+ `modifierMask` |
| `RemoteCrabCapture/ContextSheetView.swift` | 渲染：按平台取系统动作、来源展示、文案 |
| `RemoteCrabCore/Resources/Localizable.xcstrings` | 新文案 en + zh-Hans |
| `windows/crates/rc-protocol/src/events.rs` | `Modifier::META` |
| `windows/crates/rc-input/src/keymap.rs` | `META` → `LWIN` |
| `RemoteCrabCore/Tests/.../ContextProfilesTests.swift` | 扩充（Mac 现有测试不动） |
| `RemoteCrabCore/Tests/.../ContextProfileFormatTests.swift` | **新建**。旧格式迁移、优先级、校验 |

---

## Task 1: META 修饰键位（协议，两端）

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift:24-31`
- Modify: `windows/crates/rc-protocol/src/events.rs:91-98`
- Modify: `windows/crates/rc-input/src/keymap.rs:145-158`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/` (new file `MetaModifierTests.swift`)
- Test: `windows/crates/rc-input/src/keymap.rs` (inline `mod tests`)

**Interfaces:**
- Produces: `TouchEvent.Modifier.meta` (rawValue `16`), `rc_protocol::Modifier::META: u8 = 16`

- [ ] **Step 1: 写失败的 Swift 测试**

新建 `RemoteCrabCore/Tests/RemoteCrabCoreTests/MetaModifierTests.swift`：

```swift
import XCTest
@testable import RemoteCrabCore

final class MetaModifierTests: XCTestCase {
    func testMetaBitIsSixteen() {
        XCTAssertEqual(TouchEvent.Modifier.meta.rawValue, 16)
    }

    /// 旧数据不含 16 这一位，解码必须仍然成功（规则 2）。
    func testMetaBitRoundTripsThroughTheWire() throws {
        let event = IBModifier(phase: .move, x: 0, y: 0, dx: 1, dy: 0,
                               modifiers: TouchEvent.Modifier.meta.rawValue)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(IBModifier.self, from: data).modifiers, 16)
    }

    /// meta 不得与既有四位重叠——重叠会让 Windows 端静默把 Win 当成 Ctrl。
    func testMetaDoesNotOverlapExistingBits() {
        let existing: [TouchEvent.Modifier] = [.shift, .control, .option, .command]
        for m in existing {
            XCTAssertEqual(m.rawValue & TouchEvent.Modifier.meta.rawValue, 0, "\(m)")
        }
    }
}
```

位掩码枚举是 `TouchEvent.Modifier`（`IBEvents.swift:25-31`），不是 `IBModifier`——那个名字不存在。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter MetaModifierTests`
Expected: FAIL — `cannot find 'meta' in 'Modifier'`

- [ ] **Step 3: Swift 实现**

`IBEvents.swift` 的枚举改为：

```swift
public enum Modifier: UInt8, Codable, Sendable {
    case none    = 0
    case shift   = 1
    case control = 2
    case option  = 4
    case command = 8
    /// The Windows / ⊞ key. Bit 16 was free in the original wire mask.
    /// The Mac receiver has no Win key and `CGEventInjector.eventFlags`
    /// ignores unknown bits, so a stray 16 is inert there.
    case meta    = 16
}
```

- [ ] **Step 4: Rust 实现**

`events.rs`：

```rust
    pub const COMMAND: u8 = 8;
    /// The Windows key (⊞). Bit 16 — the original mask only defined 1/2/4/8.
    pub const META: u8 = 16;
```

`keymap.rs` 的 `modifier_vks`，在 `shift` 之后、`out` 返回之前加：

```rust
    // ⊞ is its own key on Windows; it must NOT collapse into Ctrl the way
    // COMMAND does, or ⊞E / ⊞R / ⊞L are unreachable from the phone.
    if modifiers & Modifier::META != 0 {
        out.push(vk::LWIN);
    }
```

- [ ] **Step 5: 跑两侧测试确认通过**

Run: `cd RemoteCrabCore && swift test --filter MetaModifierTests`
Expected: PASS

Run: `cd windows && cargo test -p rc-input -p rc-protocol`
Expected: PASS

- [ ] **Step 6: 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/MetaModifierTests.swift \
        windows/crates/rc-protocol/src/events.rs windows/crates/rc-input/src/keymap.rs
git commit -m "feat(wire): a META modifier bit, so ⊞ chords are expressible"
```

---

## Task 2: ContextProfile 数据模型（可版本化 + 可标注来源）

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift:12-50`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfileFormatTests.swift`（新建）

**Interfaces:**
- Produces: `ProfileSource` (`.builtin` / `.userFile` / `.remote`)
- Produces: `ContextProfile.schemaVersion: Int`, `.source: ProfileSource`, `.windowsProcessNames: [String]?`, `.windowsActions: [ContextAction]?`
- Produces: `ContextProfile.currentSchemaVersion == 1`

- [ ] **Step 1: 写失败的测试**

新建 `ContextProfileFormatTests.swift`：

```swift
import XCTest
@testable import RemoteCrabCore

final class ContextProfileFormatTests: XCTestCase {

    /// 规则 2：旧格式必须能加载，且一个字段都不能丢。形状取自新增
    /// schemaVersion / source 之前的 ContextProfile。
    func testLoadsThePreviousFormatWithNothingLost() throws {
        let legacy = """
        {
          "id": "demo",
          "title": "Demo",
          "bundleIDs": ["com.example.app"],
          "actions": [
            {"key": {"label": "Go", "symbol": "arrow.right", "keycode": 123, "modifiers": 0}}
          ]
        }
        """.data(using: .utf8)!

        let p = try JSONDecoder().decode(ContextProfile.self, from: legacy)
        XCTAssertEqual(p.id, "demo")
        XCTAssertEqual(p.title, "Demo")
        XCTAssertEqual(p.bundleIDs, ["com.example.app"])
        XCTAssertEqual(p.actions.count, 1)
        // 新字段全部取默认值，而不是让解码失败。
        XCTAssertEqual(p.schemaVersion, ContextProfile.currentSchemaVersion)
        XCTAssertEqual(p.source, .builtin)
        XCTAssertNil(p.windowsProcessNames)
        XCTAssertNil(p.windowsActions)
    }

    func testBuiltinProfilesAreVersionedAndSourced() {
        for p in ContextProfiles.all {
            XCTAssertEqual(p.schemaVersion, ContextProfile.currentSchemaVersion, p.id)
            XCTAssertEqual(p.source, .builtin, p.id)
        }
    }

    /// 往返相等——现有 testProfileCodableRoundTrip 依赖这一点。
    func testRoundTripKeepsEveryNewField() throws {
        var p = ContextProfiles.console
        let withWindows = ContextProfile(
            schemaVersion: p.schemaVersion, id: p.id, title: p.title,
            source: .userFile, bundleIDs: p.bundleIDs, actions: p.actions,
            windowsProcessNames: ["WindowsTerminal"],
            windowsActions: [.key(label: "Stop", symbol: "stop.fill", keycode: 53)])
        let data = try JSONEncoder().encode(withWindows)
        let back = try JSONDecoder().decode(ContextProfile.self, from: data)
        XCTAssertEqual(back, withWindows)
        XCTAssertEqual(back.source, .userFile)
        XCTAssertEqual(back.windowsProcessNames, ["WindowsTerminal"])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter ContextProfileFormatTests`
Expected: FAIL — `schemaVersion` 不存在 / 解码抛错

- [ ] **Step 3: 实现**

在 `ContextProfiles.swift` 中，`ContextProfile` 之前加：

```swift
/// Where a profile came from. A profile is executable input — it replays
/// real key events into a machine that already holds Accessibility
/// permission — so its origin must be visible and disableable, not
/// implied. `remote` is declared now and populated only once a signed
/// feed exists; nothing loads it yet.
public enum ProfileSource: String, Codable, Sendable, Equatable {
    case builtin
    case userFile
    case remote
}
```

`ContextProfile` 改为：

```swift
public struct ContextProfile: Codable, Equatable, Sendable {
    /// Bump when the on-disk shape changes incompatibly. A file claiming a
    /// newer version is rejected with a readable reason, never half-read.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let title: String
    public let source: ProfileSource
    /// macOS bundle identifiers this profile matches, first-match-wins.
    public let bundleIDs: [String]
    public let actions: [ContextAction]
    /// Windows executable stems (no `.exe`, case-insensitive match).
    /// The name is deliberately NOT generic: `bundleIDs` cannot be
    /// renamed (rule 2), so the Windows counterpart is additive.
    public let windowsProcessNames: [String]?
    /// Windows action set. `nil` means "this suite has no verified
    /// Windows mapping" and MUST render as an empty app section — it
    /// must never fall back to `actions`, because those are
    /// Mac-menu-verified shortcuts that are wrong on Windows.
    public let windowsActions: [ContextAction]?

    public init(schemaVersion: Int = ContextProfile.currentSchemaVersion,
                id: String, title: String, source: ProfileSource = .builtin,
                bundleIDs: [String] = [], actions: [ContextAction],
                windowsProcessNames: [String]? = nil,
                windowsActions: [ContextAction]? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.source = source
        self.bundleIDs = bundleIDs
        self.actions = actions
        self.windowsProcessNames = windowsProcessNames
        self.windowsActions = windowsActions
    }

    /// Hand-written so a file written before `schemaVersion` / `source`
    /// existed still decodes. Synthesized Codable would throw on the
    /// missing non-optional `Int`, and every loader in this project
    /// swallows decode errors — which is how a missing default silently
    /// wipes user data (rule 2).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        actions = try c.decodeIfPresent([ContextAction].self, forKey: .actions) ?? []
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        source = try c.decodeIfPresent(ProfileSource.self, forKey: .source) ?? .builtin
        windowsProcessNames = try c.decodeIfPresent([String].self, forKey: .windowsProcessNames)
        windowsActions = try c.decodeIfPresent([ContextAction].self, forKey: .windowsActions)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd RemoteCrabCore && swift test --filter ContextProfiles`
Expected: PASS（含原有 25 个测试，它们一个字都没改）

- [ ] **Step 5: 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfileFormatTests.swift
git commit -m "feat(profiles): version and source every suite, add the Windows slots"
```

---

## Task 3: 按平台匹配 + 优先级 + 绝不回退

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift:363-366`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfilesTests.swift`（**追加**，不改动已有测试）

**Interfaces:**
- Produces: `ContextProfiles.merged(_ extra: [ContextProfile]) -> [ContextProfile]`（纯函数）
- Produces: `ContextProfiles.profile(for:platform:in:)`，后两个参数都有默认值

- [ ] **Step 1: 写失败的测试**（追加到 `ContextProfilesTests.swift` 末尾）

```swift
    // MARK: - Windows: platform-aware matching

    private func win(_ name: String) -> IBAppInfo {
        IBAppInfo(id: "pid:1234", name: name, pid: 1234, isActive: true, iconPNG: nil)
    }

    func testWindowsMatchesOnProcessNameNotPid() {
        let p = ContextProfiles.profile(for: win("WindowsTerminal"), platform: .windows)
        XCTAssertEqual(p.id, "agent")
    }

    func testWindowsProcessNameMatchIsCaseInsensitiveAndStripsExe() {
        for spelling in ["WindowsTerminal", "windowsterminal", "WINDOWSTERMINAL.EXE"] {
            XCTAssertEqual(
                ContextProfiles.profile(for: win(spelling), platform: .windows).id,
                "agent", spelling)
        }
    }

    /// Windows 的 id 是字面量 "pid:N"，每次启动都变，绝不能参与匹配。
    func testWindowsNeverMatchesOnTheVolatilePid() {
        XCTAssertEqual(ContextProfiles.profile(for: win("zzz-unknown"), platform: .windows).id,
                       "console")
    }

    /// 没有 Windows 动作 = 应用区不显示，绝不显示 Mac 的按键。
    func testWindowsNeverFallsBackToMacActions() {
        let p = ContextProfiles.profile(for: win("com.apple.iWork.Keynote"), platform: .windows)
        XCTAssertNil(p.windowsActions, "a Mac-only suite must have no Windows action set")
    }

    func testConsoleSystemActionsHaveNoBrightnessOnWindows() {
        let commands = ContextProfiles.systemActions(for: .windows).compactMap { action -> IBSystemCommand.Command? in
            if case .system(_, _, let c) = action { return c }
            return nil
        }
        XCTAssertFalse(commands.contains(.brightnessUp))
        XCTAssertFalse(commands.contains(.brightnessDown))
        XCTAssertTrue(commands.contains(.volumeUp))
    }

    func testMacSystemActionsAreUnchanged() {
        // Mac 侧的排列顺序有测试钉住（testConsolePairsRelatedActionsInRows）。
        XCTAssertEqual(ContextProfiles.systemActions(for: .mac),
                       ContextProfiles.console.gridActions)
    }

    // MARK: - Precedence

    func testUserFileOverridesBuiltinById() {
        let override = ContextProfile(id: "agent", title: "My Agent",
                                      actions: [.voiceHero(label: "T", symbol: "waveform")])
        let merged = ContextProfiles.merged([override])
        XCTAssertEqual(merged.first { $0.id == "agent" }?.title, "My Agent")
        XCTAssertEqual(merged.filter { $0.id == "agent" }.count, 1)
    }

    func testUserFileOutranksRemoteWhichOutranksBuiltin() {
        let b = ContextProfile(id: "x", title: "builtin")
        let r = ContextProfile(id: "x", title: "remote", source: .remote)
        let u = ContextProfile(id: "x", title: "user", source: .userFile)
        XCTAssertEqual(ContextProfiles.merged([r, u]).first { $0.id == "x" }?.title, "user")
        XCTAssertEqual(ContextProfiles.merged([r]).first { $0.id == "x" }?.title, "remote")
        XCTAssertEqual(ContextProfiles.merged([]).first { $0.id == "x" }?.title, "builtin")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter ContextProfilesTests`
Expected: FAIL — `platform:` / `merged` / `systemActions` 不存在

- [ ] **Step 3: 实现**

把 `ContextProfiles` 末尾的 `profile(for:)` 换成：

```swift
    /// Order matters: a later tier REPLACES an earlier one by `id`. The
    /// old first-match-wins lookup meant a user-installed suite could
    /// never take effect — i.e. installing a plugin did nothing.
    public static func merged(_ extra: [ContextProfile] = []) -> [ContextProfile] {
        var out: [ContextProfile] = all
        for tier in [ProfileSource.userFile, .remote] {
            for profile in extra where profile.source == tier && profile.source == tier {
                out.removeAll { $0.id == profile.id }
                out.append(profile)
            }
        }
        return out
    }

    /// `platform` and `in` both default, so every existing Mac call site
    /// and test compiles and behaves unchanged.
    public static func profile(for app: IBAppInfo?,
                               platform: IBModifierBar.PeerPlatform = .mac,
                               in registry: [ContextProfile] = all) -> ContextProfile {
        guard let app else { return console }
        if platform == .windows {
            let key = normalizedProcessName(app.name)
            return registry.first { $0.windowsProcessNames?.contains(where: {
                normalizedProcessName($0) == key
            }) == true } ?? console
        }
        return registry.first { $0.bundleIDs.contains(app.id) } ?? console
    }

    /// Windows executable stems, compared without case or a trailing
    /// `.exe` — `rc-os`'s `process_name` already trims it, but a
    /// hand-written profile file may not.
    static func normalizedProcessName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasSuffix(".exe") { s = String(s.dropLast(4)) }
        return s.lowercased()
    }

    /// The system section is ALWAYS shown (spec §4.5), so it is the one
    /// place a wrong entry hurts a user who never asked for it.
    public static func systemActions(for platform: IBModifierBar.PeerPlatform) -> [ContextAction] {
        guard platform == .windows else { return console.gridActions }
        return windowsSystemActions
    }
```

并新增（放在 `console` 之后）：

```swift
    /// Windows system controls. Volume and media use VK_* and work;
    /// brightness is deliberately ABSENT because `system_keys.rs` returns
    /// false for it (a dead button is worse than no button — rule 1).
    /// Lock is ⊞L, because ⌃⌘Q collapses to Ctrl+Q, which quits the app.
    public static let windowsSystemActions: [ContextAction] = [
        .voiceHero(label: "Talk to Computer", symbol: "waveform"),
        .system(label: "Volume Up", symbol: "speaker.plus.fill", command: .volumeUp),
        .system(label: "Volume Down", symbol: "speaker.minus.fill", command: .volumeDown),
        .system(label: "Mute", symbol: "speaker.slash.fill", command: .volumeMute),
        .system(label: "Play / Pause", symbol: "playpause.fill", command: .mediaPlayPause),
        .key(label: "Lock Screen", symbol: "lock.fill", keycode: 37,
             modifiers: TouchEvent.Modifier.meta.rawValue),
        .system(label: "Browser", symbol: "safari.fill", command: .launchApp),
        .key(label: "Show Desktop", symbol: "macwindow.on.rectangle", keycode: 53,
             modifiers: TouchEvent.Modifier.meta.rawValue | 4),   // ⊞⌥D
    ]
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd RemoteCrabCore && swift test --filter ContextProfiles`
Expected: PASS（原有 25 个 + 新增）

- [ ] **Step 5: 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfilesTests.swift
git commit -m "feat(profiles): match on the peer platform, and never borrow Mac's keys"
```

---

## Task 4: 修四个坏按钮（ContextSheetView）

**Files:**
- Modify: `RemoteCrabCapture/ContextSheetView.swift:14-16, 42, 139-152`
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift`（系统动作带参数）
- Test: `ContextProfileFormatTests.swift`（追加）

- [ ] **Step 1: 写失败的测试**

`systemActions` 目前无法表达「标签与参数成对」，所以先把 launch 目标放进动作本身。在 `ContextProfileFormatTests.swift` 追加：

```swift
    /// 「标签写 Safari、参数传 bing」就是这个不变量被打破的样子。
    func testSystemActionCarriesItsOwnLaunchArgument() throws {
        let win = ContextProfiles.systemActions(for: .windows)
        let mac = ContextProfiles.systemActions(for: .mac)
        for (label, actions) in [("windows", win), ("mac", mac)] {
            for action in actions {
                guard case .system(let l, _, let cmd) = action,
                      cmd == .launchApp else { continue }
                XCTAssertFalse(l.contains("Safari"), "\(label): label/argument mismatch")
            }
        }
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter testSystemActionCarriesItsOwnLaunchArgument`
Expected: FAIL — `systemActions(for:)` 返回的 `.system` 无法带 URL

- [ ] **Step 3: 实现**

`ContextAction` 加一个带参数的系统动作（**新增 case，不改旧的**）：

```swift
public enum ContextAction: Codable, Equatable, Sendable {
    case key(label: String, symbol: String, keycode: UInt16, modifiers: UInt8 = 0)
    case system(label: String, symbol: String, command: IBSystemCommand.Command)
    /// `.system` plus the argument it needs. Added because the launch
    /// target was decided in the *view* while the label lived in the
    /// data, which is how a button ended up labelled "Safari" and
    /// opening Bing.
    case systemArg(label: String, symbol: String, command: IBSystemCommand.Command, argument: String)
    case voiceHero(label: String, symbol: String)
}
```

`mac` 的系统动作里把 Safari 那条改成：

```swift
.systemArg(label: "Safari", symbol: "safari.fill", command: .launchApp,
           argument: "com.apple.Safari")
```

Windows 那条改成：

```swift
.systemArg(label: "Browser", symbol: "safari.fill", command: .launchApp,
           argument: "https://www.bing.com")
```

`ContextSheetView.swift` 三处：

```swift
    private var profile: ContextProfile {
        ContextProfiles.profile(for: engine.frontmostMacApp,
                                platform: engine.peerPlatform)
    }

    private var systemActions: [ContextAction] {
        ContextProfiles.systemActions(for: engine.peerPlatform)
    }
```

第 42 行 `grid(ContextProfiles.console.gridActions)` → `grid(systemActions)`

139-152 的 `case .system` 分支改为（删掉 bing.com 硬编码）：

```swift
        case .system(let label, let symbol, let command):
            contextButton(label: label, symbol: symbol) {
                engine.sendSystemCommand(IBSystemCommand(command: command, argument: nil))
            }
        case .systemArg(let label, let symbol, let command, let argument):
            contextButton(label: label, symbol: symbol) {
                engine.sendSystemCommand(IBSystemCommand(command: command, argument: argument))
            }
```

`CaptureEngine` 加：

```swift
    /// Which OS the session peer runs — drives labels and which action
    /// set the context sheet shows. From `clientHello.platform`.
    var peerPlatform: IBModifierBar.PeerPlatform {
        IBModifierBar.PeerPlatform(connectedPlatform)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd RemoteCrabCore && swift test --filter ContextProfile`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add RemoteCrabCapture/ContextSheetView.swift RemoteCrabCapture/CaptureEngine.swift \
        RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfileFormatTests.swift
git commit -m "fix(context): four buttons that lied on Windows — dead, wrong, or destructive"
```

---

## Task 5: ⊞ 键行

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Components/IBModifierBar.swift:13-50, 90`
- Modify: `RemoteCrabCapture/KeyboardScreen.swift:33-40, 241-244, 395-402`
- Test: `ContextProfilesTests.swift`（追加）

**Interfaces:**
- Produces: `IBModifierBar.Modifier.meta`，`windowsLabel` → `"⊞"`，`keycode` → `55`
- Produces: `IBModifierBar.visibleModifiers(for:)` — Mac 四个、Windows 四个（⊞ 顶替 ⌘）

- [ ] **Step 1: 写失败的测试**

```swift
    // MARK: - ⊞ row

    func testMacModifierRowIsUnchanged() {
        XCTAssertEqual(IBModifierBar.visibleModifiers(for: .mac),
                       [.control, .option, .command, .shift])
    }

    /// .control 和 .command 今天都显示 "Ctrl"（两个同名按钮），
    /// 所以 Windows 上 ⊞ 必须**顶替** ⌘，而不是追加成第五个。
    func testWindowsModifierRowShowsWinInsteadOfCommand() {
        let row = IBModifierBar.visibleModifiers(for: .windows)
        XCTAssertTrue(row.contains(.meta))
        XCTAssertFalse(row.contains(.command), "⌘ would render a second 'Ctrl'")
        XCTAssertEqual(row.count, 4)
    }

    func testWindowsLabelsAreDistinct() {
        let labels = IBModifierBar.visibleModifiers(for: .windows).map(\.windowsLabel)
        XCTAssertEqual(Set(labels).count, labels.count, "duplicate labels: \(labels)")
    }

    func testMetaKeycodeIsTheLeftCommandKeyWindowsMapsToWin() {
        XCTAssertEqual(IBModifierBar.Modifier.meta.keycode, 55)   // kVK_Command
        XCTAssertEqual(IBModifierBar.Modifier.meta.rawValue, "⊞")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter "testMacModifierRowIsUnchanged|testMetaKeycode"`
Expected: FAIL — `visibleModifiers` 不存在 / `meta` 不存在

- [ ] **Step 3: 实现**

`IBModifierBar.swift` 的 UI 枚举：

```swift
        case command = "⌘"
        case shift   = "⇧"
        /// ⊞ — Windows only. Shown INSTEAD of ⌘, because ⌘ and ⌃ both
        /// render as the string "Ctrl" and two identically-labelled
        /// buttons is worse than one honest key.
        case meta    = "⊞"
```

`sfSymbol` 加 `case .meta: return "command"`；`keycode` 加 `case .meta: return 55`；
`windowsLabel` 加 `case .meta: return "⊞"`。

加：

```swift
    /// Mac: ⌃ ⌥ ⌘ ⇧. Windows: Ctrl Alt ⊞ Shift.
    public static func visibleModifiers(for platform: PeerPlatform) -> [Modifier] {
        platform == .windows ? [.control, .option, .meta, .shift] : allCases
    }
```

第 90 行改为 `ForEach(Self.visibleModifiers(for: platform), id: \.self)`。

`KeyboardScreen.swift:33-40` 的 `modifierMask` 加：

```swift
        if modifiers.contains(.meta) { mask |= 16 }
```

241-244 改为：

```swift
                    for m in IBModifierBar.visibleModifiers(for: engine.peerPlatform) {
                        modifierKey(m)
                    }
```

395-402 的 `switch` 加 `case .meta: return "Windows"`（`switch` 是穷尽的，漏了会编译失败——这是好事）。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd RemoteCrabCore && swift test --filter ContextProfilesTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/Components/IBModifierBar.swift \
        RemoteCrabCapture/KeyboardScreen.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfilesTests.swift
git commit -m "feat(keyboard): a ⊞ row for Windows, replacing the duplicate Ctrl"
```

---

## Task 6: Windows app 名单 + 有据可依的 Windows 动作

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift`
- Test: `ContextProfilesTests.swift`（追加）

**Interfaces:**
- Consumes: Task 3 的匹配、Task 2 的字段
- Produces: 各套件的 `windowsProcessNames` / `windowsActions`

**只写能查到的**（规则：没有依据的**不写**，列进交接清单）：

- [ ] **Step 1: 写失败的测试**

```swift
    func testAgentSuiteMatchesWindowsTerminal() {
        for exe in ["WindowsTerminal", "powershell", "pwsh", "cmd"] {
            XCTAssertEqual(
                ContextProfiles.profile(for: win(exe), platform: .windows).id, "agent", exe)
        }
    }

    func testEditorSuiteMatchesWindowsEditors() {
        for exe in ["Code", "devenv", "cursor", "code"] {
            XCTAssertEqual(
                ContextProfiles.profile(for: win(exe), platform: .windows).id, "editor", exe)
        }
    }

    func testBrowserSuiteMatchesWindowsBrowsers() {
        for exe in ["chrome", "msedge", "firefox", "brave"] {
            XCTAssertEqual(
                ContextProfiles.profile(for: win(exe), platform: .windows).id, "browser", exe)
        }
    }

    /// 每个有 Windows 动作的套件，行数必须是偶数（两列网格）。
    func testWindowsActionSetsHaveEvenCounts() {
        for p in ContextProfiles.all {
            guard let w = p.windowsActions else { continue }
            let grid = w.filter { if case .voiceHero = $0 { return false }; return true }
            XCTAssertEqual(grid.count % 2, 0,
                           "\(p.id) has \(grid.count) Windows grid actions")
        }
    }

    /// ⌃C 与 ⌘C 在 Windows 上塌缩成同一个 Ctrl——这是「中断」按钮
    /// 变成「复制」按钮的根因。同一套件里不允许出现这种重复。
    func testNoTwoWindowsActionsCollapseToTheSameKeystroke() {
        for p in ContextProfiles.all {
            guard let w = p.windowsActions else { continue }
            var seen: Set<String> = []
            for action in w {
                guard case .key(_, _, let kc, let mods) = action else { continue }
                // Windows: command|control both become Ctrl.
                let ctrl = (mods & 8) != 0 || (mods & 2) != 0
                let norm = "\(kc):\(ctrl ? "ctrl" : "-"):\(mods & 4):\(mods & 1):\(mods & 16)"
                XCTAssertTrue(seen.insert(norm).inserted,
                              "\(p.id): two actions collapse to \(norm) on Windows")
            }
        }
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter "testAgentSuiteMatchesWindowsTerminal|testNoTwoWindowsActionsCollapse"`
Expected: FAIL

- [ ] **Step 3: 实现**

在 Mac 套件上追加两个参数。依据：Windows Terminal / VS Code / Chrome 的官方键位表。

```swift
    /// Windows Terminal (and every CLI agent inside it: Claude Code,
    /// Codex CLI, OpenCode, Gemini CLI, Aider, goose). Only keys that
    /// are documented Windows Terminal / CLI-agent behaviour ship —
    /// copy and paste are OMITTED because their Windows Terminal
    /// bindings could not be verified without a machine, and a wrong
    /// button is worse than a missing one.
    public static let agent = ContextProfile(
        id: "agent", title: IBLocale.Context.profileAgent,
        bundleIDs: [
            "com.apple.Terminal", "com.googlecode.iterm2",
            "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        ],
        windowsProcessNames: ["WindowsTerminal", "powershell", "pwsh", "cmd", "conhost"],
        windowsActions: [
            .voiceHero(label: "Talk to Agent", symbol: "waveform"),
            .key(label: "Approve", symbol: "checkmark", keycode: 36),              // Enter
            .key(label: "Stop", symbol: "stop.fill", keycode: 53),                 // Esc
            .key(label: "Interrupt", symbol: "xmark", keycode: 8, modifiers: 2),   // Ctrl+C
            .key(label: "Clear", symbol: "eraser", keycode: 37, modifiers: 2),     // Ctrl+L
        ])
```

> Copy / paste are **deliberately omitted**. Windows Terminal's copy and
> paste chords could not be confirmed from a document on this Mac, and a
> button that copies when it should interrupt is the exact failure this
> whole change exists to remove. They go in the handover checklist.

editor（VS Code 官方键位）：

```swift
        windowsProcessNames: ["Code", "code", "devenv", "cursor", "zed", "notepad++"],
        windowsActions: [
            .voiceHero(label: "Talk to Editor", symbol: "waveform"),
            .key(label: "Command Palette", symbol: "command", keycode: 35, modifiers: 1 | 2), // Ctrl+Shift+P
            .key(label: "Find", symbol: "magnifyingglass", keycode: 3, modifiers: 2),         // Ctrl+F
            .key(label: "Save", symbol: "square.and.arrow.down", keycode: 1, modifiers: 2),  // Ctrl+S
            .key(label: "Terminal", symbol: "terminal", keycode: 50, modifiers: 2),           // Ctrl+`
            .key(label: "Close Editor", symbol: "xmark", keycode: 13, modifiers: 2),           // Ctrl+W
            .key(label: "Quick Open", symbol: "file", keycode: 35, modifiers: 2),              // Ctrl+P
        ])
```

browser（Chrome / Edge / Firefox 通用）：

```swift
        windowsProcessNames: ["chrome", "msedge", "firefox", "brave", "opera"],
        windowsActions: [
            .voiceHero(label: "Talk to Browser", symbol: "waveform"),
            .key(label: "New Tab", symbol: "plus", keycode: 24, modifiers: 2),            // Ctrl+T
            .key(label: "Close Tab", symbol: "xmark", keycode: 23, modifiers: 2),         // Ctrl+W
            .key(label: "Next Tab", symbol: "chevron.right", keycode: 43, modifiers: 2), // Ctrl+Tab
            .key(label: "Previous Tab", symbol: "chevron.left", keycode: 43, modifiers: 1 | 2),
            .key(label: "Reload", symbol: "arrow.clockwise", keycode: 15, modifiers: 2),  // Ctrl+R
            .key(label: "Address Bar", symbol: "magnifyingglass", keycode: 37, modifiers: 2), // Ctrl+L
        ])
```

presentation（PowerPoint）**本轮不做**：`F5` / `Shift+F5` 需要
`keymap.rs` 支持扩展功能键（F1–F12），而这一点在 Mac 上无法验证。一个「能匹配
上却可能发出两个相同按键」的套件，比匹配不上、干净落到 console 更糟。进交接清单。

其余套件（notes / mail / messages / calendar / xcode / text / media / chat /
meeting / image / notebook / finder / ai / opencode）**本轮不加**
`windowsProcessNames`——没有可靠的按键依据。匹配不上的应用落到 `console`
的系统区，这已经是**正确且诚实**的行为。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd RemoteCrabCore && swift test --filter ContextProfiles`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfilesTests.swift
git commit -m "feat(profiles): Windows suites for the apps whose keys are documented"
```

---

## Task 7: 本地装载 + 校验 + 来源展示

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfileStore.swift`
- Modify: `RemoteCrabCapture/CaptureEngine.swift`（持有 store）
- Modify: `RemoteCrabCapture/ContextSheetView.swift`（header 展示来源）
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfileStoreTests.swift`（新建）

**Interfaces:**
- Produces: `ContextProfileStore`，`@Observable`，`merged: [ContextProfile]`、`problems: [Problem]`
- Produces: `ContextProfileStore.Problem { file: String; reason: String }`
- Produces: `static func decode(_ data: Data, from file: String) throws -> ContextProfile`
- Produces: `static func merge(builtin:user:remote:) -> [ContextProfile]`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import RemoteCrabCore

final class ContextProfileStoreTests: XCTestCase {

    private func profileData(_ json: String) throws -> Data { try Data(json.utf8) }

    func testDecodesAValidProfile() throws {
        let json = """
        {"schemaVersion":1,"id":"demo","title":"Demo","bundleIDs":["com.example.app"],
         "actions":[{"voiceHero":{"label":"Talk","symbol":"waveform"}}]}
        """
        let p = try ContextProfileStore.decode(try profileData(json), from: "demo.json")
        XCTAssertEqual(p.id, "demo")
        XCTAssertEqual(p.source, .userFile, "a file we loaded is by definition a user file")
    }

    /// 比我们新的格式必须**拒收**，不能半读。
    func testRejectsANewerSchemaVersionWithAReadableReason() throws {
        let json = """
        {"schemaVersion":9999,"id":"future","title":"Future","bundleIDs":[],"actions":[]}
        """
        XCTAssertThrowsError(try ContextProfileStore.decode(try profileData(json), from: "f.json")) {
            let reason = String(describing: $0).lowercased()
            XCTAssertTrue(reason.contains("9999") && reason.contains("1"),
                          "the error must name both versions, got: \(reason)")
        }
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try ContextProfileStore.decode(Data("{".utf8), from: "bad.json"))
    }

    func testMergeOrderIsUserThenRemoteOverBuiltin() {
        let b = ContextProfile(id: "x", title: "builtin")
        let r = ContextProfile(id: "x", title: "remote", source: .remote)
        let u = ContextProfile(id: "x", title: "user", source: .userFile)
        let merged = ContextProfileStore.merge(builtin: [b], user: [u], remote: [r])
        XCTAssertEqual(merged.filter { $0.id == "x" }.map(\.title), ["user"])
    }

    func testABrokenFileDoesNotDiscardTheGoodOnes() throws {
        let good = try profileData("""
        {"schemaVersion":1,"id":"good","title":"Good","bundleIDs":[],"actions":[]}
        """)
        let loaded = ContextProfileStore.load([("good.json", good), ("bad.json", Data("{".utf8))])
        XCTAssertEqual(loaded.profiles.map(\.id), ["good"])
        XCTAssertEqual(loaded.problems.count, 1)
        XCTAssertEqual(loaded.problems[0].file, "bad.json")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd RemoteCrabCore && swift test --filter ContextProfileStoreTests`
Expected: FAIL — `ContextProfileStore` 不存在

- [ ] **Step 3: 实现**

新建 `ContextProfileStore.swift`：

```swift
import Foundation
import Observation

/// Owns everything that touches the disk. `ContextProfiles` stays pure
/// so its matching can be unit-tested without a filesystem.
///
/// A profile is executable input — it replays real key events into a
/// machine that already holds Accessibility permission — so a bad file
/// is rejected **loudly and individually**, never silently merged.
@Observable
public final class ContextProfileStore {

    public struct Problem: Equatable, Sendable {
        public let file: String
        public let reason: String
    }

    public struct Loaded: Equatable, Sendable {
        public let profiles: [ContextProfile]
        public let problems: [Problem]
    }

    /// `builtin < remote < userFile`, same id replaced outright.
    public private(set) var merged: [ContextProfile] = ContextProfiles.all
    public private(set) var problems: [Problem] = []

    public static let directoryName = "RemoteCrab/Profiles"

    public static func merge(builtin: [ContextProfile],
                             user: [ContextProfile],
                             remote: [ContextProfile]) -> [ContextProfile] {
        var out = builtin
        for tier in [remote, user] {
            for p in tier {
                out.removeAll { $0.id == p.id }
                out.append(p)
            }
        }
        return out
    }

    public enum LoadError: LocalizedError, Equatable {
        case newerSchema(found: Int, supported: Int)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .newerSchema(let found, let supported):
                return "This file uses format version \(found); this app understands up to \(supported). Update RemoteCrab, or ask the author for an older file."
            case .malformed(let detail):
                return "This file could not be read: \(detail)"
            }
        }
    }

    public static func decode(_ data: Data, from file: String) throws -> ContextProfile {
        guard let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = probe["schemaVersion"] as? Int
        else {
            // No version field: the pre-versioning format. Let the
            // hand-written decoder default it rather than rejecting.
            return try JSONDecoder().decode(ContextProfile.self, from: data)
        }
        guard version <= ContextProfile.currentSchemaVersion else {
            throw LoadError.newerSchema(found: version,
                                        supported: ContextProfile.currentSchemaVersion)
        }
        return try JSONDecoder().decode(ContextProfile.self, from: data)
    }

    /// One bad file must not cost the user the good ones.
    public static func load(_ files: [(name: String, data: Data)]) -> Loaded {
        var profiles: [ContextProfile] = []
        var problems: [Problem] = []
        for file in files {
            do {
                var p = try decode(file.data, from: file.name)
                p = ContextProfile(schemaVersion: p.schemaVersion, id: p.id,
                                   title: p.title, source: .userFile,
                                   bundleIDs: p.bundleIDs, actions: p.actions,
                                   windowsProcessNames: p.windowsProcessNames,
                                   windowsActions: p.windowsActions)
                profiles.append(p)
            } catch {
                problems.append(Problem(file: file.name,
                                        reason: (error as? LocalizedError)?.errorDescription
                                            ?? "\(error)"))
            }
        }
        return Loaded(profiles: profiles, problems: problems)
    }

    /// `Documents/RemoteCrab/Profiles/*.json`. No network: `remote`
    /// stays empty until a signed feed exists.
    public func reload() {
        let fm = FileManager.default
        guard let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false) else { return }
        let dir = docs.appendingPathComponent(Self.directoryName)
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: nil) else {
            merged = ContextProfiles.all
            problems = []
            return
        }
        let files: [(name: String, data: Data)] = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (url.lastPathComponent, data)
            }
        let result = Self.load(files)
        merged = Self.merge(builtin: ContextProfiles.all,
                            user: result.profiles, remote: [])
        problems = result.problems
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd RemoteCrabCore && swift test --filter ContextProfileStore`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfileStore.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfileStoreTests.swift
git commit -m "feat(profiles): load suites from Documents, reject a bad file loudly"
```

---

## Task 8: 接线、文案、验证、交接

**Files:**
- Modify: `RemoteCrabCapture/CaptureEngine.swift`（持有 store、onAppear reload）
- Modify: `RemoteCrabCapture/ContextSheetView.swift`（用 `store.merged`、header 展示来源）
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift`（新文案）
- Modify: `RemoteCrabCore/Resources/Localizable.xcstrings`（en + zh-Hans）
- Modify: `docs/WINDOWS-GAPS-2026-10-03.md`（§5 表格 + 勾选清单）

- [ ] **Step 1: 加文案**

`IBLocale.Context` 加：

```swift
        public static let windowsKey = IBL("Windows")
        public static let browser = IBL("Browser")
        public static let talkToComputer = IBL("Talk to Computer")
        public static let sourceUserFile = IBL("Custom suite")
```

`Localizable.xcstrings` 加对应 4 个 key 的 `en` 与 `zh-Hans`（Windows 保持 `Windows`；Browser → `浏览器`；Talk to Computer → `与电脑对话`；Custom suite → `自定义套件`）。

- [ ] **Step 2: 接线**

`CaptureEngine` 加 `let profiles = ContextProfileStore()`，`init` 里 `profiles.reload()`；
`ContextSheetView` 的 `profile` 改为传 `engine.profiles.merged`，`.onAppear` 里
`engine.profiles.reload()`，并在 header 的 `profile.title` 下面显示来源（仅当
`profile.source != .builtin`）。footer 文案按平台切换（今天是「…to your Mac」，
Windows 上必须说电脑）。

- [ ] **Step 3: 全量验证**

Run: `./scripts/test.sh`
Expected: Core 测试全绿 + iOS app + Mac app 都 build 成功

Run: `cd windows && cargo test --workspace`
Expected: 全绿

Run: `cd windows && cargo check --workspace --all-targets --target x86_64-pc-windows-gnu`
Expected: 0 error

Run: `cd windows && cargo clippy --workspace --all-targets -- -D warnings && cargo clippy --workspace --all-targets --target x86_64-pc-windows-gnu -- -D warnings`
Expected: 0 warning

- [ ] **Step 4: 更新交接文档**

`docs/WINDOWS-GAPS-2026-10-03.md`：§5 表格里第 1/2/3 项标为已完成并注明 commit；
把 spec §8.4 的勾选清单整段搬进去；把 spec 里标了 ⚠️ 的两条
（Windows Terminal 复制/粘贴、PowerPoint F5 扩展功能键）列为待验证。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat(context): wire the profile store, localize, and verify"
```