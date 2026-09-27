# Mac 自动更新（Sparkle 2）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Developer ID 分发的 Mac App 自动检查、后台下载，并在无活跃 iPhone 会话时静默安装并重启。

**Architecture:** 用 Sparkle 2（SPM，Embed & Sign）驱动更新；`UpdaterController` 持有 `SPUStandardUpdaterController`，通过 `SPUUpdaterDelegate.willInstallUpdateOnQuit` 返回 `true` 截获静默安装 block，由纯逻辑 `UpdateInstallGate` 决定"空闲够久"后再调用 block。扩展/驱动版本冻结。

**Tech Stack:** Swift 6.2、SwiftUI、Sparkle 2、xcodegen、XCTest、bash。

**Spec:** `docs/superpowers/specs/2026-09-27-mac-auto-update-design.md`

## Global Constraints

- v1 **只更新 App 本体**；系统扩展（相机）与 HAL 麦克风驱动的 `CFBundleVersion` **保持冻结**（当前分别 8 / 2）。
- 静默：无任何更新对话框；只有菜单栏可选的"检查更新"入口。
- 安装时机：无活跃会话（`sessionGranted == false`）且未录音，且连续空闲 ≥ `dwell`（默认 **30 秒**）。
- `RemoteCrabReceiver` 的 `CFBundleVersion` 每次发版必须**单调递增**；`CFBundleShortVersionString` 为营销版本。
- 错误只 `os_log`（subsystem `com.remotecrab`），**绝不**把原始 `NWError`/POSIX 错误显示给用户。
- 私钥永不入库；公钥可入库。UI 文案一律走 `IBLocale`（en 源 + zh-Hans），无 emoji。
- 未经明确要求不 commit；每个任务末尾的 commit 步骤仅在用户允许提交时执行。

---

### Task 1: 接入 Sparkle 2 依赖并嵌入

**Files:**
- Modify: `project-mac.yml`（`packages:` 段 + `RemoteCrabReceiver` target 的 `dependencies:` + `settings.base`）

**Interfaces:**
- Consumes: 无
- Produces: 构建产物 `RemoteCrab.app/Contents/Frameworks/Sparkle.framework`，后续任务 `import Sparkle` 可用。

- [ ] **Step 1: 加 SPM 依赖**

在 `project-mac.yml` 的 `packages:` 下（`RemoteCrabCore` 之后）加：

```yaml
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0
```

在 `RemoteCrabReceiver` target 的 `dependencies:` 列表末尾加：

```yaml
      - package: Sparkle
        product: Sparkle
        embed: true
        codeSign: true
```

在 `RemoteCrabReceiver` target 的 `settings.base` 里加 runpath：

```yaml
        LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"
```

- [ ] **Step 2: 重新生成工程并构建**

Run:
```bash
cd /Users/edwinhao/iBridge
xcodegen generate --spec project-mac.yml
xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrabReceiver \
  -configuration Debug -derivedDataPath .build/ci-derived-data/mac \
  build CODE_SIGNING_ALLOWED=NO
```
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 3: 确认 framework 真的被嵌入**

Run:
```bash
find ~/Library/Developer/Xcode/DerivedData .build/ci-derived-data -name Sparkle.framework -path '*RemoteCrab.app*' 2>/dev/null | head
```
Expected: 至少一条路径，形如 `.../RemoteCrab.app/Contents/Frameworks/Sparkle.framework`。

若没有：xcodegen 的 package `embed` 未生效，改为在 `RemoteCrabReceiver` target 增加一个 copy-files build phase（`xcodegen` 的 `postCompileScripts` 或 `dependencies` 的显式 `embed` 语法），直到 Step 3 通过。

- [ ] **Step 4: 定位 Sparkle 命令行工具（供 Task 2/6 使用）**

Run:
```bash
find .build/ci-derived-data ~/Library/Developer/Xcode/DerivedData \
  -path '*sparkle*/bin/generate_appcast' 2>/dev/null | head
```
Expected: 一条路径。记下它（Task 2 的 `generate_keys` 同目录，Task 6 会用到）。

- [ ] **Step 5: Commit（用户允许时）**

```bash
git add project-mac.yml
git commit -m "build(mac): add Sparkle 2 via SPM and embed it"
```

---

### Task 2: 生成 EdDSA 密钥 + 写入 Info.plist

**Files:**
- Modify: `project-mac.yml`（`RemoteCrabReceiver` target `info.properties`）

**Interfaces:**
- Consumes: Task 1 的 Sparkle `bin/`
- Produces: `SUPublicEDKey` / `SUFeedURL` / `SUEnableAutomaticChecks` 进入构建后的 `Info.plist`。

- [ ] **Step 1: 生成密钥（一次性，人工）**

用 Task 1 Step 4 找到的 `bin/` 目录：

Run:
```bash
"<sparkle-bin>/generate_keys -p
```
Expected: 打印一个 base64 公钥（例如 `kQx...==`），并把私钥存入登录钥匙串。
**私钥不要写入任何文件或提交**；如需备份，存到 `~/.config/remotecrab/`（0600），加入 `.gitignore`。

- [ ] **Step 2: 写 Info.plist keys**

在 `project-mac.yml` 的 `RemoteCrabReceiver` → `info.properties` 里加（把公钥替换为 Step 1 的值）：

```yaml
        SUPublicEDKey: "<Step 1 的公钥>"
        SUFeedURL: https://vgoapp.com/downloads/appcast.xml
        SUEnableAutomaticChecks: true
```

- [ ] **Step 3: 重新生成并验证 plist**

Run:
```bash
cd /Users/edwinhao/iBridge
xcodegen generate --spec project-mac.yml
xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrabReceiver \
  -configuration Debug -derivedDataPath .build/ci-derived-data/mac \
  build CODE_SIGNING_ALLOWED=NO
APP="$(find .build/ci-derived-data -name RemoteCrab.app -path '*Debug*' | head -1)"
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist"
```
Expected: 分别打印公钥与 `https://vgoapp.com/downloads/appcast.xml`。

- [ ] **Step 4: Commit（用户允许时）**

```bash
git add project-mac.yml
git commit -m "build(mac): add Sparkle feed URL + EdDSA public key to Info.plist"
```

---

### Task 3: `UpdateInstallGate` 纯逻辑（TDD）

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/State/UpdateInstallGate.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/UpdateInstallGateTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  ```swift
  public struct UpdateInstallGate: Sendable {
      public init(dwell: TimeInterval = 30)
      public let dwell: TimeInterval
      public func shouldInstall(pendingUpdate: Bool, sessionActive: Bool,
                                isRecording: Bool, idleSince: Date?, now: Date) -> Bool
  }
  ```

- [ ] **Step 1: 写失败测试**

创建 `RemoteCrabCore/Tests/RemoteCrabCoreTests/UpdateInstallGateTests.swift`：

```swift
import XCTest
@testable import RemoteCrabCore

final class UpdateInstallGateTests: XCTestCase {
    private let gate = UpdateInstallGate(dwell: 30)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoPendingUpdateNeverInstalls() {
        XCTAssertFalse(gate.shouldInstall(pendingUpdate: false, sessionActive: false,
                                          isRecording: false, idleSince: t0, now: t0.addingTimeInterval(60)))
    }

    func testActiveSessionBlocks() {
        XCTAssertFalse(gate.shouldInstall(pendingUpdate: true, sessionActive: true,
                                          isRecording: false, idleSince: t0, now: t0.addingTimeInterval(60)))
    }

    func testRecordingBlocks() {
        XCTAssertFalse(gate.shouldInstall(pendingUpdate: true, sessionActive: false,
                                          isRecording: true, idleSince: t0, now: t0.addingTimeInterval(60)))
    }

    func testIdleSinceNilBlocks() {
        XCTAssertFalse(gate.shouldInstall(pendingUpdate: true, sessionActive: false,
                                          isRecording: false, idleSince: nil, now: t0))
    }

    func testBeforeDwellBlocks() {
        XCTAssertFalse(gate.shouldInstall(pendingUpdate: true, sessionActive: false,
                                          isRecording: false, idleSince: t0, now: t0.addingTimeInterval(29)))
    }

    func testExactlyAtDwellInstalls() {
        XCTAssertTrue(gate.shouldInstall(pendingUpdate: true, sessionActive: false,
                                         isRecording: false, idleSince: t0, now: t0.addingTimeInterval(30)))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --package-path RemoteCrabCore --filter UpdateInstallGateTests`
Expected: 编译失败，`cannot find 'UpdateInstallGate' in scope`。

- [ ] **Step 3: 实现**

创建 `RemoteCrabCore/Sources/RemoteCrabCore/State/UpdateInstallGate.swift`：

```swift
import Foundation

/// Decides whether a downloaded-but-not-yet-installed update may be
/// installed now (silent install + relaunch). Pure, so the "when is it
/// idle enough" policy is unit-tested instead of buried in the app.
public struct UpdateInstallGate: Sendable {

    /// How long the session must stay inactive before we install.
    public let dwell: TimeInterval

    public init(dwell: TimeInterval = 30) {
        self.dwell = dwell
    }

    public func shouldInstall(
        pendingUpdate: Bool,
        sessionActive: Bool,
        isRecording: Bool,
        idleSince: Date?,
        now: Date
    ) -> Bool {
        guard pendingUpdate, !sessionActive, !isRecording, let idleSince else { return false }
        return now.timeIntervalSince(idleSince) >= dwell
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --package-path RemoteCrabCore --filter UpdateInstallGateTests`
Expected: 6 tests PASS。

- [ ] **Step 5: Commit（用户允许时）**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/UpdateInstallGate.swift \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/UpdateInstallGateTests.swift
git commit -m "feat(core): add UpdateInstallGate for idle-gated installs"
```

---

### Task 4: `UpdaterController` + 会话空闲信号 + App 接线

**Files:**
- Modify: `RemoteCrabReceiver/ReceiverSession.swift`（加 `static let shared`、`isSessionActive`）
- Create: `RemoteCrabReceiver/UpdaterController.swift`
- Modify: `RemoteCrabReceiver/RemoteCrabReceiverApp.swift`（用 shared session；在 `init()` attach updater）

**Interfaces:**
- Consumes: `UpdateInstallGate`（Task 3）、`RemoteCrabReceiver/ReceiverSession`（既有 `@Published state`、`isRecording`）
- Produces:
  ```swift
  @MainActor final class UpdaterController: NSObject, ObservableObject {
      static let shared: UpdaterController
      @Published private(set) var pendingUpdate: Bool
      func attach(session: ReceiverSession)
      func checkForUpdates()
      func installNow()
      var automaticallyChecksForUpdates: Bool { get set }
  }
  ```

- [ ] **Step 1: `ReceiverSession` 暴露共享实例与活跃状态**

在 `RemoteCrabReceiver/ReceiverSession.swift` 类体顶部（`enum State` 之前）加：

```swift
    /// App-lifetime singleton: the receiver is a menu-bar app with exactly
    /// one session, and the updater needs a stable reference to read idle
    /// state without depending on any view's lifetime.
    static let shared = ReceiverSession()
```

在 `private var sessionGranted = false` 附近加一个同模块可读的计算属性：

```swift
    /// True while a Mac/iPhone session is owned. Read by `UpdaterController`
    /// to gate silent installs (an active session must not be interrupted).
    var isSessionActive: Bool { sessionGranted }
```

- [ ] **Step 2: 建 `UpdaterController`**

创建 `RemoteCrabReceiver/UpdaterController.swift`：

```swift
import Foundation
import Combine
import Sparkle
import os

/// Owns Sparkle and decides *when* a silently-downloaded update gets
/// installed. The policy is "only while the phone is idle"; the hard part
/// (download, verify, atomic replace, relaunch) is Sparkle's.
@MainActor
final class UpdaterController: NSObject, ObservableObject {

    static let shared = UpdaterController()

    /// True once an update has been downloaded and is waiting for an idle
    /// window (drives the menu-bar "Restart to Update" row).
    @Published private(set) var pendingUpdate = false

    /// Sparkle's silent-install handler, stashed until we're idle.
    private var installHandler: (() -> Void)?

    private var controller: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()
    private var idleSince: Date?
    private var ticker: Timer?
    private let gate = UpdateInstallGate(dwell: 30)
    private weak var session: ReceiverSession?

    private static let log = Logger(subsystem: "com.remotecrab", category: "updater")

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
    }

    /// Called once from the App; idempotent.
    func attach(session: ReceiverSession) {
        guard self.session == nil else { return }
        self.session = session
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Menu-bar "Restart to Update" — bypass the idle wait on explicit tap.
    func installNow() {
        guard let handler = installHandler else { return }
        Self.log.info("installing pending update on explicit request")
        stopTicker()
        handler()
    }

    // MARK: - Idle gating

    private func beginWaitingForIdle() {
        guard ticker == nil else { return }
        // Low-frequency poll, and only while an update is pending — no
        // always-on timer (project rule: no idle high-frequency ticks).
        ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateIdle() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func evaluateIdle() {
        guard let session, installHandler != nil else { stopTicker(); return }
        let now = Date()
        let active = session.isSessionActive
        let recording = session.isRecording
        if active || recording {
            idleSince = nil
            return
        }
        if idleSince == nil { idleSince = now }
        if gate.shouldInstall(pendingUpdate: true, sessionActive: active,
                              isRecording: recording, idleSince: idleSince, now: now) {
            Self.log.info("installing pending update while idle")
            let handler = installHandler
            stopTicker()
            handler?()
        }
    }
}

extension UpdaterController: SPUUpdaterDelegate {
    /// Sparkle downloaded an update and would install it on quit. We take
    /// control (return true) so we can install at an idle moment instead;
    /// if the user quits first, Sparkle still installs on termination.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            Self.log.info("update downloaded; waiting for an idle window")
            installHandler = immediateInstallHandler
            pendingUpdate = true
            beginWaitingForIdle()
            return true
        }
    }

    /// Test hook: `REMOTECRAB_UPDATE_FEED` overrides the feed URL so a
    /// local appcast can exercise the flow headlessly.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["REMOTECRAB_UPDATE_FEED"]
    }
}

extension UpdaterController: SPUStandardUserDriverDelegate {
    /// Required for menu-bar / LSUIElement apps; without it Sparkle logs a
    /// "gentle reminders unsupported" warning.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
```

- [ ] **Step 3: App 接线**

在 `RemoteCrabReceiver/RemoteCrabReceiverApp.swift`：

把 `@StateObject private var session = ReceiverSession()` 改为：

```swift
    @StateObject private var session = ReceiverSession.shared
```

在 `init()` 末尾（`AXIsProcessTrustedWithOptions` 之后）加：

```swift
        UpdaterController.shared.attach(session: ReceiverSession.shared)
```

在 `AppDelegate.applicationDidFinishLaunching` 末尾加一行，确保即使 root window 未出现也已启动 updater：

```swift
        _ = UpdaterController.shared
```

- [ ] **Step 4: 构建验证**

Run:
```bash
cd /Users/edwinhao/iBridge
xcodegen generate --spec project-mac.yml
xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrabReceiver \
  -configuration Debug -derivedDataPath .build/ci-derived-data/mac \
  build CODE_SIGNING_ALLOWED=NO
```
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 5: Commit（用户允许时）**

```bash
git add RemoteCrabReceiver/ReceiverSession.swift RemoteCrabReceiver/UpdaterController.swift \
        RemoteCrabReceiver/RemoteCrabReceiverApp.swift
git commit -m "feat(mac): add Sparkle UpdaterController with idle-gated silent install"
```

---

### Task 5: 菜单栏入口 + 偏好开关 + 文案

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift`（加 `Update` 段）
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings`（加 4 条 en+zh-Hans）
- Modify: `RemoteCrabReceiver/MenuBarMenu.swift`（actions 段加两行、footer 版本行保留）
- Modify: `RemoteCrabReceiver/PreferencesView.swift`（General 加开关）
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/LocalizationCatalogTests.swift`

**Interfaces:**
- Consumes: `UpdaterController`（Task 4）、`IBLocale`
- Produces: `IBLocale.Update.checkForUpdates/restartToUpdate/autoUpdate/autoUpdateDescription`

- [ ] **Step 1: 写失败测试（校验文案存在且双语）**

创建 `RemoteCrabCore/Tests/RemoteCrabCoreTests/LocalizationCatalogTests.swift`：

```swift
import XCTest
@testable import RemoteCrabCore

final class LocalizationCatalogTests: XCTestCase {

    private func catalog() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
            "Localizable.xcstrings missing from bundle"
        )
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    func testUpdateKeysAreBilingual() throws {
        let keys = [
            IBLocale.Update.checkForUpdates,
            IBLocale.Update.restartToUpdate,
            IBLocale.Update.autoUpdate,
            IBLocale.Update.autoUpdateDescription,
        ]
        let strings = try catalog()
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertNotNil(locs["en"], "missing en: \(key)")
            XCTAssertNotNil(locs["zh-Hans"], "missing zh-Hans: \(key)")
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --package-path RemoteCrabCore --filter LocalizationCatalogTests`
Expected: 编译失败（`IBLocale.Update` 不存在）。

- [ ] **Step 3: 加 `IBLocale.Update`**

在 `IBLocale.swift` 里（`Mirror` 段之后）加：

```swift
    /// Mac 自动更新（Sparkle）相关文案。
    public enum Update {
        public static let checkForUpdates = IBL("Check for Updates…")
        public static let restartToUpdate = IBL("Restart to Update")
        public static let autoUpdate = IBL("Automatically check for updates")
        public static let autoUpdateDescription = IBL("Download and install new versions in the background.")
    }
```

- [ ] **Step 4: 加 catalog 词条**

在 `Localizable.xcstrings` 的 `"strings"` 对象里加四条（各自 en + zh-Hans，`extractionState: "manual"`）：

```json
    "Check for Updates…": {
      "extractionState": "manual",
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Check for Updates…" } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "检查更新…" } }
      }
    },
    "Restart to Update": {
      "extractionState": "manual",
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Restart to Update" } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "重启以更新" } }
      }
    },
    "Automatically check for updates": {
      "extractionState": "manual",
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Automatically check for updates" } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "自动检查更新" } }
      }
    },
    "Download and install new versions in the background.": {
      "extractionState": "manual",
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Download and install new versions in the background." } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "在后台下载并安装新版本，不打断使用。" } }
      }
    },
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --package-path RemoteCrabCore --filter LocalizationCatalogTests`
Expected: PASS。

- [ ] **Step 6: 菜单栏加两行**

在 `MenuBarMenu.swift` 的 `actionsSection`（`VStack`，见 `ActionRow(icon: "gear"...)` 之前）加：

```swift
            ActionRow(icon: "arrow.triangle.2.circlepath",
                      title: LocalizedStringKey(IBLocale.Update.restartToUpdate),
                      shortcut: "",
                      help: LocalizedStringKey(IBLocale.Update.restartToUpdate),
                      action: { UpdaterController.shared.installNow() })
                .opacity(UpdaterController.shared.pendingUpdate ? 1 : 0)
            ActionRow(icon: "arrow.down.circle",
                      title: LocalizedStringKey(IBLocale.Update.checkForUpdates),
                      shortcut: "",
                      help: LocalizedStringKey(IBLocale.Update.checkForUpdates),
                      action: { UpdaterController.shared.checkForUpdates() })
```

> 说明：pending 行用 `.opacity` 而非 `if`，因为 `MenuBarExtra(.window)` 会在内容高度变化时重排（lesson #14）。`UpdaterController.shared.pendingUpdate` 变化不会自动刷新这个视图——在 `MenuBarMenu` 顶部加 `@StateObject private var updater = UpdaterController.shared` 并读 `updater.pendingUpdate` 即可获得刷新（`@StateObject` 订阅 `@Published`）。

- [ ] **Step 7: 偏好加开关**

在 `PreferencesView.swift` 的 `generalTab` 的 `Form` 一个 `Section` 里加：

```swift
                Toggle(IBLocale.Update.autoUpdate,
                       isOn: Binding(
                           get: { UpdaterController.shared.automaticallyChecksForUpdates },
                           set: { UpdaterController.shared.automaticallyChecksForUpdates = $0 }
                       ))
                    .accessibilityHint(IBLocale.Update.autoUpdateDescription)
```

- [ ] **Step 8: 构建 + 全量测试**

Run:
```bash
cd /Users/edwinhao/iBridge
xcodegen generate --spec project-mac.yml
./scripts/test.sh
```
Expected: `RemoteCrabCore` 全部测试通过 + 两个 App target 构建成功。

- [ ] **Step 9: Commit（用户允许时）**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift \
        RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings \
        RemoteCrabCore/Tests/RemoteCrabCoreTests/LocalizationCatalogTests.swift \
        RemoteCrabReceiver/MenuBarMenu.swift RemoteCrabReceiver/PreferencesView.swift
git commit -m "feat(mac): add Check for Updates / Restart to Update UI + auto-update toggle"
```

---

### Task 6: 发布流水线（签名 Sparkle + zip + appcast）

**Files:**
- Modify: `scripts/release-mac.sh`
- Create: `scripts/make-appcast.sh`

**Interfaces:**
- Consumes: Task 1 的 Sparkle `bin/`（`generate_appcast`）、Task 2 的私钥
- Produces: `dist/appcast/appcast.xml` + `dist/RemoteCrab-<version>.zip`

- [ ] **Step 1: 在 release-mac.sh 的 `[3/5]` 重签块里补签 Sparkle**

在 `scripts/release-mac.sh` 的 `codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" --entitlements "$ROOT/RemoteCrabReceiver/RemoteCrabReceiver.entitlements" "$APP"` 这一行**之前**插入：

```bash
  # Sparkle.framework 及其嵌套二进制必须用 Developer ID 重签，
  # 且在公证之前（否则公证因未签名二进制失败）。不要用 --deep。
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE" ]]; then
    for svc in Installer Downloader; do
      s="$SPARKLE/Versions/B/XPCServices/$svc.xpc"
      [[ -d "$s" ]] && codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$s"
    done
    [[ -f "$SPARKLE/Versions/B/Autoupdate" ]] && \
      codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$SPARKLE/Versions/B/Autoupdate"
    [[ -d "$SPARKLE/Versions/B/Updater.app" ]] && \
      codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$SPARKLE/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$SPARKLE"
  fi
```

- [ ] **Step 2: 在 `[5/5] DMG` 之后产出更新用的 zip**

在 `scripts/release-mac.sh` 的 `xcrun stapler validate "$DMG"` 之后、最终 echo 之前加：

```bash
# --- 6. Sparkle 更新包（App-only zip，签名/公证已在 app.zip 阶段完成） ---
echo "==> [6/6] build the Sparkle update zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/RemoteCrab-${VERSION}.zip"
echo "   zip: $OUT/RemoteCrab-${VERSION}.zip"
```

- [ ] **Step 3: 建 `scripts/make-appcast.sh`**

创建 `scripts/make-appcast.sh`：

```bash
#!/usr/bin/env bash
#
# 生成 Sparkle appcast.xml（EdDSA 签名，私钥取自登录钥匙串）。
#
# Usage:
#   ./scripts/make-appcast.sh 1.0
#   SPARKLE_GENERATE_APPCAST=/path/to/generate_appcast ./scripts/make-appcast.sh 1.0
#
# 前置：dist/RemoteCrab-<version>.zip 已由 scripts/release-mac.sh 产出。
set -euo pipefail

VERSION="${1:?Usage: make-appcast.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$ROOT/dist/RemoteCrab-${VERSION}.zip"
APPDIR="$ROOT/dist/appcast"
BASE_URL="${REMOTECRAB_DOWNLOAD_BASE:-https://vgoapp.com/downloads/}"

[[ -f "$ZIP" ]] || { echo "missing $ZIP — run scripts/release-mac.sh $VERSION first" >&2; exit 1; }

GEN="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$GEN" ]]; then
  GEN="$(find "$ROOT/.build" "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*sparkle*/bin/generate_appcast' 2>/dev/null | head -1)"
fi
[[ -x "$GEN" ]] || { echo "generate_appcast not found; set SPARKLE_GENERATE_APPCAST" >&2; exit 1; }

# 只保留最新一个包，appcast 只含一条最新记录。
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
cp "$ZIP" "$APPDIR/"

"$GEN" --download-url-prefix "$BASE_URL" "$APPDIR"

echo ""
echo "✅ appcast: $APPDIR/appcast.xml"
echo "   上传（沿用 VPS 的 cat|ssh 更稳）："
echo "   cat '$APPDIR/appcast.xml' | ssh <vps> 'cat > /var/www/vgoapp/downloads/appcast.xml'"
echo "   cat '$ZIP'                | ssh <vps> 'cat > /var/www/vgoapp/downloads/RemoteCrab-${VERSION}.zip'"
```

- [ ] **Step 4: 赋可执行权限并做语法检查**

Run:
```bash
chmod +x /Users/edwinhao/iBridge/scripts/make-appcast.sh
bash -n /Users/edwinhao/iBridge/scripts/make-appcast.sh
bash -n /Users/edwinhao/iBridge/scripts/release-mac.sh
```
Expected: 无输出（语法 OK）。

- [ ] **Step 5: Commit（用户允许时）**

```bash
git add scripts/release-mac.sh scripts/make-appcast.sh
git commit -m "build(mac): sign Sparkle, produce update zip + EdDSA appcast"
```

---

### Task 7: 端到端验证（真机 / 本地 appcast）

**Files:** 无（验证任务）

**Interfaces:**
- Consumes: Task 1-6
- Produces: 一份验证记录（扩展未失授权、静默安装成功）。

- [ ] **Step 1: 造一个更高的构建号**

把 `project-mac.yml` 里 `RemoteCrabReceiver` 的 `CFBundleVersion` 从 `1` 改为 `2`，重新 `xcodegen generate` + 构建（不要 commit 这个临时改动，验证后还原）：

```bash
cd /Users/edwinhao/iBridge
# 临时改 CFBundleVersion: 1 -> 2，然后
xcodegen generate --spec project-mac.yml
```

- [ ] **Step 2: 起本地 feed**

把当前（build 1）签名后的 app 的 zip 作为"旧版"安装在本机；把 build 2 的 zip 放进一个临时目录并生成 appcast：

```bash
GEN="<Task 1 找到的 generate_appcast>"
mkdir -p /tmp/rc-feed && cp dist/RemoteCrab-<ver>.zip /tmp/rc-feed/
"$GEN" --download-url-prefix "http://127.0.0.1:8766/" /tmp/rc-feed
( cd /tmp/rc-feed && python3 -m http.server 8766 )
```

- [ ] **Step 3: 让本地 App 指向本地 feed**

Run（终端里直接跑已安装的 App）：
```bash
REMOTECRAB_UPDATE_FEED="http://127.0.0.1:8766/appcast.xml" \
  /Applications/RemoteCrab.app/Contents/MacOS/RemoteCrab
```
Expected（`log stream --predicate 'subsystem == "com.remotecrab"' --info` 观察）：
1. 出现 Sparkle 的下载完成 → `update downloaded; waiting for an idle window`。
2. 保证没有 iPhone 连接、没有录音；约 30 秒后出现 `installing pending update while idle`。
3. App 自动重启，菜单栏 footer 版本/build 变为新值。

- [ ] **Step 4: 确认系统扩展授权未被重置**

重启后跑一个相机权限的探针（或打开 FaceTime/Photo Booth 列表），确认 `RemoteCrab Camera` 仍在且可用；`SetupStatus` 显示的相机扩展状态为已激活。
Expected: 扩展无需重新授权（扩展 `CFBundleVersion` 未变）。

- [ ] **Step 5: 全量回归**

Run: `./scripts/test.sh`
Expected: 全绿。

- [ ] **Step 6: 完成记录**

在 `AGENTS.md` 的 "State of the world" 追加一条 lesson：Sparkle 静默更新上线、空闲门控、扩展/驱动冻结的约束。还原 Step 1 的临时 `CFBundleVersion` 改动（除非本次就是发版）。

---

## Self-Review

**Spec coverage:**
- §3 D1 静默全自动 → Task 4（`automaticallyDownloadsUpdates` + `willInstallUpdateOnQuit` 返回 true）、Task 7 验证。
- §3 D2 App-only / 冻结扩展驱动 → Global Constraints + Task 7 Step 4。
- §3 D3 Sparkle 2 → Task 1。
- §3 D4 空闲重启 → Task 3 + Task 4 `evaluateIdle`。
- §5 机制 → Task 4 Step 2。
- §6 空闲判定 → Task 3。
- §7 发布流水线（版本递增、zip、appcast、部署）→ Task 6 + Task 7 Step 1。
- §8 签名与安全 → Task 6 Step 1（重签顺序）、Task 2（公钥/私钥）。
- §9 错误处理 → UpdaterController 只 os_log，无 UI 错误路径。
- §10 测试 → Task 3 单测、Task 5 本地化测试、Task 7 端到端、全量 `test.sh`。
- §11 风险（扩展授权、二次重签）→ Task 6 Step 1 + Task 7 Step 4。

**Placeholder scan:** 无 TBD/TODO；每个代码步骤都有完整代码块。

**Type consistency:** `UpdateInstallGate.shouldInstall(pendingUpdate:sessionActive:isRecording:idleSince:now:)` 在 Task 3 定义、Task 4 `evaluateIdle` 调用，签名一致；`UpdaterController` 的 `attach/checkForUpdates/installNow/automaticallyChecksForUpdates/pendingUpdate` 在 Task 4 定义、Task 5 调用，一致；`IBLocale.Update.*` 四键在 Task 5 定义并被自身测试引用，一致。
