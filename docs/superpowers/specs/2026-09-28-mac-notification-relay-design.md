# Mac 通知 → iPhone 中继（Task Alerts）设计

_2026-09-28 · 目标：Mac 弹出通知时（排除隐私黑名单），把内容实时转发到 iPhone，
让用户在手机上看到"Mac 上的任务完成了"并切回来。_

## 1. 背景与动机

用户用 CLI/GUI agent（OpenCode / Codex / Claude Code）在 Mac 上跑长任务，结束后
Mac 弹一条通知。用户人不在 Mac 前，希望在 iPhone 上收到，再决定是否切回来检查。

需求方（本会话）已确认：
- **来源**：不接各工具 hook，而是**通用抓取 macOS 通知中心**（"适配尽可能多的 App"）。
- **转发范围**：**黑名单**（排除隐私敏感 App），其余尽量转发；可编辑。
- **iPhone 呈现**：**系统本地通知**（后台/锁屏可见）**+** App 内列表。

## 2. 可行性探针结论（2026-09-28，已实测）

用 AX 直接读 `com.apple.notificationcenterui`：

```
AXWindow/AXSystemDialog  title=Notification Center
  AXGroup/AXNotificationCenterBanner  desc=<App 名> <标题>, <副标题>, <正文>
     AXStaticText id=title    value=<标题>
     AXStaticText id=subtitle value=<副标题>
     AXStaticText id=body     value=<正文>
```

- `AXIsProcessTrusted=true`（App 已有无障碍权限，用于注入输入）。
- **title/subtitle/body 逐字段可读**；**来源 App 名**是 banner `desc` 的前缀。
- banner **转瞬即逝**（约 5 秒从 AX 消失）→ 必须**实时**抓（观察或轮询）。

## 3. 硬限制（必须在实现与文案里体现）

1. **只抓"横幅"**（实时）。错过的时间点、以及**勿扰/专注模式**下的通知**抓不到**
   （它们不进 AX 横幅）。抓"历史"需打开通知中心面板，不可靠，v1 不做。
2. **App 名是本地化字符串**（如"脚本编辑器"），**没有 bundle id** → 黑名单只能按
   **App 显示名**匹配，需覆盖各语言写法；漏列就漏拦。
3. AX UI 结构随 macOS 版本变化，属**尽力而为**，可能失效。

## 4. 非目标（v1）

- 抓通知历史 / 通知中心面板。
- 各工具 hook 集成（作为将来的补充，不在 v1）。
- 点击 iPhone 通知跳回 Mac 做动作（只读展示）。
- 富交互（回复、操作按钮）。

## 5. 架构

```
Mac (RemoteCrabReceiver)
  NotificationCapture  ── 轮询 com.apple.notificationcenterui 的 AXNotificationCenterBanner
        │  解析 {app,title,subtitle,body}；按 banner UUID 去重
        ▼
  NotificationFilter (纯, RemoteCrabCore)  ── 黑名单命中的丢弃；其余保留
        │  黑名单来自 `remotecrab.mac.notifyDenylist`（Mac 设置里可编辑）
        ▼
  IBEventBroadcaster.send(notification:)  ── 新帧 notification (0x22)
        │  TCP（现有连接）
        ▼
iPhone (RemoteCrabCapture)
  CaptureEngine.handleInbound(.notification)
        ├─ NotificationStore.append(...)        （App 内列表, @Observable）
        └─ UNUserNotificationCenter 本地通知     （后台/锁屏可见）
```

**过滤放 Mac 端**：隐私内容不进入 wire，比"全发到手机再过滤"更符合"纯本地、不泄露"。

## 6. 组件

| 组件 | 位置 | 职责 |
|---|---|---|
| `IBNotification` | `RemoteCrabCore/Networking/IBEvents.swift` | `{app,title,subtitle,body}` Codable |
| `Kind.notification = 0x22` | `IBWire.swift` | encode / decode |
| `NotificationFilter` | `RemoteCrabCore/State/` | 纯函数：`shouldRelay(app:denylist:) -> Bool`；默认黑名单常量 |
| `NotificationCapture` | `RemoteCrabReceiver/` | AX 轮询 NC 横幅 → 解析 → 过滤 → 发帧；去重 |
| `NotificationStore` | `RemoteCrabCapture/` | `@Observable` 列表 + 未读计数 |
| `LocalNotifier` | `RemoteCrabCapture/` | 封装 `UNUserNotificationCenter` 请求权限 + 投递 |
| Mac 设置 | `PreferencesView.swift` | 开关 + 黑名单编辑（增删） |
| iOS 设置/列表 | `IOSSettingsView.swift` + 一个 sheet | 开关 + 通知权限 + 列表 |

## 7. 数据流 / 关键细节

- **轮询**：每 0.5 s 读一次 NC 窗口里的 `AXNotificationCenterBanner`（探针证明可读）。
  用 banner 的 `AXIdentifier`（UUID）去重，记录已见集合（带上限，防增长）。
- **解析**：遍历 banner 子元素，收集 `id ∈ {title,subtitle,body}` 的 `AXStaticText.value`；
  App 名 = banner `desc` 去掉"标题/副标题/正文"拼出的尾串后的前缀（实现里按
  `desc` 与三字段做差集提取，稳健优先）。
- **过滤**：`NotificationFilter` 对 App 名做**不区分大小写**的黑名单包含匹配。
  默认黑名单（示例，可编辑）：信息/Messages、邮件/Mail、1Password、Keychain、
  银行/支付类、微信/WeChat、Telegram 等。**只在 Mac 端过滤**。
- **投递（iOS）**：`UNUserNotificationCenter.add` 用 `title="<app> 完成"`? 更准确：
  `title = app`，`body = title + (subtitle) + body`。权限未授予时只进 App 内列表。
- **去重/限流**：同一 banner UUID 只发一次；对同 App 高频通知做最小间隔合并（可选）。

## 8. 错误处理

- AX 读失败/NC 进程缺失：静默，重试（`os_log` `com.remotecrab`），不影响主功能。
- 通知权限被拒：只保留 App 内列表，设置里显示"去系统设置开启"。
- 断连时捕获到的通知：丢弃（v1 不做离线补发）——需在文案里说明。

## 9. 测试

- `NotificationFilterTests`：黑名单命中/未命中、大小写、空名单、默认名单含敏感项。
- `IBEventsTests`：`IBNotification` round-trip。
- `EventPipelineEndToEndTests`：notification 帧经 TCP → parser → iOS 侧回调。
- `./scripts/test.sh` 全绿。
- 手测：Mac 用 `osascript -e 'display notification …'` 发通知 → iPhone 收到本地通知 +
  列表项；把来源 App 名加入黑名单 → 不再转发。

## 10. 风险

| 风险 | 缓解 |
|---|---|
| AX 结构随系统更新失效 | 尽力而为；解析失败静默、可降级为只报 App 名；在 lesson 里记清 |
| App 名本地化导致黑名单漏拦 | 文案说明；默认名单覆盖中英文常见写法；允许用户自加 |
| 勿扰下抓不到 | 文案说明"勿扰/专注时会漏" |
| 高频通知刷屏 | 去重 + 最小间隔合并 |
| 隐私（把验证码等推到手机） | 默认黑名单 + Mac 端过滤 + 开关默认？——见 §11 |

## 11. 默认值（已定）

- **开关默认关**：隐私优先，用户在 Mac 设置里主动开启；开启时文案说明"仅转发非黑名单
  App 的通知、勿扰/专注时会漏、关掉即停止"。
- 黑名单初始内容以"隐私敏感"为准（信息/邮件/密码管理器/银行/支付/IM 等），中英文都列；
  用户可增删。
