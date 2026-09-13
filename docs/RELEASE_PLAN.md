# iBridge — V1.0 补齐计划（执行中）

_2026-09-13 · 目标：把 `docs/RELEASE_READINESS.md` 的功能缺口补到"完全可用"_

执行顺序按「可验证 + 用户可感知」优先，系统级/高风险项放后面并单独验证。

## 状态

- [x] **F7 锁屏/后台清晰提示** — iOS `scenePhase` → 回前台 toast
- [x] **F6 录制合轨** — 单个 `.mov`（h264 + aac），ffprobe 验证双轨
- [x] **F4 iOS 演示模式** — 设置开关 + 水印画面 + DEMO 徽标；演示态不弹离线 alert
- [x] **F3 手动 IP 兜底** — iPhone 固定端口 8765 + 显示 IP:port；Mac「手动连接…」
- [~] **F2 虚拟麦克风（CoreAudio HAL 插件）** — 代码完成，待安装+验证：
  - `iBridgeMicDriver/`：`SharedRing`(C 无锁环) + `iBridgeMicrophone.c`（HAL `AudioServerPlugIn`，
    单输入设备 48k/1ch/Float32，render 回调从环里读 Int16→Float32，零分配）→ 编出 `.driver`（已 build 通过）。
  - Mac app 通过 `MicRingWriter`（C 桥）把收到的 PCM 写进同一个 shm。
  - **面向用户的安装 = 双击 pkg，不碰 shell**：`scripts/build-mic-driver-pkg.sh` 产出
    `iBridgeMicrophone.pkg`（BlackHole 同款，postinstall 重启 coreaudiod）；正式分发前签名+公证，
    再嵌进 app 的 `Contents/Resources`。App 内 **偏好设置 → 麦克风驱动 → 「安装麦克风驱动…」**
    一键打开 pkg（一次管理员授权），并用 CoreAudio 枚举设备检测是否已装。
  - 开发用 `scripts/install-mic-driver.sh`（sudo）仅作调试。
  - **待做**：sudo/pkg 安装 + 在 Zoom/QuickTime 验证；**并确认沙盒 app 能否 `shm_open`**（若被沙盒挡，
    驱动读到静音 → 需让 Receiver 非沙盒，或改 XPC 桥）。
- [ ] **F1 Camera Extension 激活 + 真机验证** — **代码完成**（sysex 已编进
  `Contents/Library/SystemExtensions/`），待你在系统设置打开扩展 + Photo Booth 验证。
- [ ] **F5 素材/URL**（非代码，需人工：真机截图、privacy/support 托管）

## 每项的做法与验收

### F7 锁屏/后台提示
- iOS 侧检测 `scenePhase`/`UIApplication` 进入后台 + 摄像头中断时，给出明确文案
  （"iPhone 锁屏会暂停视频，请保持 App 在前台"）。
- 验收：锁屏后回前台，界面出现清晰说明；Mac 端不显示原始错误。

### F6 录制合轨
- `StreamRecorder`：把音频也写进 `AVAssetWriter`（AAC）→ 单个 `.mov`。
- 保留 `.wav` 作为回退（若音频 writer 失败）。
- 验收：录制得到**一个** `.mov`，QuickTime 里音画同步。

### F4 iOS 演示模式
- 无 Mac 时，"演示模式"用本地生成的假画面（彩色动画/时间戳）+ 假触控反馈，
  让审核员能看到完整 UI 流程；入口放设置页，明确标注"演示"。
- 验收：开飞行模式也能进主界面、切换 surface、看到内容；不误导（有 DEMO 标识）。

### F3 手动 IP 兜底
- iPhone：监听固定端口（如 8765，失败则回退动态）并在设置页显示 `IP:port`。
- Mac：Bonjour 找不到时，菜单里"手动连接…"输入 `IP:port`。
- 验收：关掉 Bonjour（或用不同网段）仍能连上。

### F2 虚拟麦克风（HAL）
- 新建 `AudioServerPlugin` bundle（`/Library/Audio/Plug-Ins/HAL/iBridgeMic.driver`），
  通过共享内存/环回从 Receiver 拿 PCM。需要独立 target + 安装脚本 + 签名。
- 验收：系统设置/QuickTime 里出现"iBridge Microphone"并能录到 iPhone 的声音。
- 风险：HAL 插件需装到系统路径、可能要管理员权限；开发/签名成本高。

### F1 Camera Extension 激活 + 验证
- `iBridgeCameraExtension` 已是 CMIO sysex 骨架 + XPC 桥；需：
  用户在系统设置打开扩展 → 在 Photo Booth/Zoom 验证出画面。
- 若骨架不完整，补齐 `CMIOExtensionDevice/Stream` 的帧投递。
- 验收：Photo Booth 选 "iBridge Camera" 看到实时画面。
- 风险：CMIO 最难，需真机 + 系统设置手动操作。

## 备注
- 明文 TCP（无 TLS）：非阻塞项，但 `PRIVACY.md` 要如实说明。
- 改动较大，建议每个 F 完成即 `./scripts/test.sh` 通过；F1/F2 需 `scripts/e2e-device.sh` 之外的手动验证。
