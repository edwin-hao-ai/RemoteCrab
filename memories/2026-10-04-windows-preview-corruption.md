# Memory: Windows 预览花屏 session（2026-10-04）

> 这份记录写给下一个 session 的人，不写给简历。
> 核心信息：**花屏不是手机的码率问题，是 Windows 侧解码器的问题**；但还差一步验证。

## 结论（全部测出来的，每条带数字）

**1. 根因：OpenH264 的 `DecodeFrameNoDelay` 解不了带 B 帧的流。**

决定性证据是**本产品自己录的** `docs/demo/remotecrab-demo.mp4`，同一份字节：

| 解码器 | 结果 |
|---|---|
| ffmpeg | 721 帧，零错误 |
| 我们的管线（OpenH264） | 27 帧，728 个 NAL 里 694 个被拒 |

OpenH264 自己 trace：

```
Error:DecodeCurrentAccessUnit()::::::PrefetchPic ERROR, pSps->iNumRefFrames:4.
Warning:parse_nal(), no exist Sequence Parameter Sets ahead of sequence...
Info:ResetDecoder(), context error code is 16384
```

第一个 IDR 失败 → ResetDecoder 丢 SPS → 之后每个 NAL 都报「没有 SPS」→ **永久死亡**，
而预览窗口继续显示一幅看起来合理的错误画面。

变量分离（同一画面重新编码，每次只改一个变量）：

| refs | B 帧 | 结果 |
|---|---|---|
| 4 | 2 | 27 帧（原文件） |
| 1 | 2 | 33 帧 ← 还是坏 |
| 2 | 0 | **721 帧全过** |
| 1 | 0 | 721 帧全过 |

**是 B 帧，不是参考帧数。** `openh264::Decoder::decode()` → `DecodeFrameNoDelay`，
「no delay」就是不做重排序。

**Mac 清楚是因为 VideoToolbox 天然支持重排序。** 这就是全部差别。

**⚠️ 未验证**：当前 iOS 构建（`AllowFrameReordering:false` + Main profile）
理论上不该产生 B 帧。demo 那个文件是 High profile + `has_b_frames=2`，录自更早的构建。
**抓一段当前构建的码流 `ffprobe` 确认 `has_b_frames` 之后再动 iOS。**

**2. 同时测出三个独立故障（别混在一起报）：**

- **iOS 只发 4fps**（承诺 30）：`CaptureEngine.swift:1280`
  `alwaysDiscardsLateVideoFrames = true` + `handleEncodedFrame` 在 VideoToolbox
  回调线程里直接 `connection.send`，WiFi 抖动（median 97ms / max 641ms）阻塞它
  → 编码器输出缓冲满 → 丢帧。
- **WiFi 延迟**：min 8ms / median 97ms / max 641ms。局域网正常 1-5ms。
  代码只能缓解。视频和触控共用一条 TCP 连接。
- **触控板方向没问题**：真机 86 采样，`in.dx` 与 `cursor_dx` **零反号**。
  之前几轮追的方向反转**不存在**。手感差是上面两条造成的。

**3. 之前三个 session 的诊断全是错的，而且错法相同。**

## 交付物（全部已验证、已推 origin/main）

- `rc_render::pixels` — 逐帧健康度对比**这条流自己的中位数**，不用固定阈值
- `renderer_fidelity` — 不用手机就能证明渲染层忠实（1080x1920 合成流逐级检查）
- `decode_file` — **这次最关键的工具**：任何 `.h264` 走和线上完全相同的管线，
  `--dump` 可与 ffmpeg 逐字节比，`--debug` 打开 OpenH264 自己的 trace
- `vcam_forensics` — 打印手机给的 `ownerName`、自动重试 refused 连接、
  声称 vs 实测、关键帧与离群帧的相关性
- `H264PreviewDecoder` — 记住 SPS/PPS 并在失败时重送（修丢包导致的**永久**死亡；
  **对 B 帧无效**）
- `FrameSlot` 改 `Arc` — 每帧不再深拷贝两次 8.3MB
- 协议 `0x25 requestKeyframe` + 接收端在拒绝时请求（iOS 侧待实现）
- app 状态行报告「声称 vs 实测」
- 卡住的修饰键保险丝（`released_keys` 只声明从未写入 / `end_gesture` 全仓零调用 /
  `released` 只写不读，三块都没接上，45 测试全绿）

## 我犯过的错（重要，比结论更值得记）

**这一 session 里「测量工具自己骗人」发生了 4 次**，全部同一类：

1. 「码率太低」——手机报的 6220 kbps 是**算出来的**，实际 `Quality` 覆盖了它，
   从来没人量过。真值约 9.2 Mbps。
2. 旧 `vcam_forensics` 的 8% 阈值——在**平铺合成测试图**上量的，
   而真实高对比场景量到 12.31%。
3. 我自己的 `detail()` 多除了一个帧数 → 309 帧的有纹理采集被误判成
   「镜头对着空白墙」，还打印了「这不是通过」以外的一堆错话。
4. 我在交接文档里写「已经加了请求关键帧的协议」，**当时其实没加**。

**教训**：每条要写进代码的数字，先问「谁在什么输入上量的」。继承来的数字最可能错，
因为没人复核不是自己产出的东西。见 `docs/lessons/windows.md` lesson 113-117。

## 下一步（需要 Mac / Xcode）

见 [`docs/HANDOFF-MAC-SIDE-2026-10-04.md`](docs/HANDOFF-MAC-SIDE-2026-10-04.md)：

1. `ffprobe` 确认当前构建的 `has_b_frames` → 决定 B 帧修不修
2. iOS：`NumberOfBFramesBetweenReferenceFrames: 0` 进 `VideoEncodingPolicy` + 断言
3. iOS：发送移出 VideoToolbox 回调线程 + 丢弃计数
4. iOS：实现接收 `0x25 requestKeyframe`
5. 重装后复测 fps（现在 4，承诺 30）

## 未做的

- **4K 支持**：环是文件映射所以 63MB 没问题，但 iOS 码率上限 16 Mbps 对 4K30
  （需 40-80）不够，解码内存和 minifb 窗口要重估。需要单独评估。
- **`origin/feat/windows-receiver`** 建议删：它唯一的独有 commit 改的是
  `HANDOFF_WINDOWS_MSI.md`… 实际是 `HANDOFF-WINDOWS.md`，而 main 上 `20376ce`
  **故意删掉了**那个文件（理由：描述的 9-crate/96-test 状态早被取代）。
  合它等于复活过期文件 + 塞一份「如何合并这个分支」的过期指令。