---
title: Windows 接收端 — 三个功能缺口的根因与 Mac 侧待办
type: design-note
status: current
last_verified: 2026-10-03
---

# 分屏 / 扩展屏 / 情景模式 —— 查到了什么，接下来谁做

日期：2026-10-03 · 在 Windows 机器上做的**静态代码审计**（不是猜测，每条都有
文件行号）· 代码基线 `348ae5b`

三件事的结论差别很大：一件**已经完整**（我上一轮误判了），一件**纯 Mac 侧**，
一件**两侧都要改但根因在协议的一处重载**。

---

## 1. 扩展屏 —— 已经实现了，别再改

我上一轮说"iPhone 端还没隐藏这个入口"，那是错的：我只 grep 了
`toggleExtendedDisplay`，没读它上面的 `if`。实际上：

```swift
// ContentView.swift:766
if !engine.connectedIsWindows {
    Button { … engine.toggleExtendedDisplay() } …
}
```

`CaptureEngine.swift:95` 的 `connectedIsWindows` 来自 `clientHello.platform`，
而 Windows 一直在发它（`windows/crates/rc-net/src/supervisor.rs:655`）。
所以：**镜像有、扩展屏没有、且不给用户一个点了没反应的按钮** —— 三件事都对。

**路线修正**：`WINDOWS_HANDOFF.md §4` 原来写"需要签名的 WDDM/IDD 显示驱动"，
暗示内核态。微软文档明确 IddCx 是**用户态 UMDF**：

> The IDD is the third party-provided UMDF driver for the device… The IDD uses
> a user-mode model and doesn't support kernel-mode components.

真正贵的是签名、必须装成一个设备、以及 IddCx 把桌面图像以 DirectX surface 交给
驱动并**禁用 GDI / 窗口 API**——所以 Mac 那套"把已有镜像指过去"不能照搬。

**谁做**：都不做。等 §2.1 的证书到手再说，届时驱动的签名是同一张证多签一个
`.cat`，边际成本很低。

---

## 2. 情景模式（上下文面板）—— 根因在 `AppInfo.id` 被重载

### 现象

Windows 上情景面板**永远是空的**（只有语音 hero，零个应用按钮）。

### 根因（链路完整）

```swift
// ContextProfiles.swift:363
public static func profile(for app: IBAppInfo?) -> ContextProfile {
    all.first { $0.bundleIDs.contains(app.id) } ?? console
}
```

`bundleIDs` 全是 **macOS bundle identifier**（`com.apple.iWork.Keynote`、
`com.microsoft.Powerpoint` …）。Windows 发的是：

```rust
// windows/crates/rc-os/src/apps.rs:41
apps.push(AppInfo {
    id: format!("pid:{pid}"),   // ← 字面上的 "pid:1234"
    name,                        // ← "POWERPNT"（exe 名去后缀）
    pid: pid as i32,
    …
});
```

`"pid:1234"` 永远匹配不上任何 `bundleIDs` → **永远回落到 `console`**，而：

```swift
// ContextSheetView.swift:76
profile.id == ContextProfiles.console.id ? [] : profile.gridActions
```

console profile 的 `appActions` 被显式置空。所以这不是"没实现"，是**永远匹配不上**，
而它的外观和"没实现"一模一样。

### 真正的问题不是 Windows，是字段被重载

`AppInfo.id` 同时承担两个用途：

| 用途 | macOS | Windows |
|---|---|---|
| **身份**（profile 匹配） | bundle ID，稳定、跨启动不变 | `pid:N`，**每次启动都变，且不标识任何东西** |
| **路由**（activate / quit） | bundle ID 足够 | 必须能回到 pid |

Windows 用 `pid:N` 做路由是**对的** —— 两个 Chrome 窗口、两个 VS Code 窗口共享同一个
exe 名，所以窗口列表才按 pid 合并。问题在于这个值被塞进了叫 `id` 的字段，而
`pid` **已经有自己的字段了**（`AppInfo.pid`）。于是身份这一半被路由的值顶掉了。

### 两条修法

**A. 只改 Swift（最小，无协议改动）** —— profile 匹配加一个 name 回退：

```swift
all.first { matches($0, app) } ?? console
// matches：先试 id，再试归一化的 name（"POWERPNT" → "powerpnt"）
```

Windows 已经发了可用的 `name`，`name` 又是用户真正认的东西（"PowerPoint" 而不是
"com.microsoft.Powerpoint"）。代价是 profile 注册表要加 Windows 名单，而它是
`Codable` 数据、按 `bundleIDs` 匹配——语义上应该改名成"标识符列表"。

**B. 协议加一个字段（正解，两侧都要改）** —— `AppInfo` 增加可选的
`appRef`/`bundleId`，`id` 保持路由用途。两个字段职责分开，profile 匹配改用
新字段。协议是**纯新增**，符合 `WINDOWS_HANDOFF.md §4` 的"只能加字段"。

### 谁做

**A 和 B 都要 Mac 编译**（`RemoteCrabCore` 是共享 Swift 包）。
B 还需要 iOS 重新构建 + 真机验证（profile 切换是否即时生效）。
**Windows 侧不需要任何改动** —— 无论 A 还是 B，Windows 已经把该发的都发了。

---

## 3. Win 键 / 快捷键对齐 —— 缺口在手机侧，且不需要改协议

### 现状（`windows/crates/rc-input/src/keymap.rs`，30 条单测覆盖）

| 用法 | Windows 侧行为 | 状态 |
|---|---|---|
| ⌘ **单独按**（keycode `0x37` / `0x36`） | 注入 **`LWIN`**（`keymap.rs:108`） | ✅ 通 |
| ⌘ 作**修饰键**（⌘C、⌘Tab） | 塌缩成 **Ctrl**（`keymap.rs:7-9` 写明的设计决策） | ✅ 有意为之 |
| `option` / `shift` / `control` | Alt / Shift / Ctrl | ✅ |
| 接收端自己发的 Win 组合键 | `Win+Tab`（Task View）、`Win+Ctrl+←/→`（虚拟桌面） | ✅ |

### 缺口

**没有办法从手机发 ⊞ 组合键**。点 ⌘ 再点 E 得到的是 `Ctrl+E`，不是 `⊞E`。
所以 ⊞E（资源管理器）、⊞R（运行）、⊞D、⊞Tab、⊞+shift+← 全部够不着。

⌘→Ctrl 的策略**对常见情况是对的**（Mac 肌肉记忆 ⌘C → Windows Ctrl+C），
问题是它没有逃逸口。

### 修法：不需要任何协议改动

iOS 已经知道对面是什么系统 —— `hello.platform == "windows"`，
`KeyboardScreen.swift` 已经在用它换修饰键标签（⌘ 显示成 Ctrl）。所以：

- 电脑端是 Windows 时，键盘多出一个 **⊞**；
- ⌘ 继续发 Ctrl（保持肌肉记忆），⊞ 单独发 Meta。

协议层面完全不用动：`KeyEvent` 已经能表达单个 Win 键（`0x37` → `LWIN` 已实现），
缺的只是**手机 UI 上有没有这个键**。

> **已实现，但和上面这段原计划不同**（2026-10-03，`ab86efe` + 本轮）：
> ⊞ **顶替** ⌘ 而不是并存。`windowsLabel` 把 `.control` 和 `.command` 都渲染成
> `"Ctrl"`，并存的结局是 Windows 用户看到两个一模一样、其中一个还不存在的键。
> 行变成 `Ctrl Alt ⊞ Shift`。
>
> **本轮补上的洞**：`ab86efe` 只改了 `KeyboardScreen.swift`，而修饰键行还有
> 第二个来源 —— `IBShortcutBar`（触控板 + 投屏共用）。它的 `IBModifierBar(...)`
> **没传 `platform`**，于是走缺省 `.mac`：Windows 用户在**最常用的两个界面**
> 上看到的还是 `⌃⌥⌘⇧`，只有键盘界面是对的。现在 `IBModifierBar.init` /
> `IBShortcutBar.init` / `ScreenShareView.platform` 三处的 `platform`
> **都没有默认值**，编译器强制每个调用点表态 —— 这类漏传不可能再静默发生。
> 已用真实组件渲染双向验证：修之前 Windows 出 `⌃⌥⌘⇧`，修之后出
> `Ctrl Alt ⊞ Shift`。

### 谁做

**纯 iOS 侧 → Mac 编译 + iOS 重新构建。Windows 侧一行都不用改。**

需要真机验证：⊞E 能打开资源管理器、⊞R 能打开运行、⊞ 和 ⌘ 同时存在时
修饰键提示不串。

---

## 4. "分屏" —— 全仓没有这个东西，需要你给一个词

`分屏` / `Split View` / `Stage Manager` 在整个仓库（`.md` / `.swift` / `.rs` /
`.ts` / `.tsx`）**零命中**。所以它不是 RemoteCrab 任何一个平台上的既有功能名。

两种可能的所指：

1. **macOS 的 Split View / Stage Manager 自动化** —— 那需要 macOS 私有 API
   （和 `CGVirtualDisplay` 同一类东西），Windows 上更没有对应物。
2. **"同时看 iPhone 屏幕 + 应用窗口镜像"** —— 这个**已经存在**：
   `CaptureEngine.swift:780` 明确写了 "Mirror and Extended Display are two
   SOURCES for the same viewer"，Windows 侧由 `rc-mirror` 实现。

如果是第 2 种，那它已经有了；如果是第 1 种，那是一个新功能，而且应该先问清楚
它对应用户心里的什么场景。**这一条我没法替你判断，需要你给一个具体的场景。**

---

## 5. 汇总：Mac 侧已完成（2026-10-03，`5c373a3`）

设计文档：`docs/superpowers/specs/2026-10-03-windows-context-parity-design.md`
实现计划：`docs/superpowers/plans/2026-10-03-windows-context-parity.md`

| # | 事项 | 状态 | 说明 |
|---|---|---|---|
| 1 | 情景模式 profile 匹配 | ✅ **已完成** `59a5f7f` | 按 `platform:` 匹配；Windows 走进程名（`app.id` 是 `pid:N`，每次启动都变）。`platform:` 有默认值，**25 个原 Mac 测试一字未改** |
| 2 | `AppInfo.appRef`（方案 B） | ⏸ **本轮不做** | `windowsProcessNames` 已按进程名解决同一问题，且不改协议、不需双端重建。真要拆字段，等有第二个非-Windows 平台再说 |
| 3 | ⊞ 键行 | ✅ **已完成** `ab86efe` + `d5f23e6` | ⊞ **顶替** ⌘，不是并存——`windowsLabel` 把 ⌃ 和 ⌘ 都渲染成 `"Ctrl"`，本来就有两个同名按钮。⊞ 组合键需要新的 `meta = 16` 位（交接文档说「协议不用动」只对单独点 ⊞ 成立） |
| 4 | 分屏 | ⏸ 待定义 | 仍需要你给一个具体场景 |
| 5 | 虚拟麦克风 | 不做（需签名 WDK 驱动） | — |
| 6 | 扩展屏 | 不做（等签名证书） | — |
| 7 | `capabilities` 无人消费 | 未动 | 记为 lesson 112 |

### 5.1 交接文档漏掉的四个坏按钮 —— 已修 `1cf323d`

`ContextSheetView.swift:42` 的系统区是**无条件渲染**的，所以每个 Windows 用户
**现在**就能看到 8 个按钮，其中 4 个是坏的。这比「面板是空的」严重：

| 按钮 | 之前在 Windows 上 | 现在 |
|---|---|---|
| 亮度上/下 | `system_keys.rs:33` 直接 `return false`，**什么都不发生** | **移除**（不做死按钮，规则 1） |
| **锁定屏幕**（⌃⌘Q） | `keymap.rs:147` 把 ⌘/⌃ 塌缩成 Ctrl → **`Ctrl+Q`**，在很多软件里是**退出** | **⊞L** |
| **Safari** | `ContextSheetView.swift:147` 写死 `bing.com` → 打开 **Bing** | 标签「浏览器」，参数与标签绑在数据里（`.systemArg`） |

根因是 `keymap.rs:147` 的 `command | control` 塌缩。它还导致 agent 套件的
「中断 ⌃C」和「复制 ⌘C」变成**同一个按键**——而 Windows Terminal 里 Ctrl+C 是
中断，所以「复制」按钮会中断。

### 5.2 新增测试把这类塌缩变成不可能再犯

`testNoTwoWindowsActionsCollapseToTheSameKeystroke` 会把每个套件里的动作按
Windows 的解析规则归一化，任何两个动作塌缩成同一个注入按键就失败。

### 5.3 Windows app 名单 —— 只上「有据可依」的

| 套件 | Windows 应用 | 依据 |
|---|---|---|
| `agent` | WindowsTerminal / powershell / pwsh / cmd / conhost | 终端里跑 Claude Code、Codex CLI、OpenCode、Gemini CLI、Aider、goose —— 终端无法区分是哪个 agent，与 Mac 同理 |
| `editor` | Code / devenv / cursor / notepad++ | VS Code 官方键位表 |
| `browser` | chrome / msedge / firefox / brave | Chromium/Firefox 通用 Ctrl 组合 |

**其余套件故意不映射**，落到系统控制区 —— 那是诚实且能用的行为。
「没有套件」不是缺陷，「套件里全是 Mac 快捷键」才是。

### 5.4 ⛔ 故意砍掉的两处（等真机确认再加回来）

| 项 | 为什么砍 |
|---|---|
| agent 套件的**复制/粘贴** | Windows Terminal 的复制粘贴组合键无法从文档确认。「复制」按钮变成中断正是这次要消灭的失败 |
| **PowerPoint**（`POWERPNT`） | F5 / Shift+F5 需要 `keymap.rs` 支持扩展功能键（F1–F12），这一点未验证。能匹配上却发出两个可能相同的按键，比匹配不上更糟。`testPowerPointIsNotYetMapped` 明确断言它**没有**映射，让这个省略读起来像一个决定而不是疏漏 |

### 5.5 套件格式（为市场留缝，零网络）

`Documents/RemoteCrab/Profiles/*.json`，面板打开时重读。字段：
`schemaVersion` / `source`（`.builtin` / `.userFile` / `.remote`）/
`bundleIDs`（Mac）/ `windowsProcessNames`（Windows）/ `windowsActions`。

- 优先级 `userFile > remote > builtin`，**同 id 覆盖**（旧的先匹配先赢让「装了插件等于没装」）
- 坏文件只损失自己，其余照常加载，并给出**带文件名和两个版本号**的可读原因
- 非内置套件在面板标题下显示「自定义套件」——这些按钮注入真实按键，来源不该不可见
- **`remote` 现在没人填**。上云端时格式一行都不用改，需要的只有签名校验、信任根和真实投递
- 一个套件就是一段「可执行输入」。云端来源的 profile 必须先解决信任问题再上

### 5.6 🔲 本机无法验证的（请在 Windows 真机上逐条打勾）

- [ ] ⊞L 真的锁屏（**不是退出**）
- [ ] ⊞E 打开资源管理器、⊞R 打开运行
- [ ] ⊞ 与 Ctrl/Alt/Shift 并存时修饰键提示不串
- [ ] Windows Terminal 里「中断」是中断；确认复制/粘贴该不该加回来
- [ ] 亮度按钮**不再出现**
- [ ] 「浏览器」按钮的标签与实际打开的一致
- [ ] 三个套件（agent / editor / browser）匹配正确，且每个按钮真的执行对应动作
- [ ] `POWERPNT` 落到系统控制区（不是错误地匹配到 presentation）
- [ ] 往 `Documents/RemoteCrab/Profiles/` 放一个 JSON 生效；放一个坏文件有可读报错且**不影响**其它套件
- [ ] **切换到另一台电脑在 30 秒内接上**（本轮新增）。旧版一条被拒的偏好会拒掉
      **所有人**最长 10 分钟，包括正在用的那台；现在是 30 秒宽限期，到点自动放弃。
      真机要验两条：切到一台刚被 `denied` 过的 PC —— 旧版永远接不上（`denied`
      在 Mac 端**不排任何重试**），新版 30 秒后双方都恢复可连；切到一台处于 `busy`
      的 PC —— 两版都接得上（它每 15 秒自己试一次）。
- [ ] 手机上「状态胶囊 → 断开连接」1 跳能放开当前电脑（旧版要 ⋯ → Choose a Mac）
- [ ] 「显示桌面」真的最小化全部窗口（本轮从 ⊞⌥D 改成走 `IBSystemCommand.showDesktop`）
- [ ] 语音 hero 只出现**一次**（全宽那个），系统区不再重复一个

### 5.7 本轮在 iOS 侧又查出的 Mac 残留（本轮已修 / 仍然存在）

已修（都在 iOS，Windows 侧一行没动）：

| 症状 | 根因 | 修法 |
|---|---|---|
| 触控板 + 投屏界面在 Windows 上仍显示 ⌘ | `IBShortcutBar` 调`IBModifierBar` 时没传 `platform`，走缺省 `.mac` | `platform` 三处全部去掉默认值，编译器强制表态 |
| 「Show Desktop」按钮点了没反应 | 写的 ⊞⌥D，**keycode 53 是 Escape**（`keymap.rs:105` → `vk::ESCAPE`） | 改走切换应用界面已在用的 `IBSystemCommand.showDesktop`（Windows 侧是真最小化全部，不是 Win+D 那个 toggle） |
| Windows 上看到 Safari 罗盘 | 「Browser」按钮沿用 `safari.fill` | 换 `globe`；SF Symbols 没有 Edge，也没有理由画一个 |
| 语音按钮出现两次 | `windowsSystemActions` 里带着 `.voiceHero`，而 Mac 侧 `console.gridActions` 会过滤 | 系统宫格过滤掉hero（新增 `windowsSystemGridActions`），`voiceHero(for:)` 回退到 console 的 hero |
| 系统区提示去开「屏幕录制」 | 那是 macOS 的 TCC 权限，Windows 根本没有 | Windows 上根本不渲染这个提示 |
| 空状态图标是 Mac 窗口 | `macwindow.on.rectangle` | Windows 换 `rectangle.grid.2x2` |

仍然存在（**故意留的**，不是漏）：

- **Mac 文案**：会话内会读到的 26 条已经全是「the computer / 电脑」
  （`testNoSessionSurfaceNamesAMac` 守着）。但 onboarding / 权限说明 /
  「Download for Mac」这些**产品级**文案还写着 Mac —— RemoteCrab 的 Mac 端
  是真实存在、要用户安装的东西，改它是另一个决定，不该顺手带上。
- ~~**手势教学页**~~ —— **已在 `14045b3` 修掉**：5 行改为按平台分流，
  `TrackpadGuideView` 的 `platform` 也去掉了默认值。当时它写死
  「Lock ⌃⌥⌘⇧」「Mission Control」「the Mac」，而它是**会话中被阅读**的，
  两英寸外的快捷键行已经显示 `Ctrl Alt ⊞ Shift` 了；顺带发现
  `Coach.pinchZoom` 在 catalog 里**根本没有条目**，中文界面显示英文原文。
  **同批还修了 VoiceOver 标签**（Windows 和弦键复用 Mac 的 label，于是
  `Ctrl+Z` 被念作「Mission Control」）和 **context chip 的英文 `"Computer"`**
  —— 后者只能靠看真机截图发现，英文界面下它不存在。
- **Windows 系统区是 7 个**（Mac 是 8 个，多的两个是亮度，Windows 上
  `system_keys.rs` 对亮度直接 `return false`）。两列格子最后一行会空半格，
  这是**故意留的空**，没有第八个诚实的 Windows 系统控制项可填。
- **13 个套件在 Windows 上没有映射**，落到系统控制区。这是**有据可依的取舍**
  （`testPowerPointIsNotYetMapped` 明确断言它*没有*映射），不是漏。
- **`CaptureEngine.setPreferredMac` 是死代码**（无调用者）。留着是因为
  「换一个 Mac 偏好」将来可能需要它，但要注意：它接受任意 id，若接上线路
  会让偏好指向一个从未敲门过的电脑 —— 所以 `pruneStale` 的清理改成了无条件。

### 顺便：Mac 上顺手能验的 Windows 侧结论

- 虚拟摄像头链路已闭环（`vcam_consume` 跨进程读到在动的像素），**只差人眼**
- 摄像头视频真机已验证：1080×1920 @ 30fps 持续解码
- token 持久化、`busy` 反压、握手批准流程真机已验证
- 那个 `fatal runtime error: Rust cannot catch foreign exceptions` 在真机 + 托盘下
  **仍无法复现**
