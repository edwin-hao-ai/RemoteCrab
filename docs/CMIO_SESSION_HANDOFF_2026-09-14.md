# CMIO 虚拟摄像头 + 视频链路 — 排查经验交接

_2026-09-14，由 opencode session 沉淀。承接 `docs/CMIO_AND_RELEASE_HANDOFF.md`。_

---

## 结论先行

**CMIO 虚拟摄像头已完整打通**：`RemoteCrab Camera` 出现在系统相机列表，
宿主 → 扩展 → 任意 AVFoundation 客户端的像素链路已用真实客户端验证
（探针读到 `fmt=BGRA min=3 max=241 avg=111`，并抓到了正确的 PNG 帧：
iPhone 后置摄像头拍的木地板，色彩/亮度准确）。

**遗留一个未根治的问题**：iPhone 端视频会在使用中静默停止
（触摸/音频/featureState 继续流动，唯独没有 video 帧），Mac 预览因此黑屏。
本轮加了看门狗兜底（见下），但**根因还没定位**——新 session 的第一件事
应该是抓 iOS 端日志确认是哪种中断。

---

## 一、CMIO 摄像头扩展：5 个根因（全部已修）

按发现顺序。前 4 个是扩展本身，第 5 个是我自己引入的回归。

### 1. 系统扩展注册残留（改名 App 的坑）
`/Library/SystemExtensions/db.plist` 里记录的 `container.bundlePath` /
`originPath` 是**激活时的宿主 App 路径**。App 从
`/Applications/RemoteCrabReceiver.app` 改名成 `RemoteCrab.app` 后，记录指向
不存在的路径：`systemextensionsctl` 仍显示 `[activated enabled]`，但
扩展永远不会被启动，也没有任何崩溃日志。

**修复**：检测宿主路径变化 → deactivate → activate 重新注册。
注意 deactivate 会因「ownership 不匹配」要求管理员授权而失败
（`OSSystemExtensionErrorDomain Code=13`）；**绕过方法是 bump 扩展的
`CFBundleVersion` 走升级替换路径**，替换会继承用户批准、不需要重新授权。

### 2. 缺 `deviceTransportType`
Apple/OBS 的设备 source 都会 advertise `.deviceTransportType` 并在
`deviceProperties` 里返回 `kIOAudioDeviceTransportTypeVirtual`。缺了它
CMIO 不发布设备。同时 `legacyDeviceID` 传 `nil`（不要传非 UUID 字符串）。

### 3. `main.swift` 缺 `CFRunLoopRun()`  ← 最隐蔽
`CMIOExtensionProvider.startService(provider:)` **会返回**。不接
`CFRunLoopRun()` 的话进程注册完设备就退出——表现为「扩展启动了、
addDevice 成功、然后进程消失、设备不出现」。OBS 的 main.swift 末尾
就是 `CFRunLoopRun()`。

### 4. CMIO DAL 里 sink 流的方向是 0 不是 1
头文件写 `kCMIOStreamPropertyDirection`：0=output、1=input。但扩展的
`.sink`（宿主→设备）流在 DAL 里报告的是 **0**，`.source` 是 **1**
（实测；OBS 也是直接取 `streamIds[1]`）。按字面理解会去 start 错的流，
`CMIODeviceStartStream` 返回 0 但毫无效果、扩展端 `startStream` 不被调用。
**已写死在 `CameraSinkFeeder.sinkDirection = 0` 并注释警告，别"修正"它。**

### 5. （我引入的回归）自动重注册会作废用户批准
最初 `ensureRegistered()` 用「扩展二进制 SHA256 指纹」判断是否重注册——
每次重部署 App 指纹都变 → 自动 deactivate+activate → **macOS 规定替换
系统扩展必须重新批准** → 用户批准被悄悄重置成 `[activated waiting for
user]`，虚拟摄像头整个消失且无任何报错。

**修复**：只有宿主 App **移动/改名**才自动 repair；扩展二进制更新必须
用户手动点 Preferences → Re-register。**教训：任何自动触碰 sysex 注册的
逻辑都要默认「会作废批准」。**

---

## 二、帧传输架构：XPC 不可用，必须走 CMIO sink

原方案是宿主通过自定义 `NSXPCListener(machServiceName: "...Camera.frames")`
推 H.264 NAL 给扩展。**此路不通**：systemextensionsd 给扩展生成的
launchd job 只注册 `MachServices = { CMIOExtensionMachServiceName }`，
自定义服务名无法 vend，宿主 bootstrap look-up 报 `No such process`。
Apple 论坛 (706184) 确认 app→CMIO extension 的自定义 XPC 不受支持。

**正确架构**（OBS / ldenoue sample 同款）：
- 扩展一个设备挂两条流：`.source`（设备→App）+ `.sink`（宿主→设备）
- 扩展端 sink 用 `stream.consumeSampleBuffer(from:)` 逐帧消费，
  转发给 source 的 `stream.send(...)`
- 宿主端 `CameraSinkFeeder` 用 CoreMediaIO **C API**：
  `kCMIOHardwarePropertyAllowScreenCaptureDevices=1` → 按 UID 找设备 →
  找 dir==0 的流 → `CMIOStreamCopyBufferQueue` → `CMIODeviceStartStream` →
  把解码后的 CGImage 画进 BGRA 1080p 池缓冲 → `CMSampleBufferCreateForImageBuffer`
  → `CMSimpleQueueEnqueue`
- 流控：宿主 `readyToEnqueue` 初始为 **true**（否则死锁——callback 只在
  扩展消费后才触发）；扩展每消费一帧回调一次
- **时序坑**：扩展进程是惰性启动的（客户端 start source 时才拉起）。
  宿主若在扩展起来之前 `CMIODeviceStartStream(sink)`，调用无效且不重试。
  已加 stall watchdog：入队了帧但 4s 无 ready callback → teardown 重连。

已删除：`IBCameraXPC.swift`、`CameraExtensionBridge.swift`、
`XPCFrameListener.swift`（XPC 方案整体废弃）。

---

## 三、调试手段（这次真正有用的）

- **带摄像头权限的探针 App**：命令行 `swift` 进程摄像头 TCC 是
  `notDetermined`，AVFoundation 静默不出帧（连 FaceTime 都拿不到）——
  之前所有「0 帧」结论都不可信。解法：做一个 ad-hoc 签名的
  `CameraProbe.app`（含 `NSCameraUsageDescription`），`open -a` 启动，
  用户点一次允许，之后可反复用。脚本在
  `/var/folders/.../T/opencode/CameraProbe_main.swift`（临时目录，建议
  收进 `scripts/`）。
- **帧存 PNG 直接看**：比 min/max/avg 数字可信得多。这次就是靠 PNG
  一锤定音「管线是好的，画面是真实的」。
- **`devicectl device process launch --console`** 抓 iOS stderr——iOS App
  的 `[e2e]` 标记都走 stderr（`FileHandle.standardError`），os_log 反而
  抓不到（`idevicesyslog -n -p RemoteCrabCapture` 为空）。
- **`idevicesyslog -n`**（网络设备）可用，但 App 的 os_log 不透传。
- **`launchctl setenv XXX 1` + `open -a`**：给可见启动的 App 传环境变量
  （`open` 本身不传 env）。用完记得 unset。
- **隔离测试**：`feed_sink.swift`（往 sink 灌合成亮色图）+ 探针读 →
  一次区分「管线坏」还是「源本来就暗」。

---

## 四、已根治：iPhone 视频静默停止（2026-09-14 下午定位）

**症状**：连接正常、`featureState camera=true`、触摸/音频持续流动，
但 iPhone 不再发 video/sps/pps 帧。Mac 预览黑屏。

**根因（实锤，取证日志见下）**：App 进后台时 iOS 不仅中断
AVCaptureSession（`WasInterrupted reason=1`），还会**作废
VTCompressionSession**。回前台后采集会话恢复出帧，但每一帧
`VTCompressionSessionEncodeFrame` 都返回 **-12903
（kVTInvalidSessionErr）**——编码器永久死亡，且错误只进了 os_log
（设备上抓不到），没有任何恢复逻辑。看门狗只重启采集会话，救不了
死掉的压缩会话，因此表现为「重启也没用」。

**取证方法**：`devicectl device process launch --console` 太不稳定
（频繁报 CoreDeviceError 10002 / POSIX 22——只能在 App 已由
devicectl 启动且存活的瞬间偶然 attach 成功）。可靠做法是
`RemoteCrabCapture/Forensic.swift`：每帧计数 + 事件标记同时写 stderr
和 App 容器 `Documents/forensic.log`，用
`devicectl device copy from --domain-type appDataContainer
--domain-identifier com.ibridge.iBridgeCapture --source
Documents/forensic.log` 拉取。

**修复（`H264Encoder.scheduleSessionRecreation`）**：遇到
`kVTInvalidSessionErr`（EncodeFrame 返回或 output callback 报错）
→ 在编码器队列上 invalidate + 重建压缩会话（1s 节流）；重建时清空
lastSPS/lastPPS 缓存，首帧自动重发参数集，Mac 解码器按现有路径
重新配置。真机验证：后台→前台后日志出现 `recreating
VTCompressionSession` → `recreated OK` → `frames sent to Mac` 继续
增长，预览自行恢复。

**顺带修掉一个上线级 bug**：昨天新加的 `videoWatchdog` 的
`DispatchSource` event handler 在 `@MainActor` 类型里形成、继承
MainActor 隔离，timer 在 `com.remotecrab.encoder` 队列触发时
`swift_task_checkIsolated` 直接 SIGTRAP——**只要开始推流 3 秒内
必崩**（crash log `dispatch_assert_queue_fail → closure #1 in
CaptureEngine.startVideoWatchdog()`）。修复：handler 显式标注
`@Sendable`。这正是 AGENTS.md 第 7 条的变体：DispatchSource 的
handler 不像 `DispatchQueue.async` 那样被 SDK 标成 @Sendable。

看门狗保留（应对「isRunning==true 但 output 不出帧」的另一种
失败模式），但根因已除，正常情况下不该再频繁触发。

**当日晚些时候又实锤两个冷启动 bug（都已修、真机验证）**：

1. **启动顺序 wiring bug（全天最大乌龙）**：为了修启动卡死把
   `configureCaptureSession` 挪到编码器创建**之前**执行，而配置里
   有 `videoOutput.setSampleBufferDelegate(encoder, …)`——此刻
   `encoder` 还是 nil，等于把 delegate 清空，**采集会话一帧都
   不发**。症状与「静默停止」一模一样（isRunning=true、watchdog
   每 3 秒狂触发 stop/start 也救不回来，因为 output 根本没有
   delegate）。修复：`startIfNeeded` 里先创建 `H264Encoder` 再
   配置会话。教训：**改启动顺序后必须验证冷启动出帧**，这个 bug
   `./scripts/test.sh` 和模拟器都抓不到。
2. **看门狗需要暖机宽限**：冷启动 `startRunning()` 合法耗时数秒，
   原来武装条件只有「连接 ready + 2.5s 无帧」，启动期必误触发。
   现在：`hasProducedVideoFrame == false`（首帧未出）时用 12s
   阈值，出过帧后才用 2.5s；且 `captureSession.isRunning ==
   false`（还在启动中）直接跳过。`reconfigureVideo`（旋转/切
   分辨率重建编码器）和相机开关重新打开时也会重置宽限。
3. **启动残留卡顿**：`configureCaptureSession`（begin/commit +
   addInput/addOutput，数百 ms）原来跑在主线程，启动时 UI 会卡
   一下。已改为 `nonisolated static`，整个配置在采集队列执行，
   用 `ConfigureOutcome`（@unchecked Sendable 盒子）把
   input/output 递回主 actor。改完冷启动到第 100 帧约 4 秒、
   主线程零阻塞调用。
4. **「黑屏」一度是环境因素**：用户报预览黑屏时 forensic 显示
   出帧正常但 luma=15——加了 `REMOTECRAB_DUMP_FRAMES=1`（
   `H264Encoder.dumpFrame`，第 100 帧起每 1800 帧把原始相机帧
   落成 JPEG 存 Documents）后眼见为实：画面明亮清晰、竖屏
   1080×1920、方向正确。当时的 luma=15 是手机放置位置暗。
   **以后排查黑屏先 dump 一帧看，别只信 luma 数字。**

真机验证（04:37–04:40）：冷启动→中断→恢复全链路日志干净——
`capture frames IN: 1500`、`luma avg=82 1080x1920`、
`frames sent to Mac` 持续增长、零 WATCHDOG 触发；Mac 侧
`frame probe avg=103 w=1080 h=1920`（竖屏真实画面）、
`feeding virtual camera` 同步增长。

**次要待办**：卡顿已修一处——`H264Decoder.emit` 原来**每帧新建
`CIContext`**（极贵），已改为 `lazy var ciContext` 缓存。若仍有卡顿，
下一个嫌疑是 feeder 的全帧 CGContext 绘制（1080p CPU 绘制 30fps）。

### 追加（2026-09-14 傍晚）：冷启动黑屏 + 卡死 9 秒 = 第二个预览层

用户复测又报「打开黑屏、点几次/切 tab 才好、启动卡死」。采集管线
全程健康（30fps、luma 明亮），问题在 UI 层：

- **根因**：全屏预览和 PiP 小窗**各自**往采集会话挂了一个
  `AVCaptureVideoPreviewLayer`。实测第二个 `previewLayer.session =`
  把主线程卡死 **9 秒**（相机守护进程串行注册预览客户端）；在会话未
  running 时抢跑附着还会让层 wedge 成永久黑屏，只能销毁视图重建
  （所以「切到触控板再切回来就好了」）。
- **修复**：全 App 只有一个共享 `PreviewView`
  （`CaptureEngine.previewView`），全屏/PiP 换父视图复用；
  `captureSessionReady` 闸门保证 `startRunning()` 返回前 SwiftUI
  不建任何预览（期间显示「正在启动相机…」占位）。
- **陷阱**：`AVCaptureSessionDidStartRunningNotification` 在
  `startRunning()` 返回**之前**就发——从该通知附着照样卡 9 秒，
  闸门必须钉在「startRunning 已返回」。
- **取证**：新增 `Forensic.MainStallMonitor`（500ms ping 主队列，
  >300ms 记 `[main-stall]`）。修复后启动期零 stall、附着瞬时完成。
  另外 `xcodebuild ... | tail` 会吞掉构建失败——必须
  `set -o pipefail`，否则会把旧包当新包装机白排查一轮。

---

## 五、本轮新增功能（已实现、已测试）

### 前后摄像头切换
- 协议：`IBCameraPosition`（front/back，含 `toggled`）+ `IBCameraCommand`，
  wire kind **0x15** `cameraCommand`（Mac→iPhone）
- `FeatureStateSnapshot` 新增 `cameraPosition`，**自定义 `init(from:)`
  用 `decodeIfPresent` 兜底**，旧快照缺字段默认 `.back`
- iOS：`CaptureEngine.switchCamera(to:)` / `toggleCamera()`（换
  AVCaptureDeviceInput，保持 output/encoder 不动）；相机界面右上角翻转按钮
- Mac：菜单栏 Actions → Switch Camera；`ReceiverSession.switchCamera/toggleCamera`
- 测试：cameraCommand 往返、cameraPosition 状态、legacy 快照解码（77 全绿）

### 系统扩展管理重构
- `SystemExtensionManager` 改为单例 + `applicationDidFinishLaunching` 时注册
  （原来在 `App.init()` 里提交，太早，sysextd 连接未建立，请求被静默丢弃）
- 新增 `repair()`（deactivate→activate）、stall 检测、`REMOTECRAB_SYSEX_REPAIR=1` /
  `REMOTECRAB_SYSEX_ACTIVATE=1` 调试钩子
- Preferences 加 Re-register；新增 `CameraExtensionCard` 一键引导卡
  （触发系统弹窗 + 深链 `x-apple.systempreferences:com.apple.ExtensionsPreferences`，
  fallback `com.apple.LoginItems-Settings.extension`）

---

## 六、操作注意事项（给下一次部署）

1. **只改宿主 App** → 直接 `ditto` 覆盖 `/Applications/RemoteCrab.app`，
   扩展批准保留，无需任何操作
2. **改了扩展代码** → 必须 bump `project-mac.yml` 里扩展的
   `CFBundleVersion`（当前 6）→ 部署 → 用户在系统设置重新批准
   （或 Preferences → Re-register 触发弹窗）
3. 覆盖安装后**辅助功能授权保留**（同路径同签名）；改路径/签名会掉
4. iPhone 端测试前：**自动锁定 → 永不**、保持 App 前台；设备锁屏后
   Bonjour 记录残留但 TCP 连不上，Mac 会永远停在「连接中」——这不是 bug
5. `systemextensionsctl uninstall/gc` 会挂起等 GUI 授权，脚本里别用；
   用版本 bump 替换路径
6. 重部署后验证：`systemextensionsctl list` 看 `[activated enabled]`、
   `pgrep` 扩展进程、`cmio_list.swift` 看设备

## 七、未开始的事项

- ~~**双向确权**~~ ✅（2026-09-14 下午）：Mac 不再盲连——
  `handleDiscovered` 只自动连**本机持有配对 token 的 iPhone**（双向
  都已同意过）；陌生设备出现在菜单栏 DEVICES 列表，点 Connect 才连
  （iPhone 侧批准卡片不变）。断线重连优先 `lastAttemptedPhoneName`。
  Mac 侧对称管理：菜单栏 Actions → Disconnect；Preferences →
  General → Paired iPhones（断开/忘记，`ReceiverSession.forgetPhone`）。
  `disconnect()` 置 `autoConnectSuppressed`，用户再点连接前不自动连。
- 触控板 surface 如何退回全屏摄像头（查 `FeatureDock` 的 surface 切换交互）
- 虚拟麦克风 F2：代码完成，`sudo` 装 `dist/RemoteCrabMicrophone.pkg` 验证；
  沙盒 `shm_open` 被挡（`micring unavailable (shm_open failed)`），挡了就
  改 XPC 桥或非沙盒
- Mac 配对 token key 去掉 App 名前缀（改名不再掉配对）
- ASC 文案/截图推送（`scripts/ios-app-store-metadata.py`，appId 6811599153）
- 收敛：`CameraProbe.app` / `feed_sink.swift` / `cmio_list.swift` 等临时
  调试脚本收进 `scripts/`；`REMOTECRAB_SYSEX_*` 调试钩子去留
