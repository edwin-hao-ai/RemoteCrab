# RemoteCrab — Windows 接收端方案（Rust + Tauri · 体验优先）

> 状态：草案 v2 · 2026-09-24
> 技术栈决定：**Rust 核心 + Tauri v2 外壳**（与 VGO/MDDock 同栈，本机可直接编译）
> 本文回答一个问题：**怎样让 Windows 电脑也能用 RemoteCrab，而且小白也能用好？**
> 配套阅读：`README.md`（架构）、`AGENTS.md`（项目 context + 60 条教训）、
> `docs/PRD.md`（§14 未来扩展 / §15 明确划线）。

---

## 0. 第一原则：体验优先，不是"能连上就行"

这个项目的价值不在协议，而在**用户全程不接触技术细节**。Mac 端已经用血
换来的体验（`AGENTS.md` 60 条教训里有近一半是连接/配对/提示的 UX 坑）必须
**逐面复刻**，而不是"先连通再说"。具体硬性要求：

1. **用户全程不输入 IP / 端口 / 命令**。Bonjour 自动发现为主，direct-IP 兜底
   自动发生；手动 IP 只作为"最后的逃生门"藏在菜单里（照抄
   `MenuBarMenu.swift:405` "Connect Manually…"）。
2. **状态永远说人话**。固定状态词表 + 固定文案，**永不**暴露原始
   `NWError`/POSIX/HRESULT（`AGENTS.md` 教训 13；`IBLocale.Error.*`）。
3. **每一步自检 + 自动前进**。首次设置向导每秒轮询系统状态，用户做完一步
   界面**自己**翻页，不用猜"到底生效没有"（`SetupAssistantView.swift:76-79`）。
4. **失败给明确的下一步**，不是死路：等 iPhone 的卡要写"在电脑上：托盘 →
   手动连接 → `<地址>`"（对应 iOS `IBLocale.Error.manualConnectHint`）。
5. **中英双语**（en + zh-Hans），与 iOS/Mac 逐条对齐——Windows 用户里中文
   比例只会更高。
6. **核心功能开箱即用**：Windows 上**没有** macOS 那种强制的辅助功能授权，
   所以"预览 + 触控板 + 键盘"应零配置可用（见 §3.4，这是相对 Mac 的体验优势）。

> 一句话：Windows 端不是"一个能收流的 exe"，而是 **Mac 接收端的完整体验复刻**。

---

## 1. 一句话结论

**iOS 端基本不用改。** iPhone 是 TCP **服务端**（`NWListener`，端口 8765，
Bonjour 服务 `_remotecrab._tcp`），Mac 只是客户端。所谓"支持 Windows" =
新写一个 **Windows 接收端**，讲同一套线协议，并复刻 Mac 端的全部用户面。

macOS 侧最硬的骨头（CMIO 虚拟摄像头、CoreAudio HAL 虚拟麦克风）**与 Windows
无关**——Windows 有各自等价实现，且可推迟。**唯一必须回改 iOS 的地方**是
"等待 Mac"卡里的指路文案（§7 依赖 D1）。

---

## 2. 现状拆解：哪些能复用、哪些必须重写

### 2.1 复用（跨平台资产）

| 资产 | 位置 | 复用方式 |
|---|---|---|
| 线协议规范 | `RemoteCrabCore/Networking/IBWire.swift`（397 行） | 逐字段移植到 Rust（§4 已整理） |
| 事件数据模型 | `IBEvents.swift`（507 行） | Rust `struct` + serde |
| 配对策略 | `MacPairingStore.swift` + `PairingPolicy` | 纯逻辑，照搬 |
| 触控板数学 | `TrackpadMath.swift` / `ScrollCoalescer.swift` / `PinchSmoother.swift` | 纯函数，照搬 |
| 文本变换 | `TextTransform.swift` | 纯逻辑，照搬 |
| **全部用户文案** | `DesignSystem/IBLocale.swift`（718 行）+ `Resources/Localizable.xcstrings` | **提取为共享 JSON**，两端同源（§3.6） |
| 设计 token | `DesignSystem/IB*.swift` | 复刻为 CSS 变量（或映射到 Fluent token） |

### 2.2 必须重写（Apple 框架绑定）

| 能力 | Mac 实现 | Windows 替代（§6 选型） |
|---|---|---|
| Bonjour 发现 | `NWBrowser` | Rust `mdns-sd` + direct-IP 兜底 |
| TCP / 握手 / ping | `NWConnection` | `tokio::net::TcpStream` |
| H.264 解码 | VideoToolbox | Media Foundation **或** FFmpeg |
| 音频播放 | AVAudioEngine | WASAPI（`cpal`） |
| Opus 解码 | Apple AudioConverter | `audiopus`（libopus） |
| 鼠标/键盘注入 | `CGEventPost` | Win32 `SendInput` |
| 应用切换 / 窗口列表 | `NSRunningApplication` / ScreenCaptureKit | `EnumWindows` / Windows.Graphics.Capture |
| 剪贴板 | NSPasteboard | Win32 clipboard（`arboard`） |
| 系统键 | system-defined NSEvent | `SendInput` + `VK_MEDIA_*` |
| 文件落盘 + 打开目录 | `~/Downloads/RemoteCrab` + Finder | `%USERPROFILE%\Downloads\RemoteCrab` + Explorer |
| 菜单栏 UI | SwiftUI `MenuBarExtra` | Tauri 托盘 + 浮动弹层窗 |
| 开机自启 | `SMAppService` | 注册表 `Run` 键 / 任务计划 |
| 虚拟摄像头 | CMIO system extension | MF Virtual Camera / DirectShow filter（P3） |
| 虚拟麦克风 | CoreAudio HAL 插件 | 虚拟音频驱动（P3，最难） |

### 2.3 协议里 3 处"非可移植语义"（移植时必须显式处理）

1. **`KeyEvent.keycode` 是 macOS CGKeyCode**（§4.5）→ 需建
   `CGKeyCode → Windows VK` 映射表。
2. **`TouchEvent` 是"摇杆式相对增量"**，不是绝对坐标（§4.4）→ Windows 必须
   复刻 `dx × 屏高` 累加语义，否则手感完全不对。
3. **`modifiers` 的 `command` 位**（Mac ⌘）在 Windows 语义模糊 → 映射到
   `Ctrl`（推荐）还是 `Win`？（§11 Q2）

---

## 3. 必须复刻的用户面（本方案的重心）

Mac 接收端是 `LSUIElement`（无 Dock 图标）应用，用户面由 6 块组成。Windows
端要一一对应，**信息架构、文案、状态机都照抄**。

### 3.1 首次设置向导（Setup Assistant）

来源：`RemoteCrabReceiver/SetupAssistantView.swift`（492 行）。

- **5 步左侧栏**：Welcome → Accessibility → Virtual Camera → Virtual
  Microphone → All Set。每步左侧图标随状态变化（`circle` / `circle.fill` /
  `checkmark.circle.fill` / `minus.circle`=跳过）。
- **每秒轮询 + 自动前进**：`advanceIfNeeded()` 在当前步完成后**自动翻页**；
  Welcome / All Set 是显式动作，不自动跳过（`SetupAssistantView.swift:474-479`）。
- **可选步有"Skip for now"**，且**必须用 bordered 按钮**——纯文字曾被用户
  当成"禁用"，以为被困住了（`SetupAssistantView.swift:441-450` 的注释）。
- **必做步不可跳**（Mac 是 Accessibility）。
- **完成页给总结**：每步 `✓ / 跳过 / 未完成` + "从菜单栏打开并连接你的 iPhone
  即可开始"。

**Windows 版对应**（§3.4 详述）：Welcome → **Virtual Camera（可选）** →
**Virtual Microphone（可选）** → All Set。**没有必做步**——因为 Windows 的
`SendInput` 不需要任何授权。这比 Mac 更简单，是卖点。

### 3.2 托盘弹层（主控面，最常看）

来源：`RemoteCrabReceiver/MenuBarMenu.swift`（587 行）。结构自上而下：

1. **"完成设置"提示行**（设置未完成时出现）。
2. **Header**：应用名 + 状态胶囊（`IBStatusPill`）+ 设备行（iPhone 名 + 延迟
   / 码率，或 `OFFLINE`）。
3. **设备选择区**（未连接且发现到设备时）：列出发现的 iPhone + `Connect`
   按钮 + 已配对徽章（`checkmark.shield.fill`）。
4. **串流行**：实时缩略图（80×54）+ 分辨率 / fps / 码率三行；离线时是**固定
   高度**的一行提示 + `Retry`（教训 14：高度变化会让 macOS 弹层反复抖动——
   Windows 弹层同样要固定高度）。
5. **功能开关**：Camera / Mic / Trackpad / Keyboard 四个 Toggle，离线时禁用
   且副标题变 "Connect an iPhone first"（`MenuBarMenu.swift:322-355`）。
6. **动作区**：打开控制面板(⌘P) / 预览窗(⌘⇧P) / 连接测试(⌘T) / 切换摄像头 /
   录制(⌘R) / 发送剪贴板到 iPhone / 显示最后收到的文件 / 手动连接 / 断开 /
   偏好设置(⌘,) / 退出(⌘Q)。
7. **Footer**：版本号。

**Windows 版**：托盘图标（左键/右键）+ 一个贴近托盘的**无边框浮动弹层**
（Tauri 无原生 MenuBarExtra，需自绘）。快捷键改为 `Ctrl+...`。

### 3.3 控制面板窗 + 连接测试窗

- **控制面板**（`ControlPanelView.swift`，370 行）：品牌渐变背景 + 状态胶囊 +
  预览缩略图（150×100）+ 统计卡（分辨率/fps/码率/编码）+ **延迟 sparkline**
  （真实 ping RTT 历史，无数据就隐藏——**绝不显示假数据**）+ 设备卡（CAM/MIC/
  TPAD/KEY 四个徽章）+ 动作行。窗口尺寸 380×620 单点在 App 定义里。
- **连接测试窗**（`TestWindowView.swift`，442 行）：**四象限实时自检**——
  Camera（画面 + 分辨率·fps·码率·延迟）/ Keyboard（最近按键徽章 + 滚动
  输入回显）/ Trackpad（触点轨迹 + 按压环 + 手势相位标签）/ Mic（RMS 电平条
  + 监听开关）。这是**小白验证"到底通没通"的杀手锏**，Windows 必须做。

### 3.4 macOS 设置步骤 → Windows 对应（Windows 更简单）

| Mac 设置步 | 为什么需要 | Windows 对应 | 小白友好度 |
|---|---|---|---|
| **Accessibility**（TCC，**必做**） | `CGEventPost` 需 AX 信任 | **不需要**——`SendInput` 无需授权 | ✅ 免去最烦的一步 |
| Virtual Camera（CMIO sysex，可选） | 其他 app 能看到"RemoteCrab Camera" | DirectShow filter 注册 / MF 虚拟摄像头 | 安装器一步完成 |
| Virtual Microphone（HAL pkg，可选） | 其他 app 能看到"RemoteCrab Microphone" | 虚拟音频驱动（需签名驱动） | 最难，P3 |
| Screen Recording（窗口缩略图） | ScreenCaptureKit | Windows.Graphics.Capture（无需单独授权） | ✅ 更简单 |
| 开机自启 | `SMAppService` | 注册表 `Run` / 任务计划 | 简单 |

**关键结论**：Windows 的核心体验（预览 + 触控板 + 键盘）**零权限、零驱动**
即可用。设置向导因此可以**全部可跳**，大大降低小白的门槛。需要处理的只有
**安装时的 SmartScreen/UAC**（§9 R8）。

### 3.5 状态词表（固定，两端一致）

来源：`IBLocale.Status` + `ReceiverSession.State` + `IBStatusPill.Status`。

```
状态机（Windows 端同构）：
  searching → connecting → handshaking → awaitingApproval → streaming
                                                   ↘ error

胶囊词表：LOOKING / CONNECTING / WAITING / LIVE / OFFLINE / RECONNECTING / READY
          LIVE 后缀显示真实延迟 "24 ms"（无 RTT 时只显示 LIVE）
颜色：    绿=connected 黄=searching/connecting/reconnecting 红=offline 灰=idle
禁止：    胶囊里出现原始错误文本（教训 13 的"离线 Connection lost"混排）
```

### 3.6 文案与本地化：单一来源（重要架构决策）

Mac/iOS 的文案在 `IBLocale.swift`（Swift enum）+ `Localizable.xcstrings`。
Windows 不能直接用 Swift，但**绝不能各写一份**——否则两端文案必然漂移，
"体验一致"就是空话。

**方案**：写一个提取脚本（`scripts/export-iblocale.py`），把 `IBLocale`
的 key + en + zh-Hans 导出成 `shared/iblocale.json`，Windows 端直接加载。
CI 校验两端 JSON 与 Swift 源一致（新增字符串时若忘了同步 → 红）。
这同时解决 `Error.manualConnectHint` 这类**需要按平台改措辞**的文案
（见 §7 D1）。

### 3.7 设计语言：混合方案（✅ 已拍板）

**保留 RemoteCrab 的品牌与信息架构**（两端体验不割裂），**控件与系统行为走
Windows 原生**（小白对"像 Windows 应用"更安心）。

| 维度 | 沿用 RemoteCrab | 走 Windows 原生 |
|---|---|---|
| 信息架构 | 6 个用户面 + 步骤顺序 + 分区 | — |
| 文案 / 状态词表 | 全部 en+zh、状态词、错误文案（§3.6 单一来源） | — |
| 强调色 / 语义色 | RemoteCrab accent + 绿/黄/红语义不变 | — |
| 卡片 / 层级 | 卡片圆角、细边框、分区标题 | 材质用 Mica/Acrylic 或纯色 elevation，不用 Liquid Glass |
| 技术读数 | eyebrow 大写 + 等宽字体 | 字体换 Cascadia Mono / JetBrains Mono |
| 状态胶囊 | 保留 | — |
| UI 字体 | — | Segoe UI Variable |
| 控件观感 | — | ToggleSwitch / Button / Picker 走 Fluent |
| 窗口 | — | 原生标题栏 / min-max-close / DPI 缩放 / 暗色跟随系统 |
| 托盘 | — | 通知区域规范（左键弹层 / 右键菜单） |
| 通知 | — | Windows toast（Action Center） |
| 快捷键 | 动作含义不变 | `Ctrl` 替代 `⌘` |
| 文件 | — | 资源管理器 + `%USERPROFILE%\Downloads\RemoteCrab` |
| 安装 | — | MSI/NSIS + EV 签名 |
| 设置 | 分组结构 | 普通设置窗口（WinUI 分组风格） |

**理由**：Liquid Glass 是 Apple 独有材质，硬搬到 Windows 会显得"像 Mac 应用
没做完"；但信息架构和文案是 RemoteCrab 的产品资产，改了会让两端用户对不上。
混合 = 换皮不换骨。

### 3.8 四大功能的 Windows 可行性（逐项核实）

**核心事实：iPhone 是采集端 + 识别端，Windows 只是"执行器"。** 视频在
iPhone 上 H.264 硬编、麦克风在 iPhone 上 Opus 编码、语音在 iPhone 上
**端侧** `SFSpeechRecognizer` 识别、触控板手势在 iPhone 上解析——Windows
收到的已经是成品（NAL / Opus / 文本 / 事件），只负责**显示 / 播放 / 注入**。
所以四大功能**全部可实现**，难度不在信号层，而在"让别的 app 看见 iPhone
设备"的系统集成层。

| 功能 | 信号层（Windows 必须做） | 系统集成层（对其他 app 可见） |
|---|---|---|
| **视频** | ✅ 解码 H.264 + 预览窗（易） | ⚠️ **虚拟摄像头**：Win11 22H2+ MF Virtual Camera / Win10 DirectShow filter（P3，OBS 虚拟摄像头是同款参考） |
| **麦克风** | ✅ Opus 解码 + WASAPI 播放 + RMS 电平（易） | ❌ **虚拟麦克风**：Windows 无自带虚拟音频设备，需 sysvad 类**签名驱动**（P3，最难） |
| **触控板** | ✅ `SendInput` 移动/点击/拖拽/滚动/右键/中键/修饰键（易，手感需调） | —（直接操作系统光标） |
| **语音输入** | ✅ 注入 UTF-16 文本 + `activateApp` 激活窗口 + `textCommand` 改写选中（易） | —（识别已在 iPhone 端侧完成） |

**逐项说明**：

- **视频**：iPhone `H264Encoder` → `video` NAL（AVCC）。Windows 预览走
  WebCodecs 或 Rust 解码；虚拟摄像头复用同一解码结果（§5.3）。**预览零门槛，
  虚拟摄像头是 P3 重活。**
- **麦克风**：iPhone `MicrophoneEncoder` → Opus 48k mono（`codec="opus"`，
  失败回退 `"pcm"`）。Windows 用 `audiopus` 解码 → `cpal` 播放。**注意
  Windows 无内置 Opus 解码器，必须 bundle libopus。** 播放/电平可做；
  "Zoom 里选 RemoteCrab Microphone" 需签名驱动。
- **触控板**：iPhone `TouchSurface` → `TouchEvent`（摇杆式相对增量 + 相位 +
  修饰位）。Windows `SendInput` 全支持。三/四指手势 Mac 映射 Mission
  Control/Spaces，Windows 需另选等价键（`Win+Tab` / `Ctrl+Win+←→`，§11 Q3）。
- **语音输入**：iPhone `VoiceRecognizer`（**端侧** zh-Hans/en-US）→ 增量
  `KeyEvent(.text)`。Windows 用 `SendInput` + `KEYEVENTF_UNICODE` 注入。
  语音命令（"打开 X"）→ iPhone 发 `activateApp`（0x0E）→ Windows
  `SetForegroundWindow`。改写选中 → `textCommand`（0x14）→ Windows 合成
  `Ctrl+C` 读选中、变换、`Ctrl+V` 写回、恢复剪贴板（与 Mac 的 ⌘C/⌘V 同思路）。
  **识别完全在 iPhone，Windows 零识别工作。**

**Windows 独有的风险点（需在 P1/P2 验证）**：

| # | 风险 | 影响 | 对策 |
|---|---|---|---|
| **W1** | **UIPI**：目标窗口以管理员运行时，普通权限进程的 `SendInput` 被静默丢弃 | 触控板/键盘对提权窗口无效 | 提示用户"该窗口以管理员运行"；必要时申请 `uiAccess`（需签名 + 装到 Program Files） |
| **W2** | **Secure Desktop**（UAC 提权界面）无法注入 | 平台限制，Mac 同样无法在密码框注入 | 文档说明，不做 |
| **W3** | 虚拟摄像头 API 版本差异（Win11 MF vs Win10 DirectShow），MF 可能要求 MSIX | 影响分发形态（§11 Q5） | P3 定；Win10 走 DirectShow filter |
| **W4** | `textCommand` 改写依赖合成 `Ctrl+C`/`Ctrl+V` + 剪贴板保存恢复 | 少数 app 拦截合成键 | 与 Mac 同方案；失败给提示不静默 |
| **W5** | `KeyEvent.keycode` 是 macOS 虚拟键码，含 app-switcher chords（`⌘⇥`/`⌃↑`/`⌘H`/`⌘Q`） | 直接映射会全错 | 建映射表；Mac 专属 chord 换 Windows 等价键 |

**结论**：视频 / 麦克风 / 触控板 / 语音输入 **四项全部可实现**，且信号层
都是"薄执行器"级别的难度。真正的重活只有两个——**虚拟摄像头**和**虚拟
麦克风**（P3），它们决定"Zoom/Teams 能不能直接选 iPhone 设备"，但不影响
RemoteCrab 自身的完整可用性（预览 + 播放 + 注入 + 语音全部可跑）。

---

## 4. 线协议规范（供 Rust 实现，从 Swift 源码逐字提取）

### 4.1 帧格式

```
┌──────────────────────────────────────────────────────────────┐
│ [4 字节 大端 length][1 字节 kind][payload]                     │
│ length = 1(kind) + payload.len   (1 ≤ length ≤ 64 MiB)        │
└──────────────────────────────────────────────────────────────┘
```

增量解析：跨 `read()` 保留半帧缓冲（对应 `IBWire.Parser`）；`length < 1` 或
`> 64 MiB` 丢弃整缓冲（DoS 守卫）。

### 4.2 Kind 表（0x00–0x19）

| Kind | 值 | 方向 | Payload |
|---|---|---|---|
| metadata | `0x00` | iOS→Win | JSON `IBStreamMetadata`（连接后首帧） |
| video | `0x01` | iOS→Win | 单个 H.264 NAL（**AVCC，无起始码**） |
| sps | `0x02` | iOS→Win | H.264 SPS NAL（裸） |
| pps | `0x03` | iOS→Win | H.264 PPS NAL（裸） |
| touch | `0x04` | iOS→Win | JSON `TouchEvent` |
| key | `0x05` | iOS→Win | JSON `KeyEvent` |
| audio | `0x06` | iOS→Win | JSON `AudioPacket`（opus base64） |
| featureControl | `0x07` | **Win→iOS** | JSON `FeatureControl` |
| featureState | `0x08` | iOS→Win | JSON `FeatureStateSnapshot` |
| ping | `0x09` | **Win→iOS** | 8 字节大端 timestampMicros，iOS 原样回显 |
| clientHello | `0x0A` | **Win→iOS** | JSON `IBClientHello`（连接后首帧） |
| sessionReply | `0x0B` | iOS→Win | JSON `IBSessionReply` |
| appList | `0x0C` | **Win→iOS** | JSON `IBAppList` |
| appListRequest | `0x0D` | iOS→Win | JSON `IBAppListRequest`（空） |
| activateApp | `0x0E` | iOS→Win | JSON `IBActivateApp` |
| fileOffer | `0x0F` | iOS→Win | JSON `IBFileOffer` |
| fileChunk | `0x10` | iOS→Win | 裸字节（≤128 KiB） |
| fileComplete | `0x11` | iOS→Win | JSON `IBFileComplete` |
| fileAck | `0x12` | **Win→iOS** | JSON `IBFileAck` |
| clipboardSet | `0x13` | 双向 | JSON `IBClipboard` |
| textCommand | `0x14` | iOS→Win | JSON `IBTextCommandMessage` |
| cameraCommand | `0x15` | **Win→iOS** | JSON `IBCameraCommand` |
| quitApp | `0x16` | iOS→Win | JSON `IBQuitApp` |
| windowListRequest | `0x17` | iOS→Win | JSON `IBWindowListRequest` |
| windowList | `0x18` | **Win→iOS** | JSON `IBWindowList` |
| systemCommand | `0x19` | iOS→Win | JSON `IBSystemCommand` |

> Windows = "Mac 角色"，所以 `0x07/0x09/0x0A/0x0C/0x12/0x15/0x18` 是
> Windows **发出**；其余是接收。

### 4.3 JSON 字段（serde 字段名即键名，严格对齐）

```
IBStreamMetadata   { version:int, deviceName:str, width:int, height:int,
                     fps:int, bitrateBps:int, codec:str,
                     sps:base64?, pps:base64? }

TouchEvent         { phase:str, x:f32, y:f32, dx:f32, dy:f32,
                     modifiers:u8, momentum:bool?, timestampMicros:u64 }

KeyEvent           { action:"down"|"up"|"text", keycode:u16?,
                     text:str?, modifiers:u8, timestampMicros:u64 }

AudioPacket        { opusData:base64str, sampleRate:int, channels:int,
                     timestampMicros:u64, codec:"pcm"|"opus" }

FeatureControl     { feature:"camera"|"microphone"|"voice"|"trackpad"|"keyboard",
                     enabled:bool }

FeatureStateSnapshot { cameraOn:bool, micOn:bool, voiceOn:bool,
                       trackpadOn:bool, keyboardOn:bool,
                       activeSurface:"trackpad"|"keyboard"|"cameraPreview",
                       cameraPosition:"front"|"back", timestampMicros:u64 }

IBClientHello      { name:str, id:str, token:str?, appVersion:str,
                     platform?:str }  // 新增建议："macos"|"windows"；缺省按 macos
IBSessionReply     { result:"accepted"|"pending"|"busy"|"denied",
                     ownerName:str?, token:str? }

IBAppInfo          { id:str, name:str, pid:i32, isActive:bool, iconPNG:base64? }
IBAppList          { apps:[IBAppInfo] }
IBActivateApp      { id:str, windowTitle:str? }
IBQuitApp          { id:str, force:bool }

IBWindowInfo       { id:str, appId:str, appName:str, title:str, isActive:bool,
                     width:f64, height:f64, snapshotJPEG:base64? }
IBWindowList       { windows:[IBWindowInfo], canCapture:bool }

IBFileOffer        { id:str, name:str, size:i64 }
IBFileComplete     { id:str }
IBFileAck          { id:str, status:"progress"|"saved"|"error",
                     receivedBytes:i64, path:str? }

IBClipboard        { text:str }
IBTextCommandMessage { command:str }   // uppercase/lowercase/capitalize/
                                       // trimWhitespace/stripNewlines/bulletList
IBSystemCommand    { command:enum, argument:str? }
IBCameraCommand    { position:"front"|"back" }
```

**默认值（向后兼容，必须实现）**：`AudioPacket.codec` 缺省 `"pcm"`；
`FeatureStateSnapshot.cameraPosition` 缺省 `"back"`；`TouchEvent.momentum`
缺省 `false`。

### 4.4 TouchEvent 语义（移植关键）

- `phase`：`down, move, up, rightDown, rightUp, scroll, click, dragStart,
  pinch, threeFingerSwipe, threeFingerTap, forceClick`
- 坐标**不是绝对坐标**：`move` 的 `dx/dy` = 手指位移 / iPhone 屏高，Mac 端
  累加 `dx * screenHeight`（**两轴都用高度**，`CGEventInjector.swift:27-35`）。
  Windows 用 `GetSystemMetrics(SM_CYSCREEN)` 复刻。
- `scroll` gain = `screenHeight × 1.2`（`CGEventInjector.swift:200`）。
- `pinch` → Mac 用 **⌘+scroll**；Windows 映射 **Ctrl+scroll**。
- `modifiers`：`shift=1, control=2, option=4, command=8`。
- `threeFingerSwipe` → Mac 映射 Mission Control / Spaces 快捷键（`⌃↑↓←→`）；
  Windows 需选等价动作（任务视图 `Win+Tab`、虚拟桌面 `Ctrl+Win+←/→`）——
  §11 Q3。

### 4.5 KeyEvent 语义（移植关键）

- `action=down/up` → `keycode` 是 **macOS CGKeyCode**。常用值：`0-50`
  字母/数字/标点、`36=Return`、`48=Tab`、`49=Space`、`51=Delete`、`53=Esc`、
  `55=⌘`、`56=⇧`、`58=⌥`、`59=⌃`、`123-126=方向键`。完整表
  `CGEventInjector.swift:111-130`。**Windows 需建 CGKeyCode → VK 映射**，
  修饰键走 `SendInput` 的 `KEYEVENTF_*` + 状态跟踪（对应 Mac 的
  `flagsChanged`）。
- `action=text` → 已是 IME 最终文本，Windows 用 `SendInput` +
  `KEYEVENTF_UNICODE` 逐 UTF-16 码元发送。

### 4.6 握手与生命周期

```
Win                                iOS
 │  TCP connect (Bonjour endpoint 或 IP:8765)
 │  ── clientHello (0x0A) ─────────►      name = Windows 电脑名（用户可见！）
 │  ◄── sessionReply (0x0B) ────────      accepted/pending/busy/denied
 │  ◄── metadata (0x00) ────────────
 │  ◄── featureState (0x08) ────────
 │  ── ping (0x09) 每 2s ──────────►      原样回显
 │  ── featureControl (0x07) ──────►      远程开关摄像头/麦克风
```

- **握手超时 6s**（`ReceiverSession.swift:954`）；但 `pending` 是合法等待，
  **不能**超时。
- **ping 看门狗**：每 2s 发；**8s** 无回显 → 断开重连。iOS 侧 **10s** 静默 →
  释放会话。
- **direct-IP 兜底**（必须实现）：Bonjour 5s 无结果 → 探测上次成功 IP + 热点
  网关 `172.20.10.1`，2.5s 拨号 / 8s 超时。token 按映射后的手机名存储
  （`phoneNameByIP`），直连也免重配对。
- **首次配对（TOFU）**：iOS 首次批准下发 `token`；Windows 持久化
  `{pcId, pcName, token}`，后续 `clientHello` 带上即免弹窗。
- **配对状态机**（`MacPairingStore` / `PairingPolicy`）：已配对+token 匹配 →
  `accepted`；陌生 → `pending`（iOS 弹卡）；他人占用 → `busy`。`busy`/`denied`
  时**停止 3s 重连循环**，显示原因 + 手动 `Retry`（+ 一次 30s 慢重试）。

### 4.7 键盘布局与平台感知（iOS 必须知道对端是 Mac 还是 Windows）

**问题**：iOS 现在把所有按键都当 **macOS 虚拟键码（CGKeyCode）** 发送，快捷键
栏和修饰键栏也按 Mac 语义设计（符号 ⌃⌥⌘⇧；chord `⌘⇥` / `⌃↑` / `⌘H` /
`⌘Q`）。Windows 上：
- **修饰键语义不同**：Mac 有**两个**"命令类"修饰键（⌃ control + ⌘ command），
  Windows 只有一个 Ctrl；⌘/⌥ 符号对 Windows 用户陌生。
- **Mac 专属 chord 在 Windows 上不存在**：`⌘⇥` 切 app、`⌃↑` Mission Control、
  `⌘H` 隐藏、`⌘Q` 退出，都要换成 Windows 等价键。

**方案（最小改动 + 向后兼容）**：

1. **握手带平台**：`IBClientHello` 增加可选 `platform` 字段（§4.3）。旧 Mac
   客户端不发 → 缺省按 `"macos"` 解析，**不破坏现有 Mac**。
2. **iOS 侧平台感知 UI**：`CaptureEngine` 记录 `peerPlatform`（来自
   `clientHello`，`sessionReply accepted` 后即可用）：
   - **修饰键栏**（`IBModifierBar.swift`）：Windows 上显示 **Ctrl / Alt /
     Shift**（3 键），不再是 ⌃⌥⌘⇧。
   - **快捷键栏**（`KeyboardScreen.swift`）：Windows 上换 Windows 组合——
     `Alt+Tab`（切窗口）、`Ctrl+W`、`Alt+F4`、`Ctrl+C/V/X/Z` 等；Mac 专属
     的 `⌘⇥`/`⌃↑`/`⌘H`/`⌘Q` 不出现。
3. **修饰键位映射**（**接收端职责**）：

   | iOS `modifiers` 位 | Mac 端 | Windows 端 |
   |---|---|---|
   | `shift=1` | ⇧ | Shift |
   | `control=2` | ⌃ | Ctrl |
   | `option=4` | ⌥ | Alt |
   | `command=8` | ⌘ | **Ctrl**（与 control 合并） |

   Windows 上 `control` 与 `command` 位都产出 Ctrl——这样 Mac 肌肉记忆的
   `⌘C` 在 Windows 上自然变成 `Ctrl+C`。
4. **字符输入不受布局影响**：普通打字走 `KeyEvent(.text)`（iOS IME 的最终
   文本），Windows 用 `KEYEVENTF_UNICODE` 注入，与物理键盘布局无关。只有
   **快捷键栏的虚拟键码**需要平台映射。
5. **接收端仍需 CGKeyCode→VK 映射表**（§4.5）：无论 iOS 发什么 chord，
   Windows 都要把 CGKeyCode 翻成 VK。**映射表是接收端职责，iOS 不关心**——
   这样 iOS 只改 UI 呈现，不改 wire 语义。

**长期更优（暂不做）**：把 wire 的 `keycode` 从 macOS CGKeyCode 换成
**USB HID Usage Code**（三平台通用），一次消除映射表。改动大且会碰 Mac 端，
留作 v2。

**验收**：同一台 iPhone 分别连 Mac 和 Windows，修饰键栏符号、快捷键栏 chord
各自正确；`⌘C` 在 Mac 是 ⌘C、在 Windows 是 Ctrl+C；中文输入两端都正常。

---

## 5. 目标架构（Rust + Tauri，UX-first）

```
windows/
├── Cargo.toml                     # workspace
├── crates/
│   ├── rc-protocol/               # 纯逻辑：帧编解码 + 事件模型 + 握手策略（可单测）
│   ├── rc-discovery/              # mDNS 浏览 + direct-IP 兜底
│   ├── rc-net/                    # tokio TCP + 会话状态机 + ping 看门狗
│   ├── rc-decode/                 # H.264 解码（MF / FFmpeg）
│   ├── rc-audio/                  # Opus 解码 + WASAPI 播放 + RMS 电平
│   ├── rc-input/                  # SendInput 注入 + CGKeyCode→VK 映射
│   ├── rc-os/                     # 应用/窗口枚举、剪贴板、文件落盘、系统键
│   ├── rc-strings/                # 加载 shared/iblocale.json（§3.6）
│   └── rc-vcam/                   # 虚拟摄像头（P3，独立 crate）
├── src-tauri/                     # Tauri v2：命令、托盘、事件推送到 Webview
│   ├── src/main.rs
│   └── tauri.conf.json
└── src/                           # React + Vite UI（6 个用户面见 §3）
    ├── setup/                     # 设置向导（5 步，自检轮询）
    ├── popover/                   # 托盘弹层（主控面）
    ├── panel/                     # 控制面板
    ├── test/                      # 连接测试（4 象限）
    └── prefs/                     # 偏好设置
```

### 5.1 数据流

```
mDNS/IP ─► rc-discovery ─► rc-net(会话) ─┬─ video NAL ─► rc-decode ─► 预览
                                          ├─ audio ─────► rc-audio ─► 扬声器
                                          ├─ touch/key ─► rc-input ─► SendInput
                                          └─ app/window/file/clipboard ─► rc-os
                                                   ▲
                                          featureControl / ping / clientHello
```

### 5.2 状态与 UI 的桥接

Rust `SessionState`（对应 Swift `ReceiverSession.State`）通过 Tauri event
推给 Webview，**状态词表与 Mac 完全一致**（§3.5）。UI 是纯展示 + 命令调用，
和 Mac 的 SwiftUI 层职责对齐。

### 5.3 预览渲染（需早定）

1080p30 裸 RGBA ≈ 8 MB/帧 ≈ 240 MB/s，**不能**走 Tauri IPC 传帧。

- **方案 A（推荐，单解码路径）**：Rust 解码 → `wgpu` 纹理 → 原生子窗口
  （`raw-window-handle`）。虚拟摄像头复用同一解码结果。
- **方案 B（MVP 捷径）**：NAL 透传给 WebView2 的 **WebCodecs
  `VideoDecoder`**，`<canvas>` 显示。省 Rust 解码，但虚拟摄像头要再解一遍。

建议：MVP 用 B 快速跑通"能看到画面"，P3 前切 A。

---

## 6. 组件选型（Rust crate）

| 用途 | 推荐 | 备选 | 说明 |
|---|---|---|---|
| 异步运行时 | `tokio` | std thread | |
| mDNS 浏览 | `mdns-sd` | `astro-dnssd`（Apple Bonjour SDK） | 纯 Rust，无需分发 Bonjour |
| JSON | `serde` / `serde_json` | — | 字段名严格对齐 §4.3 |
| 字节分帧 | `bytes` | — | |
| H.264 解码 | **Windows Media Foundation**（`windows` crate） | `ffmpeg-next`（带 LGPL DLL） | MF 原生硬解零外部分发；FFmpeg 更省事 |
| Opus 解码 | `audiopus`（bundled libopus） | `opus` crate | Windows 无内置 Opus |
| 音频输出 | `cpal`（WASAPI） | — | |
| 输入注入 | **`windows` crate + `SendInput`** | `enigo` | 需拖拽/滚动精细控制，直接用 Win32 |
| 剪贴板 | `arboard` | — | |
| 截图/编码 | `image` | — | 窗口缩略图 JPEG |
| 托盘 + UI | **Tauri v2** | — | 与 VGO/MDDock 同栈 |
| 预览渲染 | `wgpu` + `raw-window-handle` | WebCodecs | §5.3 |
| 通知 | Tauri notification / Windows toast | — | "文件已接收"等 |
| 开机自启 | `auto-launch` crate | 注册表直写 | |
| 虚拟摄像头 | MF Virtual Camera API | DirectShow 源滤镜 | §9 R3 |
| 虚拟麦克风 | 虚拟音频驱动 | — | §9 R4，最难 |

---

## 7. 跨项目依赖（必须回改 iOS 的地方）

| # | 依赖 | 说明 |
|---|---|---|
| **D1** | iOS "等待 Mac"卡文案 | `IBLocale.Error.manualConnectHint` 现在写死"On the Mac: menu bar → …"。Windows 用户看到会困惑。需改成平台中立（"在电脑上：RemoteCrab → 手动连接 → `<地址>`"）或按 Mac/Windows 分两版。涉及 iOS 发版。 |
| **D2** | iOS 配对卡文案 | `Pairing.allowPrompt(name)` 里的 `name` 来自 `IBClientHello.name`。Windows 端要填**用户能认出的电脑名**（如 "Edwin 的台式机" / Windows 计算机名），不能是 `DESKTOP-7X2K`。 |
| **D3** | 文案单一来源 | §3.6 的 `shared/iblocale.json` 提取脚本需同时被 iOS/Mac 的 CI 引用，否则会漂移。 |
| **D4** | 产品页/下载 | `vgoapp.com/remotecrab/` 需加 Windows 下载入口 + Windows 说明（iOS onboarding 的 "Download for Mac" 也要考虑是否加 "for Windows"）。 |
| **D5** | **iOS 平台感知键盘 UI**（重要） | `IBClientHello` 加 `platform` 字段（§4.3）；iOS `CaptureEngine` 记录 `peerPlatform`；`IBModifierBar` 与 `KeyboardScreen` 快捷键栏按 Mac/Windows 分别呈现（§4.7）。涉及 iOS 发版。**没有这一步，Windows 用户看到 ⌘⇥/⌃↑ 会一头雾水。** |

---

## 8. 关键风险与对策

| # | 风险 | 严重度 | 对策 |
|---|---|---|---|
| **R1** | Windows 无原生 Bonjour，mDNS 浏览可能失败（AP 隔离/热点/VPN） | 高 | ① `mdns-sd` 浏览 `_remotecrab._tcp.local`；② **必须实现 direct-IP 兜底**（照搬 `startFallbackLoop`：上次 IP + 热点网关 `172.20.10.1`，端口 8765）；③ 手动 IP 逃生门 |
| **R2** | H.264 NAL 是 **AVCC**（无起始码），需 `nalUnitHeaderLength=4` | 中 | 构造 `avcC` extradata：`[0x01][profile/compat/level][0xFF=lengthSizeMinusOne=3][0xE1][SPS len BE][SPS][0x01][PPS len BE][PPS]`；每个 video 帧前置 4 字节大端长度。参照 `H264Decoder.swift:127-137` |
| **R3** | 虚拟摄像头：Win10 需注册 DirectShow filter；Win11 22H2+ 有 MF Virtual Camera API（可能要求 MSIX） | 高 | 放 P3；不做也能演示。Win11 走 MF，Win10 走 DirectShow filter + 安装器注册 |
| **R4** | 虚拟麦克风：Windows 无自带虚拟音频设备，需**签名驱动**（EV 证书 + 可能 WHQL） | 高 | 放 P3/可选；成本远高于 macOS HAL 插件 |
| **R5** | `KeyEvent.keycode` 是 Mac 虚拟键码，直接当 VK 用会全错 | 中 | 建映射表（§4.5）+ 单测覆盖快捷键（⌘→Ctrl 等） |
| **R6** | 滚动/捏合手感与 Mac 不一致 | 中 | 复刻 `ScrollCoalescer` 每帧合并 + 屏高增益；Windows `MOUSEEVENTF_WHEEL`（120 单位）累加小数余量；捏合→Ctrl+滚动 |
| **R7** | 多显示器：坐标语义需虚拟屏尺寸 | 中 | 用 `SM_XVIRTUALSCREEN/SM_CYVIRTUALSCREEN` 而非主屏 |
| **R8** | 首次安装被 SmartScreen 拦截（小白最容易卡这里） | 高 | EV 代码签名证书 + MSI/WiX（或 NSIS）；安装器首屏用大白话解释"为什么 Windows 会提示" |
| **R9** | 托盘弹层自绘的定位/失焦/多屏问题 | 中 | 参考成熟 Tauri 托盘弹层实现；固定高度（教训 14）；点击外部关闭 |
| **R10** | 系统键（音量/亮度）无统一路径 | 低 | `VK_VOLUME_*`/`VK_MEDIA_*` 走 `SendInput`；亮度需 WMI/Dxva2，可能不通用 |
| **R11** | 文案漂移（两端各写一份） | 中 | §3.6 单一来源 + CI 校验 |

---

## 9. 分阶段实施计划（UX-first 顺序）

### P1 — MVP：能看到画面 + 能操作（可演示、可自测）

1. `rc-protocol`：移植 `IBWire`/`IBEvents`，单测与 Swift round-trip 逐条对齐
2. `rc-discovery`：`mdns-sd` + direct-IP 兜底
3. `rc-net`：TCP + `clientHello`/`sessionReply` + ping 看门狗 + 6s 握手超时
   + token 持久化 + `busy/denied` 处理
4. `rc-decode`：H.264 解码（先 FFmpeg 快速跑通）
5. 预览窗（WebCodecs 或 wgpu）
6. `rc-input`：`SendInput` 鼠标/键盘 + CGKeyCode→VK 映射
7. **状态词表 + 托盘弹层 + 连接测试窗**（P1 就要，因为"看得懂状态"是体验底线）
8. 设置向导（Welcome → All Set；P1 无系统级步骤，先做骨架）

**验收**：真机 iPhone 连上 Windows，看到实时画面，触控板能移动/点击/滚动，
键盘能输入中英文；断网/重连状态提示清楚；连接测试窗四象限都亮。

### P2 — 补齐 macOS 已有多数功能

- Opus 音频 + WASAPI 播放 + RMS 电平
- 剪贴板双向（`0x13`）+ "发送剪贴板到 iPhone"动作
- 文件传输（`0x0F/0x10/0x11` → `%USERPROFILE%\Downloads\RemoteCrab`）+ `fileAck`
  + "在资源管理器中显示" + toast 通知
- 应用切换器（`EnumWindows` + `0x0C/0x0E/0x16`）
- 窗口列表 + 缩略图（Windows.Graphics.Capture + `0x17/0x18`）
- 系统键（`0x19`）
- `featureControl`（`0x07`）+ `featureState` 展示
- 控制面板（延迟 sparkline）+ 偏好设置
- 录制（可选，对照 `StreamRecorder`）
- 开机自启

**验收**：`tests/acceptance/windows-parity.sh` 覆盖 P2 各帧类型 + 各用户面。

### P3 — 系统级组件（Windows 独有硬骨头）

- 虚拟摄像头（MF Virtual Camera / DirectShow filter）+ 设置向导集成
- 虚拟麦克风（驱动，可选）
- 安装器（MSI/NSIS）+ EV 签名 + 自动更新
- 托盘弹层精致化 + Fluent 视觉打磨

---

## 10. 验收标准

| 层 | 验收方式 | 证据 |
|---|---|---|
| `rc-protocol` | `cargo test`：每个 kind encode→decode round-trip，与 Swift 用例对齐 | test 名 + 通过数 |
| 发现 + 握手 | 真机 iPhone 连接成功，日志 `sessionReply: accepted` | 终端 transcript |
| 解码 | 首帧日志 + 预览可见 | 截图 |
| 输入 | 触控板移动/点击/滚动、键盘中英文输入落到记事本 | 录屏/截图 |
| 兜底 | 关 mDNS（或热点网络）仍能直连 | transcript |
| **体验（小白验收）** | ① 首次安装到"看到画面"≤ 3 分钟且无需看文档；② 拔网线/关 Wi-Fi 后状态提示清楚、能自动恢复；③ 陌生 Mac 首次连接时 iPhone 弹配对卡；④ 连接测试窗四象限有实时反馈；⑤ 全流程中英切换正确 | 录屏 + 截图 |
| 回归 | `cargo test --workspace` + `cargo clippy` + 文案 CI | CI 输出 |

---

## 11. 开放问题（需产品/技术决策）

- **Q1 设计语言 → ✅ 已拍板：混合方案**（见 §3.7）。
- **Q2 `command`(⌘) 映射**：Windows 上映射到 `Ctrl`（符合直觉）还是 `Win`？
  建议 **Ctrl**，文档说明。
- **Q3 三/四指手势**：Mac 映射 Mission Control/Spaces。Windows 映射
  `Win+Tab`（任务视图）/ `Ctrl+Win+←→`（虚拟桌面）？还是不做？
- **Q4 虚拟摄像头优先级**：Windows 的"虚拟摄像头"卖点是否 P1 就要？否则
  摄像头只能在本 App 预览窗看，Zoom 里看不到。
- **Q5 分发形态**：MSI / NSIS / MSIX？MSIX 会影响虚拟摄像头 API 可用性。
- **Q6 是否复用 MDDock 的 Tauri 外壳 / 设计 token**，还是独立仓库。
- **Q7 虚拟麦克风**：是否接受"需要装驱动"？若否，直接划到"不做"。

---

## 12. 明确不做（建议）

- ❌ Android 采集端（PRD §15 已划线）
- ❌ 云端 / 账号 / 订阅（产品原则：纯本地）
- ❌ 与 macOS 版共享 Swift 代码（协议 + 文案 JSON 是唯一契约）

---

## 附录 A：Mac 接收端文件 → Windows crate 对照

| Mac 文件 | 行数 | Windows 对应 |
|---|---|---|
| `ReceiverSession.swift` | 1360 | `rc-net`（状态机）+ `rc-os`（分发） |
| `BonjourBrowser.swift` | 78 | `rc-discovery` |
| `H264Decoder.swift` | 230 | `rc-decode` |
| `AudioPlayer.swift` | 145 | `rc-audio` |
| `Input/CGEventInjector.swift` | 350 | `rc-input` |
| `SystemCommandHandler.swift` | 65 | `rc-os::system_keys` |
| `WindowCapture.swift` | 126 | `rc-os::windows` |
| `StreamRecorder.swift` | 208 | P2（可选） |
| `MenuBarMenu.swift` | 551 | 托盘弹层（React） |
| `SetupAssistantView.swift` | 492 | 设置向导（React） |
| `SetupStatus.swift` | 190 | 系统自检（`rc-os`） |
| `ControlPanelView.swift` | 340 | 控制面板（React） |
| `TestWindowView.swift` | 412 | 连接测试（React） |
| `PreferencesView.swift` | 338 | 偏好设置（React） |
| `RemoteCrabCore/Networking/*` | ~950 | `rc-protocol` |
| `IBLocale.swift` + `Localizable.xcstrings` | 718 | `rc-strings`（共享 JSON） |

## 附录 B：参考的 Swift 关键行号（实现时对照）

- 帧编解码：`IBWire.swift:192-263`
- 事件模型：`IBEvents.swift:8-110`
- 触摸注入语义：`CGEventInjector.swift:21-70, 137-243`
- 键盘映射表：`CGEventInjector.swift:111-130`
- 握手 + 超时：`ReceiverSession.swift:937-1074`
- direct-IP 兜底：`ReceiverSession.swift:712-845`
- H.264 AVCC 包装：`H264Decoder.swift:127-216`
- 服务类型 / 端口：`IBProtocol.swift:6-11`、`CaptureEngine.swift:854`
- 状态词表：`IBLocale.swift:36-54`、`IBStatusPill.swift:15-69`、
  `ReceiverSession.swift:1444-1462`
- 设置向导自检：`SetupAssistantView.swift:76-79, 474-479`
- 托盘弹层结构：`MenuBarMenu.swift:30-70, 286-431`
- 连接测试四象限：`TestWindowView.swift:16-37, 350-408`
- 全部用户文案：`IBLocale.swift`（尤其 `Setup` / `Error` / `Connection` /
  `MenuBar` / `TestWindow` 段）
