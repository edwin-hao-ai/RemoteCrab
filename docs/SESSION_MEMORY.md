# iBridge Session Memory — 2026-09-08 ~ 2026-09-10

> 这个文件记录这次 session 的所有重要内容、决策、踩坑、教训。
> 配合 `HANDOFF.md`（AI agent 状态交接）和 `AGENTS.md`（项目 context）一起看。

## 0. Timeline

```
Day 1 (9/8)  — 从空仓库开始，建项目结构，跑 26 测试，做设计系统
Day 2 (9/9)  — 反复调 App icon 5 版，做 9 个 HTML prototypes，
              写中英双语 localization，Camera Extension + AudioUnit 骨架
Day 3 (9/10) — Apple ID 登录失败，Accessibility 权限阻塞 e2e，
              user 给了 Apple Dev cert 装到 iPhone 14
              仍卡在 Accessibility 手动加
```

## 1. PRD：实际范围

### 1.1 V0.1 → V0.2 → V1.0 路径

| 版本 | 范围 | 状态 |
|---|---|---|
| V0.1 | iOS sim e2e（wire 协议 + Bonjour + iOS Capture） | ✅ |
| V0.2 | + Mac 接收端 + 设计系统 + UI 完整 + 中英双语 + 真机装到 iPhone 14 | ✅ 大部分 |
| V0.3 | Camera Extension 完整 + 虚拟麦克风 + 真机 e2e | ❌ 待做 |
| V1.0 | App Store 发布 + 完整 Settings + 本地化 + VoiceOver | ❌ 待做 |

### 1.2 V0.2 已交付的实际 scope

**保留**：
- iOS Capture (摄像头 + 麦克风)
- Mac Receiver (Bonjour + 解码 + 播放)
- 触控板 / 键盘事件注入
- 完整设计系统（Liquid Glass + fallback）
- iOS 17 兼容（iPhone 14 OK）
- 中英双语 .xcstrings
- Simulator e2e 自动化脚本
- 26 个单元 + e2e 测试全过

**砍掉**：
- ASR / 语音输入 → 暂不做
- Windows 支持 → 暂不做
- Android 支持 → 暂不做
- App Store 发布（cert 不支持 ad-hoc）

## 2. 关键架构决策

### 2.1 部署目标
- **iOS 17.0**（不是 26！iPhone 14 / iOS 18 兼容）
- **macOS 26.0**（Liquid Glass / Camera Extension / AudioUnit v3）
- **Swift 6.2**（strict concurrency）
- Xcode 26+

### 2.2 iOS 17 兼容怎么做

```swift
// IBColors - 用 Color.dynamic(light:dark:) 简单
// IBMaterials - 关键代码
@available(iOS 26.0, macOS 26.0, *)
private struct GlassSurface<S: Shape>: View { ... }

@ViewBuilder
public static func glass<S: Shape>(...) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
        GlassSurface(shape: shape, tint: tint, interactive: interactive)
    } else {
        LegacyGlassSurface(shape: shape, tint: tint, interactive: interactive)
    }
}
```

Xcode 26 SDK 在 iOS 17 SDK 上会强制要真 signing（拒绝 ad-hoc）：
```
error: Ad Hoc code signing is not allowed with SDK 'iOS 26.5'.
```
iOS 17 deployment target + `CODE_SIGN_IDENTITY="-"` 不能用。**绕路**：
- Mac 端用 ad-hoc（手动 signing）
- iOS 端必须 team signing（用户已有 `5XNDF727Y6`）

### 2.3 Apple Development cert 实际归属
- 证书里 `Subject` 字段：`CN = Apple Development: Edwin Hao (42W33RCYXZ), OU = 5XNDF727Y6, O = Beijing VGO Co;Ltd`
- cert 名字里说 `DDG3CJL762`（错误）但 Subject 实际是 `5XNDF727Y6`
- **正确 team**：`5XNDF727Y6`（不是 `DDG3CJL762`）
- build 命令：`DEVELOPMENT_TEAM=5XNDF727Y6`

### 2.4 通信架构
- 单 TCP 连接 / Bonjour service `_ibridge._tcp` on `local.`
- 帧协议：4 byte BE 长度 + 1 byte kind + payload
- kind 列表：`0x00=metadata, 0x01=video, 0x02=sps, 0x03=pps, 0x04=touch, 0x05=key, 0x06=audio`
- 视频：H.264 VideoToolbox 硬编（iOS 端）+ 硬解（Mac 端）
- 触控/键盘：JSON over TCP
- 麦克风：16-bit Int16 PCM 20ms packets
- Bonjour service name：`iBridge — <UIDevice.current.name>`

### 2.5 设计语言
- Apple Native + Liquid Glass（iOS 26+） + `.regularMaterial` fallback
- 颜色：Apple 语义色 + iBridge brand 色（深蓝 → 紫 → 玫瑰渐变）
- 字体：SF Pro Display + SF Pro Text + **SF Mono**（技术数据用）
- 26 个 SwiftUI 组件：IBGlassCard, IBStatusPill, IBModifierBar, IBPrimaryButton, IBMicMeter, IBKeyboardKey, IBToggleRow
- 9 个 HTML prototypes（9 个 design 变体做选型）
- 19 张 SwiftUI ImageRenderer 截图

## 3. 关键设计决策记录

### 3.1 App icon — 经过 5 版迭代

| 版本 | 描述 | 评价 |
|---|---|---|
| v1 | 文字 "iB" + WiFi 波纹 | 文字太小看不清 |
| v2 | "iB R I D G E" 散开文字 | 散、差 |
| v3 | 完整 iPhone 剪影 + WiFi 波纹 | 文字不该在小尺寸出现 |
| v4 | iPhone 透出背景渐变 + 暖粉光晕 | 整体偏白 |
| **v5** | **ivory iPhone + 暖粉 glow + 渐变背景** | **最终版**，干净专业 |

最终：单 iPhone 形象，干净，无文字，深色 Apple 风格渐变。

### 3.2 onboarding / permission 流程

**关键洞察**：权限弹窗和 onboarding 必须在用户控制下：
- iOS 17+ 系统弹 Local Network 时会盖住部分 UI
- v0.2 早期 auto-start 模式会自动开 streaming → 弹窗遮挡 → 用户没意识到是哪个 app 弹的
- **修复**：iBRIDGE_AUTO_START=1 只跳过 onboarding，**不让 app 自动开 streaming** → 让用户自己按 START → 弹窗在用户控制下出现

### 3.3 Accessibility 注册（macOS 14+ 坑）

**问题**：`AXIsProcessTrustedWithOptions(prompt: true)` 只弹**一次**。Dismiss 后状态缓存 "rejected"，重启 app 不再弹。

**已尝试失败**：
1. `AXIsProcessTrustedWithOptions` 不弹窗
2. `tccutil reset Accessibility com.ibridge.iBridgeReceiver` 清了 TCC.db 但 `accessibilityd` 守护进程缓存没刷新
3. 重启 receiver 不弹
4. **必须**：手动加到 System Settings 或重启 Mac

**结论**：ad-hoc 签名 + 已 dismiss = 不可能再弹窗。**唯一可靠办法是用户手动加**。

### 3.4 Bonjour 跨 USB-tether 边界

**坑**：iPhone 14 USB 接 Mac 时在 192.168.x.x USB-tether 子网，跟 Mac 的 192.168.31.x WiFi **不在同一个 multicast 域** → Bonjour discovery 失败。

**修法**：iPhone 必须**拔 USB**（或保持 USB 但同时也连同一个 WiFi 网络）→ 自动走 WiFi Bonjour → Mac 能找到。

**验证命令**：
```bash
rtk timeout 3 dns-sd -B _ibridge._tcp 2>&1 | grep "Instance Name"
# 应该看到 "iBridge — iPhone" 出现
```

### 3.5 ImageRenderer 不渲染 Liquid Glass

**坑**：`ImageRenderer` 在 headless 模式下渲染 SwiftUI `.glassEffect()` 是无效的 → 截图里 liquid glass 表面不显示。

**修法**：用 `.regularMaterial` 在 ImageRenderer 渲染时 fallback（或者写个 fallback path），production app 走真 glassEffect，截图脚本走 fallback。

## 4. 踩坑清单（pitfalls）

### 4.1 Swift 6 strict concurrency

- `NSXPCConnection` 不 Sendable → 跨 actor 传报错
- `H264TestEncoder` callback 闭包跨 actor → 用 `nonisolated(unsafe)` 包装
- `Sendable` 协议问题 → 加 `nonisolated(unsafe)` 注解
- `IBWire.Parser` → 加 `@unchecked Sendable`

### 4.2 iOS 26 SDK 跟 iOS 17 deployment 冲突

- iOS 26 SDK 要求 iOS 18+ 真 signing
- 不能用 ad-hoc + iOS 17 target 装到 device
- **解法**：iPhone 14 真机用 team signing，simulator 用 ad-hoc 都行

### 4.3 Bonjour 实例名冲突

- simulator 和 iPhone 14 都用同一个 BundleID advertise
- simulator 叫 "iBridge — iPhone 17 Pro"
- iPhone 14 叫 "iBridge — iPhone"（UIDevice.current.name 是 "iPhone"）
- **iPhone 14 的实例名不直观**，但 Mac receiver 仍能连（用 NSDictionary 里的所有数据）

### 4.4 VideoToolbox API 变化（macOS 26 / iOS 26 SDK）

- `AUAudioUnit` v3 init: `init(componentDescription:options:)` 新签名
- `outputBusses: AUAudioUnitBusArray` 不是 `[AUAudioUnitBus]`
- `format` 属性只读
- `renderBlock` 属性只读
- `AXIsProcessTrustedWithOptions` 参数类型签名变 (CFBoolean 而不是 Bool)

### 4.5 ImageRenderer for SwiftUI 设计系统

- `.regularMaterial` ✓ 渲染
- `.glassEffect()` ✗ 渲染（macOS 26 SDK 在 headless 模式下无输出）
- 复杂 ViewBuilder 嵌套 → 编译慢、容易报错

### 4.6 Xcode build settings 误区

- `INFOPLIST_FILE_GENERATE_INFOPLIST_FILE` 是 iOS 17 deployment target 必须设对
- `DEVELOPMENT_TEAM` 不能在 `INFOPLIST_FILE` 之前不设
- `CODE_SIGN_STYLE=Manual` + `CODE_SIGN_IDENTITY="-"` = ad-hoc（仅 sim OK）
- `CODE_SIGNING_REQUIRED=YES` 不阻止 sim build 但阻止 iOS 26 真机 build

### 4.7 simctl 已知坑

- `simctl launch --setenv` 在某些 Xcode 版本不工作 → 用 `SIMCTL_CHILD_*` 前缀
- `xcrun simctl io <UDID> screenshot <path>` 必须 iOS 26 SDK
- `xcrun devicectl device process launch <bundle>` 不支持 `--` 之后传 env vars
- `xcrun devicectl device info -d <UDID>` 子命令要正确（info details, info apps...）
- Simulator 不显示 "USB-tether" 设备的 IP（跟 iPhone 真机不同）

### 4.8 缺失用户反馈的踩坑

- Allow 按钮遮挡（iOS 系统弹窗和 app UI 冲突）— 删 auto-start，改为手动触发
- iPhone 14 装不上 ad-hoc 签名（iOS 26 SDK 拒绝） — 需要 team signing
- iPhone 14 模拟器没有 camera — simctl e2e 不能跑真视频流（用 Bonjour 验证代替）

## 5. 关键文件路径（速查）

| 路径 | 作用 |
|---|---|
| `iBridgeCapture/ContentView.swift` | iOS 主 UI 入口 |
| `iBridgeCapture/CaptureEngine.swift` | Bonjour publish + H264 encode |
| `iBridgeReceiver/ReceiverSession.swift` | Bonjour browse + dispatch |
| `iBridgeReceiver/MenuBarMenu.swift` | 菜单栏 popover 主内容 |
| `iBridgeReceiver/FirstLaunchView.swift` | 首次启动引导 + 权限检查 |
| `iBridgeCore/Networking/IBWire.swift` | length-prefixed 帧协议 |
| `iBridgeReceiver/iBridgeAudioUnit.swift` | AUAudioUnit v3 虚拟麦克风 |
| `iBridgeReceiver/CameraExtensionBridge.swift` | XPC bridge to Camera Ext |
| `iBridgeCore/DesignSystem/IBMaterials.swift` | Liquid Glass 封装（iOS 26 + 17 fallback）|
| `screenshots/` | 19 张 UI 截图 |
| `scripts/test.sh` | 跑 26 测试 + 两端 build |
| `scripts/install-to-iphone.sh` | 真机安装 |
| `scripts/check-e2e-readiness.sh` | e2e 准备度检查 |
| `scripts/e2e-simulator.sh` | simulator 自动 e2e |
| `iBridgeCapture/Localizable.xcstrings` | iOS 中英双语 |
| `iBridgeReceiver/Localizable.xcstrings` | Mac 中英双语 |
| `AGENTS.md` | AI agent 用的项目 context |
| `HANDOFF.md` | 状态交接（含本 session 阻塞点）|
| `E2E_TESTING.md` | 真机 e2e 步骤 |
| `docs/SESSION_MEMORY.md` | **本文件**（session 记忆）|
| `docs/PRD.md` | **见下**（产品需求文档）|
| `docs/PITFALLS.md` | **见下**（踩坑手册）|

## 6. 测试覆盖

### 6.1 26 个测试覆盖
- `IBWireTests` (11) — frame 协议 encode/decode/partial/rejection
- `IBEventsTests` (8) — TouchEvent/KeyEvent/AudioPacket round-trip + 混合
- `BonjourEndToEndTests` (2) — 真正 Bonjour 找服务 + TCP 收发
- `EventPipelineEndToEndTests` (5) — send → TCP → parser → 注入器 全链路

### 6.2 完整测试
```bash
cd /Users/edwinhao/iBridge && ./scripts/test.sh
# 期望输出：26 tests pass + 2 builds succeed
```

## 7. 用户硬件 / 设备

- **Mac**: MacBook Pro，macOS 26，Xcode 26.6
- **iPhone**: iPhone 14，iOS 18.6.2，UDID `866A1921-B588-59D5-A1B7-B266103B2E49`
- **Apple ID**: `edwinhao@sendpalm.com`
- **Dev team**: `5XNDF727Y6`（真实归属，cert 名写错）
- **Network**: 192.168.31.0/24，Mac 在 192.168.31.105

## 8. 这次 session 学到的最大教训

1. **Bonjou**r 不会跨网段（USB-tethering vs WiFi）
2. **macOS 14+ 缓存 Accessibility 拒绝状态** — 一旦 dismiss，tccutil 都不能让它再弹
3. **iOS 17 deployment + iOS 26 SDK** 在 Xcode 26 不能 ad-hoc 装到真机
4. **cert Subject 字段**是真相，cert 显示名（"DDG3CJL762"）是误导
5. **ImageRenderer 不渲染 Liquid Glass** — SwiftUI 截图脚本必须 fallback

## 9. 给未来 session 的建议

1. **真机 e2e 阻塞点**就是 Mac 端 Accessibility 授权。这一个 manual step 解锁整个 e2e
2. **Apple ID 登录 Xcode 是有有效期的**（token 过期）— 每次大改动前重新登录
3. **iPhone 14 是当前唯一真机** — sim 不能替代真机的摄像头 / 麦克风 / 触屏
4. **iPhone 14 是 iOS 18.6.2**，不是 iOS 26 → 编译时 iOS 17 SDK 真机装没问题，但 simulator iOS 17 + iPhone 17 Pro 26.5 sim OK
5. **iPhone 真机 e2e 比 simulator 准** — simulator 摄像头是 fake 的

## 10. 用户的 PRD（产品需求）

**核心愿景**：把 iPhone 变成 Mac 的外设 — 摄像头、麦克风、触控板、键盘。

**核心差异化**（v0.2 调研）:
- 蓝牙类似 app（EpocCam / Camo / Iriun）需要订阅 + 云端
- iBridge 走本地 WiFi、零订阅、零云端 — 唯一不同
- Vision: 让 iPhone 14 这种"过时"手机在 Mac 旁"焕发第二春"

**用户痛点**:
1. Mac mini / Mac Pro 出厂没摄像头 — 主要需求
2. Bluetooth app 走订阅 + 隐私顾虑
3. 多设备（同一 iPhone 给多个 Mac 用）

**用户设备**:
- 已有 iPhone 14（iOS 18.6.2）— "过时"机型代表
- Mac 已有

**完成度**:
- V0.1 (simulator e2e) — ✅ 100%
- V0.2 (真机 e2e + UI 完整) — ✅ ~95%（唯一阻塞：Mac 端 Accessibility）
- V0.3 (Camera Extension + 虚拟麦克风完整) — ❌ ~30%（仅骨架）
- V1.0 (App Store 发布) — ❌ 0%

## 11. 下次应该做什么

按优先级：
1. **真机 e2e**（用户手动加 Accessibility 解决后）
2. V0.3 工作：Camera Extension 完整 wiring + 虚拟麦克风装到 Mac
3. V0.3：Settings UI 完整（已有简化版）
4. V0.3：错误状态 UI（无权限 / Bonjour 失败 / 网络断）
5. V0.3：崩溃报告（OSLog + Sentry）
6. V1.0：Apple Developer Program $99/年 + App Store 发布

## 12. 一些踩坑的修复历史

| 问题 | 修复 |
|---|---|
| Allow 按钮被 iOS 弹窗遮挡 | 删 auto-start，改为用户主动按 START |
| iOS 26 SDK 拒 ad-hoc | 真机用 team signing，sim 还能 ad-hoc |
| iPhone 14 iOS 18.6 装不上 | 部署目标 iOS 17，cert 团队 5XNDF727Y6 |
| Bonjour 找不到 iPhone | iPhone 必须拔 USB 走 WiFi，不能 USB-tether |
| Accessibility 注册不到 iBridgeReceiver | 唯一办法：手动加到 System Settings |
| ImageRenderer 渲染无输出 | Liquid Glass 走 .regularMaterial fallback |
| AXIsProcessTrusted 不弹窗 | ad-hoc 签名 + dismissed 后不再弹 |
| iPhone 14 UDID 难找 | `xcrun devicectl list devices` (新 API) |
| tccutil reset 不刷新 | macOS 14+ accessibilityd 守护进程缓存独立 |
| NSXPCConnection 不 Sendable | 用 `nonisolated(unsafe) UncheckedBox` 包装 |
