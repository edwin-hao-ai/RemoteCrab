# Mac 自动更新（Sparkle 2）设计

_2026-09-27 · F1 · 目标：Developer ID 分发的 Mac App 能自动发现、下载、安装新版本，用户几乎无感_

## 1. 问题

Mac 端走 Developer ID（公证 DMG，`vgoapp.com/downloads/RemoteCrab.dmg`），
不是 MAS —— **没有自动更新，也没有新版本发现**。用户装完 1.0 后永远停在 1.0，
除非自己想起来去官网重新下载。iOS 端有 App Store 自动更新，两侧版本会越差越远。

同时协议层没有任何版本协商（`clientHello.appVersion` 发出去但从不被读），
所以老 Mac + 新 iOS 只是"能连、新功能静默 no-op"。让 Mac 能自动升级，是这个
兼容性问题目前最便宜的解法。

## 2. 目标 / 非目标

**目标**
- 后台自动检查新版本、自动下载、**静默安装并重启**（无对话框）。
- 重启时机尽量不打断用户（无活跃 iPhone 会话时）。
- 发布流水线一条命令产出 appcast + 更新包。

**非目标（v1 明确不做）**
- beta/stable 双通道、增量（delta）更新、更新日志 UI。
- **扩展 / 驱动的自动更新**：虚拟摄像头是 CMIO 系统扩展（换二进制会重置授权，
  lesson #5），虚拟麦克风是装在 `/Library/Audio/Plug-Ins/HAL` 的 pkg 驱动
  （要管理员密码）。这两者 **版本冻结**，只在确有必要时手动处理。
- 真正的"不重启热替换"（编译型原生 App 做不到，见 §3）。

## 3. 决策（来自 brainstorming）

| # | 决策 | 说明 |
|---|---|---|
| D1 | 静默全自动 | 后台下载 + 自动安装 + 自动重启，无对话框。代价：重启瞬间断一下 iPhone 连接，流会重连。 |
| D2 | v1 只管 App 本体 | 扩展 / 驱动冻结；日常发版不改它们的 `CFBundleVersion`，因此不重置系统扩展授权。 |
| D3 | 用 Sparkle 2 | 事实标准；EdDSA 签名 appcast + 自带下载/原子替换/重启。项目此前很在意零依赖，但自动更新恰是 Sparkle 主场。 |
| D4 | 空闲时再重启 | 有 pending 更新时，等到无活跃会话再安装重启；若用户先退出 App，Sparkle 默认的 install-on-quit 兜底。 |

## 4. 架构

```
                 ┌─────────────────────────── Mac App (RemoteCrab) ───────────────────────────┐
                 │                                                                            │
  后台定时 ─────►│  UpdaterController (SPUStandardUpdaterController)                          │
                 │    ├─ 检查 https://vgoapp.com/downloads/appcast.xml                        │
                 │    ├─ 自动下载 .zip（EdDSA 校验 + Developer ID 校验）                       │
                 │    ├─ SPUUpdaterDelegate.willInstallUpdateOnQuit → 存下 immediateInstallBlock │
                 │    └─ installPendingUpdateIfIdle()  ← 观察 ReceiverSession 空闲状态           │
                 │                                                                            │
  ReceiverSession│  state.isIdle (无拥有者) && !isRecording                                     │
                 └────────────────────────────────────────────────────────────────────────────┘
                                        │ 调用 immediateInstallBlock
                                        ▼
                              Sparkle 安装器：替换 .app → 重启 App（无 UI）
```

**组件边界**
- `UpdaterController`（新）：唯一持有 Sparkle 的对象，生命周期随 App。对外只暴露
  `checkForUpdates()`、`pendingUpdate: Bool`、`installPendingUpdateIfIdle()`。
- `UpdateInstallGate`（新，放 `RemoteCrabCore`，纯函数 / 纯结构）：决定"现在够不够空闲"。
  可单元测试，不依赖 Sparkle / AppKit。
- `ReceiverSession`（既有）：提供 `sessionGranted` / `isRecording` 作为空闲信号，不改协议。
- `MenuBarMenu` / `PreferencesView`（既有）：加"检查更新"入口与自动更新开关。

## 5. 静默安装机制（关键 API）

Sparkle 2 的两档自动更新：`automaticallyChecksForUpdates = true` +
`automaticallyDownloadsUpdates = true` 后，更新会在后台静默下载。

下载完成后 Sparkle 调：

```swift
func updater(_ updater: SPUUpdater,
             willInstallUpdateOnQuit item: SUAppcastItem,
             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool
```

- **返回 `true`**：接管安装。把 `immediateInstallHandler` 存下来，将来某刻调用它
  → 立即安装并**无任何 UI** 地重启 App。
- 返回 `false`：交给 Sparkle 的调度，默认会在 App 退出时装。

**本设计返回 `true`**，把 block 存进 `UpdaterController.pendingInstall`。这样我们
才能实现 D4 的"等空闲"。若 App 在空闲到来前就被用户退出，Sparkle 仍会在退出时安装
（文档保证："In either case Sparkle will always attempt to install the update when
the app terminates"），所以更新不会永远拖下去。

`SPUStandardUserDriverDelegate.supportsGentleScheduledUpdateReminders` 必须为 `true`
（LSUIElement / 菜单栏 App 不加会警告）。

## 6. 空闲判定（`UpdateInstallGate`）

纯逻辑，输入：是否有 pending 更新、会话是否活跃、是否在录音、已空闲时长、当前时间。

```
shouldInstall(pendingUpdate:sessionActive:isRecording:idleSince:now:) -> Bool
  条件：pendingUpdate == true
      && sessionActive == false
      && isRecording == false
      && (now - idleSince) >= dwell        // 默认 dwell = 30s，防抖
```

- `sessionActive` 取 `ReceiverSession.sessionGranted`（Mac 是接收端，`true` = 正拥有会话）。
- `idleSince` 在首次满足"无会话"时记录；期间一旦又有会话则清零。
- 观察方式：`UpdaterController` 监听 `ReceiverSession` 的变化（Combine /
  `@Observable` 观察），状态变为空闲且有待装更新时，延迟 dwell 后调用 block。
- 不引入高频定时器（项目 lesson #15：别用常驻 `TimelineView`/高频 tick）。

## 7. 发布流水线

**一次性准备**
1. 用 Sparkle 的 `generate_keys` 生成 EdDSA 密钥对：私钥存登录钥匙串，
   公钥写入 `project-mac.yml`。
2. `project-mac.yml`（`RemoteCrabReceiver` target 的 `info.properties`）加：
   - `SUPublicEDKey: <公钥>`
   - `SUFeedURL: https://vgoapp.com/downloads/appcast.xml`
   - `SUEnableAutomaticChecks: true`
   （`SUFeedURL` 同时在代码里通过 `feedURLString(for:)` 兜底，避免 plist 被过滤。）

**每次发版**
1. 递增 `RemoteCrabReceiver` 的 `CFBundleVersion`（**必须单调递增**，Sparkle 比较的是它，
   不是 `CFBundleShortVersionString`）。扩展 / 驱动的 `CFBundleVersion` 保持不变（D2）。
2. `scripts/release-mac.sh <version>`：
   - 在现有 `[3/5] 重签嵌套代码` 里**一并**手工重签 Sparkle 的嵌套二进制（见 §8），
     必须在 `[4/5] 公证` **之前**，否则公证会因未签名二进制失败。
   - 公证 + staple 完成后，产出 `dist/RemoteCrab-<version>.zip`
     （用 `ditto -c -k --sequesterRsrc --keepParent`）供 appcast 使用；
     DMG 仍保留给首次下载的人。
3. 新增 `scripts/make-appcast.sh`：把 `.zip` 拷进一个 appcast 目录，
   跑 `generate_appcast --download-url-prefix https://vgoapp.com/downloads/`，
   输出 `dist/appcast/appcast.xml`。
4. 发布：rsync `appcast.xml` + 更新 `.zip` 到 `vgoapp.com/downloads/`
   （沿用 lesson #35 的 `cat file | ssh … 'cat > remote'` 更稳）。

**版本对照示例**

| 产物 | 版本来源 | 是否随发版变 |
|---|---|---|
| `sparkle:version` | App `CFBundleVersion` | 每次必变 |
| `sparkle:shortVersionString` | App `CFBundleShortVersionString` | 随营销版本 |
| 系统扩展 `CFBundleVersion` | 冻结（当前 8） | 否 |
| HAL 驱动 `CFBundleVersion` | 冻结（当前 2） | 否 |

## 8. 签名与安全

App 未启用沙盒，因此 **不启用 Sparkle 的 XPC 服务**（`Installer.xpc` /
`Downloader.xpc` 仅沙盒 App 需要），可移除以免多签。`ENABLE_HARDENED_RUNTIME` 已为 YES，
Developer ID 分发满足 library validation。

`scripts/release-mac.sh` 在重签 app 之后、公证之前，按 Sparkle 官方顺序补签：

```sh
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$SPARKLE/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$SPARKLE/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$SPARKLE"
```

- 不要用 `--deep` 签 app（Sparkle 文档明确警告会破坏签名）。
- 私钥（EdDSA）**永不入库**；只在钥匙串。公钥进 `project-mac.yml`。
- 下载的更新包 Sparkle 会做 **EdDSA 签名校验**（appcast 用私钥签）**和** 解包后的
  Developer ID 代码签名一致性校验，双保险。
- ATS：feed 走 HTTPS（`vgoapp.com` 已 HTTPS）。

## 9. 错误处理

- 检查 / 下载失败：`os_log`（subsystem `com.remotecrab`）记录，**不向用户抛原始错误**
  （项目 lesson #13）。用户无感，下个周期自动重试。
- 安装失败：Sparkle 回退到 install-on-quit；下个周期再试。
- 更新检查期间断网 / 服务器 404：静默，不影响主功能。
- 长期不空闲：由 install-on-quit 兜底（用户退出时安装）。

## 10. 测试

- **单元测试（`RemoteCrabCore`）**：`UpdateInstallGate` 的边界 —— 有/无 pending、
  活跃/空闲会话、录音中、dwell 未到 / 已到、空闲被重置。
- **回归**：`./scripts/test.sh` 保持全绿（含两个 App target 能构建）。
- **手工端到端**：本地起一个 appcast（或指 `--feed-url` 到本地），造一个比当前
  `CFBundleVersion` 大的包，验证：静默下载 → 空闲时替换 → 重启后版本号变大。
  在真机上确认系统扩展授权**未**被重置（`RemoteCrab Camera` 仍可用）。

## 11. 风险与未决

| 风险 | 影响 | 缓解 |
|---|---|---|
| 替换 App 可能重置 CMIO 系统扩展授权 | 摄像头失灵 | D2 冻结扩展版本；`ensureRegistered()` 已只在"App 被移动"时自动修复（lesson #5），确保不在更新后自动重注册。真机验证 §10。 |
| Sparkle 通过 SPM 二次重签易漏 | 公证失败 / 启动崩溃 | 按 §8 顺序补签；`codesign --verify --deep --strict` 把关；先本地 `spctl` 验证。 |
| 空闲可能长时间不来 | 更新迟迟不装 | install-on-quit 兜底（D4）。 |
| 签名密钥丢失 | 无法再发更新 | 私钥入钥匙串；备份到 `~/.config/remotecrab/`（0600），不入库。 |
| 首版 App（1.0 无 Sparkle） | 老用户不会自动收到含更新器的版本 | 首个带更新器的版本仍需用户手动下一次；之后即可自动。 |

## 12. 参考

- Sparkle 安装 / 签名：`https://sparkle-project.github.io/documentation/`
- `SPUUpdaterDelegate.willInstallUpdateOnQuit`：Sparkle API Reference
- 发布流程：`docs/RELEASE.md` §B、`scripts/release-mac.sh`
- 扩展授权坑：`AGENTS.md` lesson #5、#29、#30
