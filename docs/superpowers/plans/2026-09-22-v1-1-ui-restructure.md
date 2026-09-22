# RemoteCrab V1.1 交互调整 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移除 iOS 底部 FeatureDock（相机/麦克风挪顶栏、键盘入口挪到 PTT 旁）、新增前台 app 情境快捷键页（含 Mac 控制台兜底套件 + systemCommand wire kind 0x19）、Mac 端接线开机自启动/自动连接/AWDL 直连。

**Architecture:** 全部增量改动。iOS 的 PTT/修饰键锁定/键盘面/PiP 逻辑原样保留，只做位置归位。情境页是纯本地套件注册表（bundle id → 按键集），按键走现有 `KeyEvent` 注入；Mac 控制台动作新增一个 wire kind 0x19，Mac 端用 system-defined CGEvent（音量/亮度/媒体键）+ NSWorkspace（启动 app/URL）执行。AWDL 只是双端 NWParameters 加 `includePeerToPeer`。

**Tech Stack:** Swift 6 / SwiftUI / Network.framework / CoreGraphics CGEvent / ServiceManagement (SMAppService) / XCTest (RemoteCrabCore package)。

**Spec:** `docs/superpowers/specs/2026-09-22-v1-1-ui-restructure-design.md` · **线框:** `prototypes/14-v1-1-restructure.html`

## Global Constraints

- 保持 Liquid Glass 设计语言：玻璃用 `IBMaterial.bar` / `IBMaterial.glass`，字体用 `IBFont.*`，颜色用 `IBColor.*` / `Color.accentColor`，按钮用 `IBPressButtonStyle()`。**禁止**手写新渐变/新色值。
- 所有 UI 文案走 `IBLocale`（英文原文即 key），并在 `RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings` 补 zh-Hans。禁止 emoji 以外的图标（用 SF Symbols）。**注意**：仅大小写不同的两个 catalog key 会冲突导致构建失败。
- wire kind 0x15–0x18 已被占用（cameraCommand/quitApp/windowListRequest/windowList），**新 kind 用 0x19**。
- Mac 端 `remotecrab.launchAtLogin` / `remotecrab.autoReconnect` 两个 PreferencesView toggle 已存在但未接线（PreferencesView.swift:22-23）——本计划是**接线**，不新增这两个 UI。
- Mac app 是 sandboxed（network.client/server、downloads、movies、camera、mic、sysex.install、app group）。媒体键/音量/亮度走 system-defined CGEvent，不需要新 entitlement。
- `project-mac.yml` / `project-ios.yml` 改动后必须 `xcodegen generate`（Info.plist 由 yml 整体重写）。
- 每完成一个 task 跑 `cd RemoteCrabCore && swift test`（或 `swift test --filter <TestClass>`）；涉及 app target 的 task 跑 `./scripts/test.sh`。
- 提交信息格式：`feat(core): …` / `feat(ios): …` / `feat(mac): …` / `docs: …`。

---

## 关键代码事实（实施者必读，探索已核实）

- `IBWire.Kind` 在 `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBWire.swift:20-46`；encode/decode 静态方法同文件成对添加。
- `IBEventBroadcaster.send(_:)` 重载在 `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEventBroadcaster.swift`。
- `IBQuitApp`（新消息模板）在 `IBEvents.swift:372`；`IBAppInfo` 字段 `id/name/pid/isActive/iconPNG`（`:325`）。
- iOS 入站 dispatch：`CaptureEngine.handleInbound` `RemoteCrabCapture/CaptureEngine.swift:1386`；`macApps` 属性在 `:58`（`@Published private(set) var macApps: [IBAppInfo]`），Mac 在握手后和 app activate/launch/terminate 时自动推 appList（ReceiverSession.swift:896, 209-216），**前台 app 数据 iOS 端现成**。
- Mac 入站 dispatch：`ReceiverSession.handleInbound` `RemoteCrabReceiver/ReceiverSession.swift:1055`，switch 在 `:1072`，`.quitApp` case 样板在 `:1186-1189`。
- iOS NWListener 参数：`CaptureEngine.swift:779`（`let parameters = NWParameters.tcp`）。
- Mac NWBrowser：`BonjourBrowser.swift:19`；Mac NWConnection 三处：`ReceiverSession.swift:713`（fallback 探测）、`:794`（Bonjour 服务）、`:796-800`（direct-IP 拨号）。
- `IBModifierBar`：`RemoteCrabCore/Sources/RemoteCrabCore/Components/IBModifierBar.swift:6`，`init(activeModifiers: Binding<Set<Modifier>>)`，Modifier = control/option/command/shift。
- `FeatureStore`：`RemoteCrabCore/Sources/RemoteCrabCore/State/FeatureStore.swift:12`（`@Observable @MainActor`），`set(feature:enabled:)` `:43`；`Surface { trackpad, keyboard, cameraPreview }` 在 `IBEvents.swift:222-226`；`IBFeature { camera, microphone, voice, trackpad, keyboard }` 在 `:183-189`。
- `VoiceRecognizer`（`RemoteCrabCapture/VoiceRecognizer.swift`）：`start() async -> Bool`、`stop()`、`onFinal: ((String)->Void)?`、`onInterrupted: (()->Void)?`、`isRunning`、`partialText`、`lastError`、`clearError()`。
- `CGEventInjector`：`RemoteCrabReceiver/Input/CGEventInjector.swift:14`，`inject(key:)` `:71`（ReceiverSession 调用点 `:1120`）。
- PreferencesView：`RemoteCrabReceiver/PreferencesView.swift:13`，TabView × Form(.grouped)，General tab `:74-212`，launchAtLogin toggle `:85`，autoReconnect toggle `:88`。
- 测试样板：round-trip 见 `RemoteCrabCore/Tests/RemoteCrabCoreTests/AppSwitcherWireTests.swift:38-46`；TCP E2E helper `makePipeline()` / `pipe.pump(packet:until:)` 在 `EventPipelineEndToEndTests.swift:230-283, 196-222`。
- `CaptureEngine` 是 `ObservableObject`（ContentView 用 `@EnvironmentObject`），`sendKey(_:)` 在 `:269`（gate 在 `features.keyboardOn`）。

---

### Task 1: Core — `IBSystemCommand` 消息 + wire kind 0x19

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift`（追加到文件尾部）
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBWire.swift:20-46`（Kind 枚举）+ 尾部 decode 区
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEventBroadcaster.swift`（加一个 send 重载）
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/SystemCommandWireTests.swift`（新建）

**Interfaces:**
- Produces:
  - `public struct IBSystemCommand: Codable, Sendable, Equatable`，字段 `command: Command`、`argument: String?`；`public enum Command: String, Codable, Sendable { case volumeUp, volumeDown, volumeMute, brightnessUp, brightnessDown, mediaPlayPause, mediaNext, mediaPrevious, launchApp, openURL }`
  - `IBWire.encode(systemCommand:) throws -> Data` / `IBWire.decodeSystemCommand(_:) throws -> IBSystemCommand`
  - `IBEventBroadcaster.send(_ command: IBSystemCommand)`
  - `IBWire.Kind.systemCommand = 0x19`

- [ ] **Step 1: 写失败测试**

新建 `RemoteCrabCore/Tests/RemoteCrabCoreTests/SystemCommandWireTests.swift`：

```swift
import XCTest
@testable import RemoteCrabCore

final class SystemCommandWireTests: XCTestCase {

    func testRoundTripVolumeUp() throws {
        let encoded = try IBWire.encode(systemCommand: IBSystemCommand(command: .volumeUp))
        let frames = IBWire.Parser().append(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .systemCommand)
        let decoded = try IBWire.decodeSystemCommand(frames[0])
        XCTAssertEqual(decoded.command, .volumeUp)
        XCTAssertNil(decoded.argument)
    }

    func testRoundTripLaunchAppWithArgument() throws {
        let encoded = try IBWire.encode(systemCommand: IBSystemCommand(command: .launchApp, argument: "com.apple.Safari"))
        let frames = IBWire.Parser().append(encoded)
        XCTAssertEqual(frames.count, 1)
        let decoded = try IBWire.decodeSystemCommand(frames[0])
        XCTAssertEqual(decoded.command, .launchApp)
        XCTAssertEqual(decoded.argument, "com.apple.Safari")
    }

    func testRoundTripOpenURL() throws {
        let encoded = try IBWire.encode(systemCommand: IBSystemCommand(command: .openURL, argument: "https://vgoapp.com/remotecrab/"))
        let decoded = try IBWire.decodeSystemCommand(try XCTUnwrap(IBWire.Parser().append(encoded).first))
        XCTAssertEqual(decoded.command, .openURL)
        XCTAssertEqual(decoded.argument, "https://vgoapp.com/remotecrab/")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd RemoteCrabCore && swift test --filter SystemCommandWireTests 2>&1 | tail -5
```
Expected: 编译失败（`IBSystemCommand` 不存在）。

- [ ] **Step 3: 实现**

`IBEvents.swift` 尾部追加：

```swift
/// iPhone → Mac: a system-level action on the Mac (volume, brightness,
/// media keys, app/URL launch). Kind 0x19. Lock screen is NOT here —
/// it's a plain ⌃⌘Q KeyEvent chord from the iOS side.
public struct IBSystemCommand: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case volumeUp, volumeDown, volumeMute
        case brightnessUp, brightnessDown
        case mediaPlayPause, mediaNext, mediaPrevious
        case launchApp      // argument = bundle id
        case openURL        // argument = URL string
    }
    public let command: Command
    public let argument: String?
    public init(command: Command, argument: String? = nil) {
        self.command = command
        self.argument = argument
    }
}
```

`IBWire.swift` Kind 枚举 `:45` 后（`case windowList = 0x18` 下一行）加：

```swift
        case systemCommand = 0x19    // JSON IBSystemCommand (iPhone → Mac)
```

encode 区（`encode(quitApp:)` 后）加：

```swift
    /// Encode a system command (iPhone → Mac).
    public static func encode(systemCommand: IBSystemCommand) throws -> Data {
        encodeFrame(kind: .systemCommand, payload: try JSONEncoder().encode(systemCommand))
    }
```

decode 区（`decodeQuitApp` 后）加：

```swift
    /// Decode a `.systemCommand` frame's payload.
    public static func decodeSystemCommand(_ frame: Frame) throws -> IBSystemCommand {
        try JSONDecoder().decode(IBSystemCommand.self, from: frame.payload)
    }
```

`IBEventBroadcaster.swift`（`send(_ quit: IBQuitApp)` 后）加：

```swift
    /// iOS → Mac: a system-level action (volume / brightness / media / launch).
    public func send(_ command: IBSystemCommand) {
        send(kind: .systemCommand) { try IBWire.encode(systemCommand: command) }
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd RemoteCrabCore && swift test --filter SystemCommandWireTests 2>&1 | tail -3
```
Expected: 3 tests passed。

- [ ] **Step 5: 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBWire.swift RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEventBroadcaster.swift RemoteCrabCore/Tests/RemoteCrabCoreTests/SystemCommandWireTests.swift
git commit -m "feat(core): IBSystemCommand wire kind 0x19 (volume/brightness/media/launch)"
```

---

### Task 2: Core — `ContextProfiles` 套件注册表 + 匹配测试

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfilesTests.swift`（新建）

**Interfaces:**
- Consumes: `IBAppInfo`（IBEvents.swift:325）、`IBSystemCommand`（Task 1）。
- Produces:
  - `public enum ContextAction: Equatable, Sendable` — `.key(label: String, symbol: String, keycode: UInt16, modifiers: UInt8)` / `.system(label: String, symbol: String, command: IBSystemCommand.Command)` / `.voiceHero(label: String, symbol: String)`
  - `public struct ContextProfile: Equatable, Sendable` — `id: String`、`titleKey: String`、`actions: [ContextAction]`
  - `public enum ContextProfiles` — `public static func profile(for app: IBAppInfo?) -> ContextProfile`

设计说明：终端检测**只能到「前台是终端 app」**（iOS 拿不到终端里跑的进程），所以 Agent 套件的匹配 = 终端类 bundle id。这是已记录的简化。

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import RemoteCrabCore

final class ContextProfilesTests: XCTestCase {
    private func app(_ id: String, name: String = "x") -> IBAppInfo {
        IBAppInfo(id: id, name: name, pid: 1, isActive: true, iconPNG: nil)
    }

    func testKeynoteMatchesPresentation() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.iWork.Keynote")).id, "presentation")
    }

    func testPowerPointMatchesPresentation() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.microsoft.Powerpoint")).id, "presentation")
    }

    func testTerminalMatchesAgent() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.Terminal")).id, "agent")
        XCTAssertEqual(ContextProfiles.profile(for: app("com.googlecode.iterm2")).id, "agent")
        XCTAssertEqual(ContextProfiles.profile(for: app("com.mitchellh.ghostty")).id, "agent")
    }

    func testUnknownFallsBackToConsole() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.Safari")).id, "console")
    }

    func testNilFallsBackToConsole() {
        XCTAssertEqual(ContextProfiles.profile(for: nil).id, "console")
    }

    func testConsoleHasVolumeAndMediaActions() {
        let console = ContextProfiles.profile(for: nil)
        let commands = console.actions.compactMap { action -> IBSystemCommand.Command? in
            if case .system(_, _, let c) = action { return c }
            return nil
        }
        XCTAssertTrue(commands.contains(.volumeUp))
        XCTAssertTrue(commands.contains(.mediaPlayPause))
    }

    func testAgentSuiteHasVoiceHero() {
        let agent = ContextProfiles.profile(for: app("com.apple.Terminal"))
        XCTAssertTrue(agent.actions.contains { if case .voiceHero = $0 { return true }; return false })
    }
}
```

（注意：`IBAppInfo` 的 memberwise init 如果是 internal，测试用 `@testable` 即可；若其 init 不同，按 `IBEvents.swift:325` 的实际签名调整。）

- [ ] **Step 2: 跑测试确认失败**

```bash
cd RemoteCrabCore && swift test --filter ContextProfilesTests 2>&1 | tail -5
```
Expected: 编译失败。

- [ ] **Step 3: 实现**

`RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift`：

```swift
import Foundation

/// One button in the context sheet. `.key` replays a Mac keyboard
/// event (existing KeyEvent injection); `.system` is an
/// IBSystemCommand (Task 1); `.voiceHero` is the push-to-talk
/// shortcut handled by the sheet itself.
public enum ContextAction: Equatable, Sendable {
    case key(label: String, symbol: String, keycode: UInt16, modifiers: UInt8 = 0)
    case system(label: String, symbol: String, command: IBSystemCommand.Command)
    case voiceHero(label: String, symbol: String)
}

/// A frontmost-app-keyed set of shortcuts. Pure data — rendering
/// lives in the iOS ContextSheetView.
public struct ContextProfile: Equatable, Sendable {
    public let id: String
    /// IBLocale key suffix (Context.<titleKey>).
    public let titleKey: String
    public let actions: [ContextAction]
    public init(id: String, titleKey: String, actions: [ContextAction]) {
        self.id = id
        self.titleKey = titleKey
        self.actions = actions
    }
}

/// Registry: frontmost Mac app (from IBAppList / isActive) → profile.
/// Terminals map to the agent suite — iOS cannot see which process
/// runs inside the terminal, that is the documented V1.1 heuristic.
public enum ContextProfiles {

    private static let presentationBundleIDs: Set<String> = [
        "com.apple.iWork.Keynote",
        "com.microsoft.Powerpoint",
    ]

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    public static func profile(for app: IBAppInfo?) -> ContextProfile {
        guard let app else { return console }
        if presentationBundleIDs.contains(app.id) { return presentation }
        if terminalBundleIDs.contains(app.id) { return agent }
        return console
    }

    // Keycodes: ← 123, → 124, B 11, W 13, ESC 53, ⏎ 36, C 8, V 9, Q 12.
    // Modifier mask: shift=1, control=2, option=4, command=8.

    public static let presentation = ContextProfile(id: "presentation", titleKey: "presentation", actions: [
        .key(label: "Play / Exit", symbol: "play.fill", keycode: 35, modifiers: 4 | 8),   // ⌥⌘P
        .key(label: "Previous", symbol: "chevron.left", keycode: 123),
        .key(label: "Next", symbol: "chevron.right", keycode: 124),
        .key(label: "Black Screen", symbol: "rectangle.fill", keycode: 11),               // B
        .key(label: "White Screen", symbol: "rectangle", keycode: 13),                    // W
        .key(label: "Exit", symbol: "escape", keycode: 53),
    ])

    public static let agent = ContextProfile(id: "agent", titleKey: "agent", actions: [
        .voiceHero(label: "Talk to Agent", symbol: "waveform"),
        .key(label: "Approve", symbol: "checkmark", keycode: 36),                          // ⏎
        .key(label: "Interrupt", symbol: "xmark", keycode: 8, modifiers: 2),               // ⌃C
        .key(label: "Copy", symbol: "doc.on.doc", keycode: 8, modifiers: 8),               // ⌘C
        .key(label: "Paste", symbol: "doc.on.clipboard", keycode: 9, modifiers: 8),        // ⌘V
        .key(label: "Escape", symbol: "escape", keycode: 53),
    ])

    public static let console = ContextProfile(id: "console", titleKey: "console", actions: [
        .system(label: "Volume +", symbol: "speaker.plus.fill", command: .volumeUp),
        .system(label: "Volume −", symbol: "speaker.minus.fill", command: .volumeDown),
        .system(label: "Mute", symbol: "speaker.slash.fill", command: .volumeMute),
        .system(label: "Brightness +", symbol: "sun.max.fill", command: .brightnessUp),
        .system(label: "Brightness −", symbol: "sun.min.fill", command: .brightnessDown),
        .system(label: "Play / Pause", symbol: "playpause.fill", command: .mediaPlayPause),
        .key(label: "Lock Screen", symbol: "lock.fill", keycode: 12, modifiers: 2 | 8),    // ⌃⌘Q
        .system(label: "Safari", symbol: "safari.fill", command: .launchApp),
    ])
}
```

注意：console 里 `launchApp` 的 argument 由 iOS 发送侧填（见 Task 6，`ContextSheetView` 对 `.system(.launchApp)` 附带 bundle id；注册表 action 本身不带 argument——因此 `.system` case 的命令不含参数，发送时 console 的 Safari 项写死 `"com.apple.Safari"`。第一版快速启动只内置 Safari 一项，自定义启动器是 V1.2）。

- [ ] **Step 4: 跑测试确认通过**

```bash
cd RemoteCrabCore && swift test --filter ContextProfilesTests 2>&1 | tail -3
```
Expected: 7 tests passed。

- [ ] **Step 5: 提交**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/ContextProfiles.swift RemoteCrabCore/Tests/RemoteCrabCoreTests/ContextProfilesTests.swift
git commit -m "feat(core): ContextProfiles registry (presentation/agent/console suites)"
```

---

### Task 3: Mac — `SystemCommandHandler` + ReceiverSession dispatch

**Files:**
- Create: `RemoteCrabReceiver/SystemCommandHandler.swift`
- Modify: `RemoteCrabReceiver/ReceiverSession.swift:1186-1189`（`.quitApp` case 旁加新 case）
- 构建验证：`./scripts/test.sh`

**Interfaces:**
- Consumes: `IBWire.decodeSystemCommand`（Task 1）。
- Produces: `enum SystemCommandHandler { static func handle(_ command: IBSystemCommand) }`（ReceiverSession 调用点用）。

- [ ] **Step 1: 写 handler**

`RemoteCrabReceiver/SystemCommandHandler.swift`：

```swift
import AppKit
import CoreGraphics
import os

/// Executes IBSystemCommand frames from the iPhone. Volume / brightness
/// / media keys all go through system-defined CGEvents (the same path
/// the physical keyboard's media keys use — no extra entitlements, the
/// app's existing Accessibility grant covers event posting). App/URL
/// launch goes through NSWorkspace.
enum SystemCommandHandler {

    private static let log = Logger(subsystem: "com.remotecrab", category: "syscmd")

    // IOKit ev_keymap.h values.
    private static let nxSoundUp: Int32 = 0
    private static let nxSoundDown: Int32 = 1
    private static let nxBrightnessUp: Int32 = 2
    private static let nxBrightnessDown: Int32 = 3
    private static let nxMute: Int32 = 7
    private static let nxPlay: Int32 = 16
    private static let nxNext: Int32 = 17
    private static let nxPrevious: Int32 = 18

    static func handle(_ command: IBSystemCommand) {
        switch command.command {
        case .volumeUp:       postSystemKey(nxSoundUp)
        case .volumeDown:     postSystemKey(nxSoundDown)
        case .volumeMute:     postSystemKey(nxMute)
        case .brightnessUp:   postSystemKey(nxBrightnessUp)
        case .brightnessDown: postSystemKey(nxBrightnessDown)
        case .mediaPlayPause: postSystemKey(nxPlay)
        case .mediaNext:      postSystemKey(nxNext)
        case .mediaPrevious:  postSystemKey(nxPrevious)
        case .launchApp:
            if let bundleID = command.argument {
                let ok = NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleID,
                                                              options: [],
                                                              additionalEventParamDescriptor: nil,
                                                              launchIdentifier: nil)
                if !ok { log.error("launchApp failed: \(bundleID, privacy: .public)") }
            }
        case .openURL:
            if let raw = command.argument, let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Post one press+release of a system-defined (media) key.
    private static func postSystemKey(_ key: Int32) {
        postSystemKey(key, down: true)
        postSystemKey(key, down: false)
    }

    private static func postSystemKey(_ key: Int32, down: Bool) {
        let flags: UInt = down ? 0xA00 : 0xB00
        let data1 = Int((Int(key) << 16) | (Int(flags) << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )?.cgEvent else { return }
        event.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 2: 接线 dispatch**

`ReceiverSession.swift` 在 `.quitApp` case（`:1186-1189`）后加：

```swift
            case .systemCommand:
                if let command = try? IBWire.decodeSystemCommand(frame) {
                    SystemCommandHandler.handle(command)
                }
```

- [ ] **Step 3: 构建验证**

```bash
./scripts/test.sh 2>&1 | tail -20
```
Expected: Core tests 全绿 + 两个 app target 编译通过。

- [ ] **Step 4: 提交**

```bash
git add RemoteCrabReceiver/SystemCommandHandler.swift RemoteCrabReceiver/ReceiverSession.swift
git commit -m "feat(mac): execute IBSystemCommand (media-key CGEvents + NSWorkspace launch)"
```

---

### Task 4: Mac — 接线 launchAtLogin（SMAppService）+ autoReconnect 开关 + AWDL

**Files:**
- Modify: `RemoteCrabReceiver/PreferencesView.swift:85-88`（两个死 toggle 接线）
- Modify: `RemoteCrabReceiver/ReceiverSession.swift:577`（auto-connect gate）、`:660`（fallback loop gate）
- Modify: `RemoteCrabReceiver/BonjourBrowser.swift:18-19`（AWDL）
- Modify: `RemoteCrabReceiver/ReceiverSession.swift:713, 794, 796-800`（AWDL）
- 构建验证：`./scripts/test.sh`

**Interfaces:**
- Consumes: 无（Mac app 内部）。
- Produces: UserDefaults key `remotecrab.launchAtLogin` / `remotecrab.autoReconnect` 变为真实生效；新 key `remotecrab.mac.peerToPeer`（默认 true）。

- [ ] **Step 1: SMAppService 接线**

`PreferencesView.swift` 顶部加 `import ServiceManagement`。把 `:85` 的 launchAtLogin Toggle 改为：

```swift
Toggle(IBLocale.Settings.openAtLogin, isOn: $launchAtLogin)
    .onChange(of: launchAtLogin) { _, enabled in
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration can fail (e.g. running from DerivedData
            // during development) — revert the toggle to the real status.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
```

并在 `PreferencesView` body 上加启动时同步（放在 `generalTab` 的 `.onAppear` 或 view `.task`）：

```swift
.task {
    // The system is the source of truth (user can toggle us in
    // System Settings → Login Items without us knowing).
    launchAtLogin = SMAppService.mainApp.status == .enabled
}
```

- [ ] **Step 2: autoReconnect 接线**

`ReceiverSession.swift:577` 附近（`handleDiscovered` 里 `guard !autoConnectSuppressed else { return }`）改为同时读新开关：

```swift
        let autoConnectEnabled = UserDefaults.standard.object(forKey: "remotecrab.autoReconnect") as? Bool ?? true
        guard !autoConnectSuppressed, autoConnectEnabled else { return }
```

fallback loop 入口（`:660` 附近的条件判断处）加同一个 gate：

```swift
        guard UserDefaults.standard.object(forKey: "remotecrab.autoReconnect") as? Bool ?? true else { return }
```

（如果 `:660` 的具体形式不同，原则：fallback 拨号循环启动前检查该 key。）

- [ ] **Step 3: AWDL — Mac 侧 4 处**

`BonjourBrowser.swift:18-19` 改为：

```swift
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = UserDefaults.standard.object(forKey: "remotecrab.mac.peerToPeer") as? Bool ?? true
        browser = NWBrowser(for: descriptor, using: parameters)
```

`ReceiverSession.swift:713`（fallback 探测）、`:794`（Bonjour 服务连接）、`:796-800`（direct-IP 拨号）三处的 `.tcp` / `NWParameters.tcp` 同样改为先构造再设 `includePeerToPeer`（同一个 UserDefaults key）。模式：

```swift
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = UserDefaults.standard.object(forKey: "remotecrab.mac.peerToPeer") as? Bool ?? true
        let connection = NWConnection(to: serviceEndpoint, using: parameters)
```

- [ ] **Step 4: Preferences 加 AWDL toggle**

`PreferencesView.swift` 的 `@AppStorage` 组（`:18-24`）加：

```swift
    @AppStorage("remotecrab.mac.peerToPeer") private var peerToPeer: Bool = true
```

generalTab 的 auto-reconnect Toggle（`:88`）后加：

```swift
Toggle(IBLocale.Settings.peerToPeer, isOn: $peerToPeer)
```

`IBLocale.Settings`（`RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift:185` 的 Settings enum 内）加：

```swift
        public static let peerToPeer = IBL("Direct Wi-Fi (peer-to-peer)")
```

并在 `RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings` 给 key `"Direct Wi-Fi (peer-to-peer)"` 补 zh-Hans `"点对点直连 Wi-Fi"`（xcstrings 是 JSON，按现有条目结构插入；改完用 `plutil -lint` 验证）。

- [ ] **Step 5: 构建验证 + 提交**

```bash
./scripts/test.sh 2>&1 | tail -20
git add RemoteCrabReceiver/PreferencesView.swift RemoteCrabReceiver/ReceiverSession.swift RemoteCrabReceiver/BonjourBrowser.swift RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings
git commit -m "feat(mac): wire launchAtLogin (SMAppService), autoReconnect gate, AWDL peer-to-peer"
```

---

### Task 5: iOS — AWDL listener 参数

**Files:**
- Modify: `RemoteCrabCapture/CaptureEngine.swift:779`

**Interfaces:**
- Consumes: 无。Produces: iOS listener 接受 peer-to-peer 直连。

- [ ] **Step 1: 改参数**

`CaptureEngine.swift:779` 后插入一行：

```swift
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true   // AWDL: accept direct Wi-Fi when no LAN exists
```

（即原有 `let parameters = NWParameters.tcp` 保持不变，紧随其后加 `parameters.includePeerToPeer = true`。iOS 侧不加开关：listener 多端监听无副作用。）

- [ ] **Step 2: 构建 + 提交**

```bash
./scripts/test.sh 2>&1 | tail -10
git add RemoteCrabCapture/CaptureEngine.swift
git commit -m "feat(ios): accept peer-to-peer (AWDL) listener connections"
```

---

### Task 6: iOS UI — 移除 FeatureDock，顶栏 📷/🎙 开关，PTT + ⌨️ 行，⏎ 主色，相机/键盘面出口

**Files:**
- Modify: `RemoteCrabCapture/ContentView.swift`（顶栏 + 底部 PTT 行 + sheet 状态 + insets）
- Delete: `RemoteCrabCapture/FeatureDock.swift`（逻辑迁出后删除；xcodegen 按目录收文件，删文件即可，但需 `xcodegen generate --spec project-ios.yml` 后确认无残留引用）
- Modify: `RemoteCrabCapture/TouchpadScreen.swift:39,168-181`（dockClearance + ⏎ 主色 + 情境 chip，chip 在 Task 7）
- Modify: `RemoteCrabCapture/KeyboardScreen.swift:92-105`（header 加返回按钮）
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift`（新文案）
- 构建验证：`./scripts/test.sh`

**Interfaces:**
- Consumes: `FeatureStore.set(feature:enabled:)`、`VoiceRecognizer` 接口（见"关键代码事实"）。
- Produces: ContentView 底部新 PTT 行（⌨️ + 按住说话）；顶栏 📷/🎙 圆钮；`engine.showContextSheet` 暂不在本 task（Task 7 加）。

- [ ] **Step 1: 顶栏加 📷/🎙 开关**

`ContentView.swift` `topBar`（`:443-512`）中，在 app-switcher 按钮（`:471-477`）之后、溢出 Menu（`:481`）之前插入：

```swift
            // Stream toggles moved here from the retired FeatureDock:
            // they are global on/off state, which is exactly what a
            // top bar is for.
            Button {
                engine.features.set(feature: .camera, enabled: !engine.features.cameraOn)
            } label: {
                topBarIcon("video.fill", tint: engine.features.cameraOn ? .white : .white,
                           active: engine.features.cameraOn)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .buttonStyle(IBPressButtonStyle())
            .accessibilityLabel(IBLocale.Mode.camera)
            .accessibilityValue(engine.features.cameraOn ? IBLocale.A11y.on : IBLocale.A11y.off)

            Button {
                engine.features.set(feature: .microphone, enabled: !engine.features.micOn)
            } label: {
                topBarIcon("mic.fill", tint: .white,
                           active: engine.features.micOn, activeColor: IBColor.recording)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .buttonStyle(IBPressButtonStyle())
            .accessibilityLabel(IBLocale.A11y.microphone)
            .accessibilityValue(engine.features.micOn ? IBLocale.A11y.on : IBLocale.A11y.off)
```

把 `topBarIcon`（`:524-530`）扩展为：

```swift
    private func topBarIcon(_ name: String, tint: Color = .white,
                            active: Bool = false, activeColor: Color = .accentColor) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .padding(IBSpace.s.pt + 2)
            .background {
                if active {
                    Circle().fill(activeColor)
                } else {
                    IBMaterial.bar(in: Circle())
                }
            }
    }
```

（`IBColor.recording` 已存在——FeatureDock 用过 `IBColor.recording.opacity(0.85)`。若名不同以 `IBColor` 实际定义为准。）

- [ ] **Step 2: 底部换 PTT 行（⌨️ + 按住说话）**

`ContentView.swift:45-50` 的 VStack 改为：

```swift
                VStack {
                    topBar
                    Spacer()
                    pttRow
                }
                .padding(IBSpace.l.pt)
```

新增（放在 `// MARK: - Voice recognition card` 之前），PTT 手势逻辑**逐字搬自** `FeatureDock.swift:108-181`（voiceButton / startVoice / stopVoice），只改布局为 HStack 并加 ⌨️ 圆钮；`@State private var voiceHeld = false` 加到 ContentView 的 @State 组：

```swift
    @State private var voiceHeld = false

    /// Bottom row: keyboard entry (left) + wide hold-to-talk capsule.
    /// This replaces the FeatureDock — the trackpad is the default
    /// surface and needs no button; camera/mic live in the top bar.
    private var pttRow: some View {
        HStack(spacing: 10) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(IBAnimation.snappy) {
                    engine.features.activeSurface =
                        engine.features.activeSurface == .keyboard ? .trackpad : .keyboard
                }
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background {
                        if engine.features.activeSurface == .keyboard {
                            Circle().fill(Color.accentColor)
                        } else {
                            IBMaterial.bar(in: Circle())
                        }
                    }
            }
            .buttonStyle(IBPressButtonStyle(scale: 0.9))
            .accessibilityLabel(IBLocale.Mode.keyboard)

            // Hold-to-talk — moved verbatim from FeatureDock.
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: voiceHeld)
                Text(voiceHeld ? IBLocale.Voice.releaseToSend : IBLocale.Voice.holdToTalk)
                    .font(IBFont.bodyMedium)
            }
            .foregroundStyle(voiceHeld ? .white : .white.opacity(0.75))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background {
                Capsule(style: .continuous)
                    .fill(voiceHeld ? IBColor.recording.opacity(0.85) : .white.opacity(0.10))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(voiceHeld ? Color.white.opacity(0.5) : Color.white.opacity(0.14),
                                          lineWidth: voiceHeld ? 1.5 : 0.5)
                    }
            }
            .shadow(color: voiceHeld ? IBColor.recording.opacity(0.5) : .clear,
                    radius: voiceHeld ? 14 : 0)
            .scaleEffect(voiceHeld ? 1.03 : 1.0)
            .animation(IBAnimation.snappy, value: voiceHeld)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in startVoice() }
                    .onEnded { _ in stopVoice() }
            )
            .accessibilityLabel(voiceHeld ? IBLocale.A11y.voiceReleaseToStop : IBLocale.A11y.voiceHoldToTalk)
            .accessibilityAction(named: IBLocale.A11y.voiceToggle) {
                if voiceHeld { stopVoice() } else { startVoice() }
            }
        }
    }

    private func startVoice() {
        guard !voiceHeld else { return }
        voiceHeld = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        engine.features.set(feature: .voice, enabled: true)
        Task { @MainActor in
            let started = await voice.start()
            if !started {
                voiceHeld = false
                engine.features.set(feature: .voice, enabled: false)
            } else if !voiceHeld {
                voice.stop()
            }
        }
    }

    private func stopVoice() {
        guard voiceHeld else { return }
        voiceHeld = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        engine.features.set(feature: .voice, enabled: false)
        voice.stop()
    }
```

`voice.onInterrupted` 的复位回调（原 FeatureDock.swift:58-65 的 onAppear 逻辑）并入 ContentView 现有的 `.onAppear`（`:141`，`voice.onFinal` 设置处旁边）：

```swift
            voice.onInterrupted = {
                voiceHeld = false
                engine.features.set(feature: .voice, enabled: false)
            }
```

注意：相机/键盘面上 PTT 行同样显示（现状 dock 也是全局浮层）。键盘面系统键盘升起时该行被系统键盘遮挡——退出走 Step 4 的 header 按钮，与现状一致（dock 今天同样被系统键盘遮挡）。

- [ ] **Step 3: 相机面出口 ✕**

`ContentView.swift` 的相机面 overlay（`:360-362`，`flipCameraButton` 处）改为同时给 leading 一个 ✕：

```swift
                        .overlay(alignment: .topTrailing) {
                            flipCameraButton(topInset: topInset)
                        }
                        .overlay(alignment: .topLeading) {
                            Button {
                                withAnimation(IBAnimation.snappy) {
                                    engine.features.activeSurface = .trackpad
                                }
                            } label: {
                                topBarIcon("xmark")
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .buttonStyle(IBPressButtonStyle())
                            .padding(.top, topInset + 16 + 44 + 12)
                            .padding(.leading, IBSpace.l.pt)
                            .accessibilityLabel(IBLocale.A11y.closeCamera)
                        }
```

`IBLocale.A11y`（IBLocale.swift:544 A11y enum 内）加 `public static let closeCamera = IBL("Close camera view")`，xcstrings 补 zh-Hans `"关闭相机视图"`。

- [ ] **Step 4: 键盘面 header 加返回按钮**

`KeyboardScreen.swift` header（`:92-105`）：把左侧 `Image(systemName: "keyboard")` 换成返回按钮：

```swift
    private var header: some View {
        HStack {
            Button {
                engine.features.activeSurface = .trackpad
            } label: {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(IBSpace.s.pt + 2)
                    .background { IBMaterial.bar(in: Circle()) }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .buttonStyle(IBPressButtonStyle())
            .accessibilityLabel(IBLocale.Mode.trackpad)
            Spacer()
            Text(IBLocale.Keyboard.typingOnMac)
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.45))
                .ibEyebrowTracking()
        }
        .padding(.horizontal, IBSpace.s.pt)
        .padding(.top, IBSpace.s.pt)
    }
```

- [ ] **Step 5: ⏎ 主色 + dockClearance/inset 重测**

`TouchpadScreen.swift`：
- `dockClearance`（`:39`）从 `148` 改为 `76`（新底部 = 48pt PTT 行 + 16pt ContentView padding + 少量余量；改完用 `./scripts/render_ui_screenshots.swift` 或模拟器截图核对快捷键行与 PTT 行不重叠）。
- `quickKey`（`:61-84`）加 `prominent: Bool = false` 参数，prominent 时背景换 `Circle`→`RoundedRectangle` accent 填充：

```swift
    private func quickKey(text: String? = nil, symbol: String? = nil, accessibility: String, keycode: UInt16, prominent: Bool = false) -> some View {
        Button {
            sendKeyTap(keycode)
        } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                } else {
                    Text(text ?? "").font(.system(size: 17, weight: .medium))
                }
            }
            .frame(width: 48, height: 48)
            .foregroundStyle(prominent ? .white : IBColor.textPrimary)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous)
                        .fill(Color.accentColor)
                } else {
                    IBMaterial.glass(
                        in: RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous),
                        tint: IBColor.accent,
                        interactive: true
                    )
                }
            }
        }
        .buttonStyle(IBPressButtonStyle())
        .accessibilityLabel(accessibility)
    }
```

⏎ 调用处（`:177`）改为 `quickKey(symbol: "return", accessibility: IBLocale.A11y.returnKey, keycode: 36, prominent: true)`。

`ContentView.swift` `voiceCardBottomInset`（`:702-704`）改为：

```swift
    private var voiceCardBottomInset: CGFloat {
        // New bottom stack: 48pt PTT row + 16pt padding; the trackpad's
        // quick-key row floats ~76pt above it.
        engine.features.activeSurface == .trackpad ? 132 : 72
    }
```

（同样需视觉核对。）

- [ ] **Step 6: 删 FeatureDock + 构建**

```bash
rm RemoteCrabCapture/FeatureDock.swift
xcodegen generate --spec project-ios.yml
./scripts/test.sh 2>&1 | tail -20
```
Expected: 全绿。若有 `FeatureDock` 残留引用（grep 确认）逐一清理。

- [ ] **Step 7: 提交**

```bash
git add -A RemoteCrabCapture RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings
git commit -m "feat(ios): retire FeatureDock — cam/mic to top bar, PTT+keyboard row, prominent return key"
```

---

### Task 7: iOS — 情境 chip + 情境页（ContextSheetView）

**Files:**
- Create: `RemoteCrabCapture/ContextSheetView.swift`
- Modify: `RemoteCrabCapture/CaptureEngine.swift`（`frontmostMacApp`、`sendSystemCommand`、`showContextSheet`）
- Modify: `RemoteCrabCapture/ContentView.swift`（sheet 呈现）
- Modify: `RemoteCrabCapture/TouchpadScreen.swift:168-181`、`RemoteCrabCapture/KeyboardScreen.swift:195-216`（chip 固定在最左）
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift` + xcstrings
- 构建验证：`./scripts/test.sh`

**Interfaces:**
- Consumes: `ContextProfiles.profile(for:)` / `ContextAction`（Task 2）、`IBEventBroadcaster.send(_ command: IBSystemCommand)`（Task 1）、`engine.macApps`（已有）。
- Produces:
  - `CaptureEngine.frontmostMacApp: IBAppInfo?`
  - `CaptureEngine.sendSystemCommand(_ command: IBSystemCommand)`
  - `CaptureEngine.sendContextKey(keycode: UInt16, modifiers: UInt8)`（绕过 keyboardOn gate 的说明见下）
  - `CaptureEngine.showContextSheet: Bool`（`@Published`）

注意 gate：`engine.sendKey` gate 在 `features.keyboardOn`（默认 true，用户可在 Mac 端关掉键盘功能——此时情境按键也不该发，语义一致，**直接复用 `sendKey` 即可**，不需要新方法；上面 Produces 里的 `sendContextKey` 取消）。`sendSystemCommand` 不做 feature gate（控制台不属于 trackpad/keyboard 任一开关）。

- [ ] **Step 1: CaptureEngine 加三个成员**

`CaptureEngine.swift`（`macApps` 属性 `:58` 附近）加：

```swift
    /// Frontmost Mac app, from the latest pushed appList (0x0C).
    var frontmostMacApp: IBAppInfo? { macApps.first(where: { $0.isActive }) }

    /// Presents the context-shortcut sheet (observed by ContentView).
    @Published var showContextSheet = false
```

（`sendKey` 附近 `:262-290` 区）加：

```swift
    /// Context-sheet system command (volume / brightness / media / launch).
    /// Not gated on a feature toggle: the console is always available.
    func sendSystemCommand(_ command: IBSystemCommand) {
        broadcaster?.send(command)
    }
```

- [ ] **Step 2: ContextSheetView**

新建 `RemoteCrabCapture/ContextSheetView.swift`：

```swift
import SwiftUI
import RemoteCrabCore

/// Frontmost-app-aware shortcut sheet. Pure presentation over
/// ContextProfiles (RemoteCrabCore) — key actions replay Mac keyboard
/// events via engine.sendKey; console actions send IBSystemCommand.
struct ContextSheetView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss
    @State private var voice = VoiceRecognizer()
    @State private var voiceHeld = false

    private var profile: ContextProfile {
        ContextProfiles.profile(for: engine.frontmostMacApp)
    }

    var body: some View {
        ZStack {
            IBGradient.canvasDark.ignoresSafeArea()
            VStack(spacing: IBSpace.l.pt) {
                header
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(profile.actions.enumerated()), id: \.offset) { _, action in
                        actionButton(action)
                    }
                }
                Spacer()
                Text(IBLocale.Context.footer)
                    .font(IBFont.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(IBSpace.l.pt)
        }
        .onAppear {
            engine.requestMacApps()  // refresh the frontmost app
            voice.onFinal = { text in
                engine.sendVoiceText(text)
            }
            voice.onInterrupted = {
                voiceHeld = false
                engine.features.set(feature: .voice, enabled: false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.gradient)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.frontmostMacApp?.name ?? "Mac")
                    .font(IBFont.bodyMedium.weight(.semibold))
                    .foregroundStyle(.white)
                Text(profile.titleKey.uppercased())
                    .font(IBFont.eyebrowMono)
                    .ibEyebrowTracking()
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(IBSpace.s.pt + 2)
                    .background { IBMaterial.bar(in: Circle()) }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .buttonStyle(IBPressButtonStyle())
            .accessibilityLabel(IBLocale.A11y.close)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: ContextAction) -> some View {
        switch action {
        case .voiceHero(let label, let symbol):
            heroVoiceButton(label: label, symbol: symbol)
        case .key(let label, let symbol, let keycode, let modifiers):
            contextButton(label: label, symbol: symbol) {
                engine.sendKey(KeyEvent(action: .down, keycode: keycode, modifiers: modifiers))
                engine.sendKey(KeyEvent(action: .up, keycode: keycode, modifiers: modifiers))
            }
        case .system(let label, let symbol, let command):
            contextButton(label: label, symbol: symbol) {
                // launchApp carries its bundle id as the argument;
                // everything else is argument-less.
                let argument: String? = command == .launchApp ? "com.apple.Safari" : nil
                engine.sendSystemCommand(IBSystemCommand(command: command, argument: argument))
            }
        }
    }

    private func contextButton(label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                Text(label)
                    .font(IBFont.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(13)
            .background {
                IBMaterial.glass(in: RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous))
            }
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.96))
        .accessibilityLabel(label)
    }

    private func heroVoiceButton(label: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: voiceHeld)
            Text(voiceHeld ? IBLocale.Voice.releaseToSend : label)
                .font(IBFont.bodyMedium.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background {
            RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous)
                .fill(voiceHeld ? IBColor.recording.opacity(0.85) : Color.accentColor)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in startVoice() }
                .onEnded { _ in stopVoice() }
        )
        .accessibilityLabel(label)
    }

    private func startVoice() {
        guard !voiceHeld else { return }
        voiceHeld = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        engine.features.set(feature: .voice, enabled: true)
        Task { @MainActor in
            let started = await voice.start()
            if !started {
                voiceHeld = false
                engine.features.set(feature: .voice, enabled: false)
            } else if !voiceHeld {
                voice.stop()
            }
        }
    }

    private func stopVoice() {
        guard voiceHeld else { return }
        voiceHeld = false
        engine.features.set(feature: .voice, enabled: false)
        voice.stop()
    }
}
```

（注意：`IBLocale.A11y.close` 若已存在直接用，否则新增 + xcstrings 补 `"关闭"`。）

- [ ] **Step 3: ContentView 呈现 sheet**

`ContentView.swift` 的 sheet 组（`:90-116`）加：

```swift
        .sheet(isPresented: $engine.showContextSheet) {
            ContextSheetView()
                .environmentObject(engine)
                .presentationDetents([.large])
        }
```

（`engine` 是 `@ObservableObject`/`ObservableObject`，`@Published var showContextSheet` 可直接做 `$` 绑定——ContentView 里 engine 是 `@EnvironmentObject`，写 `$engine.showContextSheet` 合法。）

- [ ] **Step 4: 情境 chip 固定在两个快捷键行最左**

`TouchpadScreen.swift` 快捷键行（`:168-181`）改为 chip 在 ScrollView **外**、固定最左：

```swift
                HStack(spacing: IBSpace.s.pt) {
                    contextChip
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: IBSpace.s.pt) {
                            IBModifierBar(activeModifiers: $modifiers)
                            Rectangle()
                                .fill(IBColor.borderSubtle)
                                .frame(width: 1, height: 28)
                            quickKey(symbol: "delete.left", accessibility: IBLocale.A11y.deleteKey, keycode: 51)
                            quickKey(text: ",", accessibility: IBLocale.A11y.commaKey, keycode: 43)
                            quickKey(text: ".", accessibility: IBLocale.A11y.periodKey, keycode: 47)
                            quickKey(symbol: "return", accessibility: IBLocale.A11y.returnKey, keycode: 36, prominent: true)
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.bottom, dockClearance)
```

`contextChip`（TouchpadScreen 内新增；KeyboardScreen 同样加一份，或抽到 RemoteCrabCore Components——为最小改动，**两处各加同名私有 view**，共 ~20 行，避免动 Core 组件库）：

```swift
    /// Frontmost-app context chip, pinned left of the key row. Opens
    /// the context sheet (Task 7). Data: engine.frontmostMacApp.
    private var contextChip: some View {
        Button {
            engine.showContextSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                Text(engine.frontmostMacApp?.name ?? "Mac")
                    .font(IBFont.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background {
                IBMaterial.glass(
                    in: RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous),
                    tint: IBColor.accent,
                    interactive: true
                )
            }
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.9))
        .accessibilityLabel(IBLocale.Context.open)
    }
```

`KeyboardScreen.swift` 的 shortcutBar（`:195-216`）同法：chip 放 ScrollView 外最左（它已有 `@EnvironmentObject engine`，`:11`）。

- [ ] **Step 5: IBLocale + xcstrings**

`IBLocale.swift` 新增 section（放在 `Switcher` 后）：

```swift
    public enum Context {
        public static let open = IBL("App shortcuts")
        public static let footer = IBL("Buttons send keyboard or system events to your Mac")
    }
```

xcstrings 补 zh-Hans：`"App shortcuts"` → `"应用快捷键"`；`"Buttons send keyboard or system events to your Mac"` → `"按键将作为键盘或系统事件发送到 Mac"`。ContextSheetView 里的 action label（"Play / Exit" 等英文）走 `Text(verbatim:)` 或暂作 SF Symbol + 英文 label（V1.1 接受英文 label，本地化批次 V1.2 统一做——记入 AGENTS.md 待办）。

- [ ] **Step 6: 构建 + 提交**

```bash
./scripts/test.sh 2>&1 | tail -20
git add -A RemoteCrabCapture RemoteCrabCore
git commit -m "feat(ios): frontmost-app context sheet with presentation/agent/console suites"
```

---

### Task 8: 全量验证 + 文档

**Files:**
- Modify: `AGENTS.md`（wire 协议表加 0x19、iOS 布局段更新 dock 移除/顶栏开关/PTT 行/情境页、Mac 设置三项、AWDL）
- Modify: `README.md`（如有 dock / 界面结构描述）

- [ ] **Step 1: 全量测试**

```bash
./scripts/test.sh 2>&1 | tail -30
```
Expected: Core 全部测试（含新增 SystemCommandWireTests 3 + ContextProfilesTests 7）绿、两个 app target 编译通过。

- [ ] **Step 2: 视觉核对**

```bash
# 用模拟器跑三个 surface 截图核对底部布局（快捷键行不压 PTT 行、chip 固定）
./scripts/e2e-simulator.sh 2>&1 | tail -15   # 若环境允许
```
或至少 `xcodegen generate --spec project-ios.yml && open RemoteCrabCapture.xcodeproj` 后人工过一遍：触控板面 / 键盘面 / 相机面 / 情境页 / PiP。

- [ ] **Step 3: AGENTS.md 更新**

更新点：
1. Wire 协议表加 `systemCommand | 0x19 | iOS | JSON IBSystemCommand {command, argument?} — Mac 系统控制（音量/亮度/媒体键/启动 app）`。
2. Repository layout 的 iOS 文件列表：`FeatureDock.swift` 删除，加 `ContextSheetView.swift`；`RemoteCrabReceiver/` 加 `SystemCommandHandler.swift`；Core `State/` 加 `ContextProfiles.swift`。
3. iOS features 表：dock 描述改为「顶栏 📷/🎙 开关 + 底部 ⌨️+PTT 行 + 情境 chip」。
4. Mac features 表：设置加 launchAtLogin 已接线（SMAppService）/ autoReconnect 生效 / AWDL。
5. 「Things the next agent should know」加一条：dock 已移除的布局常量（dockClearance 76 / voiceCardBottomInset 132/72）与 V1.2 待办（激光笔、快速启动自定义、action label 本地化）。

- [ ] **Step 4: 提交**

```bash
git add AGENTS.md README.md
git commit -m "docs: AGENTS.md for V1.1 (dock removal, context sheet, systemCommand 0x19, AWDL)"
```

---

## Self-Review 记录

- Spec §1（dock 移除/顶栏开关/PTT 行/⏎/insets/相机面✕/键盘面出口）→ Task 6 全覆盖。
- Spec §2（情境 chip + sheet + 三套套件 + systemCommand）→ Task 1/2/7。偏离：音量/亮度用**步进按键**而非滑杆（Mac 无回读通道，步进与媒体键同一路径，YAGNI）；激光笔按 spec §4 不做；快速启动只内置 Safari 一项。
- Spec §3（Mac 三项）→ Task 4；AWDL iOS 侧 → Task 5。
- Kind 号从 spec 的 0x15 修正为 0x19（0x15-0x18 已占用）。
- `sendContextKey` 在 Task 7 Step 1 中取消（直接复用 `sendKey`，gate 语义一致）——计划内已说明，非遗留矛盾。
