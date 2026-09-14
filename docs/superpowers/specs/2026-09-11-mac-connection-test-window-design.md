# Mac 连接自检窗口（Connection Test Window）设计

Date: 2026-09-11 · Status: approved by user (goal mode, no intermediate check-ins)

## 背景 / 问题

Mac receiver 收到 iPhone 的 touch / key / audio 帧后直接注入系统
（`ReceiverSession.handleInbound` → `inputInjector` / `audioPlayer`），
UI 层完全看不到这些事件。用户无法直观验证"键盘/触控板/麦克风通了没有"。

已有资产：
- `session.latestFrame: CGImage?`（解码后的实时帧，ControlPanel / PreviewWindow 在用）
- `session.metadata / state / featureState`（连接与流信息）
- ping/pong 真实 RTT（`state.streaming(name:latencyMs:)`）
- `MenuBarMenu` 的 ActionRow（"Open Control Panel" / "Open Preview Window"）
  **目前全是纯 View，没有接 action** —— 本次一并接上

## 目标

一个新的「连接自检」窗口（id: `test`），从菜单栏和控制面板都能打开，
一屏四象限实时验证：

| 象限 | 内容 | 数据源 |
|---|---|---|
| 摄像头 | 实时画面 + 分辨率/fps/码率/延迟 overlay | `session.latestFrame`（已有） |
| 键盘 | 按键回显文本（环形缓冲）+ 最后按键徽章（keycode + 修饰键） | 新增 KeyEvent 镜像 |
| 触控板 | 测试板：圆点跟随 (x,y) 归一化坐标、按下/抬起/点击视觉反馈、手势类型标签（scroll/pinch/三指等） | 新增 TouchEvent 镜像 |
| 麦克风 | 实时 RMS 电平条（10Hz 刷新） | 新增 AudioPlayer RMS |

事件镜像**不影响**正常注入路径（先镜像、后注入，顺序不变）。

## 数据管道改动

### ReceiverSession（增量）

新增 `@Published` 镜像状态（全部 MainActor 内更新）：

```swift
@Published private(set) var typedText: String = ""        // 最近 ~200 字符
@Published private(set) var lastKey: KeyEvent?            // 最近一个 down/text 事件
@Published private(set) var touchVisual: TouchVisual?     // 见下
@Published private(set) var micLevel: Float = 0           // 0..1 RMS
@Published private(set) var latencyHistory: [Int] = []    // 最近 30 个 RTT 样本
```

`TouchVisual` 是 UI 友好的值类型：phase、x、y（0..1）、dx、dy、
modifiers、接收时间（用于淡出）。

挂接点（`handleInbound`）：
- `.touch`：`decodeTouch` 成功后 → 写 `touchVisual`，再 `inputInjector.inject`
- `.key`：`decodeKey` 成功后 → `.text` 追加到 `typedText`（截断 200），
  `.down` 更新 `lastKey`；再 `inputInjector.inject`
- `.audio`：`audioPlayer.consume` 不变；RMS 在 AudioPlayer 内算
- `.ping`：RTT 计算后 append 到 `latencyHistory`（截断 30）

连接断开（`.failed` / `.cancelled`）时清空 typedText/lastKey/touchVisual/micLevel。

### AudioPlayer（增量）

`consume(_:)` 在 append PCM 前对 `packet.opusData`（16-bit interleaved PCM）
算 RMS，通过闭包 `onLevel: ((Float) -> Void)?` 回调（10Hz 节流，
由 AudioPlayer 内部按 packet 时间戳节流）。ReceiverSession 在 init 里
把回调接到 `micLevel`（跳 MainActor）。

### 新文件 `RemoteCrabReceiver/TestWindowView.swift`

SwiftUI 四象限视图，遵循现有设计系统（IBFont/IBColor/圆角卡片/白字深色渐变，
与 ControlPanelView 同语言）。纯展示，不持有状态——全部读 `session`。

- 摄像头象限：`session.latestFrame` 大图，无帧时显示 placeholder
- 键盘象限：ScrollView 回显 `typedText`（等宽字体），`lastKey` 徽章
  显示修饰键符号（⌃⌥⇧⌘）+ keycode（SF Mono）
- 触控板象限：圆角矩形测试板，内部圆点位置 = (x, y) × 板尺寸；
  `.down/.rightDown/.click` 时圆点放大 + 描边；`.scroll` 显示方向箭头；
  右上角标签显示 phase 名称；500ms 无新事件圆点淡出
- 麦克风象限：水平电平条（绿→黄→红梯度），`micLevel` 驱动，
  带 150ms 衰减动画

### 窗口注册与入口（`RemoteCrabReceiverApp.swift` / `MenuBarMenu.swift` / `ControlPanelView.swift`）

- App 新增 `Window("Connection Test", id: "test")`，默认 560×640
- `MenuBarMenu` 的 ActionRow 全部接上 `@Environment(\.openWindow)`：
  - Open Control Panel → `openWindow(id: "controls")`
  - Open Preview Window → `openWindow(id: "preview")`
  - 新增 Connection Test → `openWindow(id: "test")`
- `ControlPanelView` 的 `OpenPreviewWindow` stub 接上 `openWindow(id: "preview")`，
  actionRow 增加一个打开自检窗口的按钮
- 控制面板 `latencySamples` 假正弦波 → `session.latencyHistory` 真数据

## 不做（YAGNI）

- 不改 wire 协议、不动 iOS 端
- 不做事件回放 / 录制 / 导出日志
- 不做音频波形图（电平条够用）
- 不自检窗口里加"反向测试"（Mac→iPhone）——feature 开关已在菜单栏

## 测试

- `RemoteCrabCore/Tests/` 不动（无协议变更）
- 新增轻量单测（放在 Receiver target 没有测试束——不加；用真机验证）
- 验证路径：`./scripts/test.sh`（26 测试 + 双端 build）→ 真机 e2e：
  iPhone 已连接状态下打开自检窗口，iPhone 上打字/滑触控板/说话，
  四象限实时响应

## 风险 / 注意

- **并行 session 在改同一批 Mac 文件**（MenuBarMenu / ControlPanelView /
  RemoteCrabReceiverApp）。动手前 `git status` + 重读文件；在
  `.ai-handoff/STATUS.md` 登记领地。新增文件（TestWindowView.swift）
  无冲突风险。
- `AudioPlayer.consume` 在专用 queue 上跑；RMS 回调必须跳 MainActor
  才能写 `@Published`。
- touch 坐标是 iPhone 屏幕归一化坐标，直接映射到测试板即可，
  不要做屏幕尺寸换算。
