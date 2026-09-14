# RemoteCrab — 发布就绪度分析（V1.0）

_2026-09-13 · 功能与细节层面 · 附 App Store 过审评估_

上架对象只有 **iOS 端 `RemoteCrab Capture`**；Mac 端 `RemoteCrab Receiver` 需要
Accessibility + CMIO system extension，通常**不走 Mac App Store**，单独分发。
所以"过审"只针对 iOS 包，但 iOS 包的核心价值依赖 Mac 端 —— 这正是最大风险。

---

## 1. 已具备（真机验证过）

| 能力 | 状态 |
|---|---|
| iPhone → Mac 摄像头（1080p30，VideoToolbox 硬编/硬解） | ✅ 真机 |
| 麦克风串流（48 kHz PCM） | ✅ 真机 |
| 触控板（拖动/点按/双指/修饰键/三指 Mission Control） | ✅ 真机 |
| 键盘（系统 IME / 中文 / 快捷键栏） | ✅ 真机 |
| 语音听写（设备端 SFSpeechRecognizer）+ 语音切应用/改写选中文本 | ✅ 逻辑+触发路径 |
| Bonjour 自动发现 + 多 Mac 配对（TOFU token，busy 退让） | ✅ 真机 |
| 应用切换器（iPhone 列出 Mac 运行中 App，一键拉起） | ✅ 真机 |
| 文件传输（照片/视频/文件 → `~/Downloads/RemoteCrab` + Finder） | ✅ 真机 |
| 剪贴板互通（双向） | ✅ 真机 |
| Mac 端录制（`.mov` + `.wav` → `~/Movies/RemoteCrab`） | ✅ 真机 |
| en + zh-Hans 本地化（跟随系统） | ✅ 已截图核对 |
| 74 单测 + `scripts/test.sh` + `scripts/e2e-device.sh`(10/10) | ✅ |

---

## 2. 功能缺口（发布前必须）

| # | 缺口 | 为什么必须 | 工作量 |
|---|---|---|---|
| F1 | **Camera Extension 用户激活 + 真机验证** | 头部卖点是"在 Zoom/OBS/Photo Booth 里当摄像头"。现在 Mac 端只有预览窗口；CMIO sysex 已装但用户未在系统设置打开、也未在任一 App 验证。**不跑通就必须收回营销文案** | 0.5 天 |
| F2 | **虚拟麦克风** 🟡 代码完成待装 | HAL `AudioServerPlugin`（`RemoteCrabMicDriver/`）+ 共享内存环 + 安装脚本已就绪并 build 通过；需 `sudo` 安装 + 验证，且要确认沙盒 app 的 `shm_open` 可用 | 装+验 0.5 天 |
| F3 | ~~**手动输入 IP 兜底**~~ ✅ 已做 | iPhone 固定 8765 端口 + 连接页显示 `IP:port`；Mac 菜单「手动连接…」 | 已完成 |
| F4 | ~~**审核员可测试路径**~~ ✅ 已做 | 设置里「演示模式」：无 Mac 也能看到示例摄像头画面 + DEMO 徽标 | 已完成 |
| F5 | **App Store 素材 + 托管 URL** | 真机截图、privacy/support URL、App Privacy 问卷 | 1 天 |
| F6 | ~~**录制合轨**~~ ✅ 已做 | 单个 `.mov`（h264 + aac） | 已完成 |
| F7 | ~~**锁屏/后台的清晰提示**~~ ✅ 已做 | 回前台 toast「视频在后台暂停，现已恢复」 | 已完成 |

## 3. 细节 / 体验缺口

- **安全**：局域网上是**明文 TCP**（无 TLS）。隐私政策说"不离开网络"是真的，但同网段可被嗅探。至少要在文档里如实说明；长期加配对 token 之外的传输加密。
- **首次体验**：相机/麦克风/语音/本地网络 4 个权限串行请求，较长；权限被拒后的引导还不完整。
- **Mac 端离线态**：popover 里仍显示 4 个灰色开关，信息密度偏高（新加了应用切换/文件/剪贴板/录制/自检，操作区变长）。
- **iPad**：布局未专门优化（metadata 里有 ipad129 截图位）。
- **国际化**：只有 en + zh-Hans；VoiceOver / Dynamic Type 未系统排查。
- **诊断**：无崩溃上报（隐私优先，但至少要 OSLog + 一个"导出日志"，否则真机问题无从查）。
- **Opus**：仍是裸 PCM（~96 kbps/向），WiFi 够用但浪费。

## 4. App Store 过审评估

### 结论
**权限、隐私、API 都合规，大概率能过；但有两个硬风险点，必须先解决。**

### 风险点
| 风险 | 指南 | 严重度 | 缓解 |
|---|---|---|---|
| **审核员无法测试**：核心功能依赖配套 Mac app（他们装不了/不会装） | 4.2 Minimum Functionality / 2.1 Completeness | 🔴 高 | 审核备注写清 + **演示视频 URL** + Mac app 下载指引；**强烈建议加一个 iOS 本地"演示模式"**，无需 Mac 也能看到假视频/假触控，让审核员点得动 |
| **营销夸大**："在 Zoom/OBS 当摄像头"但 F1 未跑通 | 2.3 Accurate Metadata | 🔴 高 | 先跑通 F1；否则 iOS 描述只写"Mac 端预览"，不写第三方 App 集成 |
| 后台音频模式用途 | 2.5.4 Background Modes | 🟡 中 | 审核备注说明：后台继续串流麦克风（与录音类 App 同类），且用户可控 |
| 本地网络 + Bonjour | 5.1.1 / 权限 | 🟢 低 | `NSLocalNetworkUsageDescription` + `NSBonjourServices` 已就位 |
| 语音识别权限 | 5.1.1 | 🟢 低 | `NSSpeechRecognitionUsageDescription` 已有，说明仅用于按住说话 |
| 出口合规 | 加密 | 🟢 低 | 未使用加密 → 按"不含加密/豁免"申报（与第 3 节的安全说明保持一致） |
| 付费/账号 | 3.1 / 5.1.1 | 🟢 低 | 免费、无 IAP、无账号、无追踪 |
| App Privacy 问卷 | — | 🟢 低 | 如实填 **Data Not Collected**（与实现一致） |

### 支撑材料清单（提交时随包）
- 隐私政策公开 URL（`PRIVACY.md` 内容托管）
- 支持 URL
- 6 张真机截图（iPhone 6.7" + 6.5"/5.5"）+ iPad（若声明支持）
- 审核备注：产品形态（iPhone 是 Mac 的外设）、如何在没有 Mac 时用演示模式、后台音频理由
- 可选：60 秒演示视频

## 5. 建议的 V1.0 范围

**必做**：F1 Camera Extension 验证（或收窄营销）· F2 虚拟麦克风（或收窄营销）· F3 手动 IP · F4 演示模式/审核材料 · F5 素材与 URL · F7 锁屏提示。

**可延后到 V1.1**：录制合轨 · Opus · 崩溃上报 · 10+ 语言 · iPad 精修 · 传输加密 · VoiceOver/Dynamic Type 全量。

**明确不做**（守住定位）：云 LLM 听写清理、agent 状态/Live Activity、MCP bridge、窗口缩略图（需屏幕录制权限）、任何人脸/滤镜。
