# Camera Extension XPC Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Zoom / FaceTime / Photo Booth 能选择 "RemoteCrab Camera" 并显示 iPhone 摄像头的实时画面（NAL over XPC，extension 自解码）。

**Architecture:** host（RemoteCrabReceiver）真签构建并 embed CMIO camera extension；extension 内起 `NSXPCListener(machServiceName:)`，host 通过 XPC 推压缩 H.264 NAL；extension 内已有 `StreamDecoder` 负责 VideoToolbox 解码并经 CMIO 拉取接口吐帧。XPC 连接失败时 host 静默 fallback 到 in-process 预览路径。

**Tech Stack:** Swift 6.2、xcodegen、NSXPCConnection/NSXPCListener、CoreMediaIO CMIOExtension、VideoToolbox。

**Spec:** `docs/superpowers/specs/2026-09-10-camera-extension-xpc-design.md`（已批准）

## Global Constraints

- 签名：`CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM: 5XNDF727Y6`（**不是** DDG3CJL762）
- 部署目标：macOS 26.0（host + 两个 extension），iOS 17.0（RemoteCrabCore 保留双平台）
- Mach service name：`com.remotecrab.RemoteCrabReceiver.Camera`（与 camera ext bundle id 一致）
- NAL kind 值：video=1, sps=2, pps=3（`IBNalFrame.Kind` raw value）
- wire kind 值：metadata=0, video=1, sps=2, pps=3, touch=4, key=5, audio=6
- RemoteCrabCore 是 iOS 17 + macOS 26 双平台 SPM 包：XPC 相关代码必须 `#if os(macOS)` 包裹
- XPC / CMIO 集成代码不进单元测试（spec 已批准）；每个 task 的验证 = `./scripts/test.sh` 26 测试全绿 + 双端 build 成功 + task 特有验证命令
- **不要** commit 工作区已有的未提交改动（`RemoteCrabReceiver/FirstLaunchView.swift`、`RemoteCrabReceiver/RemoteCrabReceiverApp.swift`）——每个 commit 只 `git add` 本 task 的文件
- 日志用 `os_log`，subsystem `com.remotecrab`，不写裸 `print()`（新代码遵守；不回头改旧代码）
- UI 字符串不加 emoji

---

### Task 1: project-mac.yml — 真签 + embed extension + 补 RemoteCrabCore 依赖

**Files:**
- Modify: `project-mac.yml`
- Modify: `RemoteCrabCameraExtension/Sources/RemoteCrabCameraExtension/CameraExtensionStream.swift:101-114`（修编译错误）

**Interfaces:**
- Consumes: 无
- Produces: 真签的 `RemoteCrabReceiver.app`，其 `Contents/PlugIns/` 内含 `RemoteCrabCameraExtension.appex` 和 `RemoteCrabAudioExtension.appex`；后续 task 的所有代码都在这个构建配置下编译

**背景（executor 需要知道的）:**

1. 当前 `project-mac.yml` 所有 target 是 ad-hoc 签名（`CODE_SIGN_IDENTITY: "-"`），CMIO extension 不会被系统加载。
2. **潜在 bug 1**：`RemoteCrabCameraExtension` 和 `RemoteCrabAudioExtension` 两个 target 的源码都 `import RemoteCrabCore`，但 yml 里没声明 package 依赖 —— 一旦 extension 参与构建必然链接失败。
3. **潜在 bug 2**：`CameraExtensionStream.swift` 的 `StreamDecoder.feed(nalUnit:kind:)` 里 `switch kind` 有一个 `case .metadata: break`，但 `IBNalFrame.Kind`（`RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBProtocol.swift:68-72`）只有 `video / sps / pps` 三个 case —— extension 一旦编译就会报错。当前没炸是因为 host 不依赖 extension，它从未被构建过。

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

`targets.RemoteCrabReceiver.settings.base`（第 51-59 行）改为：

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.remotecrab.RemoteCrabReceiver
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_ENTITLEMENTS: RemoteCrabReceiver/RemoteCrabReceiver.entitlements
        CODE_SIGNING_ALLOWED: YES
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: "5XNDF727Y6"
```

`targets.RemoteCrabReceiver.dependencies`（第 34-36 行）改为：

```yaml
    dependencies:
      - package: RemoteCrabCore
        product: RemoteCrabCore
      - target: RemoteCrabCameraExtension
        embed: true
        codeSignOnCopy: true
      - target: RemoteCrabAudioExtension
        embed: true
        codeSignOnCopy: true
```

- [ ] **Step 3: 修改两个 extension target — 签名 + 补 RemoteCrabCore 依赖**

`RemoteCrabCameraExtension` target：在 `sources:` 之后、`info:` 之前插入：

```yaml
    dependencies:
      - package: RemoteCrabCore
        product: RemoteCrabCore
```

其 `settings.base` 改为：

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.remotecrab.RemoteCrabReceiver.Camera
        INFOPLIST_FILE: RemoteCrabCameraExtension/Info.plist
        CODE_SIGN_ENTITLEMENTS: RemoteCrabCameraExtension/CameraExtension.entitlements
        CODE_SIGNING_ALLOWED: YES
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: "5XNDF727Y6"
```

`RemoteCrabAudioExtension` target 同样插入 `dependencies`（同上），`settings.base` 改为：

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.remotecrab.RemoteCrabReceiver.Audio
        INFOPLIST_FILE: RemoteCrabAudioExtension/Info.plist
        CODE_SIGN_ENTITLEMENTS: RemoteCrabAudioExtension/AudioExtension.entitlements
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
cd /Users/edwinhao/RemoteCrab
xcodegen generate --spec project-mac.yml
xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrabReceiver \
    -configuration Debug -allowProvisioningUpdates build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

若签名报错（provisioning profile 拉取失败）：确认 Xcode 已登录 Apple ID（已确认登录），重试时加 `-allowProvisioningDeviceRegistration`。

- [ ] **Step 6: 验证 appex 已 embed**

Run:
```bash
ls /Users/edwinhao/Library/Developer/Xcode/DerivedData/RemoteCrabReceiver-*/Build/Products/Debug/RemoteCrabReceiver.app/Contents/PlugIns/
```
Expected: 输出包含 `RemoteCrabCameraExtension.appex` 和 `RemoteCrabAudioExtension.appex`

- [ ] **Step 7: 跑全套测试确认无回归**

Run: `cd /Users/edwinhao/RemoteCrab && ./scripts/test.sh 2>&1 | tail -5`
Expected: `All checks passed.`

- [ ] **Step 8: Commit**

```bash
cd /Users/edwinhao/RemoteCrab
git add project-mac.yml RemoteCrabCameraExtension/Sources/RemoteCrabCameraExtension/CameraExtensionStream.swift RemoteCrabReceiver.xcodeproj/project.pbxproj
git commit -m "Mac: real signing (team 5XNDF727Y6) + embed camera/audio extensions"
```

---

### Task 2: XPC 协议移到 RemoteCrabCore（`IBCameraXPC.swift`）

**Files:**
- Create: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBCameraXPC.swift`
- Modify: `RemoteCrabReceiver/CameraExtensionBridge.swift`（删协议定义 + 清死代码）

**Interfaces:**
- Consumes: 无（纯定义迁移）
- Produces（后续 task 依赖这些名字）:
  - `@objc public protocol IBridgeFrameSink` — `feed(nalUnit: Data, kind: Int)` / `setFormat(width: Int, height: Int, fps: Int)` / `stop()`
  - `@objc public protocol IBridgeFrameSource` — `currentFormat() -> [String: Int]?` / `deviceName() -> String?`
  - `public enum IBridgeCameraXPC { public static let machServiceName: String }`

**背景：** host 和 extension 必须共享同一份 `@objc` 协议定义（NSXPCInterface 按协议方法签名握手）。当前协议定义在 host 侧的 `CameraExtensionBridge.swift` 里，extension 看不到。移到 RemoteCrabCore 后双端 `import RemoteCrabCore` 即可。RemoteCrabCore 同时编 iOS，所以整个文件 `#if os(macOS)` 包裹。

- [ ] **Step 1: 创建 `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBCameraXPC.swift`**

完整内容：

```swift
#if os(macOS)
import Foundation

/// XPC contract between `RemoteCrabReceiver` (host) and
/// `RemoteCrabCameraExtension` (system camera extension).
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
    public static let machServiceName = "com.remotecrab.RemoteCrabReceiver.Camera"
}
#endif
```

- [ ] **Step 2: 从 `CameraExtensionBridge.swift` 删除协议定义**

删除该文件第 4-36 行的两个 `@objc public protocol` 定义（`IBridgeFrameSink` 和 `IBridgeFrameSource`）以及它们的文档注释（第 4-13 行的总注释保留一句改写）。文件开头保留：

```swift
import Foundation
import RemoteCrabCore

/// The macOS-side bridge between `ReceiverSession` and the system
/// camera extension. The `IBridgeFrameSink` / `IBridgeFrameSource`
/// XPC protocols live in RemoteCrabCore (`IBCameraXPC.swift`) so both
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

- [ ] **Step 4: 验证 RemoteCrabCore 双平台都能编**

Run:
```bash
cd /Users/edwinhao/RemoteCrab/RemoteCrabCore && swift build 2>&1 | tail -3
```
Expected: `Build complete!`（无错误）

- [ ] **Step 5: 跑全套测试**

Run: `cd /Users/edwinhao/RemoteCrab && ./scripts/test.sh 2>&1 | tail -5`
Expected: `All checks passed.`（26 测试 + 两端 build）

- [ ] **Step 6: Commit**

```bash
cd /Users/edwinhao/RemoteCrab
git add RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBCameraXPC.swift RemoteCrabReceiver/CameraExtensionBridge.swift
git commit -m "Move camera XPC protocols to RemoteCrabCore, share with extension"
```

---

### Task 3: Extension 端 XPC listener + `startService` 入口

> **本节已在执行时修订**（2026-09-10）：Task 1 把 extension 三个文件重写为真实
> CMIOExtension SDK API（source 协议模式），原 Task 3 代码引用的旧形状
> （`device.stream`、`device.isAvailable`、`lastEmitted`、provider 直接继承
> `CMIOExtensionProvider`）已不存在。本节代码以 Task 1 之后的文件为准。
> 同时补上 Task 1 review 发现的入口缺失：没有任何地方调用
> `CMIOExtensionProvider.startService(provider:)`，extension 加载了也不服务。

**Files:**
- Create: `RemoteCrabCameraExtension/Sources/RemoteCrabCameraExtension/XPCFrameListener.swift`
- Create: `RemoteCrabCameraExtension/Sources/RemoteCrabCameraExtension/main.swift`
- Modify: `RemoteCrabCameraExtension/Sources/RemoteCrabCameraExtension/CameraExtensionProvider.swift`
- Modify: `RemoteCrabCameraExtension/Sources/RemoteCrabCameraExtension/CameraExtensionStream.swift`（加 `reset()`）
- Modify: `project-mac.yml`（camera ext 去掉 `NSExtensionPrincipalClass`，改由 main.swift 入口）

**Interfaces:**
- Consumes: Task 2 的 `IBridgeFrameSink` / `IBridgeFrameSource` / `IBridgeCameraXPC.machServiceName`；extension 已有的 `CameraExtensionStream.receive(nalUnit: Data, kind: IBNalFrame.Kind)` 和 `deviceSource.streamSource`
- Produces:
  - `final class XPCFrameListener: NSObject, NSXPCListenerDelegate` — `init(stream: CameraExtensionStream)` / `start()`
  - `final class ExtensionFrameSink: NSObject, IBridgeFrameSink`（Task 4 的 host 端会远程调用它）
  - `CameraExtensionStream.reset()` / `StreamDecoder.reset()` — 清空解码缓冲
  - `main.swift` 入口：`CMIOExtensionProvider.startService(provider:)`

**背景（三个要点）：**

1. `CameraExtensionProvider.swift` 里有死代码：Swift 协议 `RemoteCrabFrameSink`
   （小写 i，第 44-47 行）和 `weak var frameSink`（第 21 行）——没有任何代码
   设置或调用它们。本 task 删除，用真正的 XPC 路径替代。
2. **入口缺失**：extension 要真正服务，进程 main 必须调用
   `CMIOExtensionProvider.startService(provider:)`（Apple 官方 camera
   extension 模板就是 main.swift 干这件事）。`NSExtensionPrincipalClass`
   的 beginRequest 路径不适用于 CMIO extension point，从 yml 删掉。
3. **isAvailable 概念放弃**：真实 CMIO API 里 `CMIOExtensionDevice` 没有
   isAvailable 属性。host 断开时自然没有帧流出（客户端看到黑帧/定格），
   这就是 spec 要的"不可用"行为。`authorizedToStartStream` 保持
   allow-all（spec V0.1 决定）。

extension 的 entitlements 已含 `com.apple.security.network.server`，可以注册 Mach service。

- [ ] **Step 1: 给 `CameraExtensionStream` / `StreamDecoder` 加 `reset()`**

`CameraExtensionStream.swift` 中，`CameraExtensionStream` 类内（`receive(nalUnit:kind:)` 之后）加：

```swift
    /// Release buffered frames. Called when the host disconnects or
    /// the stream format changes.
    func reset() {
        decoder.reset()
    }
```

`StreamDecoder` 类内（`dequeuePixelBuffer()` 之后）加：

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
import RemoteCrabCore

/// Extension-side XPC listener. The host (RemoteCrabReceiver) connects
/// to `IBridgeCameraXPC.machServiceName` and pushes H.264 NAL units
/// through the `IBridgeFrameSink` interface.
final class XPCFrameListener: NSObject, NSXPCListenerDelegate {

    private let listener: NSXPCListener
    private let stream: CameraExtensionStream
    private let log = Logger(subsystem: "com.remotecrab", category: "camera-xpc")

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
            self?.log.info("host disconnected")
        }
        connection.interruptionHandler = { [weak self] in
            self?.log.info("host connection interrupted")
        }
        connection.resume()
        log.info("host connected")
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

（与初版相比去掉了 `onHostConnectionChanged` 回调——isAvailable 概念放弃后没有消费者，留着就是死代码。）

- [ ] **Step 3: 修改 `CameraExtensionProvider.swift` — 删死代码 + 启动 listener**

三处改动（保留 Task 1 重写的真实 SDK 结构，不要整体替换文件）：

1. 删除第 17-21 行的 `frameSink` 属性及其注释，删除第 41-47 行的
   `protocol RemoteCrabFrameSink` 死协议及其注释。
2. 在 `private let deviceSource: CameraExtensionDevice` 之后加属性：

```swift
    private let xpcListener: XPCFrameListener
```

3. `init()` 改为（加 listener 初始化和启动）：

```swift
    override init() {
        self.deviceSource = CameraExtensionDevice()
        self.xpcListener = XPCFrameListener(stream: deviceSource.streamSource)
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            logger.error("failed to add device: \(error.localizedDescription)")
        }
        xpcListener.start()
    }
```

- [ ] **Step 4: 创建 `main.swift` + yml 去掉 principal class**

创建 `RemoteCrabCameraExtension/Sources/RemoteCrabCameraExtension/main.swift`，完整内容：

```swift
import CoreMediaIO
import Foundation

// Entry point for the CMIO camera extension. The system launches this
// process when a client (Zoom, FaceTime, Photo Booth, …) enumerates or
// opens the "RemoteCrab Camera" device. `startService` never returns.
let providerSource = CameraExtensionProvider()
CMIOExtensionProvider.startService(provider: providerSource.provider)
```

`project-mac.yml` 的 `RemoteCrabCameraExtension.info.properties.NSExtension`
改为（删除 `NSExtensionPrincipalClass` 一行）：

```yaml
        NSExtension:
          NSExtensionPointIdentifier: com.apple.cmioextension-provider
```

然后重新生成工程：

Run:
```bash
cd /Users/edwinhao/RemoteCrab
xcodegen generate --spec project-mac.yml
```
Expected: 无错误输出（`💾  Generated project` 之类）

注意：xcodegen 会把 `RemoteCrabReceiver/Info.plist` 里手工加的
`CFBundleLocalizations` 块删掉（已知问题，见 Task 1 报告）。重新生成后
检查 `git diff RemoteCrabReceiver/Info.plist`，若该块被删，用
`git checkout -- RemoteCrabReceiver/Info.plist` 恢复（Info.plist 在 yml 里以
`info.path` 引用、不由 xcodegen 管理内容，恢复是安全的）。

- [ ] **Step 5: 构建验证 extension 编译通过**

Run:
```bash
cd /Users/edwinhao/RemoteCrab
xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrabReceiver \
    -configuration Debug -allowProvisioningUpdates build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`（extension 作为 embedded dependency 一并编译）

- [ ] **Step 6: 跑全套测试**

Run: `./scripts/test.sh 2>&1 | tail -5`
Expected: `All checks passed.`

- [ ] **Step 7: Commit**

```bash
cd /Users/edwinhao/RemoteCrab
git add RemoteCrabCameraExtension/Sources/RemoteCrabCameraExtension/ project-mac.yml
git commit -m "Camera extension: XPC listener + startService entry point"
```

---

### Task 4: Host 侧接线 — `ReceiverSession` → `CameraExtensionBridge`

**Files:**
- Modify: `RemoteCrabReceiver/CameraExtensionBridge.swift`（加 `NullFrameSink` + deviceName 支持）
- Modify: `RemoteCrabReceiver/ReceiverSession.swift`

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
cd /Users/edwinhao/RemoteCrab
./scripts/test.sh 2>&1 | tail -5
```
Expected: `All checks passed.`

- [ ] **Step 6: 手动 smoke — host 端 XPC 连接日志**

Run:
```bash
open -a "/Users/edwinhao/Library/Developer/Xcode/DerivedData/RemoteCrabReceiver-dtnzehgyhpjbsdcawmkwuoeyeklw/Build/Products/Debug/RemoteCrabReceiver.app"
sleep 3
log show --last 1m --predicate 'subsystem == "com.remotecrab"' 2>/dev/null | head -20
```
Expected: receiver 正常启动不崩；extension 侧日志要等系统加载 extension 后才出现（Task 5 验证）。此步只确认 host 启动无 crash。若 DerivedData 路径不同，用 `ls -d ~/Library/Developer/Xcode/DerivedData/RemoteCrabReceiver-*/Build/Products/Debug/RemoteCrabReceiver.app` 定位。

- [ ] **Step 7: Commit**

```bash
cd /Users/edwinhao/RemoteCrab
git add RemoteCrabReceiver/CameraExtensionBridge.swift RemoteCrabReceiver/ReceiverSession.swift
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
- iPhone 14 在线且 RemoteCrabCapture 在跑（当前 `devicectl` 显示 unavailable，需要先解锁/连接）
- 或：用 iPhone simulator 跑 RemoteCrabCapture 提供视频源（simulator 无摄像头，此路径只能验证 XPC 连接不能验证画面）

- [ ] **Step 1: 确认 extension 已被系统注册**

启动真签的 RemoteCrabReceiver 后：

Run:
```bash
systemextensionsctl list 2>&1 | grep -i remotecrab
pluginkit -m -i com.apple.cmioextension-provider 2>/dev/null | grep -i remotecrab
```
Expected: 至少一条命令输出包含 `com.remotecrab.RemoteCrabReceiver.Camera`

- [ ] **Step 2: Photo Booth 验证画面**

1. iPhone 14 解锁并启动 RemoteCrabCapture（摄像头模式）
2. Mac 上启动 RemoteCrabReceiver（应自动 Bonjour 连接）
3. 打开 Photo Booth → 菜单 Camera → 选 "RemoteCrab Camera"
4. Expected: 看到 iPhone 摄像头的实时画面

若列表里没有 "RemoteCrab Camera"：
- 检查 extension 签名：`codesign -dv <path>/RemoteCrabReceiver.app/Contents/PlugIns/RemoteCrabCameraExtension.appex`
- 检查日志：`log stream --predicate 'subsystem == "com.remotecrab"'` 看 XPC listener 是否起来
- 杀掉 `com.apple.cmio.registeration` 相关缓存：`sudo killall -9 cmioextensionagent 2>/dev/null; killall "Photo Booth"` 重试

- [ ] **Step 3: 断开行为验证**

退出 RemoteCrabReceiver → Photo Booth 中 "RemoteCrab Camera" 应消失或黑帧，Photo Booth 不崩溃。

- [ ] **Step 4: 更新 `E2E_TESTING.md`**

在文件中追加一节：

```markdown
## Camera Extension（V0.3）

1. 真签构建（team 5XNDF727Y6，xcodegen 后 xcodebuild -allowProvisioningUpdates）
2. 启动 RemoteCrabReceiver —— 系统自动注册 embedded extension
3. iPhone 启动 RemoteCrabCapture 并连接
4. Photo Booth / Zoom → 摄像头选 "RemoteCrab Camera" → 应看到实时画面
5. 退出 RemoteCrabReceiver → "RemoteCrab Camera" 不可用，不崩溃
排查：`log stream --predicate 'subsystem == "com.remotecrab"'`，
`pluginkit -m -i com.apple.cmioextension-provider | grep -i remotecrab`
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
cd /Users/edwinhao/RemoteCrab
git add E2E_TESTING.md AGENTS.md HANDOFF.md
git commit -m "Docs: camera extension wired, Photo Booth verification steps"
```

---

## Self-Review 记录

- **Spec 覆盖**：签名（T1）、embed（T1）、RemoteCrabCore 依赖 bug（T1）、`.metadata` 编译错误（T1）、协议迁移（T2）、extension listener（T3）、死协议删除（T3）、host 接线 + fallback（T2 Step 3 的 invalidation handler + T4）、isAvailable 驱动（T3）、E2E 文档（T5）——全覆盖
- **类型一致性**：`IBridgeFrameSink.feed(nalUnit:kind:)` 在 T2 定义、T3 实现、T4 调用一致；`IBNalFrame.Kind` raw value (1/2/3) 与 spec 一致；`machServiceName` 与 bundle id 一致
- **Placeholder 扫描**：无 TBD/TODO；每个代码 step 都是完整代码

---

## 增补（2026-09-11）：Task 5 运行时验证失败后的架构修正

Task 1-4 完成时我们以为 camera extension 是 app-extension。**运行时验证证明错了**：
CMIO camera extension 是 **system extension**（Apple 官方文档 +
ldenoue/cameraextension 已上架样本 + theoffcuts 三部曲，三方一致）。
根因证据：`.superpowers/sdd/cmio-debug-evidence.md`（executor 必读其中的
§2 参考要求和 §3 对照表）。

**已确认的环境事实：**
- team `5XNDF727Y6`（Beijing VGO Co;Ltd）是**付费 team**：钥匙串里有
  "Developer ID Application: Beijing VGO Co;Ltd (5XNDF727Y6)" 和
  "iPhone Distribution: Beijing VGO Co;Ltd (5XNDF727Y6)"。System Extension
  capability 预期可用（若 provisioning 失败，属于 BLOCKED，上报 controller）。
- `pluginkit` 对 CMIO sysex 不可见是**正常的**——验证工具是
  `systemextensionsctl list`。
- Task 1-4 写的 XPC 协议 / listener / bridge / NAL 管线全部复用，只是打包和
  激活方式变了。
- Apple 文档要点："Only apps that reside in the /Applications directory can
  activate an extension"；host 需要 System Extension + App Groups 两个
  capability；macOS 15+ 用户需在 系统设置 → 通用 → 登录项与扩展 → 相机扩展
  里手动打开开关。

### Task 6: 重打包为 system extension（产品类型 + plist + entitlements）

**Files:**
- Modify: `project-mac.yml`（camera ext target 改 system-extension + embed 目的地；host 加 entitlements/plist 键）
- Modify: `RemoteCrabCameraExtension/Info.plist`（NSExtension 块 → CMIOExtension 块）
- Modify: `RemoteCrabReceiver/RemoteCrabReceiver.entitlements`（加 system-extension.install）
- Modify: `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBCameraXPC.swift`（mach service 名改 team 前缀）
- 可能 Modify: `RemoteCrabCameraExtension/CameraExtension.entitlements`

**Interfaces:**
- Consumes: Task 1-5 全部产出
- Produces: `RemoteCrabCameraExtension.systemextension` 嵌在
  `RemoteCrabReceiver.app/Contents/Library/SystemExtensions/`；真签构建通过；
  XPC mach service 新名字（Task 7 的激活代码依赖）

**背景：** xcodegen 对 system extension 的支持：`type: system-extension`
（productType `com.apple.product-type.system-extension`）。embed 目的地
需要 `Contents/Library/SystemExtensions`（Xcode 里 dstSubfolderSpec=16 的
"Embed System Extensions" phase）。**xcodegen 的 `embed: true` 默认进
PlugIns**——若 xcodegen 不支持 systemExtensions 目的地，在 yml 里给 host 加
一个 `postCompiles`/`copyFiles` 脚本 phase 手动拷贝 + codesign，或者直接接受
xcodegen 生成的 phase 后用 `buildSettings` 修正。executor 先查 xcodegen 文档
（https://github.com/yonsm/XcodeGen 的 dependency embed 选项），选能work的
最小方案并在报告里说明。

- [ ] **Step 1: 改 camera ext target 为 system-extension**

`project-mac.yml` 的 `RemoteCrabCameraExtension` target：
- `type: app-extension` → `type: system-extension`
- `info.properties` 里删掉整个 `NSExtension` dict（system extension 不用它）
- 保留 bundle id `com.remotecrab.RemoteCrabReceiver.Camera`、entitlements、签名设置

audio ext target (`RemoteCrabAudioExtension`) **保持 app-extension 不动**
（AUv3 是 app extension，不受本次修正影响）。

- [ ] **Step 2: 改 extension Info.plist 为 CMIO sysex 形状**

`RemoteCrabCameraExtension/Info.plist`：删除 `NSExtension` 块，加入（对照
ldenoue 样本）：

```xml
<key>CMIOExtension</key>
<dict>
    <key>CMIOExtensionMachServiceName</key>
    <string>5XNDF727Y6.com.remotecrab.RemoteCrabReceiver.Camera</string>
</dict>
<key>NSSystemExtensionUsageDescription</key>
<string>RemoteCrab uses your iPhone as a camera for this Mac.</string>
```

注意 `CMIOExtensionMachServiceName` 是 **team ID 前缀** + 名字（样本：
`388X9C8CWR.com.appblit.samplecamera`）。这个 mach service 是 CMIO 子系统
和 extension 通信用的，**和我们自己的 host→extension XPC 通道是两回事**。

- [ ] **Step 3: 我们自己的 XPC mach service 改 team 前缀**

`RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBCameraXPC.swift` 里：

```swift
public static let machServiceName = "5XNDF727Y6.com.remotecrab.RemoteCrabReceiver.Camera.frames"
```

理由：system extension 的 sandbox 只能注册 team-ID 前缀的 mach service；
host（sandboxed app）也只能 lookup team 前缀的 mach service。加 `.frames`
后缀避免和 CMIOExtensionMachServiceName 撞名。

**连带改动**：host 的 `RemoteCrabReceiver.entitlements` 若 sandbox 阻止
mach-lookup，需要加（先不加，构建后运行时若 lookup 失败再加）：

```xml
<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
<array>
    <string>5XNDF727Y6.com.remotecrab.RemoteCrabReceiver.Camera.frames</string>
</array>
```

- [ ] **Step 4: host 加 System Extension capability + usage description**

`RemoteCrabReceiver/RemoteCrabReceiver.entitlements` 加：

```xml
<key>com.apple.developer.system-extension.install</key>
<true/>
```

`project-mac.yml` host 的 `info.properties` 加：

```yaml
        NSSystemExtensionUsageDescription: RemoteCrab installs a camera extension so other apps can use your iPhone as a webcam.
```

同时给 host 和 extension 都加 App Groups capability（Apple 文档要求）：
entitlements 两边各加：

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>5XNDF727Y6.com.remotecrab</string>
</array>
```

（App Group id = team ID + 自定义后缀，和 mach service 同理。）

- [ ] **Step 5: xcodegen + 真签构建，验证 .systemextension 落位**

Run:
```bash
cd /Users/edwinhao/RemoteCrab
xcodegen generate --spec project-mac.yml
git checkout -- RemoteCrabReceiver/Info.plist 2>/dev/null  # 若 CFBundleLocalizations 被 xcodegen 删掉
xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrabReceiver \
    -configuration Debug -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    build 2>&1 | tail -5
ls ~/Library/Developer/Xcode/DerivedData/RemoteCrabReceiver-*/Build/Products/Debug/RemoteCrabReceiver.app/Contents/Library/SystemExtensions/
```

Expected: `** BUILD SUCCEEDED **` + `RemoteCrabCameraExtension.systemextension`
出现在 SystemExtensions 目录。

**若 provisioning 失败**（System Extension capability 加不上 App ID）：
这是 BLOCKED，把完整错误写进报告，不要绕过。

- [ ] **Step 6: 跑全套测试 + commit**

Run: `./scripts/test.sh 2>&1 | tail -5` → `All checks passed.`

```bash
git add project-mac.yml RemoteCrabCameraExtension/Info.plist \
    RemoteCrabCameraExtension/CameraExtension.entitlements \
    RemoteCrabReceiver/RemoteCrabReceiver.entitlements \
    RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBCameraXPC.swift \
    RemoteCrabCameraExtension/  # 若 xcodegen 重新生成了 extension 的 Info.plist
git commit -m "Repackage camera extension as system extension (CMIO)"
```

### Task 7: host 激活代码 + /Applications 部署 + 注册验证

**Files:**
- Create: `RemoteCrabReceiver/SystemExtensionManager.swift`
- Modify: `RemoteCrabReceiver/RemoteCrabReceiverApp.swift`（启动时请求激活）
- Modify: `E2E_TESTING.md`、`AGENTS.md`、`HANDOFF.md`（状态更新）

**Interfaces:**
- Consumes: Task 6 的 `.systemextension` bundle + entitlement
- Produces: `SystemExtensionManager`（`activate()` / delegate 回调 os_log）；
  `systemextensionsctl list` 出现 `5XNDF727Y6 com.remotecrab.RemoteCrabReceiver.Camera`

**背景：** Apple 文档 + ldenoue 样本都要求：host 在 `/Applications` 里运行，
调用 `OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:queue:)`
+ `OSSystemExtensionManager.shared.submitRequest(_:)`，实现
`OSSystemExtensionRequestDelegate`（`requestNeedsUserApproval` /
`request(_:didFinishWithResult:)` / `request(_:didFailWithError:)`）。
macOS 15/26 上用户还要在 系统设置 → 通用 → 登录项与扩展 → 相机扩展 里
打开开关（这步是用户手动操作，executor 提示用户即可）。

- [ ] **Step 1: 创建 `RemoteCrabReceiver/SystemExtensionManager.swift`**

完整内容：

```swift
import Foundation
import OSLog
import SystemExtensions

/// Submits and tracks the activation request for the embedded CMIO
/// camera extension. The host must run from /Applications for
/// activation to succeed; the user approves in System Settings →
/// General → Login Items & Extensions → Camera Extensions.
final class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate {

    private let log = Logger(subsystem: "com.remotecrab", category: "sysex")
    private static let extensionIdentifier = "com.remotecrab.RemoteCrabReceiver.Camera"

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("submitted activation request for \(Self.extensionIdentifier, privacy: .public)")
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log.info("activation needs user approval in System Settings")
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log.info("replacing extension \(existing.bundleShortVersion, privacy: .public) with \(ext.bundleShortVersion, privacy: .public)")
        return .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        log.info("activation finished: \(String(describing: result), privacy: .public)")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        log.error("activation failed: \(error.localizedDescription, privacy: .public)")
    }
}
```

- [ ] **Step 2: 启动时触发激活**

`RemoteCrabReceiver/RemoteCrabReceiverApp.swift`：在 `init()` 里（AXIsProcessTrusted
调用之后）实例化并激活。注意该文件有**用户未提交的改动**（init 里加了
Accessibility prompt）——保留那些改动，只追加：

```swift
        SystemExtensionManager().activate()
```

注意：manager 是 delegate 持有方，request.delegate 是 weak——把 manager
存成 app 级属性（在 `RemoteCrabReceiverApp` struct 加
`private let sysexManager = SystemExtensionManager()`，init 里
`sysexManager.activate()`），防止提前释放。

- [ ] **Step 3: 构建 + 拷到 /Applications + 启动**

Run:
```bash
cd /Users/edwinhao/RemoteCrab
xcodebuild -project RemoteCrabReceiver.xcodeproj -scheme RemoteCrabReceiver \
    -configuration Debug -allowProvisioningUpdates build 2>&1 | tail -3
pkill -f "RemoteCrabReceiver.app" 2>/dev/null; sleep 1
cp -R ~/Library/Developer/Xcode/DerivedData/RemoteCrabReceiver-*/Build/Products/Debug/RemoteCrabReceiver.app /Applications/
open -a /Applications/RemoteCrabReceiver.app
sleep 5
systemextensionsctl list 2>&1 | grep -i -A2 remotecrab
log show --last 3m --predicate 'subsystem == "com.remotecrab"' 2>/dev/null | grep -i sysex | tail -10
```

Expected:
- `systemextensionsctl list` 出现 `5XNDF727Y6 com.remotecrab.RemoteCrabReceiver.Camera`
  （状态可能是 `[activated waiting for user]` 或 `[activated enabled]`）
- 若报 "needs user approval"：提示用户去 系统设置 → 通用 → 登录项与扩展 →
  相机扩展 打开 RemoteCrab 开关，然后重跑 `systemextensionsctl list`
- 若 `log show --last` 在本机报错（已知问题），用
  `log stream --predicate 'subsystem == "com.remotecrab"' --timeout 10s` 替代

**若 activation 报 "must be in /Applications"**：确认 cp 目标路径、确认
启动的是 /Applications 里的副本（`ps aux | grep RemoteCrabReceiver`）。

- [ ] **Step 4: 验证相机枚举**

Run:
```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i -A6 "video devices"
```

Expected: 列表里出现 `RemoteCrab Camera`。（此时没视频流是正常的——iPhone
不在线；能枚举到就证明 CMIO 注册链路通了。）

- [ ] **Step 5: 更新文档 + commit**

`E2E_TESTING.md` 的 Camera Extension 一节改写为实际流程（/Applications +
激活 + 系统设置开关 + `systemextensionsctl list` 验证 + ffmpeg 枚举）。
`AGENTS.md`：Camera Extension 行 Notes 改为
"system extension (CMIO), wired via XPC; activation via OSSystemExtensionManager, requires /Applications + user toggle"。
`HANDOFF.md` §4.1 保持两个 `[x]`，补一行：
`- [ ] 系统设置里批准 RemoteCrab camera extension（用户手动，一次性）`。

```bash
git add RemoteCrabReceiver/SystemExtensionManager.swift RemoteCrabReceiver/RemoteCrabReceiverApp.swift \
    E2E_TESTING.md AGENTS.md HANDOFF.md
git commit -m "Activate camera sysex on launch; verify registration + docs"
```

⚠️ `RemoteCrabReceiverApp.swift` 有用户的未提交改动——commit 前
`git diff RemoteCrabReceiver/RemoteCrabReceiverApp.swift` 确认只多了 sysex 相关行，
用户的 Accessibility prompt 改动一并提交是**可以的**（它属于同一功能面）。
