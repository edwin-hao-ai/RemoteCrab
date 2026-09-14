---
type: memory
title: Familiar iOS: 冷启动黑屏+卡死 9 秒的根因 —— 一个 App 只能有一个预览层（2026-09-14）
created: 2026-09-14T06:45:00.000000+00:00
source: cli
---

# iOS 冷启动黑屏 + UI 卡死：预览层附着（2026-09-14）

## 现象
- 打开 App 预览纯黑，切到触控板 tab 再切回来"过一会"就好了。
- 启动后 UI 完全无响应数秒，之后恢复流畅。
- 采集/编码/网络全程健康（30fps、luma 明亮、Mac 端画面正常）——纯 UI 层问题。

## 根因（取证日志铁证）
全屏预览和 PiP 小窗各自 `AVCaptureVideoPreviewLayer.session =` 附着到同一个采集会话：
1. **第二个附着把主线程卡死 9 秒**（iPhone 14 / iOS 26 实测）。相机守护进程串行注册预览客户端，第二个等第一个的管线完全建好。
2. 在会话未 running 时抢跑附着，预览层会 **wedge 成永久黑屏**，只能销毁视图重建（所以切表面能"治好"）。

## 修复（已上线验证）
- **全 App 只有一个预览视图**：`CaptureEngine.previewView`（`CameraPreview.PreviewView`），全屏和 PiP 通过 `CameraPreview(view:)` 复用同一实例，UIKit 换父视图即可，预览层永不重复附着。
- **`captureSessionReady` 闸门**：`startRunning()` 在采集队列返回后才创建预览视图并置位；之前 ContentView 显示"正在启动相机…"占位（IBLocale.Capture.cameraStarting，中英文已入 xcstrings）。
- `PreviewView.attach(to:)` 内部仍有 DidStartRunning 延迟附着兜底（但注意：该通知在 startRunning 返回**之前**就会发，附着照样会被卡住——所以闸门必须设在"startRunning 已返回"，不能只信通知）。

## 取证工具（保留在代码里）
- `Forensic.MainStallMonitor`：后台 500ms ping 主队列，>300ms 记一行 `[main-stall]` 到 forensic.log。启动期应零记录。
- 拉日志：`xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier com.ibridge.iBridgeCapture --source Documents/forensic.log --destination /tmp/x.log`
- 判断"黑屏是真黑还是环境暗"：`IBRIDGE_DUMP_FRAMES=1` 落 JPEG 到 Documents 直接看，别只信 luma。

## 教训
- "UI 卡 + 黑屏"先怀疑**主线程被 AVFoundation setter 阻塞**，再怀疑管线。
- `previewLayer.session =`、`commitConfiguration`、`startRunning` 都是会跨进程同步的调用，任何一个都能卡主线程数秒。
- 改完编译别用 `xcodebuild ... | tail`（会吞失败）——必须 `set -o pipefail`。
