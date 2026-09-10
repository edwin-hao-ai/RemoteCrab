# Camera Extension XPC Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Zoom / FaceTime / Photo Booth 能选择 "iBridge Camera" 并显示 iPhone 摄像头的实时画面（NAL over XPC，extension 自解码）。

**Architecture:** host（iBridgeReceiver）真签构建并 embed CMIO camera extension；extension 内起 `NSXPCListener(machServiceName:)`，host 通过 XPC 推压缩 H.264 NAL；extension 内已有 `StreamDecoder` 负责 VideoToolbox 解码并经 CMIO 拉取接口吐帧。XPC 连接失败时 host 静默 fallback 到 in-process 预览路径。

**Tech Stack:** Swift 6.2、xcodegen、NSXPCConnection/NSXPCListener、CoreMediaIO CMIOExtension、VideoToolbox。

**Spec:** `docs/superpowers/specs/2026-09-10-camera-extension-xpc-design.md`（已批准）

## Global Constraints

- 签名：`CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM: 5XNDF727Y6`（**不是** DDG3CJL762）
- 部署目标：macOS 26.0（host + 两个 extension），iOS 17.0（iBridgeCore 保留双平台）
- Mach service name：`com.ibridge.iBridgeReceiver.Camera`（与 camera ext bundle id 一致）
- NAL kind 值：video=1, sps=2, pps=3（`IBNalFrame.Kind` raw value）
- wire kind 值：metadata=0, video=1, sps=2, pps=3, touch=4, key=5, audio=6
- iBridgeCore 是 iOS 17 + macOS 26 双平台 SPM 包：XPC 相关代码必须 `#if os(macOS)` 包裹
- XPC / CMIO 集成代码不进单元测试（spec 已批准）；每个 task 的验证 = `./scripts/test.sh` 26 测试全绿 + 双端 build 成功 + task 特有验证命令
- **不要** commit 工作区已有的未提交改动（`iBridgeReceiver/FirstLaunchView.swift`、`iBridgeReceiver/iBridgeReceiverApp.swift`）——每个 commit 只 `git add` 本 task 的文件
- 日志用 `os_log`，subsystem `com.ibridge`，不写裸 `print()`（新代码遵守；不回头改旧代码）
- UI 字符串不加 emoji

---

### Task 1: project-mac.yml — 真签 + embed extension + 补 iBridgeCore 依赖

**Files:**
- Modify: `project-mac.yml`
- Modify: `iBridgeCameraExtension/Sources/iBridgeCameraExtension/CameraExtensionStream.swift:101-114`（修编译错误）

**Interfaces:**
- Consumes: 无
- Produces: 真签的 `iBridgeReceiver.app`，其 `Contents/PlugIns/` 内含 `iBridgeCameraExtension.appex` 和 `iBridgeAudioExtension.appex`；后续 task 的所有代码都在这个构建配置下编译

**背景（executor 需要知道的）:**

1. 当前 `project-mac.yml` 所有 target 是 ad-hoc 签名（`CODE_SIGN_IDENTITY: "-"`），CMIO extension 不会被系统加载。
2. **潜在 bug 1**：`iBridgeCameraExtension` 和 `iBridgeAudioExtension` 两个 target 的源码都 `import iBridgeCore`，但 yml 里没声明 package 依赖 —— 一旦 extension 参与构建必然链接失败。
3. **潜在 bug 2**：`CameraExtensionStream.swift` 的 `StreamDecoder.feed(nalUnit:kind:)` 里 `switch kind` 有一个 `case .metadata: break`，但 `IBNalFrame.Kind`（`iBridgeCore/Sources/iBridgeCore/Networking/IBProtocol.swift:68-72`）只有 `video / sps / pps` 三个 case —— extension 一旦编译就会报错。当前没炸是因为 host 不依赖 extension，它从未被构建过。

- [ ] **Step 1: 修改 `project-mac.yml` 顶层 settings**

把第 10-18 行的 `settings.base` 改为：

```yaml
settings:
  base:
    SWIFT_VERSION: "6.2"
    DEVELOPMENT_TEAM: "5XNDF727Y6"
    CODE_SIGN_STYLE: Automatic
    ENABLE_USER_SCRIPT_SANDBOXING: NO
    SWIFT_TREAT_WARNINGS_AS_ERRORS: NO
    MACOSX_DEPLOYMENT_TARGET: "26.0"
```

（删掉 `CODE_SIGN_IDENTITY: "-"`，`CODE_SIGN_STYLE` 从 `Manual` 改 `Automatic`，`DEVELOPMENT_TEAM` 从空改 `5XNDF727Y6`。）

- [ ] **Step 2: 修改 host target 的签名设置和 dependencies**

`targets.iBridgeReceiver.settings.base`（第 51-59 行）改为：

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ibridge.iBridgeReceiver
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_ENTITLEMENTS: iBridgeReceiver/iBridgeReceiver.entitlements
        CODE_SIGNING_ALLOWED: YES
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: "5XNDF727Y6"
```

`targets.iBridgeReceiver.dependencies`（第 34-36 行）改为：

```yaml
    dependencies:
      - package: iBridgeCore
        product: iBridgeCore
      - target: iBridgeCameraExtension
        embed: true
        codeSignOnCopy: true
      - target: iBridgeAudioExtension
        embed: true
        codeSignOnCopy: true
```

- [ ] **Step 3: 修改两个 extension target — 签名 + 补 iBridgeCore 依赖**

`iBridgeCameraExtension` target：在 `sources:` 之后、`info:` 之前插入：

```yaml
    dependencies:
      - package: iBridgeCore
        product: iBridgeCore
```

其 `settings.base` 改为：

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ibridge.iBridgeReceiver.Camera
        INFOPLIST_FILE: iBridgeCameraExtension/Info.plist
        CODE_SIGN_ENTITLEMENTS: iBridgeCameraExtension/CameraExtension.entitlements
        CODE_SIGNING_ALLOWED: YES
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: "5XNDF727Y6"
```

`iBridgeAudioExtension` target 同样插入 `dependencies`（同上），`settings.base` 改为：

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ibridge.iBridgeReceiver.Audio
        INFOPLIST_FILE: iBridgeAudioExtension/Info.plist
        CODE_SIGN_ENTITLEMENTS: iBridgeAudioExtension/AudioExtension.entitlements
        CODE_SIGNING_ALLOWED: YES
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: "5XNDF727Y6"
```

- [ ] **Step 4: 修 `CameraExtensionStream.swift` 的 `.metadata` 编译错误**

`StreamDecoder.feed(nalUnit:kind:)`（第 101-114 行）的 switch 改为：

```swift
    func feed(nalUnit: Data, kind: IBNalFrame.Kind) {
        switch kind {
        case .sps:
            sps = nalUnit
            tryMakeSession()
        case .pps:
            pps = nalUnit
            tryMakeSession()
        case .video:
            decode(nalUnit: nalUnit)
        }
    }
```

（即删掉 `case .metadata: break`。）

- [ ] **Step 5: 重新生成工程并构建**

Run:
```bash
cd /Users/edwinhao/iBridge
xcodegen generate --spec project-mac.yml
xcodebuild -project iBridgeReceiver.xcodeproj -scheme iBridgeReceiver \
    -configuration Debug -allowProvisioningUpdates build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

若签名报错（provisioning profile 拉取失败）：确认 Xcode 已登录 Apple ID（已确认登录），重试时加 `-allowProvisioningDeviceRegistration`。

- [ ] **Step 6: 验证 appex 已 embed**

Run:
```bash
ls /Users/edwinhao/Library/Developer/Xcode/DerivedData/iBridgeReceiver-*/Build/Products/Debug/iBridgeReceiver.app/Contents/PlugIns/
```
Expected: 输出包含 `iBridgeCameraExtension.appex` 和 `iBridgeAudioExtension.appex`

- [ ] **Step 7: 跑全套测试确认无回归**

Run: `cd /Users/edwinhao/iBridge && ./scripts/test.sh 2>&1 | tail -5`
Expected: `All checks passed.`

- [ ] **Step 8: Commit**

```bash
cd /Users/edwinhao/iBridge
git add project-mac.yml iBridgeCameraExtension/Sources/iBridgeCameraExtension/CameraExtensionStream.swift iBridgeReceiver.xcodeproj/project.pbxproj
git commit -m "Mac: real signing (team 5XNDF727Y6) + embed camera/audio extensions"
```

---

### Task 2: XPC 协议移到 iBridgeCore（`IBCameraXPC.swift`）

**Files:**
- Create: `iBridgeCore/Sources/iBridgeCore/Networking/IBCameraXPC.swift`
- Modify: `iBridgeReceiver/CameraExtensionBridge.swift`（删协议定义 + 清死代码）

**Interfaces:**
- Consumes: 无（纯定义迁移）
- Produces（后续 task 依赖这些名字）:
  - `@objc public protocol IBridgeFrameSink` — `feed(nalUnit: Data, kind: Int)` / `setFormat(width: Int, height: Int, fps: Int)` / `stop()`
  - `@objc public protocol IBridgeFrameSource` — `currentFormat() -> [String: Int]?` / `deviceName() -> String?`
  - `public enum IBridgeCameraXPC { public static let machServiceName: String }`

**背景：** host 和 extension 必须共享同一份 `@objc` 协议定义（NSXPCInterface 按协议方法签名握手）。当前协议定义在 host 侧的 `CameraExtensionBridge.swift` 里，extension 看不到。移到 iBridgeCore 后双端 `import iBridgeCore` 即可。iBridgeCore 同时编 iOS，所以整个文件 `#if os(macOS)` 包裹。

- [ ] **Step 1: 创建 `iBridgeCore/Sources/iBridgeCore/Networking/IBCameraXPC.swift`**

完整内容：

```swift
#if os(macOS)
import Foundation

/// XPC contract between `iBridgeReceiver` (host) and
/// `iBridgeCameraExtension` (system camera extension).
///
/// The extension runs an `NSXPCListener` on
/// `IBridgeCameraXPC.machServiceName`. The host connects and pushes
/// compressed H.264 NAL units; the extension decodes them itself via
/// VideoToolbox (`StreamDecoder`) and serves frames to CMIO clients
/// (Zoom, FaceTime, Photo Booth, …).

/// Implemented by the extension, called by the host.
@objc public protocol IBridgeFrameSink {
    /// Push one H.264 NAL unit. `kind` is an `IBNalFrame.Kind` raw
    /// value: 1 = video, 2 = SPS, 3 = PPS.
    func feed(nalUnit data: Data, kind: Int)

    /// Stream format changed; the extension should expect a fresh
    /// SPS/PPS pair and rebuild its decoder state.
    func setFormat(width: Int, height: Int, fps: Int)

    /// iPhone disconnected. Release buffered frames and stop emitting.
    func stop()
}

/// Implemented by the host, called by the extension.
@objc public protocol IBridgeFrameSource {
    /// Current stream config, e.g. `["width": 1920, "height": 1080, "fps": 30]`.
    /// nil when no iPhone is connected.
    func currentFormat() -> [String: Int]?

    /// Name of the connected iPhone, used to label the camera.
    func deviceName() -> String?
}

/// Shared constants for the camera-extension XPC channel.
public enum IBridgeCameraXPC {
    /// Mach service name the extension's `NSXPCListener` registers.
    /// Matches the camera extension's bundle identifier.
    public static let machServiceName = "com.ibridge.iBridgeReceiver.Camera"
}
#endif
```

- [ ] **Step 2: 从 `CameraExtensionBridge.swift` 删除协议定义**

删除该文件第 4-36 行的两个 `@objc public protocol` 定义（`IBridgeFrameSink` 和 `IBridgeFrameSource`）以及它们的文档注释（第 4-13 行的总注释保留一句改写）。文件开头保留：

```swift
import Foundation
import iBridgeCore

/// The macOS-side bridge between `ReceiverSession` and the system
/// camera extension. The `IBridgeFrameSink` / `IBridgeFrameSource`
/// XPC protocols live in iBridgeCore (`IBCameraXPC.swift`) so both
/// processes share one definition.
```

- [ ] **Step 3: 清理 `CameraExtensionBridge.swift` 里的死代码**

删除：
- 第 161-166 行的 `UncheckedBox` struct
- 第 196-204 行的 `private extension NSXPCConnection`（`remoteObjectProxyFuture` shim）

并把 `connectXPC(serviceName:)`（第 123-158 行）整个替换为：

```swift
    private func connectXPC(serviceName: String) async throws {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: IBridgeFrameSink.self)
        connection.exportedInterface = NSXPCInterface(with: IBridgeFrameSource.self)
        connection.exportedObject = HostSourceProvider { [weak self] in
            (width: self?.lastWidth ?? 0,
             height: self?.lastHeight ?? 0,
             fps: self?.lastFPS ?? 0)
        }
        connection.invalidationHandler = { [weak self] in
            self?.mode = .inProcess
        }
        connection.interruptionHandler = { [weak self] in
            self?.mode = .inProcess
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.mode = .inProcess
        }) as? IBridgeFrameSink else {
            connection.invalidate()
            throw CameraExtensionError.badProxy
        }
        self.connection = connection
        self.sink = proxy
        proxy.setFormat(width: lastWidth, height: lastHeight, fps: lastFPS)
    }
```

（说明：`remoteObjectProxy` 是懒代理，同步就能拿到；对端不存在时错误经 error handler / invalidation 回调，自动 fallback `inProcess`。原来 `withCheckedThrowingContinuation` + `DispatchQueue.main` 的拿法既不必要也可能死锁。）

- [ ] **Step 4: 验证 iBridgeCore 双平台都能编**

Run:
```bash
cd /Users/edwinhao/iBridge/iBridgeCore && swift build 2>&1 | tail -3
```
Expected: `Build complete!`（无错误）

- [ ] **Step 5: 跑全套测试**

Run: `cd /Users/edwinhao/iBridge && ./scripts/test.sh 2>&1 | tail -5`
Expected: `All checks passed.`（26 测试 + 两端 build）

- [ ] **Step 6: Commit**

```bash
cd /Users/edwinhao/iBridge
git add iBridgeCore/Sources/iBridgeCore/Networking/IBCameraXPC.swift iBridgeReceiver/CameraExtensionBridge.swift
git commit -m "Move camera XPC protocols to iBridgeCore, share with extension"
```

---

### Task 3: Extension 端 XPC listener（`XPCFrameListener.swift`）

**Files:**
- Create: `iBridgeCameraExtension/Sources/iBridgeCameraExtension/XPCFrameListener.swift`
- Modify: `iBridgeCameraExtension/Sources/iBridgeCameraExtension/CameraExtensionProvider.swift`
- Modify: `iBridgeCameraExtension/Sources/iBridgeCameraExtension/CameraExtensionStream.swift`（加 `reset()`）

**Interfaces:**
- Consumes: Task 2 的 `IBridgeFrameSink` / `IBridgeCameraXPC.machServiceName`；extension 已有的 `CameraExtensionStream.receive(nalUnit: Data, kind: IBNalFrame.Kind)`
- Produces:
  - `final class XPCFrameListener: NSObject, NSXPCListenerDelegate` — `init(stream:)` / `start()` / `var onHostConnectionChanged: ((Bool) -> Void)?`
  - `CameraExtensionStream.reset()` — 清空解码缓冲
  - `CameraExtensionProvider` init 时自动启动 listener，host 连接状态驱动 `device.isAvailable`

**背景：** extension 的 `CameraExtensionProvider.swift` 里有一个 Swift 协议 `iBridgeFrameSink`（小写 i，第 46-49 行）和 provider 上的 `weak var frameSink`（第 17 行）——**没有任何代码设置或调用它们**，是死代码，本 task 删除，用真正的 XPC 路径替代。extension 的 entitlements 已含 `com.apple.security.network.server`，可以注册 Mach service。

- [ ] **Step 1: 给 `CameraExtensionStream` / `StreamDecoder` 加 `reset()`**

`CameraExtensionStream.swift` 中，`CameraExtensionStream` 类内（`receive(nalUnit:kind:)` 之后）加：

```swift
    /// Release buffered frames and stop emitting. Called when the host
    /// disconnects or the stream format changes.
    func reset() {
        decoder.reset()
        lastEmitted = .distantPast
    }
```

`StreamDecoder` 类内加：

```swift
    func reset() {
        lock.lock()
        pixelBuffers.removeAll()
        lastBuffer = nil
        lock.unlock()
    }
```

- [ ] **Step 2: 创建 `XPCFrameListener.swift`**

完整内容：

```swift
import Foundation
import os
import iBridgeCore

/// Extension-side XPC listener. The host (iBridgeReceiver) connects
/// to `IBridgeCameraXPC.machServiceName` and pushes H.264 NAL units
/// through the `IBridgeFrameSink` interface.
final class XPCFrameListener: NSObject, NSXPCListenerDelegate {

    private let listener: NSXPCListener
    private let stream: CameraExtensionStream
    private let log = Logger(subsystem: "com.ibridge", category: "camera-xpc")

    /// Called when host connectivity changes (true = host connected).
    var onHostConnectionChanged: ((Bool) -> Void)?

    init(stream: CameraExtensionStream) {
        self.stream = stream
        self.listener = NSXPCListener(machServiceName: IBridgeCameraXPC.machServiceName)
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
        log.info("XPC listener started on \(IBridgeCameraXPC.machServiceName, privacy: .public)")
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: IBridgeFrameSink.self)
        connection.exportedObject = ExtensionFrameSink(stream: stream)
        connection.remoteObjectInterface = NSXPCInterface(with: IBridgeFrameSource.self)
        connection.invalidationHandler = { [weak self] in
            self?.stream.reset()
            self?.onHostConnectionChanged?(false)
        }
        connection.interruptionHandler = { [weak self] in
            self?.onHostConnectionChanged?(false)
        }
        connection.resume()
        log.info("host connected")
        onHostConnectionChanged?(true)
        return true
    }
}

/// Receives NAL units from the host over XPC and forwards them to the
/// stream's VideoToolbox decoder.
final class ExtensionFrameSink: NSObject, IBridgeFrameSink {

    private weak var stream: CameraExtensionStream?

    init(stream: CameraExtensionStream) {
        self.stream = stream
    }

    func feed(nalUnit data: Data, kind: Int) {
        guard let nalKind = IBNalFrame.Kind(rawValue: UInt8(kind)) else { return }
        stream?.receive(nalUnit: data, kind: nalKind)
    }

    func setFormat(width: Int, height: Int, fps: Int) {
        // Format description is rebuilt from the next SPS/PPS pair
        // inside StreamDecoder; drop stale frames from the old format.
        stream?.reset()
    }

    func stop() {
        stream?.reset()
    }
}
```

- [ ] **Step 3: 重写 `CameraExtensionProvider.swift`**

完整替换为：

```swift
import CoreMediaIO
import Foundation
import IOKit
import iBridgeCore

/// The Camera Extension's top-level provider object.
///
/// `CMIOExtensionProvider` is the entry point the system calls when an
/// app (Zoom, Teams, Photo Booth, OBS, …) starts consuming the camera.
/// We expose a single device backed by a single stream that forwards
/// frames from the connected iPhone.
///
/// Frames arrive over XPC: `iBridgeReceiver` connects to
/// `IBridgeCameraXPC.machServiceName` and pushes H.264 NAL units,
/// which `CameraExtensionStream` decodes via VideoToolbox.
@objc(CameraExtensionProvider)
final class CameraExtensionProvider: NSObject, CMIOExtensionProvider {

    private let device: CameraExtensionDevice
    private let xpcListener: XPCFrameListener

    override init() {
        self.device = CameraExtensionDevice()
        self.xpcListener = XPCFrameListener(stream: device.stream)
        super.init()
        xpcListener.onHostConnectionChanged = { [weak self] connected in
            self?.device.isAvailable = connected
        }
        xpcListener.start()
    }

    func connect(to client: CMIOExtensionClient) throws {
        try device.connect(to: client)
    }

    func disconnect(from client: CMIOExtensionClient) {
        device.disconnect(from: client)
    }

    // MARK: - CMIOExtensionProviderSource

    var devices: [CMIOExtensionDevice] { [device] }

    var providerName: String { "iBridge Camera" }
}

extension CameraExtensionProvider: CMIOExtensionProviderSource {}
extension CameraExtensionDevice: CMIOExtensionDeviceSource {}
extension CameraExtensionStream: CMIOExtensionStreamSource {}
```

（变化点：删 `frameSink` 属性和死协议 `iBridgeFrameSink`；init 启动 XPC listener；连接状态驱动 `device.isAvailable`；加 `@objc(CameraExtensionProvider)` 保证 principal class 按 Info.plist 的名字解析。）

- [ ] **Step 4: 构建验证 extension 编译通过**

Run:
```bash
cd /Users/edwinhao/iBridge
xcodebuild -project iBridgeReceiver.xcodeproj -scheme iBridgeReceiver \
    -configuration Debug -allowProvisioningUpdates build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`（extension 作为 embedded dependency 一并编译）

- [ ] **Step 5: 跑全套测试**

Run: `./scripts/test.sh 2>&1 | tail -5`
Expected: `All checks passed.`

- [ ] **Step 6: Commit**

```bash
cd /Users/edwinhao/iBridge
git add iBridgeCameraExtension/Sources/iBridgeCameraExtension/
git commit -m "Camera extension: XPC listener, wire host connection to isAvailable"
```

---

### Task 4: Host 侧接线 — `ReceiverSession` → `CameraExtensionBridge`

**Files:**
- Modify: `iBridgeReceiver/CameraExtensionBridge.swift`（加 `NullFrameSink` + deviceName 支持）
- Modify: `iBridgeReceiver/ReceiverSession.swift`

**Interfaces:**
- Consumes: Task 2 的 `IBridgeCameraXPC.machServiceName`、Task 3 的 extension listener
- Produces: `ReceiverSession.cameraBridge: CameraExtensionBridge`（`.xpc` 模式启动）；iPhone 每来一个 NAL 都镜像推给 extension；`IBridgeFrameSource.deviceName()` 返回已连接 iPhone 的名字

**背景：** `CameraExtensionBridge` 类存在但**从未被实例化**——全项目 grep 只有定义没有使用。本 task 把它接进 `ReceiverSession.handleInbound(_:)` 的 dispatch（`ReceiverSession.swift:135-161`）。

- [ ] **Step 1: `CameraExtensionBridge.swift` 加 deviceName 通道 + `NullFrameSink`**

在 `CameraExtensionBridge` 类的 `// MARK: - State` 区，`lastFPS` 声明之后加：

```swift
    /// Name of the connected iPhone, mirrored from stream metadata.
    public private(set) var lastDeviceName: String?
```

在 `updateFormat(width:height:fps:)` 之后加：

```swift
    /// Called when stream metadata arrives so the extension can label
    /// the camera after the connected iPhone.
    public func updateDeviceName(_ name: String) {
        sinkQueue.async { [weak self] in
            self?.lastDeviceName = name
        }
    }
```

把 `HostSourceProvider`（第 172-192 行）整个替换为：

```swift
final class HostSourceProvider: NSObject, IBridgeFrameSource, @unchecked Sendable {
    let dimensionsProvider: () -> (width: Int, height: Int, fps: Int)
    var nameProvider: () -> String? = { nil }

    init(dimensionsProvider: @escaping () -> (width: Int, height: Int, fps: Int)) {
        self.dimensionsProvider = dimensionsProvider
    }

    func currentFormat() -> [String: Int]? {
        let d = dimensionsProvider()
        return [
            "width": d.width,
            "height": d.height,
            "fps": d.fps
        ]
    }

    func deviceName() -> String? {
        nameProvider()
    }
}
```

`connectXPC(serviceName:)` 里，创建 `HostSourceProvider` 的代码改为（在赋给 `exportedObject` 前先配置 nameProvider）：

```swift
        let source = HostSourceProvider { [weak self] in
            (width: self?.lastWidth ?? 0,
             height: self?.lastHeight ?? 0,
             fps: self?.lastFPS ?? 0)
        }
        source.nameProvider = { [weak self] in self?.lastDeviceName }
        connection.exportedObject = source
```

文件末尾（`CameraExtensionError` 之前）加：

```swift
/// No-op sink used as a placeholder while the XPC connection is being
/// established (or after it falls back to in-process mode).
final class NullFrameSink: NSObject, IBridgeFrameSink {
    func feed(nalUnit data: Data, kind: Int) {}
    func setFormat(width: Int, height: Int, fps: Int) {}
    func stop() {}
}
```

- [ ] **Step 2: `ReceiverSession.swift` 实例化并启动 bridge**

在属性区（`let parser = IBWire.Parser()` 之后）加：

```swift
    /// Feeds a copy of every inbound NAL to the camera extension.
    /// Falls back to a no-op when the extension isn't reachable.
    let cameraBridge = CameraExtensionBridge(
        mode: .xpc(machServiceName: IBridgeCameraXPC.machServiceName)
    )
```

在 `init()` 末尾（`decoder.onDecoded` 赋值之后）加：

```swift
        Task { [cameraBridge] in
            try? await cameraBridge.start(sink: NullFrameSink())
        }
```

- [ ] **Step 3: `handleInbound(_:)` 里把 NAL 镜像推给 bridge**

`handleInbound(_:)` 的 switch（第 139-160 行）中，改三个 case：

```swift
            case .sps:
                decoder.feedSPS(frame.payload)
                cameraBridge.feed(nalUnit: frame.payload, kind: Int(IBNalFrame.Kind.sps.rawValue))
            case .pps:
                decoder.feedPPS(frame.payload)
                cameraBridge.feed(nalUnit: frame.payload, kind: Int(IBNalFrame.Kind.pps.rawValue))
            case .video:
                decoder.feedVideo(frame.payload)
                cameraBridge.feed(nalUnit: frame.payload, kind: Int(IBNalFrame.Kind.video.rawValue))
```

- [ ] **Step 4: `handleMetadata(_:)` 里同步格式和设备名**

`handleMetadata(_:)`（第 169-178 行）的 `do` block 里，`if let pps ...` 之后加：

```swift
            cameraBridge.updateFormat(width: decoded.width, height: decoded.height, fps: decoded.fps)
            cameraBridge.updateDeviceName(decoded.deviceName)
            if let sps = decoded.sps {
                cameraBridge.feed(nalUnit: sps, kind: Int(IBNalFrame.Kind.sps.rawValue))
            }
            if let pps = decoded.pps {
                cameraBridge.feed(nalUnit: pps, kind: Int(IBNalFrame.Kind.pps.rawValue))
            }
```

- [ ] **Step 5: 构建 + 全套测试**

Run:
```bash
cd /Users/edwinhao/iBridge
./scripts/test.sh 2>&1 | tail -5
```
Expected: `All checks passed.`

- [ ] **Step 6: 手动 smoke — host 端 XPC 连接日志**

Run:
```bash
open -a "/Users/edwinhao/Library/Developer/Xcode/DerivedData/iBridgeReceiver-dtnzehgyhpjbsdcawmkwuoeyeklw/Build/Products/Debug/iBridgeReceiver.app"
sleep 3
log show --last 1m --predicate 'subsystem == "com.ibridge"' 2>/dev/null | head -20
```
Expected: receiver 正常启动不崩；extension 侧日志要等系统加载 extension 后才出现（Task 5 验证）。此步只确认 host 启动无 crash。若 DerivedData 路径不同，用 `ls -d ~/Library/Developer/Xcode/DerivedData/iBridgeReceiver-*/Build/Products/Debug/iBridgeReceiver.app` 定位。

- [ ] **Step 7: Commit**

```bash
cd /Users/edwinhao/iBridge
git add iBridgeReceiver/CameraExtensionBridge.swift iBridgeReceiver/ReceiverSession.swift
git commit -m "Wire ReceiverSession to camera extension via XPC bridge"
```

---

### Task 5: 手动验证（Photo Booth）+ 文档更新

**Files:**
- Modify: `E2E_TESTING.md`
- Modify: `AGENTS.md`（Camera Extension 状态：skeleton → wired）
- Modify: `HANDOFF.md`（4.1 待做项勾掉 Camera Extension wiring）

**Interfaces:**
- Consumes: Task 1-4 的全部产出
- Produces: 可复现的验证步骤文档

**前置条件（用户/环境）:**
- iPhone 14 在线且 iBridgeCapture 在跑（当前 `devicectl` 显示 unavailable，需要先解锁/连接）
- 或：用 iPhone simulator 跑 iBridgeCapture 提供视频源（simulator 无摄像头，此路径只能验证 XPC 连接不能验证画面）

- [ ] **Step 1: 确认 extension 已被系统注册**

启动真签的 iBridgeReceiver 后：

Run:
```bash
systemextensionsctl list 2>&1 | grep -i ibridge
pluginkit -m -i com.apple.cmioextension-provider 2>/dev/null | grep -i ibridge
```
Expected: 至少一条命令输出包含 `com.ibridge.iBridgeReceiver.Camera`

- [ ] **Step 2: Photo Booth 验证画面**

1. iPhone 14 解锁并启动 iBridgeCapture（摄像头模式）
2. Mac 上启动 iBridgeReceiver（应自动 Bonjour 连接）
3. 打开 Photo Booth → 菜单 Camera → 选 "iBridge Camera"
4. Expected: 看到 iPhone 摄像头的实时画面

若列表里没有 "iBridge Camera"：
- 检查 extension 签名：`codesign -dv <path>/iBridgeReceiver.app/Contents/PlugIns/iBridgeCameraExtension.appex`
- 检查日志：`log stream --predicate 'subsystem == "com.ibridge"'` 看 XPC listener 是否起来
- 杀掉 `com.apple.cmio.registeration` 相关缓存：`sudo killall -9 cmioextensionagent 2>/dev/null; killall "Photo Booth"` 重试

- [ ] **Step 3: 断开行为验证**

退出 iBridgeReceiver → Photo Booth 中 "iBridge Camera" 应消失或黑帧，Photo Booth 不崩溃。

- [ ] **Step 4: 更新 `E2E_TESTING.md`**

在文件中追加一节：

```markdown
## Camera Extension（V0.3）

1. 真签构建（team 5XNDF727Y6，xcodegen 后 xcodebuild -allowProvisioningUpdates）
2. 启动 iBridgeReceiver —— 系统自动注册 embedded extension
3. iPhone 启动 iBridgeCapture 并连接
4. Photo Booth / Zoom → 摄像头选 "iBridge Camera" → 应看到实时画面
5. 退出 iBridgeReceiver → "iBridge Camera" 不可用，不崩溃
排查：`log stream --predicate 'subsystem == "com.ibridge"'`，
`pluginkit -m -i com.apple.cmioextension-provider | grep -i ibridge`
```

- [ ] **Step 5: 更新 `AGENTS.md` 和 `HANDOFF.md`**

`AGENTS.md`：
- "Mac V0.2 features" 表中 `Camera Extension skeleton` 行的 Notes 从 "CMIOExtension (Provider / Device / Stream), not yet wired" 改为 "wired via XPC (NAL over XPC, extension self-decodes)"
- "❌ Still needed for V1.0" 表中删除 "Camera Extension host wiring" 行
- "Why we ship an XPC stub for the Camera Extension" 一节改写为 "How the Camera Extension XPC bridge works"，简述 host→listener→StreamDecoder 路径

`HANDOFF.md` 4.1：
- `[ ] Camera Extension 真正装到 Mac（需 code signing）` → `[x]`
- `[ ] Camera Extension 完整 XPC bridge` → `[x]`

- [ ] **Step 6: Commit**

```bash
cd /Users/edwinhao/iBridge
git add E2E_TESTING.md AGENTS.md HANDOFF.md
git commit -m "Docs: camera extension wired, Photo Booth verification steps"
```

---

## Self-Review 记录

- **Spec 覆盖**：签名（T1）、embed（T1）、iBridgeCore 依赖 bug（T1）、`.metadata` 编译错误（T1）、协议迁移（T2）、extension listener（T3）、死协议删除（T3）、host 接线 + fallback（T2 Step 3 的 invalidation handler + T4）、isAvailable 驱动（T3）、E2E 文档（T5）——全覆盖
- **类型一致性**：`IBridgeFrameSink.feed(nalUnit:kind:)` 在 T2 定义、T3 实现、T4 调用一致；`IBNalFrame.Kind` raw value (1/2/3) 与 spec 一致；`machServiceName` 与 bundle id 一致
- **Placeholder 扫描**：无 TBD/TODO；每个代码 step 都是完整代码
