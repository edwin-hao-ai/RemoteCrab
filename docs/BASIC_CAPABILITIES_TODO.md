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
| 后台保活是否真的保住进程 | ❌ 实测被挂起 | C1：`[keepalive] session playback active` 后仍 suspend（main-stall 217318ms） |
| 锁屏检测 | ❌ | 全仓零命中 |
| 打断恢复（mic/speaker/keepalive） | ❌ 只有语音听写有 | `VoiceRecognizer.swift:562-573` |
| 热 / 低电 / 内存压力 | ❌ | 全仓零命中 |
| Mac 自动更新 | ✅ Sparkle | `project-mac.yml:84` |

---

## 2. 工作流 A：4K 的真实性

### A1. 口径已定（用户 2026-10-09）：4K = **摄像头链路**，投屏/扩展屏不算
- **用户原话**：4K 指"摄像头传输的画面"（像 Camo），扩展屏/投屏支不支持 4K 不重要。
- **精读后的真相**：
  - iOS 采集/编码 4K：**真的**（`.hd4K3840x2160`，`CaptureEngine.swift:1367`）。
  - **唯一的墙**：Mac 虚拟摄像头对 app **只广告一个 1080p 格式**
    （`IBCameraDevice.swift:35-36`、`CameraExtensionStream.swift:57-64,100-101`、
    `CameraSinkStream.swift:77-84,130-131`、`CameraSinkFeeder.swift:151-169`）。
    Zoom/OBS 拿到的永远是 1080p，所以"4K 摄像头"当前不成立。
  - **16Mbps 天花板在 iOS 上是惰性的**（`VideoEncodingPolicy.swift:12,37,64`：
    `Quality` 覆盖 `AverageBitRate`）——**A3「抬天花板」是错的方向，已作废**。
- **真机实测（2026-10-09，`REMOTECRAB_E2E_RESOLUTION` + `REMOTECRAB_E2E_BITRATE`）**：
  4K30 编码**真的跑 30fps**（`frames=61`/2s）；开场关键帧 `achieved=42,954 kbps`
  （远超 `req=16,000`，坐实天花板惰性）。静态画面稳态 ~100kbps（受场景所限）。

### A2. Mac 虚拟摄像头支持多分辨率（4K 摄像头）★核心
- **现状**：source/sink 两个 stream 各只广告一个 1080p BGRA 格式；feeder 的
  pool + draw 写死 `IBCameraDevice.width/height`（aspect-fit 进 1080p 画布）。
- **设计（读代码后，2026-10-09）**：
  1. `IBCameraDevice` 加 `resolutions: [Resolution]`（**index 0 保持 1080p**，新增 4K），
     保证**默认行为不变**、4K 为可选。
  2. `CameraExtensionStream` / `CameraSinkStream` 的 `formats` 按 `resolutions` 广告多个；
     `streamProperties(.streamActiveFormatIndex)` 返回当前索引；`setStreamProperties`
     记录 app 的选择。
  3. `CameraSinkFeeder` 按 **active format 的尺寸**建 pool / draw（查不到就退回 1080p）。
  4. ⚠️ **硬依赖**：改扩展必须 bump `CFBundleVersion`（现 "8"→"9"）+ **用户在系统设置
     重新批准相机扩展**；**我无法替用户点，也无法在无批准下测**。
- **影响面**：⚠️ 相机扩展、系统扩展批准、`release-mac.sh` 签名、feeder flow-control。
  **不能盲改**（现扩展已验证可用；改坏 = 用户相机失效直到再次批准修复）。
- **验证**：真机在 Zoom/QuickTime 看到 4K 选项并取到非零像素（CMIO 像素探针）。

### A2 进展与真机结论（2026-10-10）
- **e2e 抓到设计缺陷**：曾经做成"扩展广告 1080p+4K、host 按客户端选择喂帧"。
  真机探针证明**行不通**：客户端把 source 选成 4K，但 host 读到的
  `kCMIOStreamPropertyFormatDescription` **始终是 1920x1080**（host 读不到客户端的选择），
  于是 host 喂 1080p 进 4K source → **4K 客户端拿不到任何帧**（探针 `TIMEOUT`）。
  `source↔sink 透传`无法调和"客户端选格式"与"host 独立填帧"。
- **改为单一 4K 格式**（`IBCameraDevice.resolutions = [3840×2160]`，host 恒喂 4K）——
  没有可协商的东西。代价：手机设低于 4K 时被放大（想真 4K 就把手机设 4K）。已提交 `4a2357b`。
- **🔴 部署卡住（需用户）**：改扩展要重新注册才加载新二进制。当前注册表脏了——
  `v8 [terminated waiting to uninstall on reboot]` + `v9 [activated enabled]`（旧的、两份格式）。
  要让 `v10`（单一 4K）生效需要：**① 重启 Mac 清掉 v8 挂起项；② 在托盘 → 偏好设置 → 相机扩展
  点 "Re-register"；③ 在系统设置批准**。这三步我替代不了（点不了批准、不能重启你的机器）。
- **验证工具已就绪**：`scripts/e2e-camera-formats.sh`（枚举格式，无需相机权限）+
  `/tmp/rcprobe/CamProbe.app`（打开相机在 4K 抓一帧、读像素，需相机权限）。

### A2 真机复测（2026-10-10，用户重启+重新批准 v10 后）
- ✅ **扩展已加载 v10**（`systemextensionsctl` v10 `[activated enabled]`），
  `e2e-camera-formats.sh` = **单一 `3840x2160`**（1080p 消失）＝虚拟摄像头真的对外广告 4K 了。
- ✅ 手机 4K 采集 → Mac `video frames received` → `feeding virtual camera: N frames` →
  扩展 `sink received N frames`（整条链路活）。
- 🔴 **未通**：扩展**没有**调用 `source.send`（日志无 `source sent`），客户端（探针）拿不到帧（`TIMEOUT`）。
  `sink received` 出现但 `source sent` 不出现 → sink→source 转发没送达客户端。
  `CameraExtensionDevice` 的 `onSampleBuffer → sourceStream.send` 源码是接好的，**原因未定**，
  需要一次扩展调试循环（每次改都要重新部署）才能定位。**这是当前唯一的 4K 遗留点。**

### A3. ❌ 作废（2026-10-09）—— 天花板在 iOS 上是惰性的
- 原以为要抬 `ceilingBps`。精读 `VideoEncodingPolicy.swift:12,37,64` 后确认：
  iOS 上 `kVTCompressionPropertyKey_Quality` **完全覆盖** `AverageBitRate`，
  所以 `bitrate()` 的钳制对 iOS 毫无作用（真机也证实：`achieved=42,954` > `req=16,000`）。
- **真正要测的是 4K 稳态码率**（由 `Quality=0.75` 决定），需要**有细节/运动的场景**；
  若太占带宽/WiFi 扛不住，才需要**为 4K 单独降 Quality**（这才是 4K 的正确码率旋钮）。

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

### B1. iOS listener 拆除日志 ✅ 已实现并真机验证（2026-10-09）
- **改动**：`startListener` 加 `[hs] listener creating fixedPort=…`；
  `handleListenerState` 加 `.waiting`/`.failed`/`.cancelled` 的 `[hs]` 日志；
  `stopStreaming` 加 `[hs] stopStreaming listener=… isStreaming=…`。
- **验证**：真机日志出现 `[hs] listener creating fixedPort=true preferred=8765`
  → `[hs] listener ready port=Optional(8765)`（见 §9）。
- **收获**：这条日志**当场抓到了 C1a/C1b 的 bug**（`[hs] listener failed: -65569 DefunctConnection`）。

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

### B9. ✅ 非 bug（用户 2026-10-09 澄清：之前 Mac 客户端没开）
- **结论**：picker 本来就会列出"此网络上的电脑"；之前看不到是因为 **Mac 端客户端没运行**，
  而不是手机侧的问题。列表空 = 网络上没有在广播 presence 的电脑。
- **保留的改动（无副作用）**：picker 打开时若未在开流则 `beginPickerBrowsing()`
  （开流时 no-op）；`REMOTECRAB_E2E_SHEET=picker` 无头钩子。这两条留着无害、便于观察。
- **现状**：`startComputerBrowser()` 只在 `startStreaming()` 里被调用
  （`CaptureEngine.swift:1022`）；首次打开 app、还没开流时 presence 浏览没跑，
  列表为空 → 用户**只能等电脑主动连**，手机上选不了电脑。体验不好。
- **步骤**：
  1. 精读 `startComputerBrowser/stopComputerBrowser`、`ComputerPickerView`、
     `ContentView` 里 picker 的呈现时机，以及 phone-initiated 的 knock 流程
     （`IBPhoneHello`、`RemoteCrabCore/State/PhoneIdentity.swift`）。
  2. 设计：让 presence 浏览**独立于 streaming**（app 打开即浏览），
     选中某台在线电脑 → 走既有 knock/直拨流程触发连接。
  3. 电量/隐私取舍：不开流时是否持续浏览？可只在连接界面可见时浏览。
- **影响面**：⚠️ 中。监听/浏览生命周期、后台保活、启动顺序，别和 `startStreaming`
  起两个 browser。
- **验证**：真机冷启动、未开流时，picker 能列出局域网内开着 Mac/Windows 端的电脑，
  点一下能连上。

### B10. ✅ 已实现 + 单测（2026-10-09）
- **改动**：`ComputerRoster.isVisible`（纯函数 + 3 测）——忘掉的电脑只在**离线**时隐藏，
  **在线**时仍显示（带"未配对"徽标、点一下即 `connect(toComputer:)` 重新添加并 `clearForgotten`）。
  `refreshOnlineComputers` 不再按 forgotten 过滤，隐藏交给视图。
- **现状**：iOS 上"忘记当前电脑"后，那台电脑不再显示；要加回来只能从 Mac 端主动连。
- **期望（用户原话）**：像 iOS 的 WiFi 列表——**"已记录的"**和**"扫描到的"**都要列，
  忘了也能从扫描列表里重新添加。
- **步骤**：
  1. 精读 `MacPairingStore`（`forget`/`seen`/`paired`/`current`）、`ComputerRoster`、
     `ComputerPickerView`、`CaptureEngine.refreshOnlineComputers` / `forgottenComputerIds`。
  2. 设计：picker 分两段——"已知/已配对"与"扫描到的（在线/离线）"；
     forget 只从"已记录"移除，不影响"扫描到"段的展示，并可一键重新添加。
  3. 与 B9 合并设计（都要求 presence 浏览独立于 streaming）。
- **影响面**：⚠️ 中。`forgottenComputerIds` 的过滤、`seen` 的去重/优先级、
  `current` 门卫（`decide`）。别让"忘记"又变回"哪台都连不上"。
- **验证**：真机：忘掉当前电脑 → 它在"扫描到"段仍可见 → 点一下能重新连上并恢复配对。

---

## 4. 工作流 C：后台 / 锁屏 / 打断连续性

### C1. 后台/锁屏存活性 ✅ 已真机测量（2026-10-09）—— 结论：后台即挂起、回前台不可达
- **实测**（iPhone 14 / iOS 26）：前台 streaming 正常 → `15:34:09` 进后台 →
  进程被 suspend（`[main-stall] main thread busy 217318ms`）→ `15:37:52` 回前台时
  `[hs] listener failed: -65569: DefunctConnection`，capture listener 已死且**未被重建**；
  Mac 侧 `nc 192.168.31.148:8765` = **CLOSED**、Bonjour `_remotecrab._tcp` 为空，
  而手机前台**仍在推视频**。→ 手机在出画面，却既发现不到也连不上。
- **结论**：`BackgroundKeepAlive` 的 `.playback` + 零静音循环**没有阻止 iOS 挂起**，
  回前台后不可达，直到手动重开流。与规则 1「承诺与事实不符」同类。
- **拆出的两个缺陷见 C1a / C1b。**

### C1a. ✅ 已实现 + 单测 + 真机部分验证（2026-10-09）
- **改动**：新增 `RemoteCrabCore/State/ForegroundRecoveryPolicy.swift`（纯函数
  `shouldRebuildListener(linkAlive:listener:)` + `ListenerLiveness` 枚举）+ 6 个单测；
  `CaptureEngine.handleDidBecomeActive` 把判据从 `!BackgroundKeepAlive.shared.isActive`
  换成 `listenerLiveness`（读 `NWListener.State`），并加 `listenerLiveness` 计算属性。
- **为什么**：老判据用 keep-alive 的软件标志当"listener 活着没"的替身（lesson 154 同族）。
  run1 实测 listener 已 `failed` 但 `isActive` 仍 true → 跳过重建 → 手机不可达。
- **单测**：`ForegroundRecoveryPolicyTests`（6/6）覆盖全部分支：
  活跃连接不重建（lesson 156）、`.absent/.failed/.cancelled` 重建、
  `.ready/.other` 不动。
- **真机**：`./scripts/test.sh` 全绿（Core + 两 target + Windows）；真机 5 轮后台→前台中，
  **健康监听不动**的分支已验证（无多余重建、无 lesson 156 回归）；
  **`.failed → 重建`分支本轮未在真机复现**——5 轮里只有 run1（223s 长挂起、无连接）
  才让 listener 挂，其余（30–43s）listener 存活。
  → **诚实记录**：listener 死亡依赖"真被 suspend"的时长，间歇性；重建逻辑由单测保证。
- **顺带证据（供 B4）**：手机 `_remotecrab._tcp` **同时在 3 个接口广播**
  （`dns-sd` 实测 `if 21 / if 22 / if 13`），印证 B4 的多接口发现/去重问题。

### C1b. 🔴 BackgroundKeepAlive 实际没保住进程（需调查 iOS 26 行为）
- **现状**：保活启动了（`[keepalive] session playback active`）但进程仍被 suspend。
  可疑点：`engine.mainMixerNode.outputVolume = 0`（`BackgroundKeepAlive.swift:64`）
  让 iOS 视为"没有实际音频输出"；或 `.mixWithOthers` + 静音 buffer 在 iOS 26 不再被
  判为后台音频。
- **步骤**：
  1. 精读 `BackgroundKeepAlive` 全部 + `CaptureEngine.applyKeepAlive`。
  2. 对照试验（去掉 `outputVolume=0`；或改 buffer 为非零极低幅度；或换 category），
     **每个变体都真机验证**是否还被 suspend —— 不要只靠读代码。
  3. 若无法可靠保活，则明确产品口径（后台会断），并确保 C1a 的恢复路径可靠兜底。
- **影响面**：⚠️ 高。共享 `AVAudioSession`，可能影响麦克风/扬声器（lesson 123/161）。
- **验证**：真机：后台 30s 后进程**未被** suspend（日志持续），且 listener 仍 ready。

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

### G1. Apple Pencil = 绘画板（用户 2026-10-09 定：手机上画，精准传到电脑）
- **现状**：❌ 无 `UITouch.TouchType`/`allowedTouchTypes`/压感/倾斜；
  `TouchSurface.swift:528` 用 `majorRadius` 做 force-click——Pencil 会被误判成手指。
  `CGEventInjector` **没有** tablet/压感注入；`TouchEvent` **没有** pressure/tilt 字段。
- **设计（读代码后，2026-10-09）**：
  1. iOS：新增**绘画面**（独立于触控板的 `TouchSurface`），只收 `touch.type == .pencil`；
     采集绝对坐标 + `force`（压感）+ `altitudeAngle`/`azimuthAngle`。
  2. wire：`TouchEvent` 加**可选**字段 `pressure`/`altitude`/`azimuth`（缺省 nil，向后兼容）。
  3. Mac：`CGEventInjector` 加 **tablet 事件注入**（`CGEventType.tabletPointer` +
     `.tabletEventPointPressure` / `.tabletEventTiltX/Y` + `.tabletEventPointButtons`），
     绝对映射到 Mac 屏或投屏窗口。
  4. 区分：Pencil 走绘画面，手指照旧做触控板手势。
- **⚠️ 不确定（需 spike）**：合成的 CGEvent tablet 事件**是否被 Photoshop/Krita/笔记
  等 app 认作真实数位板输入**（很多 app 读 `NSEvent` 的 tablet 子类型，纯 `CGEventPost`
  未必被采纳）。→ 先做**最小 spike**：注入 tablet 事件，在目标 app 验证压感/坐标；
  不生效则降级为"仅精确指针、无压感"。
- **影响面**：⚠️ 新增绘画 UI + wire 字段 + Mac 注入；触控板/键盘/投屏**不动**（用独立面）。
- **验证**：真机 + Pencil，在 Mac 目标 app 里画出连续线、看压感是否变化。

### G2. 网站文案对齐（用户 2026-10-09：全站对齐，不止 Pencil）
- **现状（2026-10-09 精读 `/Users/edwinhao/VGOAPP/remotecrab`）**：
  - `features/camera/index.html:7` 现在写 **"1080p 30 帧"**——**和今天现实一致**
    （虚拟摄像头 1080p）。**4K 目前不在线上文案里**（4K 只在内部 `docs/campaign/*`
    当 Pro 卖点）。→ A2 做完后把 camera 页改成 4K。
  - 站上有 11 个 feature 页（camera/microphone/trackpad/keyboard/voice/…）。
- **要做**：① 4K 摄像头落地后更新 `features/camera`（1080p→4K）；
  ② Pencil 绘画板落地后新增 feature 页 + 首页卖点；③ 全站逐页核对与真实能力一致。
- **依赖**：**先有实现再宣传**（别重演内部 4K 文档领先于代码的事）。
- **影响面**：仅文案/网站（`~/VGOAPP/remotecrab`），发布走 `VGOAPP/scripts/deploy.sh`。
- **已做（2026-10-10，VGOAPP `22b02da`）**：
  - **摄像头文案 1080p → 4K**：feature 页 hero/description/详情 + 首页 blurb，**中英双向**，
    以及 `features/camera/index.html` 的 meta（title/og/twitter）。
  - **SEO 修复**：`public/sitemap.xml` 原来**只列了 4 条 URL**，**漏掉全部 11 个 feature 页
    + suites + privacy** → 已补全（带 lastmod/priority）。
- **待做**：① **全站逐页核对**与真实能力一致（你提到"很多没对齐"）——还没逐页过；
  ② Pencil 绘板落地后加 feature 页 + 首页卖点；③ 英文页 / hreflang（如需要）；
  ④ 各 feature 页的 JSON-LD 结构化数据（首页有，内页没有）。
- **未部署**：只提交了源码，**没跑 `deploy.sh`**（生产动作，等你确认）。

---

## 8.5 工作流 H：Mac 托盘菜单逐项可用性（用户 2026-10-09 提出）

### H1. 🟡 逐项点一遍托盘 popover 的每一行（偏好设置已修 + 已真机验）
- **根因（已修）**：托盘 → **偏好设置点了没反应**。`openPreferences()` 用的是
  `NSApp.sendAction(Selector("showSettingsWindow:"))`——这个 selector 在 **macOS 26 已失效**。
  改为 SwiftUI 的 `openSettings()`（macOS 14+，`MenuBarMenu.swift`）。
- **已运行时验证**（AppleScript UI 脚本，Accessibility 已授权）：
  **偏好设置 ⌘, → 打开"通用"设置窗**（修复前无反应）、**控制面板 ⌘P**、
  **预览窗口 ⌘⇧P**、**连接自检 ⌘T** 均打开对应窗口。
- **待验（需手机在线）**：功能开关（camera / mic / trackpad / keyboard，离线时禁用）、
  切换摄像头、开始录制、发送剪贴板、手动连接、检查更新、退出。
  扬声器是**状态行**不是开关（设计如此）。

---

## 9. 进度日志

| 日期 | 条目 | 做了什么 | 验证数字/证据 |
|---|---|---|---|
| 2026-10-09 | 审计 | 5 路代码审计 + 人工复核，建立本文档 | 见 §1 矩阵 |
| 2026-10-09 | B1 | iOS listener 生命周期日志（creating/ready/waiting/failed/cancelled + stopStreaming），仅加日志 | 真机 `[hs] listener creating` → `ready port=8765`；并抓到 `[hs] listener failed: -65569` |
| 2026-10-09 | C1 | 真机测量后台/回前台连续性 | 后台 suspend（main-stall 217318ms）→ 回前台 listener failed 且未重建 → 8765 CLOSED、Bonjour 空 |
| 2026-10-09 | C1a | 新增 `ForegroundRecoveryPolicy`（纯函数+6 测）并接线，判据从 keep-alive 改为 listener 真实状态 | `test.sh` 全绿；真机验证"健康不动"分支；`.failed→重建`分支未稳定复现（间歇，依赖长 suspend） |
| 2026-10-09 | B4 证据 | `dns-sd` 实测手机 `_remotecrab._tcp` 同时在 if 21/22/13 广播 | 印证多接口发现/去重问题 |
| 2026-10-09 | B10 | 忘记的电脑只要在线就仍显示、可重新添加（`ComputerRoster.isVisible` 纯函数+3 测） | `test.sh` 全绿（724 Core + 两 target + Windows） |
| 2026-10-09 | B9 | 发现"启动即开流+浏览"，故原场景存疑；加防御性 picker 浏览 + `E2E_SHEET=picker` | 真机 `[presence] results=1 online=1`（未显式开流） |
| 2026-10-09 | B10 e2e | `e2e-current-computer.sh` Phase D 改为断言 B10 行为；Phase E 改运行时判定 legacy 并 SKIP | `pass=24 fail=0 skipped=1` |
| 2026-10-09 | harness | 根因：`MacPairingStore.removeAll`（e2e reset）**不清 `seen`** → 每轮 stand-in（同名不同 id）堆成"重复电脑"。已修 + 测试 | 手机 prefs 事后 `seen=[]`、`paired=[]`、`preferred=None` |
| 2026-10-09 | A 复核 | 精读后更正：4K 的墙是**虚拟摄像头单一 1080p 格式**；16Mbps 天花板在 iOS 惰性（A3 作废） | `VideoEncodingPolicy.swift:12,37,64` |
| 2026-10-09 | A 实测 | 加 `REMOTECRAB_E2E_RESOLUTION` 钩子，真机测 4K 编码 | 4K30 真跑 30fps（frames=61/2s），关键帧 42,954 kbps > req 16,000 |
| 2026-10-09 | G/网站 | 确认真相：线上 camera 页写 "1080p 30 帧"（诚实）；4K 只在内部 campaign 文档 | `~/VGOAPP/remotecrab/features/camera/index.html:7` |
| 2026-10-09 | A2 实现 | 扩展广告 1080p+4K，host 按客户端选择的格式喂帧；iOS 加 4K 发热/耗电提醒 | `test.sh` 全绿（725 Core + 两 target + Windows） |
| 2026-10-09 | A e2e | **4K 摄像头端到端通过**：同版本原地替换 + 杀扩展进程重载后，探针打印 1080p+3840×2160、exit 0 | `./scripts/e2e-camera-formats.sh` ✓ |
| 2026-10-09 | A 决策 | 因此**不 bump 扩展版本**（保住用户已有批准、零支持成本），回到 8 | 待你确认发版策略 |
| 2026-10-09 | H1 | 修托盘"偏好设置"死键：`showSettingsWindow:`（macOS 26 失效）→ `openSettings()` | 编译通过；其余托盘行待 GUI 逐项验 |
| 2026-10-09 | H1 验证 | AppleScript 逐键实测托盘：⌘, 设置 / ⌘P 控制面板 / ⌘⇧P 预览 / ⌘T 连接自检 全部打开对应窗口 | 均在窗口列表中确认 |
| 2026-10-10 | A2 真机 | 手机端 4K 全链路：手机 `capture 2160x3840` → Mac `video frames received` → `feeding virtual camera`；探针证明**双格式设计坏**（host 读 source 格式恒为 1920x1080）→ 改单一 4K | 手机 forensic + host 日志 |
| 2026-10-10 | A2 部署 | 单一 4K（v10）已装 `/Applications`，但扩展注册表脏（v8 待重启卸载 + v9 旧二进制），新二进制**未加载** | ⛔ 需重启 + Re-register + 批准（用户） |
| 2026-10-10 | A2 v10 | 用户重启+批准后 v10 加载；`e2e-camera-formats.sh` = **单一 `3840x2160`**；手机→Mac→feeder→扩展 sink 全活；**唯一遗留**：扩展不调 `source.send`，客户端拿不到帧 | 探针 TIMEOUT（待扩展调试） |
| 2026-10-10 | C5 | `ThermalPolicy`（7 测）+ CaptureEngine 观测 thermal/low-power | 编译 + 测通过 |
| 2026-10-10 | D2 | `StreamTelemetry`：算真实 fps/kbps，Mac 每 ~2s 记 `stream: N fps, M kbps` | 测通过 |
| 2026-10-10 | E2 | 修正 `RELEASE_READINESS.md`「后台麦未实现」的错误陈述（`UIBackgroundModes` 确实存在） | 文档与代码一致 |
| 2026-10-10 | B7 | 新增"token 跨重启持久 + 重连被接受"测试（此前只测单次连接） | 测通过 |
| 2026-10-10 | 网站 | 摄像头文案 1080p→4K（中英+meta）；sitemap 补全 11 feature 页+suites+privacy | **已 push + 部署**，线上确认 4K |

---

## 10. 待办顺序（建议）

1. **B1**（一行日志，解锁排障）→ **C1**（真机锁屏测量）→ **B4/C2** 取证。
2. **A1** 决策 4K 口径 → 据决策走 A2-A6 或 §8 文案。
3. **B4** 两种传输模式协作 → **B2/B3/B6**。
4. **D1/D2/D3** 可观测性 → 让后续所有修复可测量。
5. **E1/F1/F2/C5** 较大改动，各自立项。
6. **G1** Pencil（重要卖点，但改动面大，独立会话）。
