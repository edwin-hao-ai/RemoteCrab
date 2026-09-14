# RemoteCrab 踩坑手册 (Pitfalls & Lessons Learned)

> 这次 session 踩的所有坑、原因、修复方案。
> 任何接续这个项目的人应该先读这个。

## 0. 关于这个文件

- **不是教程** — 是真实踩过的坑
- **不是抱怨** — 每条都带修复方案
- **不是机修手册** — 是快速索引

## 1. macOS / 系统级

### 1.1 Bonjour 不在同子网
**症状**：iPhone 14 USB 接 Mac，Mac 找不到 iPhone
**原因**：iPhone 在 192.168.x.x USB-tether 子网，Mac 在 192.168.31.x WiFi 子网。Bonjour multicast 跨子网失败。
**修复**：
- iPhone 拔 USB（必须 WiFi 连接）
- 或 iPhone 同时连同一个 WiFi 5G
- 验证：`rtk timeout 3 dns-sd -B _remotecrab._tcp 2>&1 | grep "Instance Name"`

### 1.2 macOS Accessibility 弹窗只一次
**症状**：点 "Open System Settings" 没反应，RemoteCrabReceiver 不在列表里
**原因**：
- macOS 14+ 缓存 "rejected" 状态
- 一旦 dismiss，再启 app 不再弹
- `tccutil reset` 清了 TCC.db 但 `accessibilityd` 守护进程缓存独立
- ad-hoc 签名的 app 在系统里优先级最低
**修复**（**唯一可靠**）：
- 手动加：System Settings → Privacy & Security → Accessibility → + → 选 `RemoteCrabReceiver.app` → 打开
- 或重启 Mac（Reddit 用户验证有效）

### 1.3 ImageRenderer 不渲染 Liquid Glass
**症状**：`xcrun simctl io booted screenshot` 或 `screencapture` 截图里 `.glassEffect()` 显示空白
**原因**：SwiftUI 的 ImageRenderer 在 headless 模式下无法访问 macOS 26 的 Liquid Glass 系统材质
**修复**：
```swift
@ViewBuilder
public static func glass<S: Shape>(...) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
        GlassSurface(...)  // 真实 Liquid Glass
    } else {
        LegacyGlassSurface(...)  // .regularMaterial fallback
    }
}
```
截图脚本走 fallback path。production app 走真 glassEffect。

### 1.4 iOS 26 SDK + iOS 17 deployment 冲突
**症状**：
```
error: Ad Hoc code signing is not allowed with SDK 'iOS 26.5'.
```
**原因**：iOS 26 SDK 强制 iOS 18+ 真 signing
**修复**：
- iPhone 真机用 `DEVELOPMENT_TEAM=5XNDF727Y6` 真签
- iOS Simulator 可用 ad-hoc
- Mac 可用 ad-hoc

### 1.5 Apple Development cert 真实 team
**症状**：cert 显示 "DDG3CJL762" 但 build team 配错了
**原因**：cert 名字是显示名，Subject 字段才是真 team
**诊断**：
```bash
security find-certificate -c "Apple Development" -p | openssl x509 -text -noout \
    | grep "Subject:"
# Subject: UID=82BDA3BF2M, CN=Apple Development: Edwin Hao (42W33RCYXZ),
#          OU=5XNDF727Y6, O="Beijing VGO Co;Ltd", C=US
```
**修复**：用 OU 字段（`5XNDF727Y6`），不是 cert 显示名

### 1.6 tccutil reset 不刷新
**症状**：
```
Successfully reset Accessibility approval status for com.remotecrab.RemoteCrabReceiver
```
但 app 重启后还是不弹窗
**原因**：macOS 14+ 的 `accessibilityd` 守护进程有独立缓存
**修复**：重启 Mac 或手动添加

### 1.7 系统设置手动加 app 流程
1. System Settings → Privacy & Security → Accessibility
2. 窗口左下角小 + 号
3. ⌘⇧G 前往文件夹
4. 粘贴完整路径
5. Open → 打开
6. 列表里出现 → **打开** 开关
7. 输密码授权

## 2. Swift 6 strict concurrency

### 2.1 NSXPCConnection 不 Sendable
**症状**：
```
error: 'connection' risks causing data races
```
**原因**：NSXPCConnection 没有 Sendable 标记
**修复**：
```swift
let box = UncheckedBox(connection)  // @unchecked Sendable wrapper
DispatchQueue.main.async { box.value... }
```

### 2.2 AUAudioUnit v3 init 签名变
**症状**：
```
error: argument 'flag' must be a class
```
**原因**：macOS 26 SDK 用 `kAXTrustedCheckOptionPrompt: true as CFString` (Unmanaged<CFString>) 替代旧的 Bool
**修复**：
```swift
let opts: NSDictionary = [
    "AXTrustedCheckOptionPrompt" as NSString: kCFBooleanTrue
]
_ = AXIsProcessTrustedWithOptions(opts)
```

### 2.3 VideoToolbox outputBusses 类型变
**症状**：
```
error: 'outputBusses' has different type from overridden property
```
**原因**：macOS 26 SDK 把 `[AUAudioUnitBus]` 改成 `AUAudioUnitBusArray`
**修复**：
```swift
public override var outputBusses: AUAudioUnitBusArray { [bus] }
```

### 2.4 闭包 actor 隔离
**症状**：
```
warning: result of call to 'connect()' is unused
warning: expression is 'async'-but-isolated
```
**修复**：用 `nonisolated(unsafe)` 包裹或 `MainActor.assumeIsolated { ... }`

## 3. SwiftUI / 设计系统

### 3.1 `Text` 字面量不本地化
**症状**：所有 .xcstrings 自动抽出后代码里还是写 `Text("Cancel")` 而非 `Text("cancel", bundle: .main)`
**修复**：写专门 helper：
```swift
public enum IBLocale {
    public static let cancel = "Cancel"
    public static let done = "Done"
    // ...
}
// 用法: Text(IBLocale.cancel)
```
v0.3 时把代码里所有 `Text("...")` 换成 `Text(IBLocale.对应key)` + 真正的 .xcstrings 字符串

### 3.2 多个 `.frame()` modifier 叠加
**症状**：Modifier 链长到编译变慢、容易冲突
**修复**：拆成 view modifier 链、抽 `@ViewBuilder func content() -> some View`

### 3.3 SwiftUI MenuBarExtra popover 重复 title
**症状**：popover 标题栏写 "RemoteCrab" + 内容里又写一个大 "RemoteCrab" 标题 → 颜色冲突
**修复**：删内容里那个重复标题，让标题栏做唯一标识符

## 4. iOS / macOS 集成

### 4.1 模拟器 vs 真机 Bonjour
**症状**：模拟器 e2e 跑通，真机失败
**原因**：
- 模拟器在 Mac 同主机 localhost 子网
- iPhone 真机在 192.168.31.x WiFi
- USB-tether 时子网更不同
**修复**：
- 真机必须用 WiFi（不能光 USB-tether）
- Bonjour 需同一 multicast 域

### 4.2 iPhone 14 是 iOS 18.6.2
**症状**：iOS 26 deployment 装不上
**原因**：iPhone 14 2022 款，最高 iOS 18
**修复**：iOS 17 deployment target

### 4.3 AVCaptureSession 模拟器无 camera
**症状**：simulator 跑 capture 拿不到帧
**原因**：模拟器没有 camera 硬件
**修复**：simulator e2e 只验证 Bonjour + wire 协议（不验证 video frame 内容）

### 4.4 UIDevice.current.name 跨 iOS 变化
**症状**：iPhone 14 报 "RemoteCrab — iPhone"（不是 "RemoteCrab — iPhone 14"）
**原因**：UIDevice.name 在 iOS 16+ 返回 "iPhone"（generic），不是具体型号
**修复**：手动拼字符串 + UIDevice.model 拼 "iPhone 15,3" 等
**当前状态**：Mac receiver 兼容两种命名（同时显示）

## 5. Bonjour / 网络

### 5.1 实例名冲突
**症状**：iPhone 17 Pro sim 和 iPhone 14 都用 BundleID `com.ibridge.iBridgeCapture` advertise
**原因**：Bonjour 不管 BundleID，只看 instance name
**修复**：用 UIDevice.name + UIDevice.model 拼唯一名
**当前状态**：sim 报 "RemoteCrab — iPhone 17 Pro"，iPhone 14 报 "RemoteCrab — iPhone"

### 5.2 Bonjour 跨网段
见 1.1

## 6. 工具 / 脚本

### 6.1 simctl launch --setenv
**症状**：
```
Invalid device: --setenv
```
**原因**：simctl launch 不支持 --setflag 之前的 --setenv
**修复**：用 `SIMCTL_CHILD_` 前缀：
```bash
SIMCTL_CHILD_REMOTECRAB_AUTO_START=1 xcrun simctl launch $SIM com.ibridge.iBridgeCapture
```

### 6.2 simctl 设备 ID
**症状**：`xcrun simctl launch $UDID ...` 报 "Invalid device"
**原因**：simctl 默认需要 UUID 而不是名字
**修复**：
```bash
xcrun simctl list devices booted | grep "iPhone 17 Pro" | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' | head -1
```

### 6.3 devicectl 子命令
**症状**：`devicectl device info -d $UDID` 报 "Unknown option -d"
**原因**：devicectl 不支持 -d，要 subcommand 优先
**修复**：
```bash
xcrun devicectl device info details $UDID   # 注意子命令 details
```

### 6.4 cliclick 路径
**症状**：`cliclick c:2300,12` 不工作
**原因**：坐标可能错或没有 MenuBarExtra
**修复**：先 `osascript` 查 menu bar items 找到 RemoteCrab，再 cliclick 那个位置

### 6.5 simctl screenshot 设备
**症状**：`xcrun simctl io <UDID> screenshot <path>` 不工作
**修复**：
```bash
xcrun simctl io booted screenshot /tmp/sim.png   # 'booted' 是关键字
```

## 7. 测试 / CI

### 7.1 Swift 6 测试编译
**症状**：测试编译卡住
**修复**：用 `swift test --package-path RemoteCrabCore` 而不是 `xcodebuild test`

### 7.2 xcodebuild 测试 simulator
**症状**：用 simulator 跑测试要 5+ 分钟
**修复**：直接 `swift test` + `xcodebuild build` 分开

### 7.3 ImageRenderer for SwiftUI 设计系统
见 1.3

## 8. App Store / 发布

### 8.1 个人 Apple ID 不能发布
**症状**：登录后 build 装到设备 OK，但 App Store Connect 拒绝
**原因**：需要 Apple Developer Program $99/年
**修复**：注册公司或个人 developer account
**当前状态**：可以装到设备 + 模拟器，但不能上架

### 8.2 证书命名误导
见 1.5

## 9. 协议 / 数据

### 9.1 Wire 协议 length-prefix
**采用**：4 byte BE 长度 + 1 byte kind + payload
**kind 列表**：
- 0x00 metadata
- 0x01 video (AVCC, length-prefixed)
- 0x02 sps
- 0x03 pps
- 0x04 touch (JSON)
- 0x05 key (JSON)
- 0x06 audio (base64 PCM)

### 9.2 Bonjour service name
**采用**：`_remotecrab._tcp` on `local.` domain
**为什么用 TCP**：视频需要流式可靠传输（UDP 重传复杂）
**为什么 _remotecrab 不带前缀**：Apple 推荐用公司前缀（`_remotecrab._tcp`），但用裸名也行

## 10. 修复历史时间线

| 问题 | 修复 |
|---|---|
| Allow 按钮遮挡 | 删 auto-start，改为用户主动按 START |
| iOS 26 SDK 拒 ad-hoc | 真机用 team signing，sim 还能 ad-hoc |
| iPhone 14 iOS 18.6 装不上 | 部署目标 iOS 17，cert 团队 5XNDF727Y6 |
| Bonjour 找不到 iPhone | iPhone 必须拔 USB 走 WiFi，不能 USB-tether |
| Accessibility 注册不到 RemoteCrabReceiver | 唯一办法：手动加到 System Settings |
| ImageRenderer 渲染无输出 | Liquid Glass 走 .regularMaterial fallback |
| AXIsProcessTrusted 不弹窗 | ad-hoc 签名 + dismissed 后不再弹 |
| iPhone 14 UDID 难找 | `xcrun devicectl list devices` (新 API) |
| tccutil reset 不刷新 | macOS 14+ accessibilityd 守护进程缓存独立 |
| NSXPCConnection 不 Sendable | 用 `nonisolated(unsafe) UncheckedBox` 包装 |
| AUAudioUnit 渲染崩溃 | v0.3 改用 v3 模板，重写为 v3 init 签名 |
| 模拟器 camera 假帧 | simulator e2e 只验 Bonjour，不验 video |
| Xcode 26 SWIFT_TREAT_WARNINGS_AS_ERRORS 默认开 | project-*.yml 设成 NO |
| cmd-click + 路径输入 慢 | `tccutil reset` 一行更高效 |

## 11. 调试技巧

### 11.1 查 Bonjour 服务
```bash
rtk timeout 3 dns-sd -B _remotecrab._tcp 2>&1 | grep "Instance Name"
```

### 11.2 查 iPhone 进程
```bash
xcrun devicectl device process list -d $PHONE_UDID | grep -i bridge
```

### 11.3 查 Mac Accessibility
```bash
lsappinfo info -only StatusLabel "RemoteCrabReceiver"
```

### 11.4 截屏
- Simulator: `rtk xcrun simctl io booted screenshot /tmp/sim.png`
- Mac: `rtk screencapture -x /tmp/mac.png` (no `-x` excludes mouse)
- iPhone 真机: 没有 CLI 直截，但 simctl 有 launch + view hierarchy

## 12. 下次记得做的事

1. **每次大改前在 Xcode 里重新登录 Apple ID**（token 过期）
2. **真机 e2e 前先 `Bonjour` 服务可见**（防止网络问题）
3. **写 SwiftUI 时立即把字面量抽到 IBLocale**（方便后续本地化）
4. **Mac 端任何 menu bar app 一开始就调用 `AXIsProcessTrustedWithOptions` 注册**
5. **iPhone 14 真机测试需要 WiFi 模式**（不能 USB-tether 走 Bonjour）
6. **写 Simulator e2e 时只验 wire 协议**（不验 video 内容）
7. **每次大版本改后跑 `./scripts/test.sh` 验证 baseline**

## 13. 还没解决但应该会有的坑

- **iOS 真机 video 流延迟** vs simulator：硬件加速 / codec 配置不同
- **iPhone 锁屏后 Bonjour 服务消失**：要加 `audio` UIBackgroundMode
- **多个 iPhone 同时连一个 Mac**：当前只接第一个，需要 manual
- **Camera Extension 完整 wiring**：XPC 双向 + buffer management
- **多分辨率切换**：当前切到不同分辨率要 restart stream
