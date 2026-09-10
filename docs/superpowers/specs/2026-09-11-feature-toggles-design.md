# iBridge V0.3 — 功能独立开关与组合 UX 重设计

日期：2026-09-11
状态：已获用户批准（脑暴全程经 visual companion 视觉确认）
涉及：iOS 主界面重构、触控板/键盘交互升级、协议双向化、Mac 端真实控制

---

## 1. 背景与问题

当前实现（V0.2）中功能是「模式隐含」的，而非一等公民开关：

- 主界面是 Camera / Trackpad / Keyboard 三选一模式切换，任何时刻只看到一个功能
- 键盘模式是自绘 QWERTY，但**没有接任何输入框，打不出字**（`KeyboardScreen.swift:158`）
- `CaptureEngine.startIfNeeded()` 零调用，**相机实际不启动**（9-10 重构遗留）
- 设置页（分辨率/帧率/灵敏度/保持亮屏）写入 `@AppStorage` 但**没有任何代码消费**
- 麦克风在 ContentView 和设置页各有一个互不同步的开关
- 触控板缺拖拽/惯性滚动/捏合/加速曲线；屏幕中央常驻提示卡遮挡触摸区
- Mac 端四个功能开关是 `.constant(true)` 摆设，Mac 对 iPhone 零控制

用户目标：相机/麦克风/触控板/键盘**独立开启、自由组合**；键盘打字要舒服（含中文）；
触控板交互要完整且有 iPhone 特有的质感；并为「远程操控 coding agent、语音输入」
的未来场景铺路。

## 2. 核心概念模型：流 vs 面

| 类别 | 功能 | 语义 |
|---|---|---|
| **流**（后台能力） | 相机、麦克风、语音转文字 | 打开即在后台传输，与屏幕显示无关 |
| **面**（前台交互） | 触控板、键盘（含键鼠一体）、相机预览 | 占用屏幕的交互界面 |

已选定 **方案 A · 功能坞**（用户从 A/B/C 三版视觉稿中点选）：

- 主屏底部常驻 5 图标坞：相机 🎥 / 麦克风 🎙 / 语音 🗣 是**开关**（点亮 = 正在流传输）；
  触控板 🖐 / 键盘 ⌨️ 是**面**（点亮 = 当前占屏；它们的事件流跟随面走）
- 相机开着但当前面是触控板/键盘 → 角落悬浮画中画预览，可拖动、点按进全屏预览面
- 状态一目了然：坞上亮着的图标 = 正在传给 Mac 的能力全集

（备选 B Bento 仪表盘、C 模式+开关条已被用户否决，存档于
`.superpowers/brainstorm/66047-1789043582/content/home-paradigm.html`）

## 3. 状态模型：单一事实源

新增 `FeatureStore`（iOS 端，`@Observable`，遵循 AGENTS.md 不用 ObservableObject）：

```swift
@Observable final class FeatureStore {
    var cameraOn: Bool          // 流
    var micOn: Bool             // 流
    var voiceOn: Bool           // 流（按住说话期间为 true）
    var activeSurface: Surface  // .trackpad / .keyboard / .cameraPreview
    var lockedModifiers: ModifierSet  // ⌃⌥⌘⇧ 锁定状态，触控板/键盘共享
}
```

- Dock、CaptureEngine、设置页、PiP 预览全部绑定 `FeatureStore`
- 消灭 ContentView / IOSSettingsView 两处 mic 开关不同步问题
- 状态快照通过 `featureState` 帧同步给 Mac（见 §5）
- 共享的 Codable 定义（`Feature` 枚举、`FeatureStateSnapshot`）放 iBridgeCore/Networking/IBEvents.swift

## 4. iOS 端界面

### 4.1 键盘面 — K3 键鼠一体（用户选定）

布局自上而下：

1. **输入预览卡**：显示正在输入到 Mac 的文本（目标 app 名后续迭代）
2. **小触控区**：复用触控板手势引擎的缩窄条，打字中途挪光标/点击零切换
3. **快捷键条**：esc / tab / ⌃ / ⌥ / ⌘ / ⇧ / ← / →；修饰键点按锁定（蓝色高亮），
   锁定后击键 = 组合键（如 ⌘ 锁定 + C = ⌘C）
4. **iOS 系统键盘**：隐藏的 `UITextField` 常驻第一响应者，文本差异 → `KeyEvent(.text)`

- 中文输入法/听写/自动纠错/剪贴板粘贴全部免费获得（用户明确选择此路径，
  否决自绘键盘逐键 keycode 方案——后者无中文输入法）
- 现有自绘 QWERTY 整体删除
- **Backlog（本次不做）**：K2 可自定义快捷指令 chips（「继续」「y ↵」「⌘C」），
  留给远程操控 agent 迭代；视觉稿已存档

### 4.2 触控板面

基础补齐（用户全选）：

- **拖拽**：D1 双击按住拖（tap-and-a-half，与 Mac 触控板/iOS 选词一致；
  用户认可，否决长按方案——避免与压感冲突）
- **惯性滚动**：双指滚动松手后按衰减曲线继续逐帧发 scroll 事件
- **捏合缩放**：→ Mac 端 Magnification 事件（CGEvent）
- **指针加速曲线**：快滑远、慢滑精；设置页灵敏度（1–5）真正接入曲线参数
- 中央常驻提示卡删除 → 改为前 3 次使用淡显 coach marks（`@AppStorage` 计数）

创新（用户选定 I1/I3/I5 为核心默认能力）：

- **I1 触感滚轮**：CHHapticEngine —— 滚动刻度哒哒感、点按按键感、
  拖拽拿起/放下沉感、捏合到头回弹
- **I3 指腹压感**：`UITouch.majorRadius` 接触面积检测 → Force Click
  （右键/Quick Look）；首次使用引导校准，阈值持久化
- **I5 三指系统手势**：上滑 Mission Control、左右切桌面、点按中键
  → 协议新增 `threeFinger(direction)` 事件

实验室（设置 → 实验室，默认关闭，作为「惊喜开关」）：

- **I2 空中鼠标**：CoreMotion 姿态 → 光标增量；开启后触控面出现悬浮
  激活按钮（按住激活），演示/沙发场景用
- **I4 转盘滚动**：单指画圈 = 连续滚动，iPod click wheel 式

### 4.3 语音最小版

- 任意面**按住**坞上 🗣 → `SFSpeechRecognizer` 端侧识别（zh-Hans / en-US）
- 悬浮卡实时显示中间识别结果；松手定稿 → `KeyEvent(.text)` 打进 Mac 当前焦点
- Info.plist 加 `NSSpeechRecognitionUsageDescription`；PermissionFlow 加一页
- 语音开启期间麦克风流自动让路（识别独占音频输入，语音流 ≠ 麦克风流）

## 5. 协议扩展（双向化）

现有协议为 iOS→Mac 单向。本次新增（遵循 AGENTS.md 9 步模式，每步带测试）：

| Kind | Code | 方向 | Payload |
|---|---|---|---|
| `featureControl` | `0x07` | **Mac→iPhone（首个反向帧）** | JSON `{feature, enabled}` |
| `featureState` | `0x08` | iOS→Mac | JSON `FeatureStateSnapshot` 全量快照，连接时 + 每次变化时发送 |
| TouchEvent 扩展 | — | iOS→Mac | 新相位：`dragStart`、`pinch(scale)`、`threeFinger(direction)`、`forceClick` |

- iOS 端在 `CaptureEngine`/`IBEventBroadcaster` 增加接收循环（目前只发不收）
- Mac 端 `ReceiverSession` 增加发送能力
- 向后兼容：旧版 Mac 不发 0x07，iOS 端功能开关照常本地工作；
  旧版 iOS 不发 0x08，Mac 端开关保持禁用态（显示「需要更新 iPhone 端」）

## 6. Mac 端

- `ReceiverSession` 改双向：发 `featureControl`、收 `featureState`
- MenuBarMenu 四个功能开关绑定真实状态：点击发 0x07；iPhone 端状态变化实时回显
- ControlPanel 的 CAM/MIC/TPAD/KEY 徽章接真值（关掉的功能实时灰掉）
- 修复延迟显示：现在是「连接时长」，改为真 RTT ping（复用 0x08 的往返或轻量心跳）

## 7. 还债清单（新架构的前置条件）

1. 接上 `CaptureEngine.startIfNeeded()`（相机不启动的回归）
2. 设置页生效：分辨率/帧率 → CaptureEngine 重配置；灵敏度 → 加速曲线；
   保持亮屏 → `isIdleTimerDisabled`
3. mic 开关统一到 FeatureStore（删除 ContentView/Settings 重复状态）
4. `print()` → `os_log`（subsystem `com.ibridge`）
5. 删除 KeyboardScreen 头部 emoji（违反 AGENTS.md 设计规范）
6. TouchpadScreen 修饰键条误发 `.down` 事件的问题（`TouchpadScreen.swift:149`）

## 8. 测试

- `IBEventsTests.swift`：FeatureControl / FeatureStateSnapshot / TouchEvent 新相位 round-trip
- `EventPipelineEndToEndTests.swift`：新帧 TCP 端到端；Mac→iPhone 反向帧管道
- 触控板手势状态机：用 `RecordingInputInjector` 断言事件序列
  （双击按住 → dragStart + move 序列；双指滚动 → 惯性衰减序列）
- FeatureStore 单元测试：开关组合 → 快照序列化正确性
- `./scripts/test.sh` 必须保持全绿

## 9. 不做的事（YAGNI / 显式排除）

- K2 快捷指令 chips → backlog（agent 迭代再做）
- 多 Mac/多 iPhone 选择器（沿用「自动连第一台」）
- Mac 端主动推拉流配置（分辨率等仍只能 iPhone 端改）
- 语音识别的 Mac 端识别路径（用户选 iPhone 端识别）
- Opus、虚拟麦克风、Camera Extension 已在 roadmap 其它条目

## 10. 决策记录

| 问题 | 结论 | 来源 |
|---|---|---|
| 主场景 | 摄像头与遥控器并重；未来远程操控 agent + 语音输入 | 用户 |
| 主屏范式 | A · 功能坞（否决 B/C） | 视觉稿点选 |
| Mac 能否控制 iPhone 功能 | 能（协议双向化） | 用户 |
| 键盘输入路径 | 系统键盘 + 快捷键条（否决自绘 keycode 键盘） | 用户 |
| 键盘面布局 | K3 键鼠一体；K2 chips 进 backlog | 视觉稿点选 |
| 语音范围 | 最小可用版（端侧识别 → 文本打进 Mac） | 用户 |
| 触控板补齐 | 拖拽/惯性/捏合/加速曲线 全要 | 用户多选 |
| 拖拽触发 | D1 双击按住拖 | 用户认可推荐 |
| 创新点 | I1 触感 + I3 压感 + I5 三指为核心；I2 空中鼠标 + I4 转盘进实验室默认关 | 用户 |
