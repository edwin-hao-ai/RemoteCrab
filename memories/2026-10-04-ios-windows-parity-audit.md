---
type: memory
title: iOS 侧的 Windows 兼容审计 —— ⌘ 只到了键盘界面，以及三份独立的同一句话
created: 2026-10-04T00:30:00+00:00
source: cli
---

# iOS 侧的 Windows 兼容审计

用户报「连接 Windows 后还是显示 Command」。查下来**不是一处漏改，是同一个根因
在四个地方各自实现了一遍**，而其中三处今天的代码里仍然是坏的。

## 起点：文档点名了一个文件，于是实施者只改了那一处

`docs/WINDOWS-GAPS-2026-10-03.md` §3 写着「`KeyboardScreen.swift:345` 已经在用它」，
`ab86efe` 就只改了 `KeyboardScreen.swift`。但修饰键行有**两个来源**：

| 来源 | 用在哪 | 修之前 |
|---|---|---|
| `KeyboardScreen` 自己画 | 键盘界面 | ✅ Ctrl Alt ⊞ Shift |
| `IBShortcutBar` → `IBModifierBar` | **触控板 + 投屏** | ❌ `⌃⌥⌘⇧`（`platform` 走缺省 `.mac`）|

所以同一个 app 里，**换个界面键就变了**，而两个错的面正好是最常用的两个。

**修法不是「记得传」，是去掉默认值** —— 四处 `platform` 现在都必填：
`IBModifierBar.init` / `IBShortcutBar.init` / `ScreenShareView.platform` /
`TrackpadGuideView`。编译器比 reviewer 更擅长数调用点。

## 同一句话的另外三份实现

用户只报了修饰键。但「描述这台电脑」的文案在这个产品里是**四份独立代码**：

1. **手势说明页** —— 写死「Lock ⌃⌥⌘⇧」「Mission Control」「the Mac」。
   它是**会话中被阅读**的，而两英寸外的快捷键行已经显示 Ctrl/Alt/⊞/Shift 了。
   一份描述了错误机器的说明比短说明更糟：读者无法判断哪几行可信。
   顺带发现 `Coach.pinchZoom` **在 catalog 里根本没有条目** → 中文界面显示英文原文。
2. **VoiceOver 朗读标签** —— Windows 和弦键**复用了 Mac 的 accessibility label**，
   于是 `Ctrl+Z` 被念作「Mission Control」、`Ctrl+A` 被念作「App Exposé」。
   **键帽是对的，所以没有任何检查能发现。** 抽成 `ShortcutChords` 数据
   （键帽 + 朗读配成一对）之后视图再没有「拿错标签」可言。
3. **context chip 写死英文 `"Computer"`** —— 中文手机上和「按住说话」并排。
   catalog 里早就有 `Computer` → 电脑，是调用点用字面量所以查表从没发生。
   **只能靠看截图发现**（lesson 76），英文界面下它不存在。

## 情景模式：三个按钮在说谎

`windowsSystemActions` 是**独立数组**，不是某个 profile 的 `windowsActions`，
所以 `ContextWindowsSuiteTests` 里所有 `for profile in ContextProfiles.all` 循环
**静默跳过了它** —— 它一个断言都没有，而 `systemActions(for:)` 是无条件渲染的。

- **「显示桌面」发的是 ⊞⌥Escape**：keycode `53` 是 **Escape**，不是 D
  （`keymap.rs:105` → `vk::ESCAPE`）。按钮完全没用。改走
  `IBSystemCommand.showDesktop`（切换应用界面本来就在用的路径）。
- **「浏览器」图标是 `safari.fill`** —— 这就是用户说的「Windows 上没有 Safari」。
- **`.voiceHero` 待在系统宫格里**，而 Mac 侧 `console.gridActions` 会过滤 →
  匹配的套件把「Talk to Computer」渲染**两次**（全宽一次 + 宫格里一次）。

**去掉宫格里的 hero 会让 13 个套件失去语音键** —— 因为 console 没有
`windowsActions`。所以 `voiceHero(for:)` 必须**回退到 console 的 hero**，
两条规则一起改才对。这是本轮最容易漏的一半。

## Mac 侧零影响（怎么保证的）

`console` / `gridActions` / `systemActions(for: .mac)` / `voiceHero(for: .mac)` /
`appActions` 的 Mac 分支**一行都没改**。证明不是「测试绿」，而是**渲染出来对比**：
真的 `IBShortcutBar` / `IBModifierBar` / 系统宫格塞进 `NSWindow` 截图，
Mac 那张和修改前逐格相同（8 格、亮度齐全、Safari 原样）。

⚠️ `ImageRenderer` **不给 `ScrollView` 布局**，会静默不画内容 —— 必须用
`NSHostingView` + `cacheDisplay`。差点因此以为渲染成功。

## 验证：每个断言都反向验过

把行为逐个改回旧样子，确认新断言**真的会红**。这一步抓到了我自己的问题：

- 两条 pruning 测试**按最旧→最新排列 fixture**，恰好和「最后写入胜出」这个
  bug 一致 → **空过**。真实 `seen` 是最新在前，那个顺序下 bug 保留最旧的。
- `testEqualTimestamps…` 仍在失败，因为 `daysAgo: 0` **每项各调一次 `Date()`**，
  「并列」其实差几微秒。**并列要用共享时间戳构造。**
- VoiceOver 那条我先写成比较**字符串**，改回 view 里的接线它**不会红** ——
  只有被测组件知道为什么（lesson 117）。所以把整排抽成数据。
- 一次 `python` patch **静默没匹配**（前置 replace 已改过内容），我差点把
  「没测到」当成「测到了」。

## 一个与本次改动无关、但挡住真机验证的发现

`e2e-device.sh` 22 条全红，根因是**手机正被另一台**接收端占着
（`busy owner=EDWIN`），而这是**正确行为**。读手机持久化的 `seenComputers`
一锤定音（别从日志推断）—— `…98db…` 两条 **node 相同、id 不同**，同一台机器的
两个身份。**跑 e2e 前先确认那台机器没连着手机。**

`84f30fa` 修好了症状（同名合并 + 30 天过期），真机验证 **5 行 → 3 行**，
但**根因在接收端**：`c9c0463`（`MachineGuid`）已进 main，**用户的 Windows
机器上跑的还是旧版**，不部署就还会继续产生新身份。

## 现场状态

- 6 个提交全部推上 `main`，工作区干净，`HEAD == origin/main`
- 453 测试 + 两个 app target + Windows 套件全绿
- `/Applications/RemoteCrab.app` 仍是 Developer ID 发布版，
  CDHash `d9dacda991ffaa8a1a32aff7abacf9b38b945549`，build 11
  （lesson 80 的备份/还原陷阱反复验证有效）
- `stash@{0}` 是 Windows session 的，**没碰**
- 提交前求交集确认与远端 3 个 Windows 提交**零文件重叠**才合

## 待验（只有真 Windows 机器能做）

`docs/PROMPT-WINDOWS-SESSION.md` 末尾有完整清单：修饰键三个界面不串、⊞ 单独按、
系统区四个按钮、语音只出现一次、同名只有一行、**重装后不需要重新配对**。