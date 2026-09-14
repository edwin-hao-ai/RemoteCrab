# Plan 2 — iOS 功能坞主屏 + K3 键鼠一体键盘 + 触控板手势引擎 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the iOS main UI around the Feature Dock (streams vs surfaces), replace the mock keyboard with a system-keyboard K3 layout, and give the trackpad a real gesture engine (drag / momentum scroll / pinch / accel curve / haptics / force click / three-finger) plus Labs (air mouse, wheel scroll).

**Architecture:** Pure, unit-testable logic (acceleration curve, momentum decay, text diffing) lives in RemoteCrabCore. A single reusable UIKit touch surface (`TouchSurfaceUIView`) produces all `TouchEvent`s and is embedded by both the trackpad screen and the keyboard's mini-trackpad strip. `FeatureStore` (Plan 1) drives the dock and surface switching; `CGEventInjector` learns to apply modifier flags.

**Tech Stack:** Swift, SwiftUI, UIKit gesture recognizers, CoreMotion (labs), UIFeedbackGenerator, XCTest.

**前置依赖（Plan 1 已落地，签名可直接用）：**
- `FeatureStore`：`cameraOn/micOn/voiceOn/trackpadOn/keyboardOn`（private(set)，经 `set(feature:enabled:)` 修改）、`activeSurface: Surface`（public var）
- `CaptureEngine.features`、`engine.sendTouch(_:)`、`engine.sendKey(_:)`（已按 trackpadOn/keyboardOn 门控）
- `TouchEvent.Phase` 新相位：`dragStart / pinch / threeFingerSwipe / threeFingerTap / forceClick`
- `IBModifierBar`（RemoteCrabCore 组件，`activeModifiers: Binding<Set<IBModifierBar.Modifier>>`，Modifier 有 `.control/.option/.command/.shift`）

## Global Constraints

- `./scripts/test.sh` 每个 Task 必须全绿（37 tests + 双 target）
- 新代码 `@Observable`；不新增 `print(`（os_log, subsystem `com.remotecrab`）；UI 无 emoji
- UI 文案沿用 `IBLocale` 既有 key；新文案直接硬编码英文（与现状一致），不进 xcstrings
- **keycode 语义澄清**：`KeyEvent.keycode` 文档原写"USB HID"，但 Mac 端 `CGEventInjector.postKey` 直接把它当 `CGKeyCode`（macOS 虚拟键码）用。本计划统一为 **macOS CGKeyCode**，并修正 IBEvents.swift 注释。常用值：esc=53, tab=48, delete=51, return=36, ←=123, →=124, ↑=126, ↓=125
- 触感用 `UIFeedbackGenerator`（scroll tick = `UISelectionFeedbackGenerator`，click/drag = `UIImpactFeedbackGenerator`），不用 CHHapticEngine —— 这是对 spec §4.2 措辞的收敛，理由是 generator 正是为这类离散反馈设计的，无需手工排布 haptic pattern
- 触控板修饰键必须端到端生效：iOS 事件携带 bitmask（shift=1, control=2, option=4, command=8），Mac 端注入时转成 CGEventFlags

---

### Task 1: RemoteCrabCore 纯逻辑 — TrackpadMath + TextDiff

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/Input/TrackpadMath.swift`
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/Input/TextDiff.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/TrackpadMathTests.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/TextDiffTests.swift`

**Interfaces:**
- Produces（Task 2/5 依赖）:
  - `TrackpadMath.accelerate(dx: Float, dy: Float, sensitivity: Int) -> (dx: Float, dy: Float)`
  - `TrackpadMath.momentumStep(velocity: CGPoint, elapsedSeconds: Double) -> (delta: CGPoint, newVelocity: CGPoint)?`（nil = 停止）
  - `TextDiff.events(from old: String, to new: String) -> [KeyEvent]`

- [ ] **Step 1: 写失败测试 TrackpadMathTests**

```swift
import XCTest
@testable import RemoteCrabCore

final class TrackpadMathTests: XCTestCase {

    func testAccelerateIdentityForSlowMoves() {
        let (dx, dy) = TrackpadMath.accelerate(dx: 0.001, dy: 0, sensitivity: 3)
        XCTAssertGreaterThan(dx, 0)
        XCTAssertEqual(dy, 0)
    }

    func testAccelerateFastMoveGainsMore() {
        let slow = TrackpadMath.accelerate(dx: 0.002, dy: 0, sensitivity: 3).dx
        let fast = TrackpadMath.accelerate(dx: 0.02, dy: 0, sensitivity: 3).dx
        // Fast flicks gain proportionally more than slow drags.
        XCTAssertGreaterThan(fast / 0.02, slow / 0.002)
    }

    func testSensitivityOrdering() {
        let s1 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 1).dx
        let s5 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 5).dx
        XCTAssertGreaterThan(s5, s1)
    }

    func testSensitivityClamped() {
        let s0 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 0).dx
        let s1 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 1).dx
        let s9 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 9).dx
        let s5 = TrackpadMath.accelerate(dx: 0.005, dy: 0, sensitivity: 5).dx
        XCTAssertEqual(s0, s1, accuracy: 0.0001)
        XCTAssertEqual(s9, s5, accuracy: 0.0001)
    }

    func testMomentumDecaysAndStops() {
        var v = CGPoint(x: 0, y: 800)   // 800 pt/s downward
        var steps = 0
        while let step = TrackpadMath.momentumStep(velocity: v, elapsedSeconds: 1.0 / 60.0) {
            v = step.newVelocity
            steps += 1
            XCTAssertLessThan(abs(v.y), 800.0 + 0.01)
            XCTAssertLessThan(steps, 600)  // must terminate
        }
        XCTAssertGreaterThan(steps, 10)    // but actually glide a while
    }

    func testMomentumBelowCutoffStopsImmediately() {
        XCTAssertNil(TrackpadMath.momentumStep(velocity: CGPoint(x: 0, y: 10), elapsedSeconds: 1.0 / 60.0))
    }
}
```

- [ ] **Step 2: 写失败测试 TextDiffTests**

```swift
import XCTest
@testable import RemoteCrabCore

final class TextDiffTests: XCTestCase {

    func testPureInsertion() {
        let events = TextDiff.events(from: "abc", to: "abcd")
        XCTAssertEqual(events, [KeyEvent(action: .text, text: "d")])
    }

    func testPureDeletion() {
        let events = TextDiff.events(from: "abcd", to: "ab")
        // two backspaces: down+up each, keycode 51 (macOS delete)
        XCTAssertEqual(events, [
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
        ])
    }

    func testReplacement() {
        // "abc" → "axc": delete "b" then insert "x"
        let events = TextDiff.events(from: "abc", to: "axc")
        XCTAssertEqual(events, [
            KeyEvent(action: .down, keycode: 51),
            KeyEvent(action: .up, keycode: 51),
            KeyEvent(action: .text, text: "x"),
        ])
    }

    func testNoChangeProducesNothing() {
        XCTAssertTrue(TextDiff.events(from: "same", to: "same").isEmpty)
    }

    func testUnicodeInsertion() {
        let events = TextDiff.events(from: "", to: "你好")
        XCTAssertEqual(events, [KeyEvent(action: .text, text: "你好")])
    }

    func testEmptyFromIsPureInsertion() {
        XCTAssertEqual(TextDiff.events(from: "", to: "hello"),
                       [KeyEvent(action: .text, text: "hello")])
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `cd RemoteCrabCore && swift test --filter TrackpadMathTests`
Expected: 编译失败

- [ ] **Step 4: 实现 TrackpadMath.swift**

```swift
import CoreGraphics
import Foundation

/// Pure pointer/scroll math for the iPhone-as-trackpad surface.
/// Kept in RemoteCrabCore (no UIKit) so the curves are unit-testable.
public enum TrackpadMath {

    /// Pointer acceleration: slow drags stay precise, fast flicks
    /// travel further. `sensitivity` is the 1...5 settings value.
    /// Input/output are normalized screen units (0...1 per axis).
    public static func accelerate(dx: Float, dy: Float, sensitivity: Int) -> (dx: Float, dy: Float) {
        let s = Float(max(1, min(5, sensitivity)))
        let baseGain: Float = 0.6 + 0.35 * (s - 1)   // 0.6 … 2.0
        let speed = sqrtf(dx * dx + dy * dy)
        let boost: Float = 1 + min(speed * 6, 2.0)   // fast flicks up to 3×
        let gain = baseGain * boost
        return (dx * gain, dy * gain)
    }

    /// One momentum-scroll step after the fingers lift.
    /// `velocity` is in points/second (UIKit's pan velocity).
    /// Returns the normalized scroll delta for this frame and the
    /// decayed velocity, or nil once the glide is imperceptible.
    public static func momentumStep(
        velocity: CGPoint,
        elapsedSeconds: Double
    ) -> (delta: CGPoint, newVelocity: CGPoint)? {
        let speed = hypot(velocity.x, velocity.y)
        guard speed >= 40 else { return nil }        // pt/s cutoff

        let dt = CGFloat(elapsedSeconds)
        let delta = CGPoint(x: velocity.x * dt, y: velocity.y * dt)
        let decay = pow(0.94, dt * 60)               // per-60fps-frame decay
        let newVelocity = CGPoint(x: velocity.x * decay, y: velocity.y * decay)
        return (delta, newVelocity)
    }
}
```

- [ ] **Step 5: 实现 TextDiff.swift**

```swift
import Foundation

/// Computes the minimal key-event sequence that transforms one
/// committed text into another — deletions as backspace key events
/// (macOS keycode 51), insertions as a single `.text` batch.
///
/// Used by the K3 keyboard surface: the system keyboard edits a
/// hidden UITextField, and every `editingChanged` turns into events
/// shipped to the Mac.
public enum TextDiff {

    /// macOS virtual keycode for forward-delete (backspace).
    public static let backspaceKeyCode: UInt16 = 51

    public static func events(from old: String, to new: String) -> [KeyEvent] {
        guard old != new else { return [] }

        let oldChars = Array(old)
        let newChars = Array(new)

        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count,
              oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let deletedCount = oldChars.count - prefix - suffix
        let inserted = String(newChars[prefix ..< newChars.count - suffix])

        var events: [KeyEvent] = []
        for _ in 0 ..< deletedCount {
            events.append(KeyEvent(action: .down, keycode: backspaceKeyCode))
            events.append(KeyEvent(action: .up, keycode: backspaceKeyCode))
        }
        if !inserted.isEmpty {
            events.append(KeyEvent(action: .text, text: inserted))
        }
        return events
    }
}
```

- [ ] **Step 6: 运行确认通过 + Commit**

Run: `cd RemoteCrabCore && swift test`
Expected: 全部 PASS（37 + 12 新 = 49）

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/Input/TrackpadMath.swift RemoteCrabCore/Sources/RemoteCrabCore/Input/TextDiff.swift RemoteCrabCore/Tests/RemoteCrabCoreTests/TrackpadMathTests.swift RemoteCrabCore/Tests/RemoteCrabCoreTests/TextDiffTests.swift
git commit -m "feat(core): trackpad accel/momentum math + text diffing"
```

---

### Task 2: CGEventInjector 修饰键端到端 + keycode 注释修正（Mac 端 + Core 注释）

**Files:**
- Modify: `RemoteCrabReceiver/Input/CGEventInjector.swift`
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift`（注释）

**Interfaces:**
- Consumes: `TouchEvent.modifiers` / `KeyEvent.modifiers` bitmask（shift=1, control=2, option=4, command=8）
- Produces: 无新公开接口

**背景：** Plan 1 终审确认修饰键从未端到端生效——iOS 端 modifierMask 恒 0（Task 6 才接），Mac 端从不读 modifiers。本任务修 Mac 端；iOS 端在 Task 4/6 接。

- [ ] **Step 1: CGEventInjector 加 flags 应用**

新增私有方法：

```swift
    /// TouchEvent/KeyEvent modifier bitmask (shift=1, control=2,
    /// option=4, command=8) → CGEventFlags.
    private func eventFlags(for mask: UInt8) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mask & 1 != 0 { flags.insert(.maskShift) }
        if mask & 2 != 0 { flags.insert(.maskControl) }
        if mask & 4 != 0 { flags.insert(.maskAlternate) }
        if mask & 8 != 0 { flags.insert(.maskCommand) }
        return flags
    }
```

应用点（全部在 `inject(touch:)` / `inject(key:)` 内）：
1. `.click` case 的两个 post 之间不能带 flags（post(type:at:) 签名无 flags）——把 `post(type:at:)` 改为 `post(type:at:flags:)`：

```swift
    private func post(type: CGEventType, at point: CGPoint, flags: CGEventFlags = []) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
```

`.click` / `.down` / `.up` / `.dragStart` / `.forceClick`（右键 down/up 那两个 case）调用处传 `flags: eventFlags(for: touch.modifiers)`。

2. `inject(key:)`:`.down`/`.up` 经 `postKey(code:down:)`，改为 `postKey(code:down:flags:)`：

```swift
    private func postKey(code: UInt16, down: Bool, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
```

调用处传 `eventFlags(for: key.modifiers)`。

- [ ] **Step 2: IBEvents.swift 注释修正**

`KeyEvent.keycode` 的 doc comment 中 "USB HID usage ID" 改为 "macOS CGKeyCode (virtual keycode)"，`Action` 上方注释里 "USB HID `keycode`" 同步改。

- [ ] **Step 3: 验证 + Commit**

Run: `./scripts/test.sh`
Expected: 49 tests + 双 target 绿

```bash
git add RemoteCrabReceiver/Input/CGEventInjector.swift RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift
git commit -m "fix(mac): apply modifier flags to injected events end-to-end"
```

---

### Task 3: TouchSurfaceUIView — 统一手势引擎

**Files:**
- Create: `RemoteCrabCapture/Input/TouchSurface.swift`
- Delete（在 Task 6 中随旧屏删除，本任务不动）: 旧 `TouchpadUIView` 继续存在直到 Task 6

**Interfaces:**
- Consumes: Task 1 的 `TrackpadMath`
- Produces（Task 5 键盘面、Task 6 触控板面都嵌入它）:
  - `final class TouchSurfaceUIView: UIView`，配置：
    - `var onEvent: ((TouchEvent) -> Void)?`
    - `var onTouch: ((CGPoint, Bool) -> Void)?`（光标预览用，normalize 后坐标）
    - `var modifierMask: UInt8`（由宿主 SwiftUI 从 IBModifierBar 状态桥接）
    - `var sensitivity: Int`（1...5，宿主从 @AppStorage 读）
    - `var scrollTickHaptics: Bool = true` / `var clickHaptics: Bool = true`
  - SwiftUI 包装 `struct TouchSurface: UIViewRepresentable`（同一文件内），参数为上述属性的 Binding/值

**手势全集（实现者严格按此表接线）：**

| 手势 | Recognizer | 发射 |
|---|---|---|
| 单指拖动 | UIPan 1...1 | `.down`(began) → `.move`(changed, delta 过 `TrackpadMath.accelerate`) → `.up`(ended) |
| 单指单击 | UITap 1 指 1 击 | `.click` |
| 双击按住拖 | 见下方状态机 | `.dragStart` → `.move`(armed) → `.up` |
| 双指拖动 | UIPan 2...2 | `.scroll`(changed)；ended 时若速度 > 40 pt/s 启动惯性（CADisplayLink 驱动 `TrackpadMath.momentumStep`，每帧发 `.scroll`，dy/dx 用帧 delta / bounds） |
| 双指单击 | UITap 2 指 | `.rightDown` + `.rightUp` |
| 捏合 | UIPinch | `.pinch`，dx = (scale − lastScale)，每次 changed 后置 lastScale = scale，ended/重置回 1 |
| 三指单击 | UITap 3 指 | `.threeFingerTap` |
| 三指滑动 | UIPan 3...3 | ended 时若位移 > 60pt：`.threeFingerSwipe`，dx/dy = 主轴单位向量（abs(dy)>=abs(dx) → (0, ±1)，上为正） |
| 指腹重压 | touchesMoved 里读 `UITouch.majorRadius` | 单指序列中首次 > 30.0 时发一次 `.forceClick`（每段触摸最多一次） |

**双击按住拖状态机（D1，关键算法，照此实现）：**

```swift
private var lastTapTime: TimeInterval = 0
private var lastTapLocation: CGPoint = .zero
private var dragArmed = false        // 第二下按住中
private let doubleTapWindow: TimeInterval = 0.28
private let doubleTapSlop: CGFloat = 30   // pt

// 在单指 UITap 的 handler 里：记录 lastTapTime/lastTapLocation，发 .click
// 在单指 UIPan 的 .began 里：
//   if now - lastTapTime < doubleTapWindow
//      && distance(location, lastTapLocation) < doubleTapSlop {
//       dragArmed = true
//       emit(.dragStart)   // 而不是 .down
//   } else {
//       emit(.down)
//   }
// .ended/.cancelled 里 dragArmed = false（.up 两种路径都发）
```

注意：tap 识别器会要求 pan 失败（`require(toFail:)`）会引入延迟——**不要**让 pan require tap 失败；单击的 `.click` 与拖动的 `.down` 可以并存（Mac 端 down→up 无移动 ≈ 单击，行为兼容）。这正是当前 V0.2 的行为，保持。

**触感（UIFeedbackGenerator）：**
- 单击/右键：`UIImpactFeedbackGenerator(style: .medium).impactOccurred()`
- dragStart（拿起）`.heavy`，drag 结束 `.light`
- 滚动：累计每 24pt 位移 `UISelectionFeedbackGenerator().selectionChanged()`（维护累计器，翻页式触发）
- forceClick：`UIImpactFeedbackGenerator(style: .rigid)`
- 捏合到达 |scale-1| > 0.5 边界时一次 medium impact
- 全部 generator 在 `init` 时 `prepare()`

**滚动惯性驱动：** `CADisplayLink` 在 pan(2指).ended 且速度达标时启动，target 方法里 `momentumStep`；返回 nil 或新 pan began 时 invalidate。delta 换算：`.scroll` 事件的 dx/dy = 帧 delta pt / bounds 尺寸（与双指滚动一致）。

**其他要求：**
- `isMultipleTouchEnabled = true`，`backgroundColor = .clear`，recognizer 的 `cancelsTouchesInView = false`
- os_log（category `touchsurface`），无 print
- 无障碍：`accessibilityLabel = "Trackpad surface"`, `.allowsDirectInteraction`
- 文件加 `// MARK:` 分区：Recognizers / Drag state machine / Momentum / Haptics / Emit

- [ ] **Step 1: 实现 TouchSurface.swift**（结构如上；这是 UIKit 胶水层，逻辑核心已在 Task 1 测过，本任务以编译 + 行为自查为准）

- [ ] **Step 2: 验证编译**

Run: `./scripts/test.sh`
Expected: 绿（新文件暂未被任何屏引用，不影响行为）

- [ ] **Step 3: Commit**

```bash
git add RemoteCrabCapture/Input/TouchSurface.swift
git commit -m "feat(ios): unified touch surface gesture engine"
```

---

### Task 4: FeatureDock + ContentView 重构 + 画中画预览

**Files:**
- Create: `RemoteCrabCapture/FeatureDock.swift`
- Modify: `RemoteCrabCapture/ContentView.swift`

**Interfaces:**
- Consumes: `engine.features`（FeatureStore）、`Surface` 枚举
- Produces: `FeatureDock` 视图（本任务 ContentView 专用）

**FeatureDock 规格：**
- 底部悬浮坞：圆角 28 胶囊，`.regularMaterial` 背景（用既有 `IBMaterial.bar(in:)` 风格），横向 5 个按钮等距
- 按钮 48×48 圆形；SF Symbols：相机 `video.fill`、麦克 `mic.fill`、语音 `waveform`、触控板 `hand.point.up.left.fill`、键盘 `keyboard`
- 状态着色：流开关（相机/麦克）开 = `Color.accentColor` 实心白字，关 = 白 12% 底 + 白 60% 字；面按钮（触控板/键盘）当前占屏 = accent 实心，否则同上灰
- 相机/麦克：`engine.features.set(feature:, enabled:)` 取反
- 触控板/键盘：`engine.features.activeSurface = .trackpad / .keyboard`
- 语音 🗣：**按住**手势（`DragGesture(minimumDistance: 0)` down/up）→ `features.set(feature: .voice, enabled: true/false)`；按住时图标变为红色 `waveform` + 缩放 1.1。Plan 3 接识别，本任务只接状态
- 每个按钮 accessibilityLabel（"Camera on/off" 等）

**ContentView 重构规格：**
- 删除 `Mode` 枚举、modeSelector、底部大红色 streaming 按钮 + micToggle（底部栏整体删除；streaming 开关移到顶部天线按钮旁的 ConnectionSheet，保留 sheet 内的 Start/Stop）
- `modeSurface` 改为按 `engine.features.activeSurface` 切换：
  - `.cameraPreview` → `CameraPreview(session:)` 全屏
  - `.trackpad` → `TouchpadScreen()`
  - `.keyboard` → `KeyboardScreen()`
- **PiP**：当 `engine.features.cameraOn && activeSurface != .cameraPreview` 时，右上角悬浮 120×160 圆角 14 的 `CameraPreview` 缩略（黑边描边白 10%），`DragGesture` 可拖动（@State offset，带边界 clamp），点按 → `activeSurface = .cameraPreview`
- `.cameraPreview` 面下：右上角一个 "Done" 圆形按钮（`xmark` 图标）→ 回到 `.trackpad`
- 顶部栏保留：IBStatusPill + 天线 + 设置；中间的模式切换器删除
- 相机未开时 `.cameraPreview` 面显示占位（`video.slash` 图标 + "Camera is off" 文本 + 一个 "Turn on" 按钮 `set(feature: .camera, enabled: true)`）
- `.task { await engine.startIfNeeded() }` 保留；`REMOTECRAB_AUTO_START` 逻辑保留

- [ ] **Step 1: 实现 FeatureDock.swift**（规格如上）
- [ ] **Step 2: 重构 ContentView.swift**（规格如上；ConnectionSheet 保持不动）
- [ ] **Step 3: `./scripts/test.sh` 全绿 + Commit**

```bash
git add RemoteCrabCapture/FeatureDock.swift RemoteCrabCapture/ContentView.swift
git commit -m "feat(ios): feature dock home — streams vs surfaces, PiP camera"
```

---

### Task 5: KeyboardScreen 重写 — K3 键鼠一体

**Files:**
- Rewrite: `RemoteCrabCapture/KeyboardScreen.swift`（整文件替换）
- Create: `RemoteCrabCapture/Input/SystemKeyboardInput.swift`

**Interfaces:**
- Consumes: Task 1 `TextDiff.events(from:to:)`、Task 3 `TouchSurface`、macOS keycode 约定（Global Constraints）
- Produces: 无（屏内组件）

**SystemKeyboardInput 规格（UIViewRepresentable 包 UITextField）：**
- 内部 `UITextField`：`autocorrectionType = .default`、`smartQuotesType = .no`（远端 Mac 要原文）、`returnKeyType = .default`、透明、1×1pt
- 公开：`var onTextChange: ((String, String) -> Void)?`（old, new）、`var onReturn: (() -> Void)?`、`func focus()` / `func unfocus()`
- 用 `UIControl.Event.editingChanged` target 捕获变化；`delegate.shouldReturn` → onReturn + 清空文本框（回车作为 keycode 36 发出，文本本身不入 Mac 输入框——产品决定：回车键 = 发送/执行，不输入换行。多行需求后续迭代）
- SwiftUI 侧 `@State private var committedText = ""`；onTextChange 里 `for e in TextDiff.events(from: old, to: new) { engine.sendKey(e) }` 并更新 committedText；onReturn → `engine.sendKey(KeyEvent(action: .down, keycode: 36)); sendKey(.up, 36)`，committedText 清空

**KeyboardScreen 布局（自上而下，全屏 ZStack 深色渐变背景同现有风格）：**
1. **预览卡**（沿用现有 previewCard 样式）：显示 committedText（空时占位 "Start typing…"）+ 字符计数
2. **小触控区**：`TouchSurface` 高度 96pt，圆角 14，白 5% 底 + 虚线描边；事件直接 `engine.sendTouch`；中央叠放水印文本 "mini trackpad"（白 20%）
3. **快捷键条**：横向等宽 8 键：`esc`(53) `tab`(48) `⌃` `⌥` `⌘` `⇧` `←`(123) `→`(124)
   - esc/tab/←/→：点按 → down+up 该 keycode（带当前锁定修饰符 bitmask）
   - ⌃⌥⌘⇧：切换锁定态（@State Set<IBModifierBar.Modifier>），锁定 = accent 底白字，未锁 = 白 8% 底；锁定参与后续所有按键/文本事件的 modifiers
   - 修饰键 bitmask 映射：control=2, option=4, command=8, shift=1（与 TouchEvent.Modifier 一致）
4. **SystemKeyboardInput**：1×1 透明，`.onAppear` 后 focus()；面消失时 unfocus()
5. 键盘弹起避让：整个 VStack 包在 `GeometryReader` 里，底部 `.padding(.bottom, keyboardHeight)`——用 `Publishers.keyboardHeight`？不引第三方：监听 `NotificationCenter` `keyboardWillChangeFrameNotification` 更新 @State keyboardHeight（withAnimation）
6. 删除：自绘 QWERTY、重复 modifierBar、header 里 "KEYBOARD MODE" pill（功能坞已表明身份；保留一个轻量 header：左 `keyboard` 图标 + "typing on Mac" 右对齐）

- [ ] **Step 1: 实现 SystemKeyboardInput.swift**
- [ ] **Step 2: 重写 KeyboardScreen.swift**
- [ ] **Step 3: `./scripts/test.sh` 全绿 + Commit**

```bash
git add RemoteCrabCapture/KeyboardScreen.swift RemoteCrabCapture/Input/SystemKeyboardInput.swift
git commit -m "feat(ios): K3 keyboard — system IME + shortcut bar + mini trackpad"
```

---

### Task 6: TouchpadScreen 重写 — 接入引擎 + coach marks

**Files:**
- Rewrite: `RemoteCrabCapture/TouchpadScreen.swift`（整文件替换；旧 `TouchpadUIView`/`TouchpadCaptureSurface` 随之删除）

**Interfaces:**
- Consumes: Task 3 `TouchSurface`；`@AppStorage("remotecrab.ios.trackpadSens")`

**规格：**
- 全屏 `TouchSurface`：onEvent → `engine.sendTouch`；modifierMask 从 `IBModifierBar` 的 @State Set 实时换算（shift=1, control=2, option=4, command=8）；sensitivity 从 `@AppStorage("remotecrab.ios.trackpadSens")` 读
- 光标预览圆点 + 按下扫描线：沿用现有视觉代码（从旧文件搬）
- **删除**中央常驻 gestureHints 卡 → 改为 coach marks：前 3 次进入触控板面时淡显（`@AppStorage("remotecrab.ios.trackpadCoachShown")` 计数 Int，>= 3 不再显示；显示时 3.5 秒后淡出，或任一触摸立即消失）。coach 内容三行：拖动=移动光标 / 双击按住=拖拽 / 双指=滚动·右键
- 底部保留 `IBModifierBar`（去掉 "MODIFIER KEYS" 小标题，坞上方悬浮即可）
- 顶部 "TRACKPAD MODE" pill 删除（功能坞已表明身份）

- [ ] **Step 1: 重写 TouchpadScreen.swift**
- [ ] **Step 2: `./scripts/test.sh` 全绿 + Commit**

```bash
git add RemoteCrabCapture/TouchpadScreen.swift
git commit -m "feat(ios): trackpad surface — full gestures, haptics, coach marks"
```

---

### Task 7: 实验室 — 空中鼠标 + 转盘滚动

**Files:**
- Modify: `RemoteCrabCapture/IOSSettingsView.swift`（加实验室 section）
- Modify: `RemoteCrabCapture/Input/TouchSurface.swift`（加两个 labs 开关属性 + 实现）
- Modify: `project-ios.yml`（若 CoreMotion 需要——不需要，系统框架直接 import）

**Interfaces:**
- Consumes: Task 3 的 TouchSurfaceUIView
- Produces:
  - `TouchSurfaceUIView.airMouseEnabled: Bool`、`TouchSurfaceUIView.wheelScrollEnabled: Bool`（宿主从 AppStorage 桥接）
  - `TouchSurfaceUIView.airMouseActive: Bool`（宿主据此显示激活按钮）

**设置页实验室 section（IOSSettingsView，inputSection 之后插入）：**

```swift
    @AppStorage("remotecrab.ios.labAirMouse")   private var labAirMouse = false
    @AppStorage("remotecrab.ios.labWheelScroll") private var labWheelScroll = false

    private var labsSection: some View {
        Section {
            Toggle("Air mouse", isOn: $labAirMouse)
            Toggle("Wheel scrolling", isOn: $labWheelScroll)
        } header: {
            Text("Labs")
        } footer: {
            Text("Experimental gestures. Air mouse: hold the floating button on the trackpad and tilt your iPhone to move the cursor. Wheel scrolling: hold the edge button and draw circles to scroll.")
        }
    }
```

**空中鼠标（TouchSurfaceUIView 内，labAirMouseEnabled 时生效）：**
- 宿主（TouchpadScreen）在触控面右下角显示悬浮按钮（`gyroscope` SF Symbol），仅在 labAirMouse 开启时可见；按住（DragGesture minDist 0）→ `surface.airMouseActive = true`，松开 → false
- `airMouseActive` 置 true 时：`CMMotionManager().startDeviceMotionUpdates(to: .main)` 记录参考姿态（首帧 attitude 存 ref）；之后每帧：Δroll/Δpitch 相对 ref 映射为 `.move` 事件（gain：1 rad ≈ 0.35 屏宽；dx = Δroll × 0.35 / π... 即 `dx = Float(deltaRoll / .pi) * 0.35`，y 同理用 Δpitch，符号按竖握手机倾斜方向调正——实现者在真机上验证方向，代码里用 `let yawGain: Float = 0.35 / .pi` 常量并在注释里写明"方向待真机校准"）
- 松开：stopDeviceMotionUpdates
- 按住激活时发一次 medium impact 触感
- 生命周期：view removeFromSuperview 时停 motion updates

**转盘滚动（labWheelScrollEnabled 时生效）：**
- 触控面左下悬浮小按钮（`dial.low` SF Symbol）按住进入转盘模式：按住期间单指 touch 的角度围绕按住起点累计，角位移 → `.scroll`（每 45° = 一格格滚动量 dy=0.02，顺正逆负）；松开出模式
- 实现：TouchesBegan/Moved 里当 wheelArmed 时，计算 atan2(touch − origin)，与上一角度求差（wrap 到 ±π），累加器满 π/4 发一格
- 与正常单指拖动互斥（armed 期间不发 .down/.move）

- [ ] **Step 1: IOSSettingsView 加实验室 section**
- [ ] **Step 2: TouchSurface 加两个 labs 能力 + TouchpadScreen 加两个悬浮按钮**
- [ ] **Step 3: `./scripts/test.sh` 全绿 + Commit**

```bash
git add RemoteCrabCapture/IOSSettingsView.swift RemoteCrabCapture/Input/TouchSurface.swift RemoteCrabCapture/TouchpadScreen.swift
git commit -m "feat(ios): labs — air mouse (gyro) and wheel scrolling"
```

---

## 完成后状态（Plan 2 验收标准）

- `./scripts/test.sh` 全绿（49 tests）
- 主屏 = 功能坞；相机/麦克独立开关，触控板/键盘为面；相机画中画可拖可点
- 键盘面用系统输入法（中文/听写可用），快捷键条 + 锁定修饰键 + 小触控区
- 触控板：拖拽（双击按住）、惯性滚动、捏合、加速曲线（灵敏度生效）、全触感、压感右键、三指手势
- 修饰键 iOS→Mac 端到端生效
- 设置 → 实验室：空中鼠标 + 转盘滚动默认关闭

## 移交 Plan 3 / 真机验证清单

- 语音 🗣 目前只切 voiceOn 状态，Plan 3 接 SFSpeechRecognizer
- 真机待验：pinch 符号方向、空中鼠标方向/增益、forceClick 阈值 30.0、三指手势与 iOS 系统手势（三指捏合=拷贝）的冲突、惯性滚动手感
