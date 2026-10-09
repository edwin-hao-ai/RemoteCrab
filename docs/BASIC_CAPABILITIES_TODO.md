# RemoteCrab — 基础能力 TODO（主跟踪文档）

> 建立于 2026-10-09。来源是一轮**纯代码审计**（5 个并行深度扫描 + 人工复核），
> 不是文档推断。每一条结论都带 `file:line`。
>
> **这个文件是本轮长会话的唯一进度真相。** 每完成一步，把对应 `- [ ]` 改成
> `- [x]`，并在 §9 进度日志追加一行（日期 + 做了什么 + 验证数字）。
> 不要只在聊天里说"做完了"——勾选才是完成。

---

## 0. 铁律（每次动手前先读一遍）

1. **先精读，再改。** 每个条目的第一步都是"精读 <文件>"。读完把
   `file:line` 写进进度日志，再决定怎么改。**不读就改 = 引入新 bug。**
2. **改之前先写影响面。** 每个条目都列了"影响面"字段。动手前把它补全：
   列出被改函数的**所有调用者**和共享状态，说明每一处受什么影响。
   有可信的副作用 → 要么证明不会发生，要么同一次提交里一起处理。
   （AGENTS.md 规则 4。）
3. **一个改不动的现象，缺的是测量不是编辑。** 先取证（真机日志、
   `scripts/` 探针、数字），再改。（AGENTS.md 规则 3。）
4. **不许叠 bug-fix。** 同一个问题第二次修复失败 → 停下，回到步骤 1 重新取证。
5. **门户必须能证伪。** 新断言要在**错误**的输入上失败，否则它是空过的
   （AGENTS.md lessons 111/149）。
6. **不破坏已上线的东西。** 这个项目基本完善，任何改动都要跑
   `./scripts/test.sh` + 两个 target 构建 + Windows 套件；UI/真机的事还要真机验。
7. **改完记录。** 勾选 + 进度日志 + 必要的 handoff。

### 判定图例

| 判定 | 含义 |
|---|---|
| ✅ REAL | 代码实现，且能找到调用路径 |
| 🟡 PARTIAL | 部分实现 / 有已核实的空洞 |
| ❌ ABSENT | 全仓搜索无命中（已注明搜了什么） |
| ❓ UNKNOWN | 静态读不出，只能真机测量 |

---

## 1. 结论速览（审计矩阵，2026-10-09）

| 能力 | 判定 | 最强证据 |
|---|---|---|
| 摄像头采集 + H.264 硬编 | ✅ | `H264Encoder.swift:106-141` |
| iOS 4K 采集/编码 | ✅ | `CaptureEngine.swift:1338,1368-1370` |
| Mac 虚拟摄像头 4K | ❌ 写死 1080p | `IBCameraDevice.swift:35-36`，`CameraExtensionStream.swift:100-101` |
| 4K 端到端测试 | ❌ | 无 capture→decode→feed→record 的 4K 测试 |
| Windows 4K 30fps | 🟡 ~15fps | `docs/WINDOWS-4K-FEASIBILITY-2026-10-05.md:34` |
| 4K 码率供给 | 🟡 16Mbps 天花板截到 43% | `VideoEncodingPolicy.swift:64` |
| 麦克风 + Opus（单声道） | ✅ | `MicrophoneEncoder.swift:168-193`，`IBOpusCodec.swift:49,61` |
| 扬声器播放（立体声 PCM 平面） | ✅ | `SpeakerPlayer.swift:97-100` |
| AEC / AGC / 降噪 | ❌ | 全仓零命中；mic/speaker 由 `AudioModeArbiter` 互斥（`:61-64`） |
| 触控板 / 键盘注入 | ✅ | `CGEventInjector` |
| Apple Pencil | ❌ | 无 `UITouch.TouchType`/`allowedTouchTypes`/pressure/azimuth |
| Bonjour 发现 | ✅（iPhone 无 TXT） | `CaptureEngine.swift:1612-1616` |
| 直连 IP 回退 | ✅（Mac 端口写死 8765） | `ReceiverSession.swift:1518,1528` |
| AWDL 点对点共存 | 🟡 能自愈但不优先 WiFi | `ReceiverSession.swift:1356-1357,1702-1738` |
| iOS listener 拆除日志 | ❌ 只有启动日志 | `CaptureEngine.swift:1050-1079,1674-1675` |
| 半开连接侦测 | ✅ | `CaptureEngine.swift:3805-3815`，`ReceiverSession.swift:2136-2139` |
| 对端认证（HMAC 挑战-应答） | ✅ | `PeerAuth.swift:50-123` |
| 传输加密（内容保密） | ❌ 明文 TCP | `CaptureEngine.swift:1600`，`PeerAuth.swift:24-27` |
| Keychain 存 token | ❌ UserDefaults / 明文 JSON | `MacPairingStore.swift:551-563` |
| 崩溃上报 | ❌ | `diagnostics.rs:85-101`（仅 Windows 本地） |
| 结构化遥测 | ❌ | 无 SDK、无上传路径 |
| 真实端到端延迟 | ❌ 只有 ping RTT | `IBLatencyTracker.swift:88-106` |
| release 实际码率/fps | ❌（env-gated） | `H264Encoder.swift:408-442` |
| 码率自适应 / 拥塞控制 | ❌ 固定 `Quality=0.75` | `VideoEncodingPolicy.swift:37` |
| `UIBackgroundModes:[audio]` | ✅（文档说没有，是文档错） | `Info.plist:54-57`，`project-ios.yml:74-75` |
| 锁屏检测 | ❌ | 全仓零命中 |
| 打断恢复（mic/speaker/keepalive） | ❌ 只有语音听写有 | `VoiceRecognizer.swift:562-573` |
| 热 / 低电 / 内存压力 | ❌ | 全仓零命中 |
| Mac 自动更新 | ✅ Sparkle | `project-mac.yml:84` |

---

## 2. 工作流 A：4K 的真实性

### A1. ✅/❌ 决定 4K 的对外口径（先决策，再动手）
- **现状**：4K 只出现在 Mac 预览窗口和录制文件；虚拟摄像头（Zoom/OBS/FaceTime
  真正消费的）写死 1080p；Windows 解码 ~15fps；链路 16Mbps 天花板。
  文案（`docs/campaign/*`）已把 4K 当 Pro 卖点。
- **步骤**：
  1. 精读 `IBCameraDevice.swift`、`CameraExtensionStream.swift`、
     `CameraSinkFeeder.swift`、`VideoEncodingPolicy.swift`。
  2. 决策三选一：**(a) 真做 4K**（A2+A3+A4）／**(b) 降级为"1080p 高清"**／
     **(c) 4K 只在"录制/预览"口径**。
  3. 决策写入 §9，并同步 §8 文案条目。
- **影响面**：只影响对外承诺与优先级，不改代码。
- **验证**：决策本身。

### A2. Mac 虚拟摄像头支持多分辨率（若选 a）
- **现状**：`IBCameraDevice.width/height` 写死 1920×1080；`CameraExtensionStream`
  只广告一个 BGRA 格式；`CameraSinkFeeder` 的 pool + draw 写死 1080p（aspect-fit）。
- **步骤**：
  1. 精读 `RemoteCrabCameraExtension/*` 与 `RemoteCrabReceiver/CameraSinkFeeder.swift`，
     理清 source/sink 两个 stream、format 广告、pool buffer 的生命周期。
  2. 设计：按输入分辨率**动态**广告格式（或广告固定 1080p + 允许 4K 源下采样）。
  3. ⚠️ 精读部署规则（AGENTS.md："改扩展必须 bump `CFBundleVersion` + 重新批准；
     换签名会打掉 Accessibility/扩展授权"）。
- **影响面**：相机扩展、系统扩展注册/批准、`release-mac.sh` 签名流程、
  `CameraSinkFeeder` 的 flow-control（one-in-one-out，`readyToEnqueue` 初始 true）。
- **验证**：真机在 Zoom/QuickTime 里看到 4K 选项并取到非零像素
  （参考 CMIO handoff 的像素探针）。

### A3. 抬 `ceilingBps` 并让 4K30 拿到足够码率（若选 a）
- **现状**：`ceilingBps = 16_000_000`（`VideoEncodingPolicy.swift:64`），4K30
  请求 ~37Mbps 被截到 43%。测试
  `testTheCeilingIsReachableButOnlyByGenuinelyLargeFormats` 钉住它。
- **步骤**：
  1. 精读 `VideoEncodingPolicy.swift` + `VideoEncodingPolicyTests.swift`。
  2. 决定新上限（考虑 HOME WiFi 承载力 + 手机热），并加/改测试。
  3. 实测 4K30 的**实际**码率（`REMOTECRAB_E2E_BITRATE=1`，见 D2）。
- **影响面**：带宽、手机发热/降频、Windows 解码压力、家庭路由。
- **验证**：真机实测码率达到目标，且不触发过热/丢帧。

### A4. Windows 4K 解码的"设备相关性"测量矩阵
- **现状**：单机实测 ~15fps，瓶颈=OpenH264 软件解码 + `to_bgra`。
- **步骤**：
  1. 精读 `windows/crates/rc-render/src/decoder.rs`、`window.rs`、
     `examples/bench_decode.rs`。
  2. 在**至少 2-3 台不同 PC**（或不同 CPU）上跑 `bench_decode`，记录
     `feed_nal`/`to_bgra`/合计/fps，判断是否随 CPU 缩放。
  3. 评估 GPU 解码路线（Media Foundation / DXVA）——项目**未评估过**（feasibility §待定）。
  4. 结论：4K 在 Windows 上现实可达的帧率是多少。
- **影响面**：新建/替换解码器是 Windows 侧大改，需先出可行性结论。
- **验证**：多机数字表（谁测的、什么 CPU、什么输入）。

### A5. 修启动路径的分辨率/编码器不对称（独立真 bug）
- **现状**：启动时编码器与 metadata 按**请求的预设**建立
  （`CaptureEngine.swift:564-566` + `:592-595`），但
  `configureCaptureSession` 在不支持时**静默回退**（`:1540-1545`）。运行时路径
  反而正确（`:1358-1361`）。→ 启动选 4K 且设备不支持时，编码器 3840×2160 吃更小采集。
- **步骤**：
  1. 精读 `CaptureEngine.swift:548-597` 与 `:1536-1546`。
  2. 让启动路径也"先探测 `canSetSessionPreset`，再据**实际**预设决定编码器 dims 与 metadata"。
  3. 加测试（纯逻辑部分可抽到 Core）。
- **影响面**：启动配置顺序、metadata、编码器尺寸、`configureCaptureSession` 的返回值。
  注意注释 `:561-563` 说"编码器必须先于 session 配置存在"——不能破坏这个约束。
- **验证**：单测 + 真机选一个不支持的预设，日志与 metadata 一致。

### A6. 4K 真机端到端验证
- **现状**：❓ 无任何 4K 端到端测试。
- **步骤**：
  1. 真机选 4K，Mac 预览/录制，Windows 预览，各抓一帧看分辨率与观感。
  2. 记录协商、metadata、SPS 尺寸、实际 fps/码率。
- **影响面**：无（验证）。
- **验证**：三端数字 + 像素。

---

## 3. 工作流 B：网络连接确定性（含两种传输模式）

### B1. iOS listener 拆除日志（一行，解锁所有排障）
- **现状**：启动有三条日志（`CaptureEngine.swift:1021,1631,1667`），
  `stopStreaming()` 与 `.cancelled` 分支**无任何日志**（`:1050-1079,1674-1675`）。
  这正是 §7「listener 有时没起来」悬着的原因（无法区分"没起"和"起了又停"）。
- **步骤**：
  1. 精读 `startListener` / `handleListenerState` / `stopStreaming`。
  2. 在 `stopStreaming` 与 `.cancelled`/`.failed` 分支加 `Forensic.log("[hs] listener stopped/teardown …")`
     （**release 也可见**？见 D 决策；至少 e2e 可见）。
  3. 真机跑一次「连接→断开→再连接」，日志能读出完整生命周期。
- **影响面**：极小（只加日志）。注意 `Forensic` 是 DEBUG/env-gated，确认 e2e 下可见。
- **验证**：真机日志同时出现 started + stopped。

### B2. 修复直连回退端口不一致
- **现状**：iOS 8765 被占就退到**随机端口**（`CaptureEngine.swift:1606-1611`）；
  Mac 回退**写死 8765**（`ReceiverSession.swift:1518,1528`）。→ 随机端口时 Mac 直连永远失败。
- **步骤**：
  1. 精读两端端口逻辑 + `IBPhoneHello`/metadata 是否带实际端口。
  2. 决定修法：(a) iOS 优先固定端口失败即报错不放随机端口；或
     (b) 把实际监听端口通过 presence/TXT/hello 传给 Mac。
- **影响面**：回退路径、手动连接提示（`wifiAddress`/`listeningPort`）、多实例监听冲突。
- **验证**：单测 + 真机在 8765 被占场景下仍能直连。

### B3. 处理 NWConnection `.waiting`
- **现状**：iOS（`:1676`、`:2446`、`:3572`）与 Mac（`:1794`、`:2379`）都未处理
  `.waiting`，卡住只能等 watchdog。
- **步骤**：
  1. 精读所有 `stateUpdateHandler` 的 switch 分支。
  2. 决定 `.waiting` 是否该重试/换地址（结合 `DialWatchdogPolicy`）。
- **影响面**：连接状态机、用户状态文案。别把 `.waiting` 当成失败直接断开。
- **验证**：单测 + 真机模拟不可路由端点。

### B4. 两种传输模式（WiFi vs AWDL）的优雅协作 ★重点
- **现状**：两端**始终开 AWDL**（`CaptureEngine.swift:1601`，
  `ReceiverSession.swift:1577`）；iPhone 在 if 17/if 18/if 13 同时广播；
  Mac `NWBrowser` 不按手机稳定 id 去重（`BonjourBrowser.swift:79-85`），
  `handleDiscovered` 取 `phones.first(...)` 不优先 WiFi（`:1356-1357`）；
  靠 8s watchdog + 一次性 `retryWithoutPeerToPeer` 自愈（`:1702-1738`）。
  iPhone `_remotecrab._tcp` **不发布 TXT**（`CaptureEngine.swift:1612-1616`），
  所以 Mac 无法辨认接口/身份。
- **步骤**：
  1. 精读 `BonjourBrowser.swift`、`ReceiverSession.handleDiscovered/connect/tcpParameters`、
     `DialWatchdogPolicy.swift`、`PeerToPeerRetryLatch.swift`、`DirectDialAddress.swift`、
     `CaptureEngine.startListener/handleListenerState`。
  2. 真机取证：同一 WiFi 下 `dns-sd -L` 看手机从几个接口广播、Mac 实际连的是哪个
     （connection state 日志 / remoteEndpoint）。
  3. 设计（提案，待批）：
     - iPhone 在 `_remotecrab._tcp` 上发布 **TXT**（至少 `id`/`ifaces`/`port`），
       使 Mac 能按稳定 id 去重并分辨接口；
     - `BonjourBrowser` 改 `.bonjourWithTXTRecord`；
     - `handleDiscovered` **优先可路由的 WiFi 端点**，AWDL 仅作兜底；
     - 直连回退的 gate 从"发现为空"改成"发现里没有**可路由**的"。
  4. 每改一处，先写影响面（配对、id key、tokenStore 按 name 的键、`current`）。
- **影响面**：⚠️ 大。`tokenStore` 用手机 **name** 作键（`currentTokenKey = phone.name`），
  改 id 方案会牵动配对/token/`phoneNameByIP`。必须与配对测试一起改。
- **验证**：真机在"有 WiFi / 只有 AWDL / 热点"三种场景下都能稳定连上，
  且优先走 WiFi（日志数字）。

### B5. 直连回退 gate 与去重
- **现状**：`startFallbackLoop` 的 gate 是"`discovered` 里没有已配对手机"
  （`ReceiverSession.swift:1489`），AWDL 让"空"几乎不发生 → 直连路径少用。
  `fallbackCandidates` 已去重（`:1513-1514`）。
- **步骤**：与 B4 一起设计；确认"可路由"判据。
- **影响面**：回退循环频率、与 phone-initiated 的竞态（`:1525` 已跳过）。
- **验证**：真机。

### B6. 连接医生界面（把失败变成可执行的下一步）
- **现状**：失败只给状态行，没有 Bonjour 状态 / 最后错误 / 一键重试的汇总界面。
  （AGENTS.md 规则 1 一直要求"状态行要说清为什么 + 下一步"。）
- **步骤**：
  1. 盘点现有状态源：`connectionState`、`failureReason`、`lastError`、
     `discovered`、listener 状态、ping。
  2. 设计一个最小面板（Mac 优先）显示：发现/监听/认证/链路各阶段 + 一个动作。
- **影响面**：Mac 菜单栏/设置 UI；iOS 连接 sheet。
- **验证**：真机在"没 WiFi""Bonjour 被墙""配对被拒"三种失败下各看到可执行提示。

### B7. Swift 侧跨连接/重启测试
- **现状**：`PairingHandshakeE2ETests.swift:14`、`BonjourEndToEndTests.swift:18`
  都只做**一次**连接；跨连接/重启覆盖只在 Rust（`rc-net/tests/session.rs`）。
- **步骤**：
  1. 精读这两个 E2E 测试，找可复用的 TCP 测试脚手架。
  2. 加"第二次连接 / 断线重连 / 重启后 token 仍在"的测试。
- **影响面**：测试层。
- **验证**：新测试在正确代码上绿、在故意破坏上红。

### B8. 重连退避统一
- **现状**：iOS 1→2→4→5s；Mac 固定 3s；Windows 固定 3s（`/24` 扫描才几何退避）。
- **步骤**：精读三处；决定是否统一（低优先，可能故意不同）。
- **影响面**：三端。确认不是有意差异后再动。
- **验证**：真机切网/切电脑。

---

## 4. 工作流 C：后台 / 锁屏 / 打断连续性

### C1. 锁屏存活性的真机测量 + 断言
- **现状**：❌ 无锁屏检测；存活完全押在 `.playback` 静音保活上
  （`BackgroundKeepAlive.swift:37-67`），代码无任何断言。
- **步骤**：
  1. 精读 `BackgroundKeepAlive.swift`、`CaptureEngine.applyKeepAlive`、
     `ContentView` 的 scenePhase 处理。
  2. 真机测：流媒体中手动锁屏 → 看连接/listener/mic 是否续；
     记录（`[hs] listener stopped` 之类，依赖 B1）。
  3. 把观测固化为断言/日志。
- **影响面**：只加观测；改动保活机制风险高，单独评估。
- **验证**：真机数字。

### C2. mic / speaker / keep-alive 的打断恢复
- **现状**：❌ 只有语音听写有 `interruptionNotification`
  （`VoiceRecognizer.swift:562-573`）；mic/speaker/keepalive **没有**
  interruption/routeChange/ConfigurationChange 观察者。
- **步骤**：
  1. 精读 `MicrophoneEncoder`、`SpeakerPlayer`、`BackgroundKeepAlive` 的
     session 生命周期与 `AudioModeArbiter` 的交接（含 lesson 161：
     deactivate→reactivate 同 runloop 会让 `setActive` 失败 561017449）。
  2. 设计统一的 `AVAudioSession` 打断/路由恢复（集中在一个地方）。
- **影响面**：⚠️ 共享 `AVAudioSession`，牵动 mic/speaker/keepalive/听写四方。
  必须按模块注释的 `deactivateSession:` 语义走。
- **验证**：真机来电/Siri 打断后 mic/speaker 能恢复。

### C3. `.inactive` 状态处理
- **现状**：两个 scenePhase observer 都不处理 `.inactive`
  （`RemoteCrabCaptureApp.swift:30-34`、`ContentView.swift:307-327`）。
  来电横幅/Siri 只触发 `.inactive` 时**什么都不运行**。
- **步骤**：精读两处；决定 `.inactive` 该做什么（大概率只用于 C2 的恢复触发）。
- **影响面**：与 C2 耦合。
- **验证**：真机。

### C4. 相机特性关闭时是否停硬件（隐私/一致性）
- **现状**：切后台只关"特性"（`ContentView.swift:320-322`），帧在发送处丢
  （`CaptureEngine.swift:4261`），`stopRunning()` 不在换挡路径；回前台即使相机
  关着也重启硬件（`:1183-1189`）。
- **步骤**：精读相机 start/stop 全路径；决定"特性关 = 硬件停"。
- **影响面**：相机会话生命周期、预览层、watchdog。别让重启逻辑打架。
- **验证**：真机（相机关闭时指示灯应灭）。

### C5. 热 / 低电 / 内存压力处理
- **现状**：❌ 全仓零命中。
- **步骤**：
  1. 精读编码/流媒体循环，找降级点（降分辨率/降帧率/停流）。
  2. 设计对 `thermalState`/`isLowPowerModeEnabled`/`didReceiveMemoryWarning` 的响应。
- **影响面**：与 A3 码率、用户体验。默认策略要保守（先降质不粗暴断流）。
- **验证**：真机（可用 `xcrun simctl`/`ProcessInfo` 模拟低电较难，需真机烫机）。

---

## 5. 工作流 D：可观测性（让自己看得见）

### D1. 崩溃上报（先决策：自建 vs SDK，隐私优先）
- **现状**：❌ iOS/macOS 无崩溃处理；Windows 仅本地 panic 日志
  （`diagnostics.rs:85-101`）。
- **步骤**：
  1. 精读现有 `Forensic`、`os_log`、`diagnostics.rs`。
  2. 决策：MetricKit（系统、隐私友好）+ 本地文件？还是最小自建上传？
     注意产品"无云"承诺——上报必须**显式、可选、脱敏**。
  3. 只在决策通过后实现。
- **影响面**：隐私政策、审核问卷（Data Not Collected 可能变）、品牌承诺。
- **验证**：制造一次崩溃，能拿到报告。

### D2. release 下的实际码率 / fps / 丢帧埋点
- **现状**：实际码率只在 `H264Encoder.recordRateProbe`（env-gated，
  `H264Encoder.swift:408-442`）；接收端**完全不测**入站 fps/码率。
- **步骤**：
  1. 精读 `H264Encoder` 的帧/字节计数、`ReceiverSession` 的收帧点。
  2. 加轻量计数（发送端输出字节/fps；接收端入站帧/fps/丢帧），
     仅在需要时展示（ControlPanel），不新增加载。
- **影响面**：性能（要够轻）、UI。
- **验证**：数字与外部工具一致。

### D3. 真实端到端延迟
- **现状**：❌ `latencyHistory` 只是 ping RTT（`IBLatencyTracker.swift:88-106`）；
  metadata 无时间字段（`IBProtocol.swift:48-71`）。
- **步骤**：
  1. 精读 `IBStreamMetadata`、`IBPingProbe`、编码/解码时间戳。
  2. 设计 v1：metadata 或帧头带 capture 时间戳，接收端减本机时钟得 e2e 延迟。
  3. 用可靠时钟（避免跨设备时钟漂移的假数）。
- **影响面**：wire 协议（加字段必须 `#[serde(default, skip_serializing_if)]` 兼容旧端，
  AGENTS.md 规则 2）；三端。
- **验证**：真机数字，能证伪（暂停/恢复时变化合理）。

---

## 6. 工作流 E：音频质量

### E1. 决策 + 实现 AEC / AGC / 降噪
- **现状**：❌ 全仓零命中；mic 与 speaker 由 `AudioModeArbiter` **互斥**
  （`:61-64`），不是回声消除。
- **步骤**：
  1. 精读 `MicrophoneEncoder`、`SpeakerPlayer`、`AudioModeArbiter`、
     `AVAudioSession` 用法。
  2. 评估 `AVAudioSession` voice-processing（`.voiceChat`/voiceProcessing IO）
     是否可用、对延迟/音质的影响。
  3. 决策是否放开 mic+speaker 同时开（当前互斥是产品决策）。
- **影响面**：⚠️ 共享 session、延迟、与扬声器模式的互斥逻辑。
- **验证**：真机通话/会议场景主观 + 客观（回环测试）。

### E2. 文档纠正：`RELEASE_READINESS.md` 与代码矛盾
- **现状**：`docs/RELEASE_READINESS.md:79` 说"`UIBackgroundModes` 在代码库中不存在"，
  但 `Info.plist:54-57`/`project-ios.yml:74-75` 明确有 `[audio]`。
- **步骤**：修正该文档，指向真实代码。
- **影响面**：无代码。
- **验证**：文档与代码一致。

---

## 7. 工作流 F：传输安全（先决策）

### F1. 传输加密（内容保密）
- **现状**：❌ 纯 TCP 明文（视频/音频/按键/剪贴板）；`PeerAuth` 只做认证
  （`PeerAuth.swift:24-27` 自己写明"does not encrypt anything"）。
- **步骤**：
  1. 精读 `tcpParameters`（两端）、`PeerAuth`、`IBWire`。
  2. 决策：`NWProtocolTLS`/DTLS 是否可套在当前 NWConnection/NWListener 上；
     或应用层加密（CryptoKit）后是否值得（性能/复杂度）。
  3. 注意旧端兼容（协议加能力协商）。
- **影响面**：⚠️ 协议、性能、三端、审核出口合规声明。
- **验证**：抓包确认不可读 + 功能不退化。

### F2. token 迁 Keychain
- **现状**：❌ `MacPairingStore.swift:551-563`（UserDefaults JSON）、
  `ReceiverSession.swift:1067-1077`（UserDefaults）、`token.rs:478-490`（明文文件）。
- **步骤**：精读三处存储；设计迁移（旧格式必须能读，AGENTS.md 规则 2）。
- **影响面**：登录时数据迁移，做错会清空用户配对。
- **验证**：旧格式加载测试。

---

## 8. 工作流 G：Apple Pencil（重要卖点）

### G1. Pencil 支持审计 + 设计
- **现状**：❌ 无 `UITouch.TouchType`/`allowedTouchTypes`/pressure/azimuth；
  `TouchSurface.swift:528` 用 `majorRadius` 做 force-click 启发——Pencil 的
  `majorRadius` 语义不同，会被误判。
- **步骤**：
  1. 精读 `RemoteCrabCapture/Input/TouchSurface.swift` 全部触摸处理，
     以及 iOS 输入编码 `TouchEvent`（`IBEvents.swift`）与 Mac 注入
     `CGEventInjector`。
  2. 决策：Pencil 用来做什么？
     - 当**精确指针**（映射到 Mac 光标，压感可选映射为压力/绘图）？
     - 在**投屏**上做**批注/绘画**（PencilKit）？
     - 与触控板手势如何区分（Pencil vs 手指）？
  3. 设计事件扩展（wire 新字段必须向后兼容）。
  4. 评估 hover / 压感 / 倾斜是否能跨平台传递（Mac 端 CGEvent 无原生压感——
     可能需要私有 API 或降级）。
- **影响面**：⚠️ `TouchSurface`（触控板+键盘 mini-pad+投屏共用）、wire 协议、
  Mac/Windows 注入。改动会波及所有触摸界面——必须逐界面回归。
- **验证**：真机 + Pencil，逐界面确认不破坏手指交互。

### G2. 网站更新 Pencil 卖点
- **依赖**：G1 的结论（**先有实现再宣传**，别重演 4K 的"宣传领先于实现"）。

---

## 9. 进度日志

| 日期 | 条目 | 做了什么 | 验证数字/证据 |
|---|---|---|---|
| 2026-10-09 | 审计 | 5 路代码审计 + 人工复核，建立本文档 | 见 §1 矩阵 |

---

## 10. 待办顺序（建议）

1. **B1**（一行日志，解锁排障）→ **C1**（真机锁屏测量）→ **B4/C2** 取证。
2. **A1** 决策 4K 口径 → 据决策走 A2-A6 或 §8 文案。
3. **B4** 两种传输模式协作 → **B2/B3/B6**。
4. **D1/D2/D3** 可观测性 → 让后续所有修复可测量。
5. **E1/F1/F2/C5** 较大改动，各自立项。
6. **G1** Pencil（重要卖点，但改动面大，独立会话）。
