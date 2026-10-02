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
`KeyboardScreen.swift:345` 已经在用它换修饰键标签（⌘ 显示成 Ctrl）。所以：

- 电脑端是 Windows 时，键盘多出一行 **⊞**，和 ⌘ 并存；
- ⌘ 继续发 Ctrl（保持肌肉记忆），⊞ 单独发 Meta。

协议层面完全不用动：`KeyEvent` 已经能表达单个 Win 键（`0x37` → `LWIN` 已实现），
缺的只是**手机 UI 上有没有这个键**。

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

## 5. 汇总：谁需要 Mac 编译

| # | 事项 | 改哪里 | Mac 编译 | iOS 重构建 | 真机验证 |
|---|---|---|---|---|---|
| 1 | 情景模式 profile 匹配（方案 A，改 Swift） | `RemoteCrabCore/State/ContextProfiles.swift` | ✅ | ✅ | ✅ |
| 2 | 情景模式 `AppInfo.appRef`（方案 B，改协议） | `IBEvents.swift` + `rc-protocol/events.rs` + `rc-os/apps.rs` | ✅ | ✅ | ✅ |
| 3 | Win 键行（⊞ 与 ⌘ 并存） | `RemoteCrabCapture/KeyboardScreen.swift` | ✅ | ✅ | ✅ |
| 4 | 分屏 | —— | 待定义 | 待定义 | 待定义 |
| 5 | 虚拟麦克风 | 不做（需签名 WDK 驱动） | — | — | — |
| 6 | 扩展屏 | 不做（等签名证书） | — | — | — |
| 7 | `capabilities` 无人消费 | `RemoteCrabCapture`（记为 lesson 112，未开成待办） | 可选 | 可选 | — |

**Windows 侧在这几条里需要动的只有第 2 项的 `rc-protocol` + `rc-os` 两处**，
其余都是共享 Swift 包或纯 iOS。第 1、3 项**完全不需要碰 Windows 代码**。

### 建议的执行顺序（在 Mac 上）

1. **第 3 项**（Win 键行）—— 最小、最独立、收益最直接，且不改协议。
2. **第 1 项**（profile 匹配加 name 回退）—— 让情景模式在 Windows 上不再是空的。
3. **第 2 项**（`appRef` 字段）—— 正解，但要改协议 + 双端重建，放在 1、2 之后。
4. **第 4 项** —— 等你给场景。

### 顺便：Mac 上顺手能验的 Windows 侧结论

- 虚拟摄像头链路已闭环（`vcam_consume` 跨进程读到在动的像素），**只差人眼**
- 摄像头视频真机已验证：1080×1920 @ 30fps 持续解码
- token 持久化、`busy` 反压、握手批准流程真机已验证
- 那个 `fatal runtime error: Rust cannot catch foreign exceptions` 在真机 + 托盘下
  **仍无法复现**
