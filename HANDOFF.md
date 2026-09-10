# iBridge 项目 — 完整上下文 (Handoff to next AI agent)

## 0. 项目是什么

iBridge — 把 iPhone/iPad 变成 Mac 的外设：摄像头、麦克风、触控板、键盘，通过本地 WiFi 走 Bonjour + TCP。

## 1. 已完成（V0.2）

### 1.1 iOS app (`iBridgeCapture/`)
- `RootView.swift` + `OnboardingFlow.swift`（3 页 paged onboarding）+ `PermissionFlow.swift`（权限请求）
- `ContentView.swift`（Camera / Trackpad / Keyboard 三个模式切换器）
- `CaptureEngine.swift` — AVCaptureSession + VideoToolbox H.264 硬编 + NWListener Bonjour 发布
- `H264Encoder.swift` — VideoToolbox 硬编码
- `MicrophoneEncoder.swift` — AVAudioEngine → 20ms PCM packets
- `TouchpadScreen.swift` — UIView 触控捕获，UIPanGestureRecognizer + UITapGestureRecognizer
- `KeyboardScreen.swift` — QWERTY 全键盘
- `IOSSettingsView.swift` — Form 风格设置面板
- `CameraPreview.swift` — AVCaptureVideoPreviewLayer
- `Info.plist` — 权限描述、本地化（含 zh-Hans）、Bonjour 服务声明
- `Assets.xcassets/AppIcon.appiconset/` — 14 个 iOS 尺寸图标
- `Localizable.xcstrings` — 中英双语（60+ 字符串）

### 1.2 Mac app (`iBridgeReceiver/`)
- `iBridgeReceiverApp.swift` — 多个 Scene（first-launch / 菜单栏 / preview / control panel）
- `ReceiverSession.swift` — NWBrowser Bonjour 浏览 + dispatch
- `H264Decoder.swift` — VideoToolbox 硬解
- `AudioPlayer.swift` — AVAudioEngine 播放
- `AudioReceiver.swift` — 路由 iPhone 麦克风到 speakers / virtual mic
- `iBridgeAudioUnit.swift` — AUAudioUnit v3 虚拟麦克风
- `iBridgeAUInstanceProvider.swift` — host/extension 共享 AU
- `Input/` — `InputInjector.swift` 协议 + `CGEventInjector.swift` + `Input/InputInjector.swift`（共享）
- `MenuBarMenu.swift` — 菜单栏 popover
- `MenuBarIcon.swift` — Canvas 自定义菜单栏图标
- `FirstLaunchView.swift` — 首次启动引导 + Accessibility 权限检查
- `ControlPanelView.swift` — 浮动控制面板
- `PreviewWindow.swift` — 实时预览窗口
- `CameraExtensionBridge.swift` — XPC bridge 到 Camera Extension
- `PreferencesView.swift` — macOS Settings 风格偏好设置
- `Info.plist` — LSUIElement=YES（菜单栏 app），权限描述，本地化
- `Localizable.xcstrings` — 中英双语
- `iBridgeReceiver.entitlements` — sandbox + network + camera + microphone

### 1.3 iBridgeCore (`iBridgeCore/`)
- `Package.swift` — iOS 17 / macOS 26, Swift 6.2
- `Sources/iBridgeCore/`
  - `DesignSystem/`
    - `IBColors.swift` — 颜色 token
    - `IBTypography.swift` — SF Pro Display/Text/Mono
    - `IBSpacing.swift` — 间距 + 圆角
    - `IBAnimations.swift` — spring 配置
    - `IBMaterials.swift` — Liquid Glass 封装，iOS 17/18 fallback
  - `Components/`
    - `IBGlassCard.swift` — Liquid Glass 容器
    - `IBStatusPill.swift` — 连接状态 pill
    - `IBModifierBar.swift` — ⌃⌥⌘⇧ 修饰键
    - `IBPrimaryButton.swift` — 录制按钮
    - `IBToggleRow.swift` — 设置 toggle
    - `IBMicMeter.swift` — 麦克风电平
    - `IBKeyboardKey.swift` — 键盘按键
    - `IBDesignSystemShowcase.swift` — 全组件 showcase
  - `Input/InputInjector.swift` — 协议 + RecordingInputInjector（跨平台）
  - `Networking/`
    - `IBProtocol.swift` — 事件类型（TouchEvent / KeyEvent / AudioPacket）
    - `IBWire.swift` — length-prefixed binary 帧编码
    - `IBEventBroadcaster.swift` — iOS 端 sender
  - `Audio/iBridgeAUInstanceProvider.swift` — host/extension 共享 AU
- `Tests/` — 26 个 e2e 测试全过

### 1.4 Camera Extension (`iBridgeCameraExtension/`)
- 完整 skeleton（`CameraExtensionProvider.swift` / `Device.swift` / `Stream.swift`）
- 需 code signing + 系统扩展安装才能用

### 1.5 项目基础设施
- `project-ios.yml` — xcodegen 配置，DEVELOPMENT_TEAM=DDG3CJL762（你的 Apple Development team）
- `project-mac.yml` — macOS app + 两个扩展 target，ad-hoc signing
- `scripts/`
  - `test.sh` — CI 跑全套（26 测试 + 两端 build）
  - `e2e-simulator.sh` — simulator 自动 e2e
  - `install-to-iphone.sh` — 真机安装脚本
  - `check-e2e-readiness.sh` — 检查 e2e 准备度
  - `release-ios.sh` — App Store 发布
  - `render_ui_screenshots.swift` — 生成设计截图
  - `generate-ios-app-icons.sh`（Python + PIL）
  - `ios-metadata.json` + `ios-app-store-metadata.py` — App Store Connect
- `screenshots/` — 19 张 UI 截图
- `E2E_TESTING.md` — 真机 e2e 步骤
- `AGENTS.md` — 给 AI agent 的项目 context
- `HANDOFF.md` — 本文件
- `PRIVACY.md` — 隐私政策
- `iOS 17 部署目标` — iPhone 14 (iOS 18.6.2) 可装

## 2. 已做但你本地 Apple ID 装不了 iPhone 14 的部分

### 2.1 登录问题
- Apple ID `edwinhao@sendpalm.com` 登录 Xcode 后已能装到 iPhone 14（已成功 `xcodebuild` 装到 `866A1921-B588-59D5-A1B7-B266103B2E49`）
- DEVELOPMENT_TEAM 正确值是 `5XNDF727Y6`（**不是** `DDG3CJL762`），cert 实际属于这个 team

### 2.2 装到 iPhone 14 的命令
```bash
cd /Users/edwinhao/iBridge
xcodebuild -project iBridgeCapture.xcodeproj -scheme iBridgeCapture \
    -destination "id=866A1921-B588-59D5-A1B7-B266103B2E49" \
    -configuration Debug build \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM=5XNDF727Y6 \
    -allowProvisioningUpdates
```
然后用 devicectl 安装（详见 `scripts/install-to-iphone.sh`）

## 3. 未完成 — **当前阻塞在 Accessibility 权限**

### 3.1 问题
- iPhone 14 安装并启动了 iBridge app（Bonjour 服务已发布在 `local._ibridge._tcp`）
- Mac 端 `iBridgeReceiver` 跑起来了（PID 5585），菜单栏 popover 显示 "iBridge" + 3 步说明
- 但 **Accessibility 权限没授权** → iBridgeReceiver 在 `System Settings → Privacy & Security → Accessibility` 列表里**找不到**

### 3.2 已尝试的方法（都失败）
1. `AXIsProcessTrustedWithOptions(prompt: true)` — 不弹窗（被 system 缓存 "rejected" 状态）
2. `tccutil reset Accessibility com.ibridge.iBridgeReceiver` — 成功输出 "Successfully reset"，但重启 app 仍不弹窗
3. 多次重启 receiver —— 不弹窗

### 3.3 为什么
- macOS 14+：app dismiss 过一次 Accessibility 弹窗后，状态被缓存
- `tccutil reset` 清了 TCC.db 里的条目，但 `accessibilityd` 守护进程缓存里仍是 "rejected"
- ad-hoc 签名的 app 在系统里的优先级更低

### 3.4 唯一可靠的方法（**用户手动操作**）
系统设置 → 辅助功能 → 点 **+** → 文件选择器 → **⌘⇧G** 输入路径 → 选 `iBridgeReceiver.app` → Open → 打开它 → 输密码授权

路径：
```
/Users/edwinhao/Library/Developer/Xcode/DerivedData/iBridgeReceiver-dtnzehgyhpjbsdcawmkwuoeyeklw/Build/Products/Debug/iBridgeReceiver.app
```

### 3.5 另一个方法
重启 Mac（Reddit 用户验证有效）— `sudo shutdown -r now` 然后再启动 app

## 4. 还没做的（V0.3 - V1.0）

### 4.1 待做功能
- [ ] Camera Extension 真正装到 Mac（需 code signing）
- [ ] Camera Extension 完整 XPC bridge
- [ ] 虚拟麦克风（AUv3 extension）— 装到 iBridgeReceiver
- [ ] Simulator e2e 增强（自动 Bonjour 验证）
- [ ] 完整真机 e2e 流程

### 4.2 待做发布项
- [ ] 真机测试（用户自己跑）
- [ ] App Store 截图（需真机 capture）
- [ ] 真实 Apple Developer Program ($99/年) — 当前是个人 free team 5XNDF727Y6，能装不能发布
- [ ] Notarization — Mac app 发布到 App Store 需要
- [ ] 完整本地化（现在 .xcstrings 已搭好，但代码里 `IBLocale` 还没完全迁移过去用 `Text("…", bundle:)`）
- [ ] 错误状态 UI（无权限 / Bonjour 失败 / 网络断）
- [ ] 崩溃报告（OSLog + Sentry）
- [ ] Settings UI — iOS 端有 `IOSSettingsView`，但 Mac 端 `PreferencesView` 是简化版
- [ ] App Store 审核前的截图
- [ ] 视频 / 音频的模拟器 e2e 增强（现在 simulator e2e 只跑 Bonjour discovery）

## 5. 关键架构决策

### 5.1 部署目标
- iOS: **17.0**（兼容 iPhone 14, iOS 18.6.2）
- macOS: **26.0**（需要 Liquid Glass + Camera Extension + AudioUnit v3）

### 5.2 设计系统
- Apple Native + Liquid Glass（iOS 26+） + `.regularMaterial` fallback（iOS 17/18）
- 颜色：Apple 语义色 + 自定义 brand 色
- 字体：SF Pro Display/Text + SF Mono（technical readouts）

### 5.3 Wire 协议
- 单一 TCP 连接，长度前缀 binary 帧
- 4 byte BE 长度 + 1 byte kind + payload
- kind：metadata(0x00), video(0x01), sps(0x02), pps(0x03), touch(0x04), key(0x05), audio(0x06)
- Bonjour service: `_ibridge._tcp` on `local.`

### 5.4 iPhone 端
- `IBEventBroadcaster` → `IBWire.encode()` → TCP → `IBWire.Parser` on Mac → dispatch
- 视频：`AVCaptureSession` → `VideoToolbox` H.264 硬编
- 触控：`UIView` gesture recognizers → `TouchEvent` JSON
- 键盘：`UITextField` → `KeyEvent` JSON
- 麦克风：`AVAudioEngine` → 20ms PCM Int16 packets

### 5.5 Mac 端
- `ReceiverSession` — `NWBrowser` 找 iPhone，`IBWire.Parser` 解析
- `H264Decoder` — VideoToolbox 解码
- `AudioReceiver` — PCM 播放
- `Input/InputInjector` 协议 + `CGEventInjector` 实现 + `RecordingInputInjector` 测试用
- `MenuBarExtra(.window)` + 自定义 `MenuBarIcon` Canvas

## 6. 关键设计文档

- `AGENTS.md` — 详细的项目 context（**下一个 AI agent 必读**）
- `E2E_TESTING.md` — 真机 e2e 完整步骤
- `RUN.md` — 真机/模拟器运行步骤
- `README.md` — 项目概览 + 架构图
- `PRIVACY.md` — 隐私政策

## 7. 用户的真机状态

### 7.1 设备
- Mac（你现在的）：macOS 26
- iPhone 14：iOS 18.6.2，UDID `866A1921-B588-59D5-A1B7-B266103B2E49`
- iPhone 已连到 Mac 同一个 WiFi（`192.168.31.0/24` 网段）

### 7.2 当前 Bonjour 状态
- iPhone 14 正在 advertise `_ibridge._tcp` 服务
- 名字："iBridge — iPhone"（UIDevice.current.name 返回 "iPhone"）
- iPhone 17 Pro simulator 也在 advertise（独立 iBridge — iPhone 17 Pro）

### 7.3 Mac 端进程
- iBridgeReceiver 跑在 PID 5585
- 菜单栏 popover 显示（需要 Accessibility 才能正常显示设备列表）
- iPhoneReceiver UI 在屏幕上

## 8. 你想做的下一步

**最优先**：完成 e2e 真机测试。流程：
1. 在 Mac 系统设置 → 辅助功能 → + → 加 iBridgeReceiver → 打开 → 输密码
2. iBridgeReceiver popover 会显示 "Accessibility granted" 状态
3. iPhone 14 已经 Bonjour 发布中
4. 等待几秒，Mac 端会检测到 iPhone 14 并自动连接
5. Mac 端显示实时画面

**最简单一条命令解决**：
```bash
open -a "/Users/edwinhao/Library/Developer/Xcode/DerivedData/iBridgeReceiver-dtnzehgyhpjbsdcawmkwuoeyeklw/Build/Products/Debug/iBridgeReceiver.app"
```
- 菜单栏 popover 应出现
- 等 2-3 秒
- 列表里应出现 "iPhone"（iPhone 14）

## 9. 关于 kimi code / 其他 AI agent

任何 AI agent 接续工作时：

1. **必读**：`AGENTS.md`（详细设计、协议、流程）
2. **必看**：`E2E_TESTING.md`（真机测试步骤）
3. **看 git log**：56 个 commits 全部为 V0.2 准备工作
4. **跑测试**：`./scripts/test.sh` 验证 26 测试通过
5. **必查环境**：
   - Xcode 26 已装
   - iPhone 14（iOS 18.6.2）已连 Mac
   - iPhone 14 的 iBridgeCapture app 已装（需先在 Xcode 登录 Apple ID）
   - Mac Apple ID 登录了
   - Accessibility 是唯一阻塞 e2e 的点
6. **如果要发真机测试**：
   - 登录 Apple ID
   - 在 System Settings → Accessibility → + → 选 iBridgeReceiver → 打开

## 10. 立即可做的（无需再等任何东西）

- ✅ `./scripts/test.sh` 跑全套 — 26 tests
- ✅ `./scripts/e2e-simulator.sh` 跑 simulator e2e
- ✅ `./scripts/check-e2e-readiness.sh` 看 e2e 准备度
- ✅ `swift build` + `swiftc -parse-as-library` 跑 e2e_receiver_demo.swift
- ✅ 截图、build、commit 任何修改
- ❌ 装到真机需要先登录 Apple ID
- ❌ Accessibility 需要手动加到列表

## 11. 重要文件 / 路径速查

| 文件 | 作用 |
|---|---|
| `iBridgeCapture/ContentView.swift` | iOS 主 UI（三个 mode 切换）|
| `iBridgeCapture/CaptureEngine.swift` | 摄像头/麦克风采集 + Bonjour 发布 |
| `iBridgeReceiver/ReceiverSession.swift` | Mac 端 Bonjour 浏览 + dispatch |
| `iBridgeReceiver/MenuBarMenu.swift` | 菜单栏 popover 内容 |
| `iBridgeReceiver/iBridgeAudioUnit.swift` | AUAudioUnit v3 虚拟麦克风 |
| `iBridgeReceiver/CameraExtensionBridge.swift` | XPC bridge 到 Camera Extension |
| `iBridgeCore/Networking/IBWire.swift` | length-prefixed 帧协议 |
| `iBridgeCore/DesignSystem/IBMaterials.swift` | Liquid Glass 封装 |
| `iBridgeCapture/Localizable.xcstrings` | iOS 中英双语 |
| `iBridgeReceiver/Localizable.xcstrings` | Mac 中英双语 |
| `scripts/test.sh` | CI 跑全套 |
| `scripts/install-to-iphone.sh` | 真机安装 |
| `scripts/check-e2e-readiness.sh` | e2e 准备度检查 |
| `screenshots/` | 19 张 UI 截图 |
| `AGENTS.md` | **给 AI agent 的项目 context** |
| `E2E_TESTING.md` | 真机 e2e 步骤 |
| `HANDOFF.md` | **本文件**（状态交接） |

## 12. 验证脚本可跑的命令

```bash
cd /Users/edwinhao/iBridge

# 跑 26 测试 + 两端 build
./scripts/test.sh

# Simulator e2e
./scripts/e2e-simulator.sh

# 检查真机 e2e 准备度
./scripts/check-e2e-readiness.sh

# 看 iPhone 14 装的没装、什么状态
xcrun devicectl device info list -d 866A1921-B588-59D5-A1B7-B266103B2E49 2>&1 | head -10
xcrun devicectl device process list -d 866A1921-B588-59D5-A1B7-B266103B2E49 2>&1 | grep -i bridge

# Bonjour 找 iBridge
rtk timeout 3 dns-sd -B _ibridge._tcp 2>&1 | grep "Instance Name" | head -3

# 截屏 simulator 或 Mac
rtk xcrun simctl io booted screenshot /tmp/sim-now.png 2>&1 | tail -1
rtk screencapture -x /tmp/mac-now.png 2>&1 | tail -1

# 触发 iPhone 上的 iBridge
xcrun devicectl device process launch -d 866A1921-B588-59D5-A1B7-B266103B2E49 com.ibridge.iBridgeCapture --terminate-existing 2>&1 | tail -2
```

## 13. 当前 e2e 阻塞点 + 解锁步骤

**问题**：iBridgeReceiver 不在 macOS Accessibility 列表里 → 鼠标键盘模拟进不去 → 接收不到 iPhone 事件

**解锁**（3 分钟）：
1. Mac 系统设置 → 隐私与安全性 → 辅助功能
2. 点窗口左下角小 + 号
3. 按 **⌘⇧G**（前往文件夹）→ 取消 / 输入上面 iBridgeReceiver.app 路径
4. **Open** → 选 iBridgeReceiver
5. 列表里 iBridgeReceiver 出现 → 打开它
6. 输密码授权

**之后**：
- iBridgeReceiver popover 状态变 "Accessibility granted"
- iPhone 14 Bonjour 被检测到
- 等待 2-3 秒 → Mac 显示实时 iPhone 摄像头画面
- 触控板 / 键盘 / 麦克风全部通

## 14. 给 kimi code / 下一个 AI 的关键

**最优先任务**：完成 iPhone 14 ↔ Mac 真实 e2e。这需要：
1. 用户手动授权 Accessibility（13 步走不通）
2. 或者 macOS 重启（重新弹窗）
3. 重启后跑 e2e-simulator 变体测试 iPhone 真机

**然后**：补完 V0.3 / V1.0 缺失项（11 项待做）

**不要做的事**：
- 不要再花时间在 Apple ID 登录上（已经登录了）
- 不要再花时间在 DMG 打包上（无助于 Accessibility）
- 不要再花时间在 Bonjour discovery（已 working，iPhone 14 在 advertise）

**关键判断点**：iPhone 14 的 `iBridge — iPhone` 已经在 Bonjour 上发布，Mac receiver 在跑。**唯一阻塞是 Mac 端 Accessibility 授权**。解决这个之后，整个 e2e 流就通了。
