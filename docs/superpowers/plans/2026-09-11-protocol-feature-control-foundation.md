# Plan 1 — 协议双向化 + FeatureStore + 还债 + Mac 真实控制 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make features (camera/mic/trackpad/keyboard) first-class toggleable capabilities with a single source of truth (`FeatureStore`), a bidirectional wire protocol (Mac→iPhone control), real Mac-side toggles, and fix the V0.2 debt (camera never starts, settings never applied, key events never injected).

**Architecture:** Extend `IBWire`/`IBEvents` with three new frame kinds (featureControl 0x07 Mac→iPhone, featureState 0x08 iPhone→Mac, ping 0x09 for real RTT). Add a shared `FeatureStore` (@Observable) in RemoteCrabCore. CaptureEngine gains a receive loop; ReceiverSession gains a send path. Mac menu-bar toggles bind to real synced state.

**Tech Stack:** Swift, SwiftUI, Network.framework (NWConnection/NWListener), XCTest, os_log.

## Global Constraints

- 新增协议帧必须遵循 AGENTS.md 的 9 步模式，全部带 round-trip 测试
- 新代码用 `@Observable`，不用 `ObservableObject`（既有类的 `@Published` 保持不动，避免大范围重构）
- 日志用 `os_log`，subsystem `com.remotecrab`；不允许新增 `print(`
- UI 字符串不允许 emoji；SF Symbols only
- 向后兼容：旧 Mac 不发 0x07 时 iOS 本地开关照常工作；旧 iOS 不发 0x08 时 Mac 开关显示禁用态
- 每个 Task 完成跑 `./scripts/test.sh`（RemoteCrabCore 26 tests + 两个 app target 编译），必须全绿再 commit
- 单测命令：`cd RemoteCrabCore && swift test --filter <TestClassName>`

---

### Task 1: 协议扩展 — FeatureControl / FeatureStateSnapshot / Ping / TouchEvent 新相位

**Files:**
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift`
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBWire.swift`
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEventBroadcaster.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/IBEventsTests.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/IBWireTests.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/EventPipelineEndToEndTests.swift`

**Interfaces:**
- Produces（后续所有 Task 依赖这些精确签名）:
  - `enum IBFeature: String, Codable, Sendable, CaseIterable { camera, microphone, voice, trackpad, keyboard }`
  - `struct FeatureControl: Codable, Sendable, Equatable { feature: IBFeature; enabled: Bool }`
  - `enum Surface: String, Codable, Sendable { trackpad, keyboard, cameraPreview }`
  - `struct FeatureStateSnapshot: Codable, Sendable, Equatable { cameraOn, micOn, voiceOn, trackpadOn, keyboardOn: Bool; activeSurface: Surface; timestampMicros: UInt64 }`
  - `TouchEvent.Phase` 新 case：`dragStart`, `pinch`, `threeFingerSwipe`, `threeFingerTap`, `forceClick`
  - `IBWire.Kind` 新 case：`featureControl = 0x07`, `featureState = 0x08`, `ping = 0x09`
  - `IBWire.encode(featureControl:) throws -> Data`、`IBWire.encode(featureState:) throws -> Data`、`IBWire.encodePing(sentMicros: UInt64) -> Data`
  - `IBWire.decodeFeatureControl(_:) throws -> FeatureControl`、`IBWire.decodeFeatureState(_:) throws -> FeatureStateSnapshot`、`IBWire.decodePing(_:) -> UInt64`
  - `IBEventBroadcaster.send(_ snapshot: FeatureStateSnapshot)`、`IBEventBroadcaster.sendPingEcho(_ payload: Data)`

**设计说明（实现者必读）：**
- TouchEvent 不加新字段（保持 synthesized Codable、旧 iOS payload 仍可被新 Mac 解码）。语义编码进既有字段：
  - `pinch`: `dx` = 缩放增量（+0.01 表示放大 1%）
  - `threeFingerSwipe`: `dx/dy` = 方向单位向量（上 (0,1)、下 (0,-1)、左 (-1,0)、右 (1,0)）
  - `threeFingerTap`: 中键，仅用 phase + x/y
  - `dragStart`: 双击按住开始拖拽（= 左键按住不放），后续 `.move` 为拖动，`.up` 结束
  - `forceClick`: 指腹重压，映射为右键
- 旧 Mac 收到未知 phase 的 TouchEvent 时 JSON 解码抛错，`ReceiverSession` 里 `try?` 已使其静默丢弃 — 天然向后兼容，无需额外处理
- ping 帧双向复用同一 kind：Mac 发 8 字节 BE 时间戳，iOS 原样回 echo，Mac 算 RTT

- [ ] **Step 1: 写失败测试 — IBEvents round-trip**

在 `RemoteCrabCore/Tests/RemoteCrabCoreTests/IBEventsTests.swift` 末尾追加：

```swift
    func testFeatureControlRoundTrip() throws {
        let control = FeatureControl(feature: .camera, enabled: false)
        let data = try JSONEncoder().encode(control)
        let decoded = try JSONDecoder().decode(FeatureControl.self, from: data)
        XCTAssertEqual(decoded, control)
    }

    func testFeatureStateSnapshotRoundTrip() throws {
        let snap = FeatureStateSnapshot(
            cameraOn: true, micOn: false, voiceOn: false,
            trackpadOn: true, keyboardOn: true,
            activeSurface: .trackpad, timestampMicros: 123_456
        )
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(FeatureStateSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testTouchEventNewPhasesRoundTrip() throws {
        for phase: TouchEvent.Phase in [.dragStart, .pinch, .threeFingerSwipe, .threeFingerTap, .forceClick] {
            let event = TouchEvent(phase: phase, x: 0.5, y: 0.5, dx: 0.02, dy: 1)
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(TouchEvent.self, from: data)
            XCTAssertEqual(decoded, event)
        }
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `cd RemoteCrabCore && swift test --filter IBEventsTests`
Expected: 编译失败（FeatureControl 未定义）

- [ ] **Step 3: 实现 IBEvents.swift 扩展**

在 `IBEvents.swift` 中给 `TouchEvent.Phase` 追加 case（保持既有 case 不动）：

```swift
        case dragStart        // double-tap-hold: begin drag (left button held)
        case pinch            // two-finger pinch; dx = scale delta (+0.01 = +1%)
        case threeFingerSwipe // dx/dy = unit direction vector (up = (0,1))
        case threeFingerTap   // three-finger tap = middle click
        case forceClick       // deep press (majorRadius) = right click
```

文件末尾追加：

```swift
/// The independently toggleable capabilities of an iPhone running
/// RemoteCrabCapture. `.camera / .microphone / .voice` are background
/// streams; `.trackpad / .keyboard` are input channels.
public enum IBFeature: String, Codable, Sendable, CaseIterable {
    case camera
    case microphone
    case voice
    case trackpad
    case keyboard
}

/// Mac → iPhone: toggle a feature remotely (kind 0x07).
public struct FeatureControl: Codable, Sendable, Equatable {
    public let feature: IBFeature
    public let enabled: Bool

    public init(feature: IBFeature, enabled: Bool) {
        self.feature = feature
        self.enabled = enabled
    }
}

/// Which interaction surface currently occupies the iPhone screen.
public enum Surface: String, Codable, Sendable {
    case trackpad
    case keyboard
    case cameraPreview
}

/// iPhone → Mac: full feature-state snapshot (kind 0x08), sent on
/// connect and on every change.
public struct FeatureStateSnapshot: Codable, Sendable, Equatable {
    public let cameraOn: Bool
    public let micOn: Bool
    public let voiceOn: Bool
    public let trackpadOn: Bool
    public let keyboardOn: Bool
    public let activeSurface: Surface
    public let timestampMicros: UInt64

    public init(
        cameraOn: Bool,
        micOn: Bool,
        voiceOn: Bool,
        trackpadOn: Bool,
        keyboardOn: Bool,
        activeSurface: Surface,
        timestampMicros: UInt64
    ) {
        self.cameraOn = cameraOn
        self.micOn = micOn
        self.voiceOn = voiceOn
        self.trackpadOn = trackpadOn
        self.keyboardOn = keyboardOn
        self.activeSurface = activeSurface
        self.timestampMicros = timestampMicros
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd RemoteCrabCore && swift test --filter IBEventsTests`
Expected: PASS（含新 3 个测试）

- [ ] **Step 5: 写失败测试 — IBWire 新 kind round-trip**

在 `IBWireTests.swift` 末尾追加：

```swift
    func testRoundTripFeatureControl() throws {
        let control = FeatureControl(feature: .microphone, enabled: true)
        let data = try IBWire.encode(featureControl: control)
        let parser = IBWire.Parser()
        let frames = parser.append(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .featureControl)
        XCTAssertEqual(try IBWire.decodeFeatureControl(frames[0]), control)
    }

    func testRoundTripFeatureState() throws {
        let snap = FeatureStateSnapshot(
            cameraOn: false, micOn: true, voiceOn: false,
            trackpadOn: true, keyboardOn: false,
            activeSurface: .keyboard, timestampMicros: 42
        )
        let data = try IBWire.encode(featureState: snap)
        let parser = IBWire.Parser()
        let frames = parser.append(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .featureState)
        XCTAssertEqual(try IBWire.decodeFeatureState(frames[0]), snap)
    }

    func testRoundTripPing() throws {
        let data = IBWire.encodePing(sentMicros: 9_876_543)
        let parser = IBWire.Parser()
        let frames = parser.append(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .ping)
        XCTAssertEqual(IBWire.decodePing(frames[0]), 9_876_543)
    }
```

- [ ] **Step 6: 运行确认失败**

Run: `cd RemoteCrabCore && swift test --filter IBWireTests`
Expected: 编译失败

- [ ] **Step 7: 实现 IBWire.swift 扩展**

`Kind` 枚举追加：

```swift
        case featureControl = 0x07   // JSON FeatureControl (Mac → iPhone)
        case featureState  = 0x08    // JSON FeatureStateSnapshot (iPhone → Mac)
        case ping          = 0x09    // 8-byte BE timestampMicros, echoed verbatim
```

encode 区追加：

```swift
    /// Encode a FeatureControl (Mac → iPhone remote toggle).
    public static func encode(featureControl: FeatureControl) throws -> Data {
        let json = try JSONEncoder().encode(featureControl)
        return encodeFrame(kind: .featureControl, payload: json)
    }

    /// Encode a FeatureStateSnapshot (iPhone → Mac state sync).
    public static func encode(featureState: FeatureStateSnapshot) throws -> Data {
        let json = try JSONEncoder().encode(featureState)
        return encodeFrame(kind: .featureState, payload: json)
    }

    /// Encode a ping frame. Payload is the 8-byte big-endian sender
    /// timestamp in microseconds; the iPhone echoes it back verbatim
    /// so the Mac can compute a real RTT.
    public static func encodePing(sentMicros: UInt64) -> Data {
        var payload = Data(capacity: 8)
        for shift in stride(from: 56, through: 0, by: -8) {
            payload.append(UInt8((sentMicros >> UInt64(shift)) & 0xFF))
        }
        return encodeFrame(kind: .ping, payload: payload)
    }
```

decode helpers 区追加：

```swift
    /// Decode a `.featureControl` frame's payload.
    public static func decodeFeatureControl(_ frame: Frame) throws -> FeatureControl {
        try JSONDecoder().decode(FeatureControl.self, from: frame.payload)
    }

    /// Decode a `.featureState` frame's payload.
    public static func decodeFeatureState(_ frame: Frame) throws -> FeatureStateSnapshot {
        try JSONDecoder().decode(FeatureStateSnapshot.self, from: frame.payload)
    }

    /// Decode a `.ping` frame's payload into the sender timestamp.
    public static func decodePing(_ frame: Frame) -> UInt64 {
        var value: UInt64 = 0
        for byte in frame.payload.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
```

- [ ] **Step 8: IBEventBroadcaster 增加发送方法**

在 `IBEventBroadcaster` 中追加：

```swift
    public func send(_ snapshot: FeatureStateSnapshot) {
        send(kind: .featureState) { try IBWire.encode(featureState: snapshot) }
    }

    /// Echo a ping payload back to the Mac verbatim (RTT measurement).
    public func sendPingEcho(_ payload: Data) {
        send(kind: .ping) { IBWire.encodeFrame(kind: .ping, payload: payload) }
    }
```

- [ ] **Step 9: 运行确认通过 + TCP 端到端测试**

在 `EventPipelineEndToEndTests.swift` 末尾追加（模仿文件内既有 TCP 测试的写法）：

```swift
    func testFeatureStateSurvivesTCPTrip() throws {
        // Encode → fragment arbitrarily → parse → decode, mirroring the
        // existing pipeline tests' pattern.
        let snap = FeatureStateSnapshot(
            cameraOn: true, micOn: true, voiceOn: false,
            trackpadOn: true, keyboardOn: true,
            activeSurface: .trackpad, timestampMicros: 7
        )
        let wire = try IBWire.encode(featureState: snap)
        let parser = IBWire.Parser()
        // Feed byte-by-byte to prove fragmentation safety.
        var frames: [IBWire.Frame] = []
        for i in wire.indices {
            frames.append(contentsOf: parser.append(wire[i..<wire.index(after: i)]))
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try IBWire.decodeFeatureState(frames[0]), snap)
    }
```

Run: `cd RemoteCrabCore && swift test`
Expected: 全部 PASS（26 旧 + 7 新 = 33）

- [ ] **Step 10: Commit**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/Networking/ RemoteCrabCore/Tests/
git commit -m "feat(protocol): featureControl/featureState/ping frames + touch phases"
```

---

### Task 2: FeatureStore — 功能状态单一事实源

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/State/FeatureStore.swift`
- Test: `RemoteCrabCore/Tests/RemoteCrabCoreTests/FeatureStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `IBFeature` / `FeatureControl` / `FeatureStateSnapshot` / `Surface`
- Produces:
  - `@Observable @MainActor final class FeatureStore`
  - 属性：`cameraOn / micOn / voiceOn / trackpadOn / keyboardOn: Bool`、`activeSurface: Surface`、`onChange: (@MainActor (FeatureStateSnapshot) -> Void)?`
  - 方法：`set(feature: IBFeature, enabled: Bool)`、`apply(_ control: FeatureControl)`、`snapshot() -> FeatureStateSnapshot`

- [ ] **Step 1: 写失败测试**

创建 `RemoteCrabCore/Tests/RemoteCrabCoreTests/FeatureStoreTests.swift`：

```swift
import XCTest
@testable import RemoteCrabCore

@MainActor
final class FeatureStoreTests: XCTestCase {

    func testDefaultsMatchV02Behavior() {
        let store = FeatureStore()
        XCTAssertTrue(store.cameraOn)
        XCTAssertFalse(store.micOn)
        XCTAssertFalse(store.voiceOn)
        XCTAssertTrue(store.trackpadOn)
        XCTAssertTrue(store.keyboardOn)
        XCTAssertEqual(store.activeSurface, .cameraPreview)
    }

    func testSetFeatureFlipsAndNotifies() {
        let store = FeatureStore()
        var snapshots: [FeatureStateSnapshot] = []
        store.onChange = { snapshots.append($0) }
        store.set(feature: .microphone, enabled: true)
        XCTAssertTrue(store.micOn)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].micOn)
        // Setting to the same value is a no-op (no redundant broadcast).
        store.set(feature: .microphone, enabled: true)
        XCTAssertEqual(snapshots.count, 1)
    }

    func testApplyFeatureControl() {
        let store = FeatureStore()
        store.apply(FeatureControl(feature: .camera, enabled: false))
        XCTAssertFalse(store.cameraOn)
    }

    func testSnapshotCarriesAllFields() {
        let store = FeatureStore()
        store.set(feature: .voice, enabled: true)
        store.activeSurface = .keyboard
        let snap = store.snapshot()
        XCTAssertTrue(snap.voiceOn)
        XCTAssertEqual(snap.activeSurface, .keyboard)
        XCTAssertGreaterThan(snap.timestampMicros, 0)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd RemoteCrabCore && swift test --filter FeatureStoreTests`
Expected: 编译失败

- [ ] **Step 3: 实现 FeatureStore**

创建 `RemoteCrabCore/Sources/RemoteCrabCore/State/FeatureStore.swift`：

```swift
import Foundation

/// The single source of truth for which RemoteCrab capabilities are live.
///
/// Owned by `CaptureEngine` on iOS; every toggle — local UI or a
/// remote `FeatureControl` frame from the Mac — flows through
/// `set(feature:enabled:)`, which fires `onChange` exactly once per
/// actual change so the engine can broadcast a `featureState` frame
/// and sync side effects (e.g. starting/stopping the mic encoder).
@Observable
@MainActor
public final class FeatureStore {

    public private(set) var cameraOn = true
    public private(set) var micOn = false
    public private(set) var voiceOn = false
    public private(set) var trackpadOn = true
    public private(set) var keyboardOn = true

    /// Which interaction surface currently occupies the screen.
    /// Not broadcast-affecting on its own, but included in snapshots.
    public var activeSurface: Surface = .cameraPreview {
        didSet {
            if activeSurface != oldValue { notify() }
        }
    }

    /// Called once per actual state change with a fresh snapshot.
    public var onChange: (@MainActor (FeatureStateSnapshot) -> Void)?

    public init() {}

    public func set(feature: IBFeature, enabled: Bool) {
        let changed: Bool
        switch feature {
        case .camera:
            changed = cameraOn != enabled; cameraOn = enabled
        case .microphone:
            changed = micOn != enabled; micOn = enabled
        case .voice:
            changed = voiceOn != enabled; voiceOn = enabled
        case .trackpad:
            changed = trackpadOn != enabled; trackpadOn = enabled
        case .keyboard:
            changed = keyboardOn != enabled; keyboardOn = enabled
        }
        if changed { notify() }
    }

    /// Apply a remote toggle from the Mac. Identical to a local toggle.
    public func apply(_ control: FeatureControl) {
        set(feature: control.feature, enabled: control.enabled)
    }

    public func snapshot() -> FeatureStateSnapshot {
        FeatureStateSnapshot(
            cameraOn: cameraOn,
            micOn: micOn,
            voiceOn: voiceOn,
            trackpadOn: trackpadOn,
            keyboardOn: keyboardOn,
            activeSurface: activeSurface,
            timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000)
        )
    }

    private func notify() {
        onChange?(snapshot())
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd RemoteCrabCore && swift test --filter FeatureStoreTests`
Expected: PASS（4 个测试）

- [ ] **Step 5: Commit**

```bash
git add RemoteCrabCore/Sources/RemoteCrabCore/State/ RemoteCrabCore/Tests/RemoteCrabCoreTests/FeatureStoreTests.swift
git commit -m "feat(core): FeatureStore single source of truth for capability state"
```

---

### Task 3: CaptureEngine — 接收循环 + FeatureStore 接线 + 相机启动修复 + os_log

**Files:**
- Modify: `RemoteCrabCapture/CaptureEngine.swift`
- Modify: `RemoteCrabCapture/ContentView.swift`

**Interfaces:**
- Consumes: Task 1 的 `IBWire.decodeFeatureControl/decodePing`、`FeatureControl`；Task 2 的 `FeatureStore`
- Produces:
  - `CaptureEngine.features: FeatureStore`（UI 唯一入口；Task 6 设置页、Plan 2 的 Dock 都绑它）
  - `CaptureEngine.syncMicrophone(_ enabled: Bool)`（private；`setMicrophoneEnabled` 被它取代并从公开 API 删除——ContentView 与 IOSSettingsView 的调用点在本计划 Task 3/6 中全部更新，不留兼容 shim）

- [ ] **Step 1: CaptureEngine 持有 FeatureStore + 状态广播/副作用**

在 `CaptureEngine` 中：

1. 属性区（`private(set) var broadcaster` 附近）追加：

```swift
    /// Single source of truth for capability state. Bound by the UI
    /// and mutated by remote FeatureControl frames alike.
    let features = FeatureStore()

    private let parser = IBWire.Parser()
```

2. `init` 不存在（用默认），在 `startIfNeeded()` 开头（`guard !didConfigure` 之后、`requestPermissions()` 之前）接 onChange：

```swift
        features.onChange = { [weak self] snapshot in
            self?.handleFeaturesChanged(snapshot)
        }
```

3. 新增私有方法（放 `// MARK: - Sending` 区上方）：

```swift
    // MARK: - Feature state

    private func handleFeaturesChanged(_ snapshot: FeatureStateSnapshot) {
        broadcaster?.send(snapshot)
        syncMicrophone(snapshot.micOn)
    }

    private func syncMicrophone(_ enabled: Bool) {
        if enabled {
            if audioEncoder == nil {
                audioEncoder = MicrophoneEncoder()
            }
            if let broadcaster { audioEncoder?.start(broadcaster: broadcaster) }
        } else {
            audioEncoder?.stop()
        }
    }
```

4. 删除旧的 `setMicrophoneEnabled(_:)` 方法（其逻辑已移入 `syncMicrophone`）。

5. `handleConnectionState` 的 `.ready` 分支里，broadcaster 建立后追加两行（mic 启动改为按 FeatureStore 状态、并立即同步全量状态给 Mac）：

```swift
                broadcaster = b
                // Tell the Mac the full feature state right away.
                b.send(features.snapshot())
                // Start mic only if the feature is on.
                syncMicrophone(features.micOn)
```

替换掉原有的 `if let mic = audioEncoder { mic.start(broadcaster: b) }`。

- [ ] **Step 2: CaptureEngine 增加接收循环（featureControl + ping echo）**

1. 在 `accept(connection:)` 的 `connection.start(queue: queue)` 之后追加：

```swift
        startReceiving(from: connection)
```

2. 新增方法（放 `handleConnectionState` 之后）：

```swift
    // MARK: - Receiving (Mac → iPhone control)

    private func startReceiving(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.handleInbound(data)
                }
            }
            if error != nil { return }
            if !isComplete && self.connection != nil {
                self.startReceiving(from: connection)
            }
        }
    }

    private func handleInbound(_ data: Data) {
        for frame in parser.append(data) {
            switch frame.kind {
            case .featureControl:
                if let control = try? IBWire.decodeFeatureControl(frame) {
                    features.apply(control)
                }
            case .ping:
                broadcaster?.sendPingEcho(frame.payload)
            default:
                break // all other kinds are iPhone → Mac only
            }
        }
    }
```

3. `stopStreaming()` 末尾追加 `parser.reset()`。

- [ ] **Step 3: os_log 迁移（CaptureEngine）**

文件顶部 `import os`；类内加：

```swift
    private static let log = Logger(subsystem: "com.remotecrab", category: "capture")
```

把文件里全部 `print("[RemoteCrab] ...")` 替换为 `Self.log.error/info(...)`（错误用 `.error`，状态用 `.info`；日志串用 `\(variable, privacy: .public)` 插值）。`IBEventBroadcaster.swift` 里那处 `print` 也一并换成同等 Logger（category `broadcaster`）。

- [ ] **Step 4: ContentView 修复 — 相机启动 + mic 绑 FeatureStore**

`ContentView.swift`：

1. 删除 `@State private var micEnabled = false`（第 8 行）和 `.onChange(of: micEnabled)` 修饰符（39–41 行）。
2. `body` 的 `.onAppear` 之后追加：

```swift
        .task {
            await engine.startIfNeeded()
        }
```

3. `micToggle` 里 `micEnabled` 改为 `engine.features.micOn`（3 处：图标、文案、accessibilityLabel），按钮 action 改为：

```swift
            Button {
                engine.features.set(feature: .microphone, enabled: !engine.features.micOn)
            } label: {
```

4. 运行 `cd RemoteCrabCore && swift test` + 完整 `./scripts/test.sh`，全部通过。

- [ ] **Step 5: Commit**

```bash
git add RemoteCrabCapture/CaptureEngine.swift RemoteCrabCapture/ContentView.swift RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEventBroadcaster.swift
git commit -m "feat(capture): bidirectional engine, FeatureStore wiring, camera start fix"
```

---

### Task 4: ReceiverSession — 发送 featureControl + 真 RTT + os_log

**Files:**
- Modify: `RemoteCrabReceiver/ReceiverSession.swift`

**Interfaces:**
- Consumes: Task 1 的 `encode(featureControl:)` / `encodePing` / `decodeFeatureState` / `decodePing`；`FeatureStateSnapshot`
- Produces:
  - `ReceiverSession.featureState: FeatureStateSnapshot?`（@Published，Task 5 的 UI 绑定它）
  - `ReceiverSession.setFeature(_ feature: IBFeature, _ enabled: Bool)`（Task 5 的开关调用它）

- [ ] **Step 1: 状态与发送**

`ReceiverSession` 属性区追加：

```swift
    /// Latest feature-state snapshot from the iPhone. nil until the
    /// first `featureState` frame arrives (older iOS builds never
    /// send one — the UI must treat nil as "remote control unavailable").
    @Published private(set) var featureState: FeatureStateSnapshot?

    private var pingTimer: Timer?
    private static let log = Logger(subsystem: "com.remotecrab", category: "receiver")
```

（顶部加 `import os`。）

新增公开方法（放 `start()` 之后）：

```swift
    /// Mac → iPhone: toggle a feature remotely. No-op when disconnected.
    func setFeature(_ feature: IBFeature, _ enabled: Bool) {
        guard let connection, connection.state == .ready else { return }
        do {
            let data = try IBWire.encode(featureControl: FeatureControl(feature: feature, enabled: enabled))
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            Self.log.error("featureControl encode failed: \(error, privacy: .public)")
        }
    }
```

- [ ] **Step 2: 处理 featureState + ping 回包，修延迟显示**

1. `handleInbound` 的 switch 追加两个 case：

```swift
            case .featureState:
                if let snap = try? IBWire.decodeFeatureState(frame) {
                    featureState = snap
                }
            case .ping:
                let sentMicros = IBWire.decodePing(frame)
                let nowMicros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                let rttMs = Int((nowMicros &- sentMicros) / 1_000)
                if case .streaming(let name, _) = state {
                    state = .streaming(name: name, latencyMs: rttMs)
                }
```

2. 删除 `handleInbound` 末尾「latencyMs = 连接时长」的整段（`if case .streaming ... connectionStartedAt ...`），`connectionStartedAt` 属性一并删除。

3. ping 定时器 — `handleConnectionState` 的 `.ready` 分支末尾加：

```swift
            startPingLoop(on: conn_ref)   // 用当前 connection
```

`.cancelled` / `.failed` 分支加 `stopPingLoop()`。新增：

```swift
    private func startPingLoop(on connection: NWConnection) {
        stopPingLoop()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self, weak connection] _ in
            guard let connection, connection.state == .ready else { return }
            let micros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            connection.send(content: IBWire.encodePing(sentMicros: micros),
                            completion: .contentProcessed { _ in })
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPingLoop() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
```

注意：`.ready` 分支里当前没有 `conn` 局部名——在该 case 里用 `if let connection` 拿到再传。

4. os_log：文件里两处 `print("[RemoteCrab] metadata decode failed: ...")` 等全部换成 `Self.log`。

- [ ] **Step 3: 验证**

Run: `./scripts/test.sh`
Expected: 37 tests PASS + 两个 app target 编译成功

- [ ] **Step 4: Commit**

```bash
git add RemoteCrabReceiver/ReceiverSession.swift
git commit -m "feat(receiver): bidirectional session, real RTT latency via ping"
```

---

### Task 5: Mac 端接入 — CGEventInjector 新相位/修 key 注入 + MenuBarMenu 真开关 + ControlPanel 徽章

**Files:**
- Modify: `RemoteCrabReceiver/Input/CGEventInjector.swift`
- Modify: `RemoteCrabReceiver/MenuBarMenu.swift`（togglesSection，195–219 行附近）
- Modify: `RemoteCrabReceiver/ControlPanelView.swift`（231–234 行附近的硬编码 `active: true`）

**Interfaces:**
- Consumes: Task 1 新相位；Task 4 的 `session.featureState` / `session.setFeature(_:_:)`
- Produces: 无新公开接口

**背景（实现者必读）：**
- `CGEventInjector.postKey` 目前只 `print`，**键事件从未真正注入** — 本任务修复
- `.move` 目前总是 post `leftMouseDragged`，意味着普通移动光标也带着左键 — 修复为 `mouseMoved`；拖拽期间由 `.dragStart` 后的 `.move` 走 `leftMouseDragged`（用 `lastPhase` 跟踪）
- pinch 无法通过公开 API 发 gesture 事件，合成 **⌘+滚轮**（浏览器/预览/多数 app 支持）

- [ ] **Step 1: CGEventInjector 重写 inject(touch:)**

`inject(touch:screenSize:)` 替换为（新增 `private var lastPhase: TouchEvent.Phase?` 属性）：

```swift
    public func inject(touch: TouchEvent, screenSize: CGSize) {
        let absX = Double(touch.x) * Double(screenSize.width)
        let absY = Double(touch.y) * Double(screenSize.height)

        switch touch.phase {
        case .down:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseDown, at: lastCursor)
        case .up:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseUp, at: lastCursor)
        case .move:
            let dx = Double(touch.dx) * Double(screenSize.width)
            let dy = Double(touch.dy) * Double(screenSize.height)
            moveCursor(to: CGPoint(x: lastCursor.x + dx, y: lastCursor.y + dy))
            // Plain finger move = hover; while a drag is armed
            // (dragStart seen, no up yet) = left-drag.
            if isDragging {
                post(type: .leftMouseDragged, at: lastCursor)
            }
        case .dragStart:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseDown, at: lastCursor)
            isDragging = true
        case .scroll:
            postScroll(dx: touch.dx, dy: touch.dy, commandHeld: false)
        case .pinch:
            // No public API posts magnification gestures; ⌘+scroll is
            // the standard zoom shortcut honoured by most apps.
            postScroll(dx: 0, dy: touch.dx, commandHeld: true)
        case .rightDown:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .rightMouseDown, at: lastCursor)
        case .rightUp:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .rightMouseUp, at: lastCursor)
        case .click:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .leftMouseDown, at: lastCursor)
            post(type: .leftMouseUp, at: lastCursor)
        case .threeFingerTap:
            moveCursor(to: CGPoint(x: absX, y: absY))
            postOther(button: 2, down: true, at: lastCursor)   // middle click
            postOther(button: 2, down: false, at: lastCursor)
        case .threeFingerSwipe:
            postMissionControl(dx: touch.dx, dy: touch.dy)
        case .forceClick:
            moveCursor(to: CGPoint(x: absX, y: absY))
            post(type: .rightMouseDown, at: lastCursor)
            post(type: .rightMouseUp, at: lastCursor)
        }
        if touch.phase == .up { isDragging = false }
        lastPhase = touch.phase
    }
```

配套新增/修改的私有方法（替换旧 `postScroll` 内联逻辑与 `postKey`）：

```swift
    private var isDragging = false

    private func postScroll(dx: Float, dy: Float, commandHeld: Bool) {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-dy * 50),
            wheel2: Int32(-dx * 50),
            wheel3: 0
        )
        if commandHeld { event?.flags = .maskCommand }
        event?.post(tap: .cghidEventTap)
    }

    private func postOther(button: Int, down: Bool, at point: CGPoint) {
        let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point,
                            mouseButton: CGMouseButton(rawValue: UInt32(button))!)
        event?.post(tap: .cghidEventTap)
    }

    /// Three-finger swipes map to the Mac's built-in shortcuts:
    /// up = Mission Control (⌃↑), down = App Exposé (⌃↓),
    /// left/right = switch Space (⌃← / ⌃→).
    private func postMissionControl(dx: Float, dy: Float) {
        let keyCode: CGKeyCode
        if abs(dy) >= abs(dx) {
            keyCode = dy > 0 ? 126 : 125        // up / down
        } else {
            keyCode = dx > 0 ? 124 : 123        // right / left
        }
        postKeyCombo(code: keyCode, flags: .maskControl)
    }

    private func postKeyCombo(code: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        up?.post(tap: .cghidEventTap)
    }

    private func postKey(code: UInt16, down: Bool) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
        event?.post(tap: .cghidEventTap)
    }
```

（`postKey` 的旧 `print` 实现删除。）

- [ ] **Step 2: MenuBarMenu 四个开关接真状态**

`togglesSection`（MenuBarMenu.swift 195–219）中四个 `isOn: .constant(true)` 全部替换：

```swift
            ToggleRow(icon: "camera.fill",
                      title: "Camera",
                      subtitle: "Live iPhone feed",
                      isOn: featureBinding(.camera, \.cameraOn))
            Divider().opacity(0.3).padding(.leading, 38)
            ToggleRow(icon: "mic.fill",
                      title: "Microphone",
                      subtitle: "Stream iPhone mic",
                      isOn: featureBinding(.microphone, \.micOn))
            Divider().opacity(0.3).padding(.leading, 38)
            ToggleRow(icon: "hand.point.up.left.fill",
                      title: "Trackpad",
                      subtitle: "Control Mac cursor",
                      isOn: featureBinding(.trackpad, \.trackpadOn))
            Divider().opacity(0.3).padding(.leading, 38)
            ToggleRow(icon: "keyboard",
                      title: "Keyboard",
                      subtitle: "Type on the Mac",
                      isOn: featureBinding(.keyboard, \.keyboardOn))
```

新增 helper（放 `sectionHeader` 附近）：

```swift
    /// Live binding to the iPhone's feature state. Reads come from the
    /// latest `featureState` snapshot; writes send a `featureControl`
    /// frame. Until the first snapshot arrives the toggle shows off
    /// and writes are dropped by `ReceiverSession` when disconnected.
    private func featureBinding(
        _ feature: IBFeature,
        _ keyPath: KeyPath<FeatureStateSnapshot, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { session.featureState?[keyPath: keyPath] ?? false },
            set: { session.setFeature(feature, $0) }
        )
    }
```

（确认文件顶部有 `import RemoteCrabCore`；`session` 是该视图既有的 `@EnvironmentObject`/`@ObservedObject`——沿用现有属性名。）

- [ ] **Step 3: ControlPanel 徽章接真值**

`ControlPanelView.swift` 231–234 附近的四个 `active: true` 分别改为：

```swift
active: session.featureState?.cameraOn ?? false
active: session.featureState?.micOn ?? false
active: session.featureState?.trackpadOn ?? false
active: session.featureState?.keyboardOn ?? false
```

（同样沿用该视图既有的 session 属性名。）

- [ ] **Step 4: 验证 + Commit**

Run: `./scripts/test.sh`
Expected: 全绿

```bash
git add RemoteCrabReceiver/Input/CGEventInjector.swift RemoteCrabReceiver/MenuBarMenu.swift RemoteCrabReceiver/ControlPanelView.swift
git commit -m "feat(mac): real feature toggles, new gesture phases, fix key injection"
```

---

### Task 6: iOS 设置生效 + 残余还债

**Files:**
- Modify: `RemoteCrabCapture/CaptureEngine.swift`（加 `applyVideoConfig`）
- Modify: `RemoteCrabCapture/IOSSettingsView.swift`
- Modify: `RemoteCrabCapture/TouchpadScreen.swift`（149–158 行修饰键误发事件）
- Modify: `RemoteCrabCapture/KeyboardScreen.swift`（52 行 emoji）

**Interfaces:**
- Consumes: Task 3 的 `engine.features`
- Produces:
  - `CaptureEngine.applyVideoConfig(resolution: String, fps: Int) async` — Plan 2/3 不动它
  - `IOSSettingsView` 的 `trackpadSens` 保持 `@AppStorage("remotecrab.ios.trackpadSens")` 原样 — Plan 2 的加速曲线读它

- [ ] **Step 1: CaptureEngine.applyVideoConfig**

`CaptureEngine` 的 `encoder` 声明从 `private let encoder = H264Encoder()` 改为 `private var encoder = H264Encoder()`。新增：

```swift
    /// Reconfigure capture + encode for a new resolution / frame rate.
    /// Safe to call while streaming; the Mac re-reads dimensions from
    /// the metadata frame we re-send.
    func applyVideoConfig(resolution: String, fps: Int) async {
        let (preset, width, height): (AVCaptureSession.Preset, Int, Int) = {
            switch resolution {
            case "720p": return (.hd1280x720, 1280, 720)
            case "4K":   return (.hd4K3840x2160, 3840, 2160)
            default:     return (.hd1920x1080, 1920, 1080)
            }
        }()
        captureSession.beginConfiguration()
        captureSession.sessionPreset = preset
        captureSession.commitConfiguration()

        let newEncoder = H264Encoder(width: Int32(width), height: Int32(height),
                                     fps: fps, bitrate: bitrateFor(width: width, height: height, fps: fps))
        do {
            try await newEncoder.start { [weak self] frame in
                Task { @MainActor in self?.handleEncodedFrame(frame) }
            }
            encoder = newEncoder
            // Re-point the video output's delegate at the new encoder.
            captureSession.beginConfiguration()
            for output in captureSession.outputs {
                if let video = output as? AVCaptureVideoDataOutput {
                    video.setSampleBufferDelegate(newEncoder, queue: queue)
                }
            }
            captureSession.commitConfiguration()

            metadata = IBStreamMetadata(deviceName: UIDevice.current.name,
                                        width: width, height: height,
                                        fps: fps, bitrateBps: bitrateFor(width: width, height: height, fps: fps))
            if let connection, connection.state == .ready {
                sendMetadata(on: connection)
            }
        } catch {
            Self.log.error("applyVideoConfig failed: \(error, privacy: .public)")
        }
    }

    /// ~0.1 bpp real-time talk-band heuristic, clamped to [1, 12] Mbps.
    private func bitrateFor(width: Int, height: Int, fps: Int) -> Int {
        let raw = Int(Double(width * height * fps) * 0.1 / 8)
        return min(max(raw, 1_000_000), 12_000_000)
    }
```

注意：`IBStreamMetadata(deviceName:width:height:fps:bitrateBps:)` 的精确初始化签名以 `RemoteCrabCore` 中既有定义为准（`defaultConfig()` 用到的那组参数，可能还有 `codec`/`sps`/`pps` 带默认值——照搬 `defaultConfig()` 的调用形状）。

- [ ] **Step 2: IOSSettingsView 生效化**

1. 删除 `@AppStorage("remotecrab.ios.micEnabled") private var micEnabled` 一行。
2. mic Toggle 改为绑 FeatureStore：

```swift
            Toggle(IBLocale.Mic.on, isOn: Binding(
                get: { engine.features.micOn },
                set: { engine.features.set(feature: .microphone, enabled: $0) }
            ))
                .accessibilityLabel(IBLocale.Mic.on)
                .accessibilityHint("Stream the iPhone microphone to your Mac")
```

（删掉原来的 `.onChange(of: micEnabled)`。）

3. 分辨率/帧率 Picker 各加：

```swift
            .onChange(of: resolution) { _, new in
                Task { await engine.applyVideoConfig(resolution: new, fps: frameRate) }
            }
```
```swift
            .onChange(of: frameRate) { _, new in
                Task { await engine.applyVideoConfig(resolution: resolution, fps: new) }
            }
```

4. keepScreenOn Toggle 加：

```swift
            .onChange(of: keepScreenOn) { _, new in
                UIApplication.shared.isIdleTimerDisabled = new
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = keepScreenOn
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
```

- [ ] **Step 3: TouchpadScreen 修饰键误发事件修复**

`TouchpadScreen.swift` 149–158 行：删除 `IBModifierBar` 后面的整个 `.onChange(of: modifiers)` 修饰符块（它每次切修饰键都误发一个 `.down` TouchEvent）。修饰键的正确生效路径是手势事件发出时读取当前 `modifiers` 集合——该路径已存在，不要动。

- [ ] **Step 4: KeyboardScreen 去 emoji**

`KeyboardScreen.swift` 52 行附近 header 中的 `"⌨ typing on Mac"` 文本：删掉 `⌨ ` 前缀，只留纯文本（Plan 2 会整体重写此屏，这里只清掉规范违规）。

- [ ] **Step 5: 验证 + Commit**

Run: `./scripts/test.sh`
Expected: 37 tests PASS + 双 target 编译成功

```bash
git add RemoteCrabCapture/CaptureEngine.swift RemoteCrabCapture/IOSSettingsView.swift RemoteCrabCapture/TouchpadScreen.swift RemoteCrabCapture/KeyboardScreen.swift
git commit -m "fix(ios): apply settings for real, unify mic state, drop stray events"
```

---

## 完成后状态（Plan 1 验收标准）

- `./scripts/test.sh` 全绿（37 tests）
- 相机在 ContentView 出现时真正启动；设置页改分辨率/帧率立即生效并重发 metadata
- Mac 菜单栏四个开关显示 iPhone 真实状态，点击可远程开/关 iPhone 对应功能
- 延迟显示为真 RTT（2 秒刷新）
- 键盘 `.down/.up` 事件在 Mac 端真正注入（此前从未生效）
- 触控板普通移动不再误带左键拖拽
