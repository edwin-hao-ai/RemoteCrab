# Camera Extension XPC Wiring — 设计文档

日期：2026-09-10
状态：已批准（架构方向）
目标版本：V0.3

## 目标

让 Mac 上的视频会议应用（Zoom / FaceTime / Photo Booth / OBS）能在摄像头列表里看到
"iBridge Camera"，并显示 iPhone 摄像头的实时画面。

成功标准：
1. `iBridgeReceiver.app` 真签构建并启动后，系统自动注册 embedded camera extension
2. Photo Booth 中选择 "iBridge Camera" 出现实时画面（iPhone 已连接时）
3. iPhone 未连接时，"iBridge Camera" 在列表中不可用或显示黑帧，不崩溃
4. `./scripts/test.sh` 26 个测试保持全绿，simulator e2e 不受影响

## 两个已批准的架构决策

### 签名：team 5XNDF727Y6 + Automatic

macOS 系统拒绝加载 ad-hoc 签名的 CMIO extension。`project-mac.yml` 全部三个
target（host / camera ext / audio ext）统一改为：

```yaml
CODE_SIGN_STYLE: Automatic
DEVELOPMENT_TEAM: 5XNDF727Y6
# 去掉 CODE_SIGN_IDENTITY: "-"
```

用户 Apple ID 已在 Xcode 登录，cert 真实归属 5XNDF727Y6（不是 DDG3CJL762）。

### 帧传输：NAL over XPC（extension 自解码）

host（iBridgeReceiver）把网络上收到的 H.264 NAL unit 原样通过 XPC `Data` 消息推给
extension；extension 内已有的 `StreamDecoder`（`CameraExtensionStream.swift`）负责
VideoToolbox 解码 → ring buffer → CMIO 拉取。

否决的替代方案：
- **IOSurface 共享解码帧**：零拷贝、延迟略低，但需要 IOSurface 生命周期管理 +
  host/extension 解码逻辑重构。XPC 传压缩 NAL 只有几 Mbps，性能完全够。V0.4 再优化。
- **Extension 直连 iPhone TCP**：绕开 host，违反"一条 TCP 连接"设计，Bonjour /
  权限 / 状态同步全部变复杂。

## 改动点（5 处）

### 1. `project-mac.yml` — 签名 + embed

- 三个 target 统一 `CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM: 5XNDF727Y6`
- host target 增加：

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

xcodegen 会生成 "Embed App Extensions" build phase，把 `.appex` 打进
`Contents/PlugIns/`。host 启动时系统自动发现并注册 "iBridge Camera"。

**修一个潜在 bug**：`iBridgeCameraExtension` target 的源码
（`CameraExtensionStream.swift`）已经 `import iBridgeCore` 并使用
`IBNalFrame.Kind`，但 `project-mac.yml` 里该 target 没有声明
`dependencies: - package: iBridgeCore`。xcodegen 不会链接 iBridgeCore，
真签构建必然失败。本次一并补上（audio ext 若同样 import 也一并处理）。

### 2. 统一 XPC 协议定义到 iBridgeCore

把 `@objc IBridgeFrameSink` / `IBridgeFrameSource` 从
`iBridgeReceiver/CameraExtensionBridge.swift` 移到
`iBridgeCore/Sources/iBridgeCore/Networking/IBCameraXPC.swift`，host 和 extension
共享同一份定义。

协议保持现有形状（已够用）：

- `IBridgeFrameSink`（extension 实现，host 调用）：
  - `feed(nalUnit: Data, kind: Int)` — kind: 1=video, 2=SPS, 3=PPS
  - `setFormat(width: Int, height: Int, fps: Int)`
  - `stop()`
- `IBridgeFrameSource`（host 实现，extension 调用）：
  - `currentFormat() -> [String: Int]?`
  - `deviceName() -> String?`

注意：iBridgeCore 的 Package.swift 目前声明 iOS 17 + macOS 26 双平台。XPC 协议
文件只 import Foundation（`@objc` 协议 + NSXPCInterface 不在 iOS 上编译），所以
该文件要用 `#if os(macOS)` 包起来，或放到 macOS-only 的 source 条件编译中。
推荐 `#if os(macOS)`，简单直接。

删除 extension 里没人调用的 Swift 协议 `iBridgeFrameSink`
（`CameraExtensionProvider.swift` 中定义，小写 i），以及 provider 上悬空的
`frameSink` 属性。

### 3. Extension 端新增 XPC listener

新文件 `iBridgeCameraExtension/Sources/iBridgeCameraExtension/XPCFrameListener.swift`：

- extension 不是 Mach service 的天然注册点，但它持有
  `com.apple.security.network.server` entitlement（已存在），可以创建
  `NSXPCListener(machServiceName: "com.ibridge.iBridgeReceiver.Camera")`
- `CameraExtensionProvider.init()` 里启动 listener
- listener 接受连接后，把 exported object 设为实现 `IBridgeFrameSink` 的
  `ExtensionFrameSink`：收到的 NAL 转发给 `CameraExtensionStream.receive(nalUnit:kind:)`
- 通过 `remoteObjectProxy` 拿到 host 的 `IBridgeFrameSource`，查询
  `deviceName()` 用于设备标签（fallback "iBridge Camera"）
- 连接建立 → `device.isAvailable = true`；invalidation/interruption →
  `isAvailable = false` + `StreamDecoder` 清空

### 4. Host 侧 `CameraExtensionBridge` 补全

- 保留现有 `Mode.inProcess` / `Mode.xpc` 双模式
- `start(sink:)`：XPC 模式连接 `com.ibridge.iBridgeReceiver.Camera`，
  连接失败 / invalidation → 静默 fallback in-process（现有代码骨架已有此意图，
  补全错误处理）
- `ReceiverSession` dispatch SPS/PPS/video 时调用 `bridge.feed(nalUnit:kind:)`
  （检查 ReceiverSession 当前是否已调用，若未接线则接上）
- `updateFormat(width:height:fps:)` 在收到 SPS/PPS 时从 NAL 解析或从
  `IBStreamMetadata` 读取后调用

### 5. Extension 生命周期 / 可用性

- host 启动 → 系统发现 embedded appex → 注册 "iBridge Camera"（macOS 12.3+
  自动行为，无需 host 显式 activate）
- `CameraExtensionDevice.isAvailable` 由 XPC 连接状态驱动：
  - 无 host 连接 → `false`（Zoom 里显示不可用/黑帧）
  - 有连接 → `true`
- `authorize()` 保持 V0.1 的 allow-all（注释已注明生产应校验）

## 错误处理

| 场景 | 行为 |
|---|---|
| XPC 连接失败（extension 未安装/未签名） | host fallback in-process 预览，不报错给用户 |
| XPC 连接中断（host 退出） | extension `isAvailable = false`，清空 ring buffer |
| SPS/PPS 未到先收 video NAL | 丢弃（`StreamDecoder` 现有行为） |
| extension 解码错误 | 丢帧，`VTDecompressionSession` 必要时重建 |
| iPhone 断开 | host 调 `sink.stop()`，extension 清空缓冲 |

## 测试

- `./scripts/test.sh` 26 个测试保持全绿（XPC 代码不进单元测试，它是系统集成）
- 新增单元测试（如可行）：`IBCameraXPC` 协议编译性由双端 import 验证；
  `StreamDecoder` 的 SPS/PPS → format description 逻辑可加纯逻辑测试（如现有测试模式允许）
- 手动验证步骤（写入 E2E_TESTING.md 更新）：
  1. 真签构建 + 启动 iBridgeReceiver
  2. iPhone 启动 iBridgeCapture 并连接
  3. Photo Booth → 摄像头列表选 "iBridge Camera"
  4. 看到实时画面
  5. 退出 iBridgeReceiver → "iBridge Camera" 消失或不可用

## 明确不做（YAGNI）

- IOSurface 零拷贝传输（V0.4 优化项）
- 多摄像头/多流（一个 device 一个 stream 足够）
- Extension 直连 iPhone
- 虚拟麦克风 AUv3 的 wiring（本次只保证 audio ext target 签名一致，
  不完成它的 XPC bridge —— 那是另一个 V0.3 待办）
- Notarization（发布项，V1.0 前再做）

## 风险

| 风险 | 缓解 |
|---|---|
| CMIO extension 签名要求比预期严格（如需 Developer ID） | 先 development cert 验证；Zoom/Photo Booth 对 development-signed CMIO ext 在本机可用 |
| `NSXPCListener(machServiceName:)` 在 sandboxed appex 里被拒 | entitlements 已有 `network.server`；若仍失败，改为 host 侧 listener + extension 主动连接（反向 XPC，架构对称） |
| xcodegen `embed: true` 对 app-extension 生成错误的 build phase | 检查生成结果，必要时改用手动 `copyFiles` phase 配置 |
