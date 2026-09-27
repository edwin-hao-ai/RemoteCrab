# Mac 通知 → iPhone 中继 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Mac 弹出通知（排除隐私黑名单）时，把 `{app,title,subtitle,body}` 实时转发到 iPhone，iPhone 弹本地通知并进 App 内列表。

**Architecture:** Mac 端用 AX 轮询 `com.apple.notificationcenterui` 的横幅 → 纯逻辑黑名单过滤 → 新 wire 帧 `notification` (0x22) → iPhone 端 `UNUserNotificationCenter` + `@Observable` 列表。过滤在 Mac 端（隐私内容不上 wire）。

**Tech Stack:** Swift 6、Accessibility (AX) C API、UserNotifications、xcodegen、XCTest。

**Spec:** `docs/superpowers/specs/2026-09-28-mac-notification-relay-design.md`

## Global Constraints

- **尽力而为**：只抓"横幅"（实时）；勿扰/专注模式下抓不到；解析失败静默（`os_log` subsystem `com.remotecrab`），不影响主功能。
- **隐私**：过滤在 **Mac 端**；默认**开关关闭**；黑名单默认含敏感 App（中英文名）。
- **App 名是本地化字符串**（无 bundle id），黑名单按显示名匹配。
- 文案走 `IBLocale`（en + zh-Hans）；无 emoji；技术读数 SF Mono。
- 未明确要求不 commit（沿用本会话：允许在分支上 commit）。
- 不破坏现有 217 个 `RemoteCrabCore` 测试与两个 App 构建。

---

### Task 1: Wire 帧 `notification` (0x22) + 编解码 + 测试

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift`
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBWire.swift`
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEventBroadcaster.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/IBEventsTests.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/EventPipelineEndToEndTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct IBNotification: Codable, Sendable, Equatable {
      public let app: String        // source app display name (localized)
      public let title: String
      public let subtitle: String
      public let body: String
      public init(app: String, title: String, subtitle: String = "", body: String = "")
  }
  ```
  `IBWire.Kind.notification = 0x22`; `IBWire.encode(notification:) throws -> Data`;
  `IBWire.decodeNotification(_ frame: RawFrame) throws -> IBNotification`;
  `IBEventBroadcaster.send(_ n: IBNotification)` (Mac → iPhone).

- [ ] **Step 1: 失败测试（round-trip）** — 在 `IBEventsTests.swift` 加：

```swift
func testNotificationRoundTrip() throws {
    let n = IBNotification(app: "OpenCode", title: "Task finished",
                           subtitle: "session 3", body: "All tests passed")
    let frame = try IBWire.encode(notification: n)
    let decoded = try IBWire.decodeNotification(IBWire.Parser().parse(frame)!.first!)
    XCTAssertEqual(decoded, n)
}
```
（若 Parser 用法与现状不同，照 `IBEventsTests` 里既有的 decode 测试写法来。）

- [ ] **Step 2: 跑，确认 RED** — `swift test --package-path RemoteCrabCore --filter IBEventsTests`

- [ ] **Step 3: 实现**
  - `IBWire.Kind` 末尾加 `case notification = 0x22`。
  - `IBEvents.swift` 加 `IBNotification`（照 `IBClipboard` 的形状）。
  - `IBWire.swift` 加 `public static func encode(notification:) throws -> Data { try encodeFrame(kind: .notification, object: notification) }`（照现有 JSON encode helper）与 `decodeNotification`。
  - `IBEventBroadcaster.swift` 加 `public func send(_ n: IBNotification) { send(kind: .notification) { try IBWire.encode(notification: n) } }`。

- [ ] **Step 4: 跑，确认 GREEN**，并跑全量 `swift test --package-path RemoteCrabCore`。

- [ ] **Step 5: E2E 管道测试** — `EventPipelineEndToEndTests.swift` 加一条：sender 发 `IBNotification` → TCP → parser → 断言收到。

- [ ] **Step 6: Commit** — `feat(core): add IBNotification wire frame (0x22)`

---

### Task 2: `NotificationFilter` 纯逻辑 + 测试

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/State/NotificationFilter.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/NotificationFilterTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct NotificationFilter: Sendable {
      public static let defaultDenylist: [String]
      public let denylist: [String]
      public init(denylist: [String] = NotificationFilter.defaultDenylist)
      /// true = forward to iPhone. Case-insensitive substring match on app name.
      public func shouldRelay(app: String) -> Bool
  }
  ```

- [ ] **Step 1: 失败测试** — `NotificationFilterTests.swift`:

```swift
import XCTest
@testable import RemoteCrabCore

final class NotificationFilterTests: XCTestCase {
    func testAllowsUnknownApp() {
        XCTAssertTrue(NotificationFilter().shouldRelay(app: "OpenCode"))
    }
    func testBlocksDenylistedApp() {
        let f = NotificationFilter(denylist: ["Messages", "信息"])
        XCTAssertFalse(f.shouldRelay(app: "Messages"))
        XCTAssertFalse(f.shouldRelay(app: "信息"))
    }
    func testCaseInsensitive() {
        XCTAssertFalse(NotificationFilter(denylist: ["messages"]).shouldRelay(app: "Messages"))
    }
    func testEmptyDenylistAllowsAll() {
        XCTAssertTrue(NotificationFilter(denylist: []).shouldRelay(app: "Anything"))
    }
    func testDefaultDenylistCoversSensitiveApps() {
        let f = NotificationFilter()
        for app in ["Messages", "Mail", "信息", "邮件", "1Password", "WeChat", "微信"] {
            XCTAssertFalse(f.shouldRelay(app: app), app)
        }
    }
}
```

- [ ] **Step 2: 跑，确认 RED** — `swift test --package-path RemoteCrabCore --filter NotificationFilterTests`

- [ ] **Step 3: 实现**

```swift
import Foundation

/// Decides whether a captured Mac notification may be relayed to the
/// iPhone. Pure so the policy is unit-tested. Denylist-first: the user
/// asked to exclude privacy-sensitive apps and allow everything else
/// (we can't know what apps they install). App names are localized
/// strings with no bundle id, so matching is case-insensitive substring
/// on the display name (see the design's hard limits).
public struct NotificationFilter: Sendable {
    public static let defaultDenylist: [String] = [
        // Password managers / auth
        "1Password", "Keychain", "钥匙串", "Bitwarden", "LastPass", "Authy", "验证码",
        // Messaging / social
        "Messages", "信息", "Mail", "邮件", "WeChat", "微信", "Telegram",
        "WhatsApp", "Signal", "QQ",
        // Finance / banking
        "银行", "Bank", "支付宝", "Alipay", "微信支付", "PayPal", "Wallet", "钱包",
    ]

    public let denylist: [String]

    public init(denylist: [String] = NotificationFilter.defaultDenylist) {
        self.denylist = denylist
    }

    public func shouldRelay(app: String) -> Bool {
        let a = app.lowercased()
        return !denylist.contains { !$0.isEmpty && a.contains($0.lowercased()) }
    }
}
```

- [ ] **Step 4: 跑，确认 GREEN**

- [ ] **Step 5: Commit** — `feat(core): add NotificationFilter (denylist policy)`

---

### Task 3: Mac 采集器 `NotificationCapture` + 接线

**Files:**
- Create: `RemoteCrabReceiver/NotificationCapture.swift`
- Modify: `RemoteCrabReceiver/ReceiverSession.swift`（暴露发送入口 + 启动采集）
- Modify: `RemoteCrabReceiver/PreferencesView.swift`（开关 + 黑名单编辑）
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift` + catalog

**Interfaces:**
- Consumes: `IBNotification`, `IBEventBroadcaster.send(_:)`, `NotificationFilter`.
- Produces: `NotificationCapture`（`@MainActor final class`，`start()`/`stop()`）；设置项
  `remotecrab.mac.notifyRelay`（Bool，默认 false）、`remotecrab.mac.notifyDenylist`（[String]）。

- [ ] **Step 1: 采集器** — `NotificationCapture.swift`：
  - 每 0.5s 在后台队列用 AX 读 `com.apple.notificationcenterui` 的窗口，找
    `AXGroup`（`AXIdentifier` 含 `AXNotificationCenterBanner` 或 role=`AXNotificationCenterBanner`），
    其子 `AXStaticText` 里 `id ∈ {title,subtitle,body}` 取 `value`；
    App 名 = banner `AXDescription` 去掉标题/副标题/正文串后的前缀（trim 分隔符 `,，`）。
  - 去重：用 banner 的 `AXIdentifier`（UUID）存 `Set<String>`，带上限（如 200，FIFO 淘汰）。
  - 过滤：`NotificationFilter(denylist: UserDefaults…).shouldRelay(app:)`。
  - 发送：回调给 `ReceiverSession` → `broadcaster.send(IBNotification(...))`。
  - `os_log` subsystem `com.remotecrab`, category `notifycapture`；失败静默。
  - 不在前台/勿扰时自然读不到 → 跳过。

- [ ] **Step 2: 接线** — `ReceiverSession` 加 `startNotificationRelay()`（会话 accepted 后启动、断开停止），并在 `handleInbound` 不需要改（Mac 是发送方）。仅当 `notifyRelay` 开启时启动。

- [ ] **Step 3: 设置 UI** — `PreferencesView` 一个 Section：Toggle「转发通知到 iPhone」（绑 `remotecrab.mac.notifyRelay`，默认 off，开启时给说明文案）；黑名单编辑（列出当前项，可增删）。

- [ ] **Step 4: 文案** — `IBLocale` 加 `Notify` 段（en + zh-Hans；含说明"仅横幅、勿扰会漏、默认关"），catalog 补词条。

- [ ] **Step 5: 构建** — `xcodegen generate --spec project-mac.yml` + `xcodebuild … build CODE_SIGNING_ALLOWED=NO`。

- [ ] **Step 6: Commit** — `feat(mac): capture Mac notification banners and relay to iPhone`

---

### Task 4: iOS 接收 + 本地通知 + App 内列表 + 设置

**Files:**
- Create: `RemoteCrabCapture/NotificationStore.swift`（`@Observable` 列表 + 未读数）
- Create: `RemoteCrabCapture/LocalNotifier.swift`（`UNUserNotificationCenter` 权限 + 投递）
- Create: `RemoteCrabCapture/NotificationListView.swift`（列表 sheet）
- Modify: `RemoteCrabCapture/CaptureEngine.swift`（`handleInbound` 加 `case .notification`）
- Modify: `RemoteCrabCapture/ContentView.swift` 或 overflow 菜单（入口 + 未读角标）
- Modify: `RemoteCrabCore/.../IBLocale.swift` + catalog；`project-ios.yml`（若需通知权限无需额外 key）

**Interfaces:**
- Consumes: `IBNotification`（来自 Task 1）
- Produces: `NotificationStore`（`append(_:)`, `items`, `unread`）; `LocalNotifier.requestAuthorization()`, `post(_:)`.

- [ ] **Step 1: `NotificationStore`** — `@Observable final class`：`items: [IBNotification]`（带上限 100），`unread: Int`，`append`/`markAllRead`。

- [ ] **Step 2: `LocalNotifier`** — `requestAuthorization(options: [.alert,.sound])`；`post(_ n: IBNotification)` → `UNMutableNotificationContent`（title = app, body = 拼接 title/subtitle/body），`UNNotificationRequest` 立即触发。

- [ ] **Step 3: dispatch** — `CaptureEngine.handleInbound` 加 `case .notification:` → 解析 → `store.append` + `LocalNotifier.post`（权限未授予则只 store）。注意：`IBNotification` 已是结构体，decode 后直接分发。

- [ ] **Step 4: UI** — 列表 sheet（`NotificationListView`）+ 入口（overflow 菜单「通知」+ 未读角标）；App 启动请求一次通知权限（或在设置里）。

- [ ] **Step 5: 文案 + 构建** — `IBLocale`（en+zh-Hans）+ catalog；`xcodegen generate --spec project-ios.yml`；`xcodebuild … build CODE_SIGNING_ALLOWED=NO`。

- [ ] **Step 6: Commit** — `feat(ios): show relayed Mac notifications (local + in-app list)`

---

### Task 5: 端到端验证（真机/本机）

**Files:** 无（验证）。

- [ ] **Step 1:** `./scripts/test.sh` 全绿。
- [ ] **Step 2:** Mac 设置里开启转发；Mac 上 `osascript -e 'display notification "hello body" with title "Task done"'` → iPhone 收到本地通知 + 列表项（脚本编辑器/终端 来源）。
- [ ] **Step 3:** 把来源 App 名加入黑名单 → 再发 → **不再转发**。
- [ ] **Step 4:** 关闭开关 → 不转发。
- [ ] **Step 5:** 记录 lesson（AX 抓通知横幅的可行性与限制）+ 更新 AGENTS/roadmap。

---

## Self-Review
- **Spec coverage:** §5 架构 → T1(帧)/T3(Mac)/T4(iOS)；§6 组件 → 同名文件；§7 细节 → T3 解析/去重、T4 投递；§9 测试 → T1/T2 单测 + T5 手测；§10/§3 限制 → Global Constraints + 文案。
- **Placeholder scan:** 无 TBD；核心（帧、过滤）给了完整代码；AX/通知为机械实现给足接口与步骤。
- **Type consistency:** `IBNotification(app:title:subtitle:body:)`、`NotificationFilter.shouldRelay(app:)`、`Kind.notification=0x22` 在各任务一致。
- **未决**：Mac 端采集的 AX 细节以本会话探针输出为准（`AXNotificationCenterBanner` + `AXStaticText id=title/subtitle/body` + banner `desc` 前缀）。
