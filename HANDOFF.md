# iBridge — 状态交接 (Handoff)

> 给下一个接手的 AI/人。项目细节看 `AGENTS.md`（必读），本文件只放**当前状态**。

_Last updated: 2026-09-12 by opencode_

## 项目

把 iPhone/iPad 变成 Mac 的摄像头 / 麦克风 / 触控板 / 键盘，Bonjour + TCP，零云端、零订阅。

## 已完成并真机验证（2026-09-12）

- **真机 e2e 全链路打通**（iPhone 14 / iOS 26.6.2 + Mac）
  - 视频：1080p @ 30fps，Mac 端 VideoToolbox 解码正常
  - 音频：48 kHz PCM 20 ms 包持续入站
  - 键盘 / 鼠标注入：`iBridge-e2e-OK` 真的打进 TextEdit 光标处（Accessibility 已授权）
  - **关键澄清**：之前"Mac 测试面板黑屏"不是解码 bug，是**后置摄像头被挡住**（手机扣在桌上）。
    诊断方法：`H264Decoder` 里有 env-gated 亮度探针（`IBRIDGE_DEBUG_FRAME_PROBE=1`）。
- **多语言**：iBridgeCore 统一 String Catalog（`Sources/iBridgeCore/Resources/Localizable.xcstrings`，en + zh-Hans），
  `IBLocale` 走 `Bundle.module`；跟随系统语言。Mac 首启/菜单栏、iOS 首页均已验证中英切换。
- **多 Mac 配对记忆**：见 `AGENTS.md` 的 "Multi-Mac pairing" 与
  `docs/superpowers/specs/2026-09-12-multi-mac-pairing-design.md`。
  首次 iPhone 弹窗授权 + TOFU token；已配对免弹窗；他人占用时 `busy` 退让不刷屏。

## F2 虚拟麦克风（2026-09-13，代码完成待装）

- 新增 `iBridgeMicDriver/`：`SharedRing.{h,c}`（C + stdatomic 无锁 SPSC 环，48k mono Int16，2s）、
  `iBridgeMicrophone.c`（CoreAudio HAL `AudioServerPlugIn`：驱动/设备/流三层，单**输入**设备
  48k/1ch/Float32，`DoIOOperation(ReadInput)` 从环读 Int16→Float32，render 路径零分配）、
  `MicRingBridge.{h,c}`（给 Swift 的不透明 C 桥）。
- `project-mac.yml` 新增 `iBridgeMicrophone`（`type: bundle`，`WRAPPER_EXTENSION: driver`，
  `CFPlugInFactories/Types` 指向 `iBridgeMicrophone_Create`），随 app 构建但不 embed。
- Mac app：`iBridgeReceiver/MicRingWriter.swift` + 桥接头 + `SharedRing.c/MicRingBridge.c`；
  `.audio` 收到 PCM 时同时 `micRing.write()`。
- 脚本：`scripts/install-mic-driver.sh` / `uninstall-mic-driver.sh`（装 `/Library/Audio/Plug-Ins/HAL` + 重启 coreaudiod，需 sudo）。
- **未验证**：需要 `sudo` 安装 + 在 App 里选「iBridge Microphone」；
  **并需确认沙盒 app 能 `shm_open`**（若被挡，得让 Receiver 非沙盒或改 XPC 桥）。
- 设计/行业调研见 `docs/superpowers/specs/2026-09-13-virtual-mic-hal-design.md`。

## V1.0 补齐批次 1（2026-09-13）

- **F7** 后台/锁屏提示：iOS `scenePhase` → 回前台 toast「视频在后台暂停，现已恢复」。
- **F6** 录制合轨：`StreamRecorder` 现在用 `AVAssetWriter` 写**单个 `.mov`**（H.264 + AAC），
  ffprobe 验证双轨；不再输出 `.wav`。
- **F4** iOS 演示模式：设置开关 + `DemoCameraView`（水印示例画面）+ 顶栏「演示」徽标；
  演示态不弹离线 alert，方便 App Review 无 Mac 体验。
- **F3** 手动 IP 兜底：iPhone 监听固定 8765（占用则动态），连接页显示 `IP:port`；
  Mac 菜单「手动连接…」输入 `host:port`。
- 仍在做：**F2 虚拟麦克风（CoreAudio HAL）**、**F1 Camera Extension 激活+验证**（见 `docs/RELEASE_PLAN.md`）。

## 菜单栏 logo / 报错 / 触控板卡顿（2026-09-13）

- 菜单栏图标从 SF Symbol 手机 → **monitor-buddy logo 模板图**
  （`iBridgeReceiver/Assets.xcassets/MenuBarIcon.imageset`，母版 `assets/menu-bar-icon.svg`，
  `rsvg-convert` 生成 18/36/54，`template-rendering-intent: template`）。录制时仍切 record 圆点。
- 不再把原始 `NWError` 显示到 UI（之前弹出 `POSIXErrorCode(rawValue: 54): Connection reset by peer`）；
  改为日志记原始错误 + 界面显示 `IBLocale.Error.iPhoneConnectionLost`。`IBStatusPill.disconnected` 不再渲染 reason
  （之前出现"离线 Connection lost"混排）。
- 触控板卡顿：cursor 的 `TimelineView` 之前 20Hz 常驻重绘 → 改为 idle 时 paused。

## e2e（2026-09-13）

- `./scripts/e2e-device.sh`：真机无头 e2e，构建+部署+跑全部 `IBRIDGE_E2E_*` 标志，断言 receiver 日志 marker。
  **10/10 通过**：握手 / 视频 / 音频 / 触控 / 按键 / 文件传输 / 剪贴板 / 应用切换 / 录制。
- `./scripts/test.sh`：74 单测 + 双端 build。
- UI 审查：模拟器 `IBRIDGE_E2E_SURFACE=trackpad|keyboard|camera` 预设界面后 `simctl io screenshot`。

## iOS UI 大修（2026-09-13）

- 顶栏收敛：状态胶囊 → 小图标 + 一个 `⋯` 溢出菜单（应用切换/发送/剪贴板/连接/设置）。
- 连接状态做成**居中 alert 卡片**（图标+标题+副标题+暗色 scrim），不再挤顶栏、不竖排。
- 修 FeatureDock 变高导致 `TouchpadScreen.dockClearance` 88 不够、⌃⌥⌘⇧ 压住"按住说话"的问题 → 148。
- KeyboardScreen 顶部加 56pt 避让顶栏；"Start typing…" 等补齐本地化。
- iOS 目录补 17 个 key（ConnectionSheet 的 Type/Domain/Status/Resolution/Bitrate/Codec、无障碍标签等）。
- e2e：`IBRIDGE_E2E_SURFACE=trackpad|keyboard|camera` 预设界面，便于模拟器截图审查。

## 语音改写选中文本（2026-09-13）

- `textCommand 0x14` + `TextTransform`（纯函数，本地）：大写/小写/首字母/去空格/去换行/项目符号。
- iPhone 语音说「改写为全部大写 / make this a bullet list」→ Mac 变换当前选区。
- Mac 用**合成 ⌘C 读选区 + ⌘V 写回**（保存/恢复用户剪贴板）。
- **重要**：沙盒 app **读不了别的 app 的 AX 树**（`kAXSelectedTextAttribute` 静默返回空），
  所以放弃了 AX 方案，改用剪贴板。这是踩过的坑。
- 单测覆盖 TextTransform + wire；**真机端到端未稳定验证**（手机锁屏/多实例陈旧 owner 干扰），
  建议在 TextEdit 里选中文字手动试一次。e2e：`IBRIDGE_E2E_TEXT_COMMAND=uppercase`（+10s）。

## 剪贴板互通 + 语音切应用（2026-09-13）

- **剪贴板**：`clipboardSet 0x13`（双向）。iOS AppSwitcherView 工具栏 → 发 iPhone 剪贴板；
  Mac 菜单栏 → 发 Mac 剪贴板。真机：`clipboard received from iPhone (21 chars)`。
- **语音命令**：`CaptureEngine.handleVoiceCommand` —— 说"打开 X"/"切换到 X"/"switch to X"
  会 `activateMacApp` 而不是输入文本。
- e2e flag `IBRIDGE_E2E_CLIPBOARD=1`。

## AirDrop 式文件传输 + 录制（2026-09-13）

- **发送到 Mac**：iPhone 顶栏上传图标 → 照片/视频（PhotosPicker）或文件（fileImporter）
  → wire `fileOffer 0x0F` / `fileChunk 0x10`(raw) / `fileComplete 0x11`
  → Mac 写入 `~/Downloads/iBridge/` 并**在 Finder 中显示**；`fileAck 0x12` 回进度。
- **录制**：Mac 菜单栏 Record（⌘R）→ `~/Movies/iBridge/recording-<stamp>.mov`（H.264，5s≈3-5MB）
  + `recording-<stamp>.wav`（16-bit PCM）；停止后 Finder 显示。
- **沙盒坑**：沙盒里 `FileManager` 把 `~/Downloads`/`~/Movies` 重定向到容器。
  解决：加 `files.downloads.read-write` + `assets.movies.read-write` 权限，并用
  `getpwuid` 取真实 home（`MacPaths`，见 `StreamRecorder.swift`）。
- 真机验证：`file saved /Users/edwinhao/Downloads/iBridge/…`；`.mov` 1920×1080 / 5.07s；
  `.wav` 473KB（开麦）。e2e flag：`IBRIDGE_E2E_SEND_FILE=1`（iOS）、`IBRIDGE_E2E_RECORD=1`（Mac）。

## App switcher（2026-09-13，借鉴 WhisPrompt / Codex Micro）

- Mac 通过 `appList`(0x0C) 广播运行中的 App；iPhone 顶栏网格图标打开切换表，
  点按发 `activateApp`(0x0E) → `NSRunningApplication.activate()`；可置顶（pin）。
- 键盘快捷键栏新增 `⌘⇥` / `⌘\`` / `⌃↑` / `⌃↓` / `⌘H` / `⌘Q`。
- 真机验证：`published 6 apps to iPhone` → `activated app 文本编辑`。
- e2e flag `IBRIDGE_E2E_SWITCH=<bundleid>`。

## 真机复测结果（2026-09-13）

- 多 Mac 配对**已真机验证**：
  - 首次：`clientHello (paired:false)` → `pending` →（AUTOPAIR 模拟点按）→ `accepted` → 视频/音频入站
  - 令牌持久化：不重装、关掉 AUTOPAIR 后重连 → `clientHello (paired:true)` → 直接 `accepted`（无需再授权）
  - 第二台 Mac（`open -n -a … --args -ibridge.mac.id second-mac-test`）→ `sessionReply: busy owner=MacBook Pro de Edwin`，
    约每 32s 一次慢重试（30s slow retry，**无 3s 重连风暴**），owner 不受影响（持续 4140+ 帧）

## 待做

- [ ] 相机扩展用户开关（系统设置 → 登录项与扩展 → 相机扩展 → 打开 iBridge）
- [ ] 虚拟麦克风（CoreAudio HAL 插件，非 AUv3）+ 真实 Opus 编码
- [ ] App Store 截图 / 提交、崩溃报告、VoiceOver、完整本地化收尾

## 真机 e2e 速查

```bash
# iOS：跳过 onboarding + 自动推流 + 自动配对（无头）
xcrun devicectl device process launch --device 866A1921-B588-59D5-A1B7-B266103B2E49 \
  --terminate-existing \
  --environment-variables '{"IBRIDGE_AUTO_START":"1","IBRIDGE_AUTOSTREAM":"1","IBRIDGE_E2E_MIC":"1","IBRIDGE_E2E_AUTOPAIR":"1"}' \
  com.ibridge.iBridgeCapture

# Mac 日志
log stream --predicate 'subsystem == "com.ibridge"' --info --style compact

# 门禁
./scripts/test.sh              # 62 测试 + 双端 build
```

env flags：`IBRIDGE_AUTO_START`（跳 onboarding）、`IBRIDGE_AUTOSTREAM`（自动推流）、
`IBRIDGE_E2E_MIC`、`IBRIDGE_E2E_INPUT`（脚本化触控+打字）、`IBRIDGE_E2E_VOICE`、
`IBRIDGE_E2E_AUTOPAIR`（自动批准配对）。

## 环境注意

- 真机 build：`DEVELOPMENT_TEAM=5XNDF727Y6`（不是 project-*.yml 里的 DDG3CJL762）。
- Mac 端重签/换路径会让 Accessibility 失效；在**系统设置 → 辅助功能**里重新打开
  `/Applications/iBridgeReceiver.app`（本次重部署后授权保留，验证过）。
- iOS 锁屏会挂起 Bonjour 监听 → "Connection reset by peer"；测试时设自动锁定为永不。
- `timeout` 命令 macOS 没有；别用它包 `dns-sd`。
