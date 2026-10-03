---
title: Windows 情景模式对齐 + ⊞ 键 + 可扩展的套件格式
type: design
status: draft
date: 2026-10-03
baseline: 348ae5b（Mac 侧 b219a40 合并后）
---

# Windows 情景模式对齐、⊞ 键行，与一个能长成市场的套件格式

日期：2026-10-03 · 在 Mac 上做的设计 · 前置交接文档
[`docs/WINDOWS-GAPS-2026-10-03.md`](../../WINDOWS-GAPS-2026-10-03.md)

## 0. 摘要

三件事一起做，因为它们共用同一个根因——**这套按键语义是按 Mac 写死的**：

1. **修 4 个坏按钮**（现在就影响 Windows 用户，见 §1）
2. **每平台独立动作集 + ⊞ 键行**（方案 A，见 §2–§4）
3. **把套件格式做完整 + 本地文件装载**（零网络，为云端留缝，见 §5）

不做：远程加载、市场分发、签名。理由见 §7。

---

## 1. 起点：交接文档漏掉的四个坏按钮

交接文档说「情景模式在 Windows 上永远是空的」。这对**应用区**成立，但
`ContextSheetView.swift:42` 的系统区是**无条件渲染**的：

```swift
sectionLabel(IBLocale.Context.systemSection)
grid(ContextProfiles.console.gridActions)
```

所以每个 Windows 用户**现在**就能看到 8 个按钮，其中 4 个是坏的：

| 按钮 | Windows 上实际发生什么 | 证据 |
|---|---|---|
| 音量上/下/静音 | `VK_VOLUME_*` ✅ | `system_keys.rs:27-29` |
| 播放 / 暂停 | `VK_MEDIA_PLAY_PAUSE` ✅ | `system_keys.rs:34` |
| **亮度上/下** | `return false`，什么都不发生 | `system_keys.rs:30-33` |
| **锁定屏幕**（⌃⌘Q） | **`Ctrl+Q`**——在很多软件里是「退出」 | `keymap.rs:147` |
| **Safari** | 打开 **Bing** | `ContextSheetView.swift:147` |

根因是 `keymap.rs:147` 把两个修饰键塌缩成一个：

```rust
let ctrl = modifiers & (Modifier::COMMAND | Modifier::CONTROL) != 0;
```

⌘ 和 ⌃ 变成同一个 Ctrl。于是 Mac 上「复制 ⌘C」和「中断 ⌃C」在 Windows 上是
**同一个按键**；而在 Windows Terminal 里 Ctrl+C 是**中断**，所以「复制」按钮会中断。

这违反 AGENTS.md 规则 1——「在 Mac 上好用、Windows 上坏，比不发布更糟」——
而且标着「锁定屏幕」的按钮可能**退出用户正在用的软件**。它现在就在线上。

---

## 2. 纠正交接文档：⊞ 组合键需要动协议

交接文档 §3 写「协议层面完全不用动：`KeyEvent` 已经能表达单个 Win 键
（`0x37` → `LWIN` 已实现）」。

**对「单独点 ⊞」成立，对 ⊞ 组合键不成立。** 修饰键位掩码只有 4 位
（`IBEvents.swift:25-31`：shift=1 / control=2 / option=4 / command=8），而
`COMMAND` 在 Windows 上被映射成 Ctrl。所以 ⊞E、⊞R、⊞D、⊞Tab、⊞L
**一个都发不出去**——而这正是本次要交付的核心能力。

**修法**：新增 `meta = 16`。纯新增，两端各加一行常量 + 一个分支。

---

## 3. 数据模型

```swift
public enum ProfileSource: String, Codable, Sendable {
    case builtin, userFile, remote
}

public struct ContextProfile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int          // 新增
    public let id: String
    public let title: String
    public let source: ProfileSource       // 新增
    public let bundleIDs: [String]         // 不动（规则 2：永不重命名既有字段）
    public let actions: [ContextAction]    // 不动 = Mac 现状
    public let windowsProcessNames: [String]?   // 新增
    public let windowsActions: [ContextAction]? // 新增
}
```

### 3.1 必须手写 `init(from:)`

`schemaVersion: Int` 是**非可选**，合成 Codable 遇到旧 JSON 会直接抛错。
按规则 2（`MacPairingStore.loadSeen` 吞掉解码错误 → 静默清空用户数据），
必须用 `decodeIfPresent` 显式给默认值：

```swift
schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
source        = try c.decodeIfPresent(ProfileSource.self, forKey: .source) ?? .builtin
windows*      = try c.decodeIfPresent([...].self, forKey: .windows...)
```

并加一条测试：**加载旧格式 JSON，断言没有任何字段丢失**。

### 3.2 为什么不重命名 `bundleIDs`

它语义上已经不对（叫通用名、只装 Mac bundle id）。但重命名要写解码桥，
风险大于收益，而规则 2 明说「never rename or retype an existing field」。
新增 `windowsProcessNames` 作为 Windows 原生对应字段。

代价：插件作者要理解「Mac 填 `bundleIDs`、Windows 填 `windowsProcessNames`」。
写进 README。

---

## 4. 匹配、优先级、动作解析

### 4.1 签名（Mac 回归风险为零的关键）

```swift
public static func profile(for app: IBAppInfo?,
                           platform: PeerPlatform = .mac) -> ContextProfile
```

`platform:` **有默认值** → 现有 25 个 Mac 测试和唯一生产调用点
（`ContextSheetView.swift:15`）**一行都不用改**。

`PeerPlatform` 复用 `IBModifierBar.PeerPlatform`（已存在，已由
`clientHello.platform` 驱动），不引入新概念。

### 4.2 合并与优先级

```swift
builtin < remote < userFile     // 同 id 覆盖，不是先匹配先赢
```

先合并成一份有序列表，再 `first { matches }`。今天
`all.first { ... }` 先匹配先赢，用户**装了插件也盖不掉内置套件**——
那装了等于没装。

### 4.2a 谁负责合并（可测试性）

`ContextProfiles` 保持**纯函数**——不碰磁盘。合并与装载由一个
`@Observable ContextProfileStore` 拥有（与 `FeatureStore` 同一个
single-source-of-truth 模式），由 `CaptureEngine` 持有，
`ContextSheetView` 从 environment 取。

```swift
ContextProfiles.profile(for: app, platform: p, in: store.merged)
```

`store.merged` 的默认参数是 `ContextProfiles.all`，所以纯单测不需要磁盘，
现有测试也不用改调用方式。

### 4.3 匹配规则

| 平台 | 匹配什么 | 不匹配什么 |
|---|---|---|
| mac | `bundleIDs.contains(app.id)` | — |
| windows | `app.name`（大小写不敏感、防御性去 `.exe`） | **`app.id`** |

不匹配 `app.id` 的原因：Windows 发的是字面量 `"pid:1234"`
（`rc-os/src/apps.rs:41`），每次启动都变、不标识任何东西。

### 4.4 动作解析——绝不回退

```swift
windows: profile.windowsActions ?? []      // 不是 ?? profile.actions
```

回退到 Mac 动作**就是 bug 本身**（§1）。没有 Windows 动作 = 应用区不显示，
而不是显示一堆错的东西。

### 4.5 系统区按平台出，标签和参数绑在一起

现在标签写死「Safari」、参数在 `ContextSheetView.swift:147` 按平台分支，
所以才出现「标签 Safari、打开 Bing」。改成系统动作整条按平台出：

| | Mac（不变） | Windows |
|---|---|---|
| 音量上/下/静音、播放暂停 | ✅ 保留 | ✅ 保留 |
| 亮度上/下 | ✅ 保留 | ❌ **移除**——不做死按钮 |
| 锁定屏幕 | ⌃⌘Q | **⊞L** |
| 启动浏览器 | 标签 Safari / `com.apple.Safari` | 标签「浏览器」/ 一个 URL |

亮度记为后续（Windows 要 WMI `WmiMonitorBrightnessMethods`，且只对内置笔记本屏
有效，外接显示器无效——不是按键能表达的）。

---

## 5. ⊞ 键行

### 5.1 两个 UI 类型

| 类型 | 位置 | 作用 |
|---|---|---|
| `IBEvents.Modifier` | `IBEvents.swift:25-31` | **位掩码**，加 `.meta = 16` |
| `IBModifierBar.Modifier` | `IBModifierBar.swift:13-17` | **UI 键**，加 `.meta = "⊞"`，keycode 55 |

`keymap.rs` 已有 `0x37 => LWIN`，且 Mac keycode 55 = 左 ⌘；`L` 也已有映射
（测试 `cg_to_vk(0x25) == 0x4C`，Mac keycode 37 = L）。所以 ⊞ 和 ⊞L 都只差
「把 META 映射成 LWIN」这一个分支。

### 5.2 影响面（规则 4）

`ForEach(Modifier.allCases)` **只有一处**：`IBModifierBar.swift:90`。加 case
只在这一个地方生效，但它在 Mac 上必须**被过滤掉**。

### 5.3 顺带修一个标签 bug

`windowsLabel` 把 `.control` 和 `.command` **都**映射成 `"Ctrl"`
（`IBModifierBar.swift:44,46`），所以 Windows 用户现在看到的修饰键行是：

```
Ctrl   Alt   Ctrl   Shift
```

两个同名按钮，其中一个还是假的（⌘ 在 Windows 上不是独立的键）。

所以：**Windows 上 ⊞ 取代 ⌘ 出现在这一行**，而不是追加第五个。

| | 修饰键行 |
|---|---|
| mac | ⌃ ⌥ ⌘ ⇧（**不变**） |
| windows | Ctrl Alt ⊞ Shift |

⌘ → Ctrl 的**肌肉记忆保持不变**（位还是映射成 Ctrl），只是不再显示一个
骗人的重复按钮。这同时满足「对齐 Mac」和「保留 Windows 自身特色」。

### 5.4 行为

和 ⌘ 完全同构：轻点 = 粘滞修饰键，长按 = 发真实 key down/up
（`onModifierKey` 走 `modifier.keycode`，⊞ = 55 → Windows `LWIN`）。

---

## 6. 套件格式 + 本地装载（零网络）

### 6.1 为什么不是「市场」

`ContextAction.key(keycode:modifiers:)` 加上整个 `ContextProfile`，等价于
**「从文件或网络读一段 JSON，就能注入任意按键」**。在 Mac 上就是任意
`CGEventPost`——而这个 app 已经有辅助功能权限。

所以从云端来的 profile **不是数据，是可执行输入**。签名、信任根、审核、
崩溃隔离是市场的一部分，但**来源与优先级必须在数据里**，现在不定将来要重做。
这两样我们现在就定。

### 6.2 做什么

- `schemaVersion`（格式版本；云端必需）
- `source`：`.builtin` / `.userFile` / `.remote`，**可展示、可禁用**
- 合并规则 `userFile > remote > builtin`
- 装载缝：`Documents/RemoteCrab/Profiles/*.json`
- **校验失败给可读原因**，不静默忽略（`schemaVersion` 比我们新 → 拒收该文件并说明；
  其余文件照常加载）
- 来源显示在面板 header 上——一个按键从哪来，绝不能是不可见的
- **不引入网络**

### 6.3 将来上云端

同一个 `ContextProfile` payload 用 HTTPS 取回来，**格式一行都不用改**。
需要新增的只有：签名校验、信任根、`remote` 源的真实投递。

---

## 7. 明确不做

| 项 | 理由 |
|---|---|
| 远程加载 / 云端市场 | 签名与信任根无从谈起；AGENTS.md「不要因为好做就加功能」 |
| 插件沙箱 / 崩溃隔离 | 需要先有生态 |
| Windows 亮度（WMI） | 只对内置笔记本屏有效，外接显示器无效；需真机验证 |
| 语义化动作（方案 C） | Mac 回归面最大，且无法在 Mac 上验证。2027 年的事 |
| 扩展屏 / 虚拟麦克风 | 已确认不做（签名驱动） |

---

## 8. 测试

### 8.1 Mac 回归（必须在且必须绿）

- 现有 25 个 `ContextProfilesTests` **一字不改**全绿——`platform:` 默认值保证
- `./scripts/test.sh`：Core 367+ + iOS app + Mac app

### 8.2 新增测试

| # | 测试 | 为什么 |
|---|---|---|
| 1 | **加载旧格式 JSON**，断言无字段丢失 | 规则 2 |
| 2 | Windows 解析**绝不**回退到 Mac 动作 | §1 的根因 |
| 3 | 按进程名匹配（大小写不敏感、去 `.exe`） | §4.3 |
| 4 | 优先级 `userFile > remote > builtin`（同 id 覆盖） | §4.2 |
| 5 | Windows 系统动作**不含**亮度 | 不做死按钮 |
| 6 | 系统动作的标签与参数成对一致 | 「Safari→Bing」那个 bug |
| 7 | `meta` 位往返编解码 | §2 |
| 8 | Windows 系统动作含 ⊞L（meta + keycode 37） | §4.5 |
| 9 | **同一套件内，任意两个动作在同一平台解析后不产生相同注入按键** | ⌃C/⌘C 那个塌缩 |
| 10 | `schemaVersion` 过大 → 拒收该文件 + 可读原因，其余照常 | §6.2 |
| 11 | Mac 修饰键行仍是 ⌃⌥⌘⇧（4 个，无 ⊞） | 规则 1 |

测试 9 是这次最有价值的一条——它把 §1 那类塌缩变成一个**不可能再犯**的约束。

### 8.3 Windows 侧

- `cargo test --workspace`
- `cargo check --workspace --all-targets --target x86_64-pc-windows-gnu`
- `cargo clippy --workspace --all-targets -- -D warnings`（Mac 目标）
- `cargo clippy ... --target x86_64-pc-windows-gnu -- -D warnings`

### 8.4 本机**无法**验证的（写进交接清单，逐条打勾）

- [ ] ⊞L 在真机上真的锁屏（不是退出）
- [ ] ⊞E 打开资源管理器、⊞R 打开运行
- [ ] ⊞ 行与 Ctrl/Alt/Shift 并存时修饰键提示不串
- [ ] Windows Terminal 里「中断」是中断、「复制」是复制（不再塌缩）
- [ ] 亮度按钮确实**不再出现**
- [ ] 浏览器按钮标签与实际打开的一致
- [ ] 放进 `Documents/RemoteCrab/Profiles/` 的 JSON 生效，且坏文件有可读报错

---

## 9. 实施顺序

1. **协议 + 数据模型**：`meta = 16`（两端）、`schemaVersion`/`source`/手写解码器、旧格式测试
2. **P0 修复**：系统区按平台出（去亮度、⊞L、浏览器标签）、修 `ContextSheetView.swift:147`
3. **匹配 + 优先级 + 动作解析**：`platform:` 默认参数、进程名匹配、合并
4. **⊞ 键行**：UI 枚举 + 两端映射 + Mac/windows 两套行
5. **Windows app 名单 + 各套件 Windows 动作**（只写有据可依的，其余标待验证）
6. **本地装载 + 校验 + 来源展示**
7. **新测试**（§8.2）全绿 → `./scripts/test.sh` + cargo 全套
8. **更新交接文档**：`docs/WINDOWS-GAPS-2026-10-03.md` §5 表格改为已完成 + §8.4 勾选清单