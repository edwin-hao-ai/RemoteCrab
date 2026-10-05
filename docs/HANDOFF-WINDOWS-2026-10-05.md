---
title: 交接给 Windows session —— Mac 侧做完了，剩下四件只有你的机器能量
type: handoff
status: current
last_verified: 2026-10-05
code_baseline: 0e9f423
---

# 交接：Mac 侧四条已修完，剩下四件只能在你那台 Windows 机器上做

读者：**Windows session**。写的人：**Mac session**（2026-10-05）。

先说清楚**已经不用你做的**，免得你重做：

| 你 10-04 交接的 | Mac 侧状态 |
|---|---|
| `CaptureEngine.swift` 扬声器习惯会静默关麦克风 | ✅ 已修（`SpeakerRestorePolicy` + 5 测试） |
| 4d 形状断言用累计平均，数学上不可能通过 | ✅ 已修（`SpeakerEnvelope`，6 测试） |
| iOS 接收 `0x25 requestKeyframe` | ✅ 已实现（`0x25` + `ForceIntraFrame`） |
| 「加 `NumberOfBFramesBetweenReferenceFrames: 0`」 | 🔴 **别做**，前提无效，见 §3 |

---

## 0. 三句话

1. **`0x25` 的协议定义你写对了，但发送逻辑你还没写** —— `rc-protocol` 里有
   `Kind::RequestKeyframe` 和它的 encode，但 `rc-net`/`rc-app`/解码器**零处发送**。
   Mac 侧现在能接收了，所以只差你按下按钮。
2. **Mac 侧已经把「B 帧是病因」这个结论否掉了**，用一台机器就否掉了，
   `ffprobe has_b_frames=0`，而且探针带对照组。详见 §3。
3. 你说「本 session 发现的第五处声称做了但实际没做」的那条 listener 现象，
   我已经补进 `docs/HANDOFF-IOS-QUALITY.md` §7 了，**但标成「未复现也未排除」**。

---

## 1. 🔴 `0x25`：定义有了，发送逻辑没有

你写的是「协议定义**和发送逻辑**」，并指向 `HANDOFF-MAC-SIDE` §4 第 4 条 ——
第 4 条讲的是另一个话题（声称 vs 实测的报告）。核实结果：

```
$ grep -rn "RequestKeyframe" windows/ --include="*.rs"
crates/rc-protocol/src/wire.rs:97:    RequestKeyframe = 0x25,
crates/rc-protocol/src/wire.rs:157:            0x25 => Kind::RequestKeyframe,
crates/rc-protocol/src/wire.rs:221:    encode_frame(Kind::RequestKeyframe, &[])
crates/rc-protocol/src/wire.rs:5xx: (三个测试)
```

**没有任何地方发送它。** `rc-app/src/speaker.rs` 里 kind `0x24` 有真的发送路径
（`encode_speaker_audio`），`0x25` 连调用点都没有。所以 Mac 侧这个功能现在
是**前向兼容但完全没人触发**的状态。

### 要你做的

在你的解码器已经判定「我丢了参考帧」的地方发一帧 `0x25`。判据建议：

- 收到 `.video` 但 OpenH264 什么都没吐出来，且**不是**刚收到 keyframe → 请求一次
- 每 N 个 NAL 最多请求一次，否则抖动一次会刷出一串请求
- 复用的现成代码：`rc_net/src/dispatch.rs` 里的 `tx`，和
  `rc_protocol::Kind::RequestKeyframe`

Mac 侧收到后做的事（你不用管，但方便你确认接线对不对）：

```
IBWire.Kind.requestKeyframe (0x25)
  → CaptureEngine.handleKeyframeRequest()
  → KeyframeRequestPolicy.shouldForceIntraFrame(sessionActive: cameraOn:)
  → H264Encoder.requestForceIntraFrame()
  → kVTEncodeFrameOptionKey_ForceKeyFrame on the next encoded frame
```

手机侧会打一行，可以用来验：

```
[video-forensic] keyframe request honoured — asking VideoToolbox for an IDR
[video-forensic] keyframe request ignored (session=false camera=false)
```

### ⚠️ 顺便：iOS 那边有一个你没写下来的坑，我已经补了

`IBWire` 原来对不认识的 kind 字节回退到 `.video`：

```swift
kind: Kind(rawValue: kindByte) ?? .video,   // ← 旧
kind: Kind(rawValue: kindByte) ?? .unknown, // ← 现在
```

也就是说**任何本 build 不认识的 kind 都被当成 H.264 NAL 喂进解码器**，`0x24`
和 `0x25` 都在其中。你给 `from_u8_or_video` 加守卫测试是对的，Swift 侧当时
什么都没有。现在未知 kind 走 `.unknown`，并且有一条测试断言**未知帧后面那一帧
仍然能解析**，这样一个坏字节不会把整条流吞掉。

---

## 2. 🔴 扬声器：iPhone ↔ Windows 播放这一段从来没跑过

Mac 侧的两条前提都做完了（麦克风不会被静默关掉、入口已开），**协议和 Windows
采集你那边也验过**（`rms=497 peak=1100 dropped=0`，125 包 / 2.5 s）。
唯一没跑过的是**最后一段：电脑的声音真的从手机出来**。

这是 §1 里那个「验收清单」第 3 行，需要你的机器 + 一台解锁的 iPhone：

- [ ] 手机声音菜单 → 扬声器项**可见**（Mac 侧已开，Windows 上也应该出现）
- [ ] 手机开扬声器 → **电脑声音从手机出来**
- [ ] 手机关扬声器 → 电脑声音回到本机

⚠️ 抄断言的话注意：`docs/HANDOFF-IOS-QUALITY.md` §6.2 里那段 4c/4d 的描述
**已经过时**（Mac 侧把 `pcmRms` 改成了 peak-hold，另加了 `pktRms=`）。
以 `RemoteCrabCapture/SpeakerPlayer.swift` 和 `scripts/e2e-speaker.sh` 的现状
为准，两边同一个断言不能有两种含义。

---

## 3. 🔴 B 帧结论：**已经被否掉了，不要改 iOS**

你 10-04 的结论（`docs/HANDOFF-MAC-SIDE-2026-10-04.md` §1）建立在解码
`docs/demo/remotecrab-demo.mp4` 上。那个文件是
**`scripts/demo-video.sh:99` 用 `-c:v libx264` 从 macOS 录屏生成的**：

```
$ ffprobe -v error -select_streams v:0 -show_entries stream=profile,has_b_frames,width,height \
    -of default=nw=1 docs/demo/remotecrab-demo.mp4
profile=High
has_b_frames=2
width=1468
height=1180
```

产品的码流是 **1080x1920**；这个文件是 **1468x1180 的并排合成画面**
（模拟器窗口 + Mac 接收端窗口，`screencapture -V 33`）。尺寸上就不可能是手机的
码流，而且模拟器没有摄像头 —— 它根本不是手机的画面。`High profile` 和
`has_b_frames=2` 是 libx264 的产物。

**你的数字我都复现了，一个不差**（工具和 OpenH264 的结论都是真的）：

```
ffmpeg                          721 帧
cargo run -p rc-render --example decode_file -- demo.h264
  decoded   : 27 frames, 1468x1180
  no output : 694 video NALs produced nothing
  refused   : 1388
```

问题只在于**这个文件从不上线**。

### 用一台 Mac 就把这个问题问完了

写了 `scripts/vt-bframe-probe.swift`：拿 `H264Encoder.createSession` 的
**原样 7 个 key** 跑真实 VideoToolbox，150 帧确定性噪声，输出 Annex-B 给
ffprobe。它**先读 `H264Encoder.swift` 确认那 7 个 key 还在**，对不上就退出 ——
不然它会安静地测量上个月的配置。

```sh
swift scripts/vt-bframe-probe.swift /tmp/vt.h264 shipping
swift scripts/vt-bframe-probe.swift /tmp/vt-reorder.h264 reorder   # 对照组
ffprobe -v error -select_streams v:0 -show_entries stream=profile,has_b_frames -of default=nw=1 /tmp/vt.h264
```

**实测（这台 Mac，macOS 26.5）**：

| mode | `AllowFrameReordering` | `has_b_frames` |
|---|---|---|
| `shipping`（线上那套 key） | `false` | **0** |
| `reorder`（对照组） | `true` | **2** |

对照组是关键：**它看得见 B 帧**（报 2），所以 shipping 那一档的 0 是读数而不是
 blindness。另外注意 `reorder` 的 **2** 和 demo 文件的 `has_b_frames=2` 一模一样 ——
进一步说明那个文件就是一个「允许重排序」的编码结果，即 libx264 的默认值。

**结论：线上这套编码配置不产生 B 帧，加那个 key 是修一个不存在的病。**
这也是你文档里那条行动项（「先量再改」）的答案。

**诚实的边界**：这是 macOS 的 VideoToolbox，不是 iOS 的。key 名和 SDK 相同，
所以它能否证、不能证明。真机抓一段仍然是最终判据，但方向已经很清楚了。

---

## 4. 两条 Rust 侧的 bug（在你那个 crate 里，本 session 没碰）

`HANDOFF_WINDOWS_MSI.md` §"顺带发现" 里这两条我确认仍然成立，都属于你的代码，
所以我没改（免得和你正在写的 crate 打架）：

1. **`Parser::try_parse_next` 会静默丢掉整个缓冲区。** 一个坏长度值触发
   `self.buffer.clear()`，把**已经收完整**的帧一起丢掉，而且**不计数、不上报**。
   表现是**画面卡死**而不是花屏，日志里什么都没有。修法：丢弃到该帧为止、
   保留之前的帧、记一次计数。
2. **`rc-render/src/window.rs` 的指针生命周期。** `update_with_buffer(&buffer, …)`
   传切片，minifb 异步持有指针；下一轮若因尺寸变化 `buffer = vec![…]` 重分配，
   minifb 可能正在读已释放内存。1080x1920 恒定所以不触发，**切分辨率就会**。

---

## 5. 那条「未复现也未排除」的 listener

`HANDOFF_WINDOWS_MSI.md` §顺带发现 item 1 说要补进
`docs/HANDOFF-IOS-QUALITY.md` —— **当时没补**。我补了，是 §7。

但我把它标成 **NOT reproduced, NOT excluded**，不是排除，理由：

- 你观察到的是「ping 通、二层可达、8765 无监听、手机不报错」
- 而「listener 从没启动」和「listener 启动了然后被停掉」从外面看**完全一样**
- 而且你观察的那次正好有一个 `vcam_forensics` 在跑 —— 那也正是手机最可能
  正在被占用、换地址、或者进后台的时候

**能一次性了结它的东西在手机侧**，不在你那边：iOS 现在**没有**同时打
「listener 起来了」和「listener 被拆了」这两行，所以从外面没法区分。
如果你要再查，先要这两行日志，否则第三次观察到的还是同一个歧义。

优先级我排最后 —— 你那两条 Rust bug 和 §1 的发送逻辑都是机械的、范围清楚的，
先做那些。

---

## 6. 本 session 在 Mac 侧做完的（可以对照着看）

`6fff9d5` + 后续提交，**560 Core 测试**（本轮 +20）、两个 app target、
Windows 套件、`cargo build --workspace` 全绿；每一条新断言都反向验过
（改坏生产值看它变红，再还原）。

另外一条你现在可以拿去用的实测：**Windows 上 `fatal runtime error: Rust cannot
catch foreign exceptions` 是托管方式不是 Windows 缺陷**（`--preview` 默认开，
minifb 在 macOS 开不了 Cocoa 窗口），`--no-preview` / `--decode-only` 立刻正常。

## 7. 交付

- [ ] `0x25` 的发送逻辑接上（§1）—— 现在定义是死的
- [ ] iPhone ↔ Windows 扬声器出声（§2）—— 唯一没跑过的一段
- [ ] `try_parse_next` 的缓冲区静默清空（§4.1）
- [ ] `window.rs` 的指针生命周期（§4.2）
- [ ] §5 那条 listener 的歧义，等 iOS 侧补了两行日志再动