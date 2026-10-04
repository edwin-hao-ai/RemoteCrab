---
title: Windows 交接 —— 「用 iPhone 当音箱」功能（协议已就绪，接收端未实现）
type: handoff
status: current
last_verified: 2026-10-04
code_baseline: afdaab4
---

# Windows 交接：让 Windows 电脑的声音从 iPhone 播出来

日期：2026-10-04 · 全部工作在 **Mac 侧**完成并推送（`afdaab4`）· Windows 接收端
**一行都还没写**

> **2026-10-04 晚间追加：Mac 端自己先坏过一轮，已修好。** 下面第 3 节写的
> 「Mac 侧已实测跑通」指的是**链路通**，不是**音质对** —— 真实播放是尖锐的杂音，
> 根因有三个（第 6 节）。**这三个坑 Windows 端一个都躲不掉，而且第 3 节的
> 「已跑通」很容易让实现者以为调度和格式不用想。先读第 6 节再动手。**

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

---

## 6. ⚠️ 先读这一节：Mac 端自己坏过，三个坑你一个都躲不掉

**Windows 端采集系统声音之后，会立刻遇到和 Mac 端一模一样的三个问题。**
它们都不是 Mac 特有的，是「把系统混音抽出来 → PCM → 20 ms 一包 → 喂给播放器」
这条路的固有属性。第 3 节说「Mac 侧已实测跑通」，指的是**链路通**。

用户当时的原话是「非常乱七八糟的声音，而且好像关不掉，声音是那种很尖锐的」。

### 6.1 定时器不是调度器（最贵的一个）

Mac 端原来有一个 20 ms 定时器，**无条件**补一个静音包 —— 这是**故意的**，
因为 `AVAudioPlayerNode.isPlaying` 必须保持 true，否则系统会回收音频会话，
声音会断。它同时还有一个函数在来包时播真实音频。

两者都没错，合起来就是：**每秒喂 100 包，播放器只能消费 50 包**。
队列每秒涨 50 包（一秒延迟），于是：

| 现象 | 机制 |
|---|---|
| 声音乱、碎片化 | 真音频和静音交错，且越来越滞后 |
| 关不掉 | 队列里积压的上千个包还在播 |
| e2e 是绿的 | 没有任何断言检查填充比例 |

设备实测：填充 `916 / 1021` = **47%**。

正确形状是**反过来**：真实音频由**数据到达**驱动，用播放队列深度当**反馈项**
（ring 里够填满「当前队列 + 起播缓冲」才加下一包），定时器只负责维持 graph，
**绝不在有音频等待时补静音**。

> ⚠️ 还有一个更反直觉的：即使只让定时器喂音频也不行。
> `Task.sleep(20 ms)` **实测约 30 ms**，播放器每秒消费 50 包 —— 时钟漂了就喂不上。
> 实测 `played=33 包/秒` 而到达 `46 包/秒`，接收环溢出丢包。
> **所以真实音频的调度不能挂在时钟上。**

### 6.2 buffer 布局：声明和写法必须是同一个

Mac 端声明 `interleaved: true`，然后用**平面**写法 `int16ChannelData[ch][frame]` 填。

实测两个 channel 指针**只差 2 字节** —— `dst[1][0]` 和 `dst[0][1]` 是同一个地址，
**每个右声道样本都被下一个左声道样本覆盖**。结果：

* **尖锐** = 左声道 2 倍速播放
* **不清晰** = 右声道消失
* **杂音** = 幸存样本组成源里不存在的 L,R 配对（梳状滤波）

Windows 端 `AVAudioFormat` 同样能声明 `AVAudioFormatFlagIsInterleaved`，
`WASAPI` 的 `WAVEFORMATEXTENSIBLE` 也有对应位。**如果你的混音回调拿到的是
非交织（planar，每通道一个 buffer），而你按交织读（或反过来），症状一模一样。**

**测量的方法**：把两个通道指针打印出来算地址差。差 2 字节 = 交织；
差很大 = 平面。**不要靠猜。**

### 6.3 别用 tap 做这个诊断

Mac 端为了客观验证，加了个 `installTap` 监听输出 —— 它**把 app 搞崩了**（signal 5），
而且在崩之前一直报「静音」，也就是**它坏的时候看起来像功能坏了**。

要证明立体声是否正确，**从交给播放器的 buffer 里读回第一帧**即可，
主线程做，零风险：`outL=-6402 outR=-3366` 是两个不同的值（立体声 OK）；
如果两个值**完全相同**，那就是「一个通道 2 倍速、另一个丢掉」的形状。

### 6.4 验收不能只看「有没有收到包」

Mac 端原来的 e2e 断言只有 `pcmRms != 0`，填充占 47% 时它照样通过。
现在加了两条，**你实现完也照抄**：

```
4e 填充占比 <= 20%（silence / (enqueued + silence)）
4f 队列深度 <= 6 包（120 ms）
```

### 6.5 参考实现在哪

* 决策（纯函数，可测，有测试）：`RemoteCrabCore/Sources/RemoteCrabCore/Audio/SpeakerSchedule.swift`
  + `SpeakerPCMWriter.swift`，测试 `SpeakerScheduleTests` / `SpeakerPCMWriterTests`
* 接线：`RemoteCrabCapture/SpeakerPlayer.swift`
* 采集侧布局结论：`RemoteCrabReceiver/SystemAudioTap.swift`（`ingest` 附近有实测记录的注释）

**照抄调度决策和 buffer 写入这两个部分 —— 它们是跨平台的。**
采集部分（CoreAudio process tap → WASAPI loopback）才是你要写的。
