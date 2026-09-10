# Voice Minimal (Plan 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按住功能坞 🗣 → iPhone 端侧语音识别（SFSpeechRecognizer，zh-Hans/en-US）→ 松手把定稿文本以 `KeyEvent(.text)` 打进 Mac 当前焦点；语音期间麦克风流自动让路。

**Architecture:** 新增 `VoiceRecognizer`（iBridgeCapture 层，封装 SFSpeechRecognizer + AVAudioEngine 识别会话）。FeatureDock 的按住手势从「只切 voiceOn 状态」升级为「驱动 VoiceRecognizer」。语音激活期间 CaptureEngine 暂停 MicrophoneEncoder（识别独占音频输入）。权限走 PermissionFlow 新增 speech 页 + `NSSpeechRecognitionUsageDescription`。

**Tech Stack:** Speech framework (SFSpeechRecognizer/SFSpeechAudioBufferRecognitionRequest), AVAudioEngine, SwiftUI, iBridgeCore (KeyEvent/IBWire 已有，无协议变更)。

**Spec:** `docs/superpowers/specs/2026-09-11-feature-toggles-design.md` §4.3（语音最小版）。用户已批准的范围：最小可用版，端侧识别，Mac 端不做识别。

## Global Constraints

- 设计语言（AGENTS.md）：Apple 原生 Liquid Glass；SF Symbols only；UI 字符串无 emoji；技术读数用 SF Mono；`os_log` subsystem `com.ibridge`，禁止 `print()`；新代码用 `@Observable` 而非 `ObservableObject`
- 不改协议（KeyEvent `.text` 已存在，Mac 端 CGEventInjector 已能消费——Plan 2 Task 5 键盘已在用）
- 语音流 ≠ 麦克风流：语音激活时 MicrophoneEncoder 必须停止（两个 AVAudioEngine 抢同一输入硬件会冲突），松手后按 micOn 状态恢复
- Gate：`./scripts/test.sh` 全绿（49+ tests + 两个 app target 编译）
- **并行会话警告**：工作区有别的会话的未提交改动（`.gitignore`、`iBridgeCapture/Info.plist`、未跟踪的 `.ai-handoff/`、`.mddock/`、`memories/`）。只 stage 自己任务的文件，绝不碰这些
- `iBridgeCapture/Info.plist` 特殊处理：它被并行会话改着（未提交），且 project-ios.yml 的 `info.properties` 才是 xcodegen 再生时的来源。`NSSpeechRecognitionUsageDescription` 要**两边都加**：yml（提交）+ 工作树 Info.plist（**只改不 stage**，留给并行会话一起带走）

---

### Task 1: VoiceRecognizer 核心 + 麦克风让路

**Files:**
- Create: `iBridgeCapture/VoiceRecognizer.swift`
- Modify: `iBridgeCapture/CaptureEngine.swift`（syncMicrophone 让路逻辑）

**Interfaces:**
- Produces（Task 2 依赖）:
  - `@Observable final class VoiceRecognizer`，构造 `init()`，方法：
    - `func start() async -> Bool`（请求权限+启动识别会话；false=不可用/无权限）
    - `func stop()`（结束识别；最终文本通过 onFinal 回调）
    - `var partialText: String`（实时中间结果，UI 绑定）
    - `var isRunning: Bool`
    - `var onFinal: ((String) -> Void)?`（松手定稿文本，空结果不回调）
- Consumes: `FeatureStateSnapshot.voiceOn`（已存在，Plan 1）；`CaptureEngine.sendKey(_:)`（已存在）

**规格：**

`VoiceRecognizer` 实现要点：

```swift
import Speech
import AVFoundation

@Observable final class VoiceRecognizer {
    private(set) var partialText = ""
    private(set) var isRunning = false
    var onFinal: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
}
```

- 语言选择：优先 `SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))`，若 `!isAvailable` 或 `supportsOnDeviceRecognition == false` 则退 `en-US`，再退 `SFSpeechRecognizer()`（系统默认）。把选择逻辑收进 `private func makeRecognizer() -> SFSpeechRecognizer?`，注释写明「端侧优先，无端侧模型时允许服务端（SFSpeechRecognizer 默认行为）」
- `start()`：先 `SFSpeechRecognizer.requestAuthorization`（异步 await 包装）；非 `.authorized` → return false。然后 `AVAudioSession` `.record` category + `.measurement` mode + setActive(true)（包 do-catch，失败 return false）。建 `SFSpeechAudioBufferRecognitionRequest`，`shouldReportPartialResults = true`，若 `recognizer.supportsOnDeviceRecognition` 则 `requiresOnDeviceRecognition = true`。`recognizer.recognitionTask(with:request)` 回调里更新 `partialText`（跳 MainActor）。tap：`inputNode.installTap(onBus: 0, bufferSize: 1024, format:)` → append buffer。audioEngine.prepare + start
- `stop()`：`audioEngine.stop()`、`inputNode.removeTap(onBus: 0)`、`request.endAudio()`；在 task 的 isFinal 回调或 1.5s 兜底延迟后：取最终文本（非空去空白后）调 `onFinal`，然后 cleanup（task.cancel、request=nil、`try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)`）。注意 onFinal 只调一次（用 flag 防 isFinal 与兜底双触发）
- 所有属性读写收敛到 MainActor（类标 `@MainActor` 或内部 hop，遵循既有代码风格）
- os_log：subsystem `com.ibridge`，category `VoiceRecognizer`；记录授权结果、识别错误、on-device 是否可用

`CaptureEngine.swift` 让路（最小改动）：

- `handleFeaturesChanged` 与 `.ready` 分支里的 `syncMicrophone(snapshot.micOn)` / `syncMicrophone(features.micOn)` 全部改为 `syncMicrophone(micOn && !voiceOn)`（取对应作用域里的值）
- 不动 MicrophoneEncoder 本身（stop/start 已幂等）

- [ ] **Step 1: 写 VoiceRecognizer.swift + CaptureEngine 让路改动**
- [ ] **Step 2: `./scripts/test.sh` 全绿 + Commit**

```bash
git add iBridgeCapture/VoiceRecognizer.swift iBridgeCapture/CaptureEngine.swift
git commit -m "feat(ios): voice recognizer core + mic stream yield during voice"
```

---

### Task 2: FeatureDock 接线 + 悬浮识别卡 + VoiceOver

**Files:**
- Modify: `iBridgeCapture/FeatureDock.swift`（voice 按钮驱动 VoiceRecognizer）
- Modify: `iBridgeCapture/ContentView.swift`（持有 VoiceRecognizer、悬浮卡 overlay、onFinal → sendKey）

**Interfaces:**
- Consumes: Task 1 的 `VoiceRecognizer`（`partialText/isRunning/onFinal/start()/stop()`）；`CaptureEngine.sendKey(KeyEvent)`、`KeyEvent(kind: .text, text:)`（IBEvents.swift，签名以现有代码为准）；`FeatureStore.set(feature: .voice, enabled:)`（现状）
- Produces: 无（终端任务）

**规格：**

- `ContentView` 层 `@State private var voiceRecognizer = VoiceRecognizer()`（或 engine 持有，取与现有环境注入最自然的方式——ContentView 已 `@EnvironmentObject engine`）。onAppear 时配置 `voiceRecognizer.onFinal = { text in engine.sendKey(KeyEvent(kind: .text, keyCode: nil, text: text, ...)) }`——KeyEvent 的初始化参数以 `iBridgeCore/Sources/iBridgeCore/Networking/IBEvents.swift` 实际签名为准，参照 KeyboardScreen 里 `.text` 的既有用法
- `FeatureDock` 加一个 `let voice: VoiceRecognizer` 参数；voiceButton 的 DragGesture：`onChanged` 首次 → `features.set(feature: .voice, enabled: true)` + `Task { await voice.start() }`；`onEnded` → `features.set(feature: .voice, enabled: false)` + `voice.stop()`。`start()` 返回 false（无权限）时：立即 `features.set(feature: .voice, enabled: false)`（按钮不亮假状态）
- **悬浮识别卡**：voice.isRunning 时在坞上方悬浮一张圆角卡（IBMaterial/bar 材质，与 FeatureDock 同风格）：实时显示 `voice.partialText`（空时显示 "Listening…"），左侧一个红色 `waveform` SF Symbol。任一面上都要显示（overlay 在 ContentView 根 ZStack，和 PiP 同级），不拦截触摸（`.allowsHitTesting(false)`）
- **VoiceOver**（Task 4 评审留的尾巴）：voice 按钮加 `.accessibilityAction(named: "Start Voice Input")` / 松开语义无法由 action 表达——改为：VoiceOver 下双击切换 start/stop（`accessibilityAction` 里 `voiceHeld ? stop : start`），label 文案保持现状即可
- 松开 → 定稿文本打进 Mac 后，卡片显示一行 "Sent" 勾 0.8s 再消失（轻反馈；实现不起就降级为直接消失，注释说明）

- [ ] **Step 1: 接线 FeatureDock + ContentView 悬浮卡**
- [ ] **Step 2: `./scripts/test.sh` 全绿 + Commit**

```bash
git add iBridgeCapture/FeatureDock.swift iBridgeCapture/ContentView.swift
git commit -m "feat(ios): hold-to-talk voice input wired to speech recognition"
```

---

### Task 3: 权限 — speech 页 + UsageDescription

**Files:**
- Modify: `iBridgeCapture/PermissionFlow.swift`（Stage 加 speech）
- Modify: `project-ios.yml`（info.properties 加 NSSpeechRecognitionUsageDescription——提交）
- Modify: `iBridgeCapture/Info.plist`（同 key——**只改不 stage**，并行会话占用中）

**规格：**

- `PermissionFlow.Stage` 加 `case speech`（放在 microphone 之后、localNetwork 之前）：
  - title: "Speech Recognition"
  - symbol: "waveform"
  - reason: "Hold the voice button to dictate text into your Mac. Recognition happens on your iPhone — audio never leaves your device for this feature."
- `requestSpeech()`：`SFSpeechRecognizer.authorizationStatus()` + `SFSpeechRecognizer.requestAuthorization`（continuation 包装，与 requestCamera 同模式）；`.authorized` → granted，其余 → denied
- `import Speech`
- project-ios.yml `info.properties`（NSMicrophoneUsageDescription 行之后）加：
  ```yaml
  NSSpeechRecognitionUsageDescription: iBridge recognizes your speech on-device to type into your Mac.
  ```
- iBridgeCapture/Info.plist 工作树加同 key/string（跟随现有 key 顺序，插在 NSMicrophoneUsageDescription 后），**不要 git add 这个文件**
- Commit 只含 PermissionFlow.swift + project-ios.yml

- [ ] **Step 1: PermissionFlow + yml + 工作树 plist**
- [ ] **Step 2: `./scripts/test.sh` 全绿 + Commit**

```bash
git add iBridgeCapture/PermissionFlow.swift project-ios.yml
git commit -m "feat(ios): speech recognition permission — onboarding page + usage description"
```

---

### Task 4: Plan 2 polish wave（Minor 清扫）

**Files:**
- Modify: `iBridgeCapture/KeyboardScreen.swift`、 `iBridgeCapture/TouchpadScreen.swift`、`iBridgeCapture/Input/TouchSurface.swift`、`iBridgeCore/Sources/iBridgeCore/Text/TextDiff.swift`（路径以实际为准，TextDiff 在 Plan 2 Task 1 引入，先 grep 定位）

**规格（全部来自 Plan 2 终审确认的 Minor 清单，逐条修）：**

1. `KeyboardScreen.swift:23` 附近：删除未使用的 log 声明
2. `KeyboardScreen.swift:76` 附近：延迟 focus 的 asyncAfter 加守卫——触发时若 `features.activeSurface != .keyboard` 则放弃 focus
3. `TouchpadScreen.swift` coach marks：3.5s 淡出 asyncAfter 加代际守卫（capture 当前 showing 计数/世代 token，过期不执行），避免重入截断
4. `TouchSurface.swift` 转盘模式：记录 armed 时的 touch identity（`ObjectIdentifier(touch)` 或保存 UITouch 引用），后续只跟踪同一根手指，不再 `touches.first`
5. `TouchSurface.swift` 转盘 tick 触感：尊重 `scrollTickHaptics` 开关（与惯性滚动 tick 同一开关语义）
6. TextDiff 注释：forward-delete/backspace 表述修正（代码行为不变）

每条都是 5-15 行小改；一次 commit。

- [ ] **Step 1: 六条修复**
- [ ] **Step 2: `./scripts/test.sh` 全绿 + Commit**

```bash
git add iBridgeCapture/KeyboardScreen.swift iBridgeCapture/TouchpadScreen.swift iBridgeCapture/Input/TouchSurface.swift iBridgeCore/Sources/iBridgeCore/Text/TextDiff.swift
git commit -m "fix(ios): polish wave — focus guards, coach-mark generation, wheel touch identity"
```

---

## 完成后状态（Plan 3 验收标准）

- `./scripts/test.sh` 全绿
- 按住坞上 🗣：语音激活（按钮变红），悬浮卡实时出中间文本；松手定稿 → Mac 当前焦点收到文本（KeyEvent .text，走既有键盘通道）
- 语音期间麦克风流自动停，松手后按 micOn 恢复
- 首次使用触发 speech 权限请求；PermissionFlow 有 speech 页；Info.plist（工作树）+ project-ios.yml 都有 NSSpeechRecognitionUsageDescription
- 无权限时按住不亮假状态
- Plan 2 六条 Minor 清扫完毕

## 移交 / 真机验证清单

- 中文/英文识别实测；端侧模型是否已下载（requiresOnDeviceRecognition 在无端侧模型时的行为）
- 语音与麦克风让路的时序手感（松手后麦克风流恢复延迟）
- "Sent" 反馈如降级需真机确认观感
- 协议层无变更，Mac 端零改动

## 不做的事（YAGNI）

- 语音命令（"按回车" 等指令解析）→ backlog
- 实时流式上屏（边说边打，非松手定稿）→ backlog
- Mac 端识别路径 → 显式排除（spec §9）
