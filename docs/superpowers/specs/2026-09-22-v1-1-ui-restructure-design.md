# RemoteCrab V1.1 交互调整 — 设计文档（spec）

- 日期：2026-09-22
- 状态：已与用户对齐（三轮线框迭代），进入实施
- 线框：`prototypes/14-v1-1-restructure.html`（v3，唯一权威视觉参考）
- 总原则：**在现有代码上增量改动，不推翻现有 UI**。逐文件精读后再改；保持 Liquid Glass 设计语言（`IBMaterial` / `IBFont` / `IBGradient.canvasDark` / `IBLocale` 双语键）。

---

## 1. iOS：移除 FeatureDock，功能重新归位

### 现状（代码事实）

- `RemoteCrabCapture/ContentView.swift` — 浮动顶栏（状态钮 / ▦ app 切换器 / ⋯ 溢出菜单）+ 底部 `FeatureDock`；PiP（120×160，右上，可拖动，点按 → 相机面，`ContentView.swift:712-750`）；voiceCard（底部浮卡，`voiceCardBottomInset` 204/146）。
- `RemoteCrabCapture/FeatureDock.swift` — PTT 胶囊（DragGesture 按住/松开，`voiceButton` + `startVoice/stopVoice`）+ 4 钮行（trackpad | camera toggle | mic toggle | keyboard）。
- `RemoteCrabCapture/TouchpadScreen.swift` — 全屏 TouchSurface + 光标预览；底部快捷键行（横向 ScrollView）：`IBModifierBar`（⇧⌃⌥⌘ 可锁定）| 分隔线 | ⌫ , . ⏎（keycode 36 已在，`:177`）；`dockClearance = 148`（`:39`）。
- `RemoteCrabCapture/KeyboardScreen.swift` — K3：header + 预览卡 + mini 触控板(96pt) + shortcut bar（esc/tab/⌫/⌃⌥⌘⇧/方向/⌘⇥/⌘`/MC/Exposé/⌘H/⌘Q）+ 隐藏 UITextField 系统 IME；return = 发送并清空（`handleReturn`）。

### 改动

1. **删除 FeatureDock 的 4 钮行**；PTT 胶囊逻辑原样搬走（手势语义、voice.onInterrupted 复位、haptics 全部保留）。
2. **顶栏新增两个 44pt 玻璃圆钮**：📷（video.fill）、🎙（mic.fill），复用 `features.set(feature: .camera/.microphone)`。关态 = `IBMaterial.bar` 灰玻璃；开态 = accent 蓝（📷）/ 录制红（🎙）。位置：状态钮 | Spacer | ▦ | 📷 | 🎙 | ⋯。
3. **底部新 PTT 行**（所有 surface 共用，ContentView 层）：`⌨️ 圆钮（48pt）+ PTT 胶囊（flex）`。⌨️ 在 `.trackpad ↔ .keyboard` 间 toggle；在 keyboard surface 上 ⌨️ 高亮，再点返回 trackpad。
4. **触控板快捷键行**：⏎ 用 accent 色（`qk send`）；行首插入情境 chip（见 §2）。`dockClearance` 按新底部高度重测（底部从 ~148pt 降到 ~110pt）。
5. **voiceCardBottomInset** 按新底部高度重测。
6. **相机面退出**：相机全屏面加 ✕（返回 trackpad，**保持流**）；顶栏 📷 再点 = 关流。现有 `flipCameraButton` 保留。
7. **surface 切换仅剩两条路径**：⌨️ 圆钮（键盘）+ PiP 点按（相机）。trackpad 是默认面。
8. `REMOTECRAB_E2E_SURFACE` 等 env flag 直接设 `activeSurface`，不受影响。

### 已定案的默认决策（原"待确认"项）

- 键盘面退出：再点 ⌨️（toggle）+ 键盘面 header 的 🖐 图标可点（返回 trackpad）。
- 相机面退出：✕ 保持流返回；📷 圆钮关流。
- 情境 chip：固定在快捷键行最左，**不随 ScrollView 滚动**（chip 在 ScrollView 外，行内其余内容滚动）。

---

## 2. 情境快捷键页（Context Sheet）

### 入口

快捷键行最左的固定 chip：显示 Mac 前台 app 图标占位 + 名称（数据来自现有 `appList`/`isActive`，协议 0x0C，**零新协议**）。触控板面与键盘面都有。无连接/无数据时 chip 显示「Mac」并回落到控制台套件。

### 页面

全屏 sheet（`.presentationDetents([.large])` 风格与现有 sheet 一致）：header（app 图标 + 名称 + LIVE + ✕）→ 段切换 → 2 列 keypad 大按钮 → 底部「⚙️ 自定义」。

### 三套内置套件

| 套件 | 匹配 | 按键 |
|---|---|---|
| 演讲 | Keynote (`com.apple.iWork.Keynote`) / PowerPoint (`com.microsoft.Powerpoint`) | 播放/结束、← →、激光笔（**本版不做**，见 §5）、快捷翻译、计时、黑屏/白屏 |
| Agent | 前台为终端且进程匹配 kimi/claude/codex/opencode（第一版简化为：终端类 app + 名称匹配） | 按住说话给 Agent（hero，复用 VoiceRecognizer）、切 Session、切 Model、批准 ⏎、拒绝/中断 ⌃C、复制 ⌘C、粘贴 ⌘V |
| Mac 控制台（兜底，永远可用） | 无匹配时的默认 | 音量滑杆、亮度滑杆（内建屏）、⏯/⏭ 媒体键、🔒 锁屏（⌃⌘Q）、🚀 快速启动（自定义 app/URL） |

### 实现路径

- iOS 端新增 `ShortcutProfile` 注册表：bundle id（+终端进程名启发式）→ 套件定义（纯数据 + SwiftUI 渲染）。
- 普通按键全部走现有 `sendKeyTap` → `KeyEvent`（含 extra 修饰掩码，复用 KeyboardScreen 的 chord 模式）。
- 控制台动作需要**新 wire kind `systemCommand`（0x15）**：`IBSystemCommand { command }`，枚举：`volumeSet(Float)`、`brightnessSet(Float)`、`mediaPlayPause`、`mediaNext`、`mediaPrevious`、`lockScreen`、`launchApp(String)` / `openURL(String)`。按 AGENTS.md「How to write a new feature」9 步流程加（IBEvents → IBWire Kind/encode/decode → Broadcaster → CaptureEngine → ReceiverSession dispatch → 2 个测试）。
- Mac 端执行：`SystemCommandHandler`（新文件）
  - 音量：CoreAudio 默认输出设备 `kAudioDevicePropertyVolumeScalar`（AudioToolbox，sandbox 可用）
  - 亮度：IOKit `IODisplaySetFloatParameter`（仅内建屏；外接显示器 DDC 本版不做）
  - 媒体键/锁屏：CGEvent system-defined（NX_KEYTYPE_PLAY 等）/ ⌃⌘Q 键事件
  - 快速启动：`NSWorkspace.openApplication` / `open(URL)`
- 自定义：长按 chip/按键 → 编辑（改键/排序），按 app 存 UserDefaults。**第一版可只做展示+内置，自定义编辑放 V1.2**（减少范围）。

---

## 3. Mac：设置新增三项

在现有 Mac 设置界面（Preferences/Settings 视图，实施时先定位）新增：

1. **登录时自动启动** — `SMAppService.mainApp.register()` / `.unregister()`（macOS 13+），状态读 `SMAppService.mainApp.status`。`@AppStorage("remotecrab.mac.launchAtLogin")` 驱动。
2. **自动连接已配对 iPhone**（默认开）— 启动即开始 Bonjour 浏览 + fallback 拨号（现状已是 launch 即浏览；此项控制是否自动**连接**而不仅是浏览）。
3. **点对点直连（AWDL）**（默认开）— 双端 `NWParameters.includePeerToPeer = true`：iOS 侧 `NWListener` 的 parameters、Mac 侧 `NWBrowser` + 直连 `NWConnection` 的 parameters。wire 协议零改动。连接详情 sheet 显示传输路径（WiFi / 点对点）。

---

## 4. 明确不做（V1.1 范围外）

- ❌ 激光笔（唯一需要 Mac 端新 UI 窗口的项，砍）
- ❌ 外接显示器亮度（DDC/CI，标实验也不做）
- ❌ 睡眠/关机/专注模式（权限与安全性存疑，V1.2 再议）
- ❌ 情境按键的可视化自定义编辑器（V1.2，先内置三套）
- ❌ 推翻现有布局/配色/组件库的任何改动

## 5. 测试与验证

- `RemoteCrabCore/Tests`：`IBSystemCommand` round-trip（`IBEventsTests` 风格）+ `EventPipelineEndToEndTests` TCP round-trip；套件注册表匹配逻辑（bundle id → profile）单测。
- `./scripts/test.sh` 全绿。
- 受影响 UI 常量（`dockClearance`、`voiceCardBottomInset`）改后手动核对触控板面底部不重叠。
- AGENTS.md 同步：dock 移除、顶栏开关、新 wire kind 0x15、新设置项。

## 6. 实施顺序（概要）

1. Core：`IBSystemCommand` + wire kind 0x15 + 测试（纯增量，最安全）
2. Mac：`SystemCommandHandler` + 设置三项（SMAppService / 自动连接 / AWDL）
3. iOS 连接层：`includePeerToPeer`
4. iOS UI：FeatureDock 移除 + 顶栏开关 + PTT 行 + ⌨️ + ⏎ 主色 + 常量重测
5. iOS UI：情境 chip + 情境页（三套套件）
6. 全量验证 + AGENTS.md
