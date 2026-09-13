# Handoff — CMIO Camera Extension + Release assets

_2026-09-13 · for the next session_

## A. 未完成：CMIO 虚拟摄像头不出现（最高优先）

**目标**：让 “Familiar Camera” 出现在 Photo Booth / Zoom / 飞书 的摄像头列表里。

**现状（已诊断）**
- `systemextensionsctl list` → `com.ibridge.iBridgeReceiver.Camera (0.2/1)  [activated enabled]`。
- 但扩展进程**从未启动**（`pgrep` 无），无崩溃日志。
- `system_profiler SPCameraDataType` / `AVCaptureDevice.DiscoverySession` 只看到 FaceTime HD。
- 结论：系统"已启用"却没加载扩展 → 设备不注册。**不是权限问题（已 enabled）**。

**关键文件**
- 扩展：`iBridgeCameraExtension/Sources/iBridgeCameraExtension/`
  - `main.swift`（`CMIOExtensionProvider.startService(provider:)`）
  - `CameraExtensionProvider.swift`（provider + 加 device）
  - `CameraExtensionDevice.swift`（device + 加 stream）
  - `CameraExtensionStream.swift`（stream + VideoToolbox 解码 + `CMIOExtensionStream.send`）
  - `XPCFrameListener.swift`（host→extension 帧；`IBridgeCameraXPC.machServiceName`）
- 工程：`project-mac.yml` 的 `iBridgeCameraExtension` target（`type: system-extension`,
  `CMIOExtension.CMIOExtensionMachServiceName`, `CFBundlePackageType: SYSX`）
- Host：`iBridgeReceiver/CameraExtensionBridge.swift`、`SystemExtensionManager.swift`
- 扩展嵌在 `/Applications/Familiar.app/Contents/Library/SystemExtensions/…Camera.systemextension`

**下一步排查（按顺序）**
1. 对照 Apple 官方 Camera Extension 示例（WWDC22 “Create a camera extension”）核对
   `Info.plist`（`CMIOExtension` 键、`CMIOExtensionMachServiceName`、`CFBundlePackageType`、
   executable 名）与 **entitlements**（当前是沙盒+app-groups+network+camera；示例可能不同，
   注意是否需 `com.apple.developer.camera-extension`）。
2. 开着 `log stream --predicate 'subsystem == "com.apple.systemextensions"'` 后再枚举摄像头，
   看 systemextensionsd 为何不 launch（会给出具体原因）。
3. 确认 host 的 `OSSystemExtensionRequest` 真的发出（`SystemExtensionManager`），
   且 `CameraExtensionBridge` 的 XPC 服务名 == 扩展 Info.plist 的 `CMIOExtensionMachServiceName` == `IBridgeCameraXPC.machServiceName`。
4. 打通设备注册后，再做 App 内**「启用相机扩展」一键引导卡片**（触发系统弹窗 + 深链
   `x-apple.systempreferences:com.apple.ExtensionsPreferences`，读 `isAwaitingUserApproval`）。

**坑**：重装/重签 App 会**作废系统扩展批准**（和辅助功能一样）→ 每次重部署后系统里那条会回到
`waiting for user` / 假 enabled。发布版（签名稳定、装一次）只需批准一次。

**命名**：扩展显示名已改为 **Familiar Camera**（`CameraExtensionProvider/Device.swift`），
重新激活后才生效；旧激活实例仍显示 “iBridge Camera”。

## B. 发布 / App Store Connect 资产

- **App**：name `Familiar: Phone as Cam & Pad`，**appId `6811599153`**，
  bundleId `com.ibridge.iBridgeCapture`，SKU `ibridge`，team `5XNDF727Y6`。
- **ASC 网页**：https://appstoreconnect.apple.com/apps/6811599153
  TestFlight：同上 → TestFlight 标签页
  API Keys：https://appstoreconnect.apple.com/access/integrations/api
- **ASC API 凭证**：`~/.config/mddock/ios-release.env`
  （`APPLE_API_KEY=DDG3CJL762`, `APPLE_API_ISSUER=a28bcef1-d045-49f2-b86e-81aebe6b6b25`,
  `APPLE_API_KEY_PATH=~/.config/mddock/AuthKey_DDG3CJL762.p8`）；
  已软链到仓库脚本读取的 `~/.config/ibridge/ios-release.env`。
- **已上传 TestFlight**：版本 `0.2.0` / build `2026091321`（2026-09-13），
  delivery UUID `cac8140f-6e69-4165-9666-fd80ac90ea40`。
- **构建/上传**（详见 `docs/RELEASE.md`）：
  ```sh
  xcodebuild -project iBridgeCapture.xcodeproj -scheme iBridgeCapture \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath build/iBridgeCapture.xcarchive archive \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=5XNDF727Y6 -allowProvisioningUpdates
  xcodebuild -exportArchive -archivePath build/iBridgeCapture.xcarchive \
    -exportPath build/asc -exportOptionsPlist ExportOptions-asc.plist -allowProvisioningUpdates
  mkdir -p ~/.appstoreconnect/private_keys && cp ~/.config/mddock/AuthKey_DDG3CJL762.p8 ~/.appstoreconnect/private_keys/
  xcrun altool --upload-app -f build/asc/iBridgeCapture.ipa -t ios \
    --apiKey DDG3CJL762 --apiIssuer a28bcef1-d045-49f2-b86e-81aebe6b6b25
  ```
  （`ExportOptions-asc.plist` = `method: app-store-connect`；本机测试用 `ExportOptions.plist` = `debugging`。）
- **注意**：ASC **不能通过 API 创建 app**（只能在网页建）；版本/文案/截图可自动化
  （`scripts/ios-app-store-metadata.py`，appId 已填 6811599153）。
- 首次 TestFlight 要填**出口合规：不含加密**。内部测试无需 Beta 审核。

## C. 本会话其它坑（详见 AGENTS.md 第 11–15 条 + memories/）
- iOS 顶栏是浮层，surface 顶部要留白；长状态用居中 alert，不进胶囊。
- `MenuBarExtra(.window)` 内容高度/动画变化会让窗口**漂移**：行固定高度 + 去掉常驻动画
  （`ProgressView` 转圈、`repeatForever` 脉冲点都删了）。
- 沙盒 app：`FileManager` 把 `~/Downloads`/`~/Movies` 重定向进容器 → 用 `getpwuid` + 对应 entitlement。
- 沙盒 app **读不了别的 app 的 AX 树** → 选区改写改用合成 ⌘C/⌘V。
- 改名/重装会重置：**本地网络权限**、**辅助功能**、**系统扩展批准**。
- 桌面 App 文件已改名 `/Applications/Familiar.app`（带 AppIcon）；麦克风驱动 pkg = `dist/FamiliarMicrophone.pkg`。
