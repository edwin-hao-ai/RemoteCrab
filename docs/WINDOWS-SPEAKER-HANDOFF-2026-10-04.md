---
title: Windows 交接 —— 「用 iPhone 当音箱」功能（协议已就绪，接收端未实现）
type: handoff
status: superseded
last_verified: 2026-10-04
code_baseline: 096f287
superseded_by: WINDOWS-SPEAKER-2026-10-04.md
---

> **✅ 本交接已实现，见 [`WINDOWS-SPEAKER-2026-10-04.md`](WINDOWS-SPEAKER-2026-10-04.md)。**
>
> 第 1 节（协议）照做；第 2 节（loopback）照做，`IAudioClient::Initialize` 需要传
> **完整的 40 字节 `WAVEFORMATEXTENSIBLE`**，只给 18 字节的头会 `E_INVALIDARG`
> （0x80070057）；第 3 节（必须 PCM）照做；第 4 节（删 iOS 那行）**还没做**，
> 因为 Mac session 得先修一个会让麦克风被静默关掉的 bug（新文件第 6 节）；
> 第 5 节的「Windows 没有等价物」做成了运行时 A/B + 崩溃可恢复的 marker；
> 第 6 节（验收清单）变成了一条命令：`remotecrab --speaker-probe`，
> 本机实测 `rms=497 peak=1100 dropped=0`。
>
> **下面保留原文**，作为设计决策的记录。

---

# Windows 交接：让 Windows 电脑的声音从 iPhone 播出来

日期：2026-10-04 · 全部工作在 **Mac 侧**完成并推送（`096f287`）· Windows 接收端
**一行都还没写**

---

## 0. 一句话

协议两端都已就绪（kind `0x24` + `feature: "speaker"`），Mac 侧采集已实测跑通，
**Windows 侧只差「采集系统声音」这一件事**。iOS 端在 Windows 上**故意隐藏了这个
入口**，等你实现采集后再打开 —— 见第 4 节，那一行改完功能就全平台可用。

---

## 1. 协议已经为 Windows 准备好了

`windows/crates/rc-protocol/src/wire.rs` 已登记：

```rust
SpeakerAudio = 0x24,
```
以及 `0x24 => Kind::SpeakerAudio` 的分派，和
`json_codec!(encode_speaker_audio, decode_speaker_audio, Kind::SpeakerAudio, AudioPacket);`

**payload 复用现有的 `AudioPacket` 结构，一个字段都不用加**（`windows/crates/rc-protocol/src/events.rs:154`）：

| 字段 | 值 |
|---|---|
| `opus_data` | **未压缩的 Int16 PCM**（不是 Opus，见第 3 节） |
| `sample_rate` | `48000` |
| `channels` | `2` |
| `codec` | `"pcm"`（`AUDIO_CODEC_PCM` 常量已存在） |
| `timestamp_micros` | Unix 微秒 |

包长 **3840 字节** = 20 ms × 48000 × 2ch × 2 bytes。

> ⚠️ **`from_u8_or_video` 的兜底是 `Kind::Video`。** 如果你在 Windows 端回发
> `0x24` 却没有登记，iPhone 会把这个 JSON 当成 H.264 NAL 喂进摄像头解码器 ——
> **表现是摄像头画面被搞坏，不是一个报错**。已经有测试
> （`every_declared_kind_is_reachable_from_its_byte`）钉住了这一点，别删。

---

## 2. 你要实现的：WASAPI loopback 采集

Mac 侧用的是 CoreAudio process tap。**Windows 没有等价物，需要用 WASAPI 的
loopback 模式**：

```
IAudioClient::Initialize(..., AUDCLNT_STREAMFLAGS_LOOPBACK, ...)
```

- **不需要驱动、不需要签名、不需要新的依赖族。** `windows` crate 0.62 已经在
  5 个 crate 里依赖了，只需要打开 feature：
  `Win32_Media_Audio`、`Win32_System_Com`、`Win32_Devices_FunctionDiscovery`
  （三个 feature 我确认过**已在本地 crate 里**，离线可解析）。
- loopback 采集的是**默认输出端点的混音**，这跟 Mac 的全局 tap 语义一致。
- ⚠️ **已知限制：loopback 只截获送到默认输出端点的音频。** 用户把声音送到
  AirPods/HDMI 时可能抓不到 —— Mac 侧的 tap 没有这个限制（实测过：声音送到
  一个完全无关的虚拟输出设备，tap 照样捕获）。这个差异要在 UI 或文档里说清楚。

### 数据流

```
默认输出端点 → IAudioCaptureClient → 读 WASAPI 缓冲
  → 转 Int16 交织立体声（源通常是 Float32，48 kHz）
  → 每凑够 960 帧发一个 kind 0x24
```

发包的位置对齐 Mac 侧的 `ReceiverSession.pumpSpeakerAudio()`（用
`windows/crates/rc-audio` 或新建一个 crate）。

---

## 3. 必须用 PCM，不能用 Opus（这条是实测结论，别重新推导）

`rc-audio` 里已经有纯 Rust 的 Opus 编解码。**扬声器通道不要用它。**

Mac 侧实测（2026-10-04，macOS 26）：把 Opus 扩成立体声后，**编码端确实是立体的
（包大 2.3 倍），但解码端每个包只回 960 个样本 —— 单声道，而且幅度只剩约三分之一**。
读作交织立体声时左右声道 rms 完全相同，这是「被压成单声道」的特征，不是「安静的
立体声」。

- **平台是好的**：`afconvert` 自己往返立体声 Opus 完全正确（左 rms 8426 / 右
  rms 0）。所以是 `AudioConverter` 调用方式的问题，**不是不可能**，值得有人跟进。
- 两条死路，别再走：`AudioStreamBasicDescription` 在当前 SDK 里**没有
  `mChannelsPerPacket` 字段**；`afconvert -d "opus@48000/2"` 会被
  `ExtAudioFileSetProperty` 拒绝。
- 详见 `docs/lessons/mac-receiver.md` lesson 124。

**为什么 PCM 可以接受**：48 kHz 立体声 Int16 = **1.5 Mbps**，相对同一条链路上已经在
跑的 H.264 视频不算什么，而且**零编解码延迟** —— 这一点对这个功能比带宽更重要，
因为端到端延迟是它最弱的地方。

---

## 4. 打开 iOS 端的入口（一行）

`RemoteCrabCapture/ContentView.swift`，麦克风那个下拉菜单里：

```swift
// 删掉这一行，扬声器项就会出现：
let speakerAvailable = !engine.connectedIsWindows
```

改成 `true`（或者直接去掉这个 gate）。**这行的注释说明了为什么现在隐藏**：一个
Windows 用户点了一个永远不会有反应的按钮，比看不到这个功能更糟。

菜单本身已经是**两个独立开关**（麦克风 / 扬声器，各自打勾），和「镜像 / 扩展屏」
那个下拉菜单是同一个写法。**不要**把它改成一个「关/麦克风/扬声器」的三选一 ——
那是两个独立功能。

---

## 5. Windows 特有的一个坑：「不要两边一起响」

Mac 侧靠 tap 的 `muteBehavior = .mutedWhenTapped` 解决：手机播的时候电脑本机
安静，而且**手机一断音频自动回到电脑**（这正是选这个方案而不是「虚拟输出设备」
的原因 —— 后者在手机断开时会留下一个完全没有声音的电脑，用户只能自己去系统设置
里改回来）。

**Windows 没有等价物。** 你有两个选择：

| 方案 | 代价 |
|---|---|
| 抓完不处理，电脑和手机一起响 | 最简单；用户自己调音量 |
| `IAudioEndpointVolume::SetMasterVolumeLevelScalar(0)` 压主音量 | **进程崩了会把音量留在 0**，必须下次启动时恢复 |

**如果选压音量**：恢复逻辑要放在启动路径的最前面，并且要有「上次退出时是否还
在静音」的持久标记。**这是 Windows 侧唯一需要小心设计的地方**，其余部分比 Mac
侧简单（不需要驱动）。

Mac 侧已经把这件事做成了用户偏好（`remotecrab.mac.speakerMutesLocal`，默认
mute），Windows 侧建议对齐：让用户选，而不是替用户决定。

---

## 6. 真机验证清单（🔒 只能在你的 Windows 机器上做）

Mac 侧有一条真机 e2e：`./scripts/e2e-speaker.sh`。**它的断言设计值得照抄一份
Windows 版**，尤其是最后两条 —— 我在 Mac 上被自己的 harness 骗了五次：

1. **`pcmRms` 必须非零** —— 包在流动不等于声音在流动。系统输出是数字静音时，
   所有「包计数」断言都会通过，而用户听到的是无声。
2. **包络（envelope）必须有形状** —— 一段有音符和间隔的音频 arriving 完整时会打印
   出波形；一条直线说明收到的是单音或片段。iOS 端
   `SpeakerPlayer.envelopeText` 已经在报这个，Windows 端照做。

其他要照抄的：
- 先**编译并安装**再测，并**验证装上去的二进制里真的有这段代码**（我第一次跑
  测的是几个月前的旧接收器，得到四个自信的 FAIL）。
- **Mac 日志窗口要在启动手机之前打开**（连接在 1–2 秒内建立）。
- 测之前**重启接收器**（强制重装手机 app 会让 Mac 持有一个已不存在的连接对象，
  它不会重拨，然后手机会被另一台电脑接管）。
- 手机被别的电脑占着时是 `busy`，**那是正确行为**，脚本应当明确说出来并退出。

---

## 7. 当前状态（诚实版）

| 部分 | 状态 |
|---|---|
| 协议（两端） | ✅ 已登记并测试 |
| iOS 播放 | ✅ 真机实测跑通，492 个包到达并播出 |
| iOS UI | ✅ 两个独立开关，中英文案齐全 |
| Mac 采集 | ⚠️ tap 抓到真实声音（rms=1989 peak=8856），但 `takePacket()` 从环形缓冲读出全零 —— **未解决的缺陷** |
| Windows 采集 | ❌ 未开始 |
| iPad | ❌ 未测 |

**所以这个功能目前还不能用**：界面正常、数据在流动、但听到的是静音。缺陷已经
精确定位在 `RemoteCrabReceiver/SystemAudioTap.takePacket()` 读环形缓冲这一步 ——
Mac 和 Windows 的实现都会共用这个设计，所以**先在 Mac 上把它修对，再写 Windows
的版本**，否则同一个 bug 会写两遍。
