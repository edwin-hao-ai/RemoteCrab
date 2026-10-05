# 交接给 Mac / iOS session：Windows 侧查完的三件事

> Windows 接收端 session，2026-10-04。全部**在 Windows 机器上测出来的**，每条都带数字。
> 本文档只写 **iOS 侧需要做的事**，因为 Windows 侧已经做完了。
>
> 已同步到 `origin/main`。`git pull` 就能拿到。

---

## 0. 一句话

**Windows 的花屏不是手机的码率问题，是我们自己的解码器。** 已定位到确切机制。
但**还有一件事需要你在 Mac 上确认**，因为它决定这是不是一个还活着的病。

---

## 1. 🔴 花屏根因：OpenH264 的 `DecodeFrameNoDelay` 解不了带 B 帧的流

这是本次最重要的结论，**测出来的**，不是读出来的。

### 决定性实验

`docs/demo/remotecrab-demo.mp4` —— **本产品自己录的** demo。同一份字节：

| 解码器 | 结果 |
|---|---|
| **ffmpeg** | **721 帧，零错误** |
| 我们的管线（OpenH264） | **27 帧，728 个 NAL 里 694 个被拒** |

让 OpenH264 自己 trace 之后：

```
Error:DecodeCurrentAccessUnit()::::::PrefetchPic ERROR, pSps->iNumRefFrames:4.
Warning:parse_nal(), no exist Sequence Parameter Sets ahead of sequence...
Info:ResetDecoder(), context error code is 16384
```

**第一个 IDR 就失败 → `ResetDecoder()` 把 SPS 丢掉 → 之后每个 NAL 都报「没有 SPS」
→ 永久性死亡。** 而预览窗口还在继续显示一幅看起来合理的错误画面。

### 变量分离（这是关键的一步）

同一画面重新编码，每次只改一个变量：

| refs | B 帧 | 我们的解码器 |
|---|---|---|
| 4 | 2 | **27 帧**（原文件） |
| 1 | 2 | **33 帧** ← 还是坏 |
| **2** | **0** | **721 帧 全过** |
| 1 | 0 | 721 帧 全过 |

**是 B 帧，不是参考帧数。** 参考帧数降到 1 也没用，去掉 B 帧立刻全过。

原因在 API 名字里：`openh264::Decoder::decode()` 调的是
**`DecodeFrameNoDelay`**——「no delay」就是**不做重排序**，因此解不了带 B 帧的流。

### 为什么 Mac 清楚、Windows 花

同一台手机、同一个编码器、同一个 WiFi：

- **Mac** 用 **VideoToolbox** 编解码 → 天然支持 B 帧重排序 → 清楚
- **Windows** 用 **OpenH264** → 不重排序 → 花屏

**「手机的码率是不是太低」这个问题从一开始就是错的。** 手机没变过。

### ⚠️ 需要你在 Mac 上确认的一件事

`H264Encoder.swift:107` 已经有：

```swift
kVTCompressionPropertyKey_AllowFrameReordering:    false,
kVTCompressionPropertyKey_ProfileLevel:            kVTProfileLevel_H264_Main_AutoLevel,
```

**Main profile 本身不允许 B 帧**，所以**当前构建理论上不该产生 B 帧**。
而 demo 那个文件是 **High profile + `has_b_frames=2`**，
说明它录自**更早的构建**（那个 key 加入之前）。

**所以必须先抓一段当前构建的码流确认：**

```cmd
remotecrab.exe --record --no-preview --no-tray --connect <iphone-ip>:8765
remotecrab.exe        # 另一个窗口：输入 record 开始录制，quit 停止
```

```sh
ffmpeg -i <录制>.mp4 -c copy -bsf:v h264_mp4toannexb -f h264 x.h264
ffprobe -v error -select_streams v:0 -show_entries stream=has_b_frames,profile -of default=nw=1 x.h264
```

- **`has_b_frames=0`** → 当前构建没问题，**B 帧不是活跃病因，别改**。
  Windows 侧还有一个候选（参考帧丢失，见 `HANDOFF_WINDOWS_MSI.md`），需要用
  `vcam_forensics` 再定。
- **`has_b_frames > 0`** → 确认。iOS 侧修法：

  ```swift
  kVTCompressionPropertyKey_NumberOfBFramesBetweenReferenceFrames: 0,
  ```

  这个 key 比 `AllowFrameReordering` 更明确（iOS 15+ / iOS 26 SDK 都有），
  应该和 `quality`、`keyframeIntervalSeconds` 一起放进
  `RemoteCrabCore/Input/VideoEncodingPolicy.swift` 并加断言，
  这样测试能钉住它，而不是留成一个字面量。

**不要在验证 `has_b_frames` 之前改 iOS。** 上面的表证明 B 帧**能**解释
「解不出来」，但没说当前构建一定产生了它。

---

## 2. 🔴 iOS 只发了 4fps（承诺 30），已定位机制

Windows 侧实测（真手机，180 秒）：

```
video NALs received    : 348
frames decoded         : 309  (3.5 fps, wall clock)
stream rate            : 1878 kbps   （metadata 声称 9331）
keyframe every         : 14.85s     （配置是 2s）
NALs refused           : 39
```

**位置**：`RemoteCrabCapture/CaptureEngine.swift:1280`

```swift
videoOutput.alwaysDiscardsLateVideoFrames = true
```

采集层在消费端跟不上时**静默丢掉迟到的帧**。完整的因果链：

**WiFi 抖动（实测 RTT median 97ms / max 641ms） → `connection.send` 阻塞 →
VideoToolbox 的输出回调被卡 → 内部缓冲满 → 丢帧。**

注意 **`handleEncodedFrame` 是在 VideoToolbox 的回调线程里直接
`connection.send` 的**（`CaptureEngine.swift:2980`）。只要网络有抖动，
这个回调就阻塞，而它阻塞的是**编码器的输出通路**。

### 建议的改法

**不要在 VideoToolbox 的回调线程里做网络发送。** 把帧交给一个自己的队列，
队列满了就丢最新的（live 流本来就该丢旧的，不是积压）：

- 一个有界队列 + 一个发送线程，`connection.send` 移到发送线程
- 队列满时丢**最旧**的帧，并且**计数**——现在这个丢弃是完全静默的
- `H264Encoder` 已经有 `didDrop` 委托会打 `[video-forensic] capture DID DROP frames: N total`，
  把它接到队列丢弃上也一起打，这样两个丢弃点能区分开

### WiFi 本身

代码侧只能缓解（降码率/降分辨率给链路腾带宽），**根本上是网络问题**：
`min=8ms / median=97ms / max=641ms`，局域网正常是 1-5ms。
视频和触控走同一条 TCP 连接，带宽被视频占满时触控事件会排队——
这大概就是「触控板不太好用」的一部分原因。

---

## 3. 协议缺一个能力：请求关键帧

OpenH264 自己的 issue 里，对「解码器跟不上/丢包」的标准对策是
**`ForceIntraFrame`**（#1998、#1163）——检测到丢帧就向编码器要一个 IDR。

**这个产品里没有这个能力。** `IBCameraCommand` 只有 `position`（前后摄像头切换），
协议里没有任何「请求关键帧」的东西。

Windows 侧我已经加了协议定义和发送逻辑（见 §「已经做完」第 4 条），
**iOS 侧需要你实现接收**：

- 收到 `0x25`（`requestKeyframe`）时，调
  `VTCompressionSession` 的 `ForceIntraFrame` —— 也就是 `H264Encoder`
  需要的那个 `force_intra_frame()`
- `H264Encoder` 里已经有类似的东西（`VTCompressionSessionEncodeFrame` 的
  `forceKeyFrame` 参数），接上即可

---

## 4. 已经做完的（不需要 Mac 参与，全部已验证）

1. **`decode_file` 工具**——任何 `.h264`（`.mp4` 先抽流）走**和线上完全相同**的管线，
   输出 NAL 普查、拒绝计数、健康判决。`--dump` 可与 ffmpeg 逐字节对比，
   `--debug` 打开 OpenH264 自己的 trace。**以前没人能在不连手机的情况下
   判断解码器有没有坏**——这就是前三轮 session 绕圈的原因。

   ```sh
   cargo run --release -p rc-render --example decode_file -- file.h264
   ```

2. **取证探针会主动点名这个故障**——关键帧到了但一个都没解出来时，它明确说
   「不是网络的错，是解码器拒绝了自包含的画面」，给出 B 帧这条已知原因和
   §1 里那条 `ffprobe` 命令。以前是永远显示错误画面。

3. **SPS/PPS 重新注入**——`H264PreviewDecoder` 记住参数集并在失败时重送。
   **对 B 帧无效**（OpenH264 是根本解不了，不是丢了 SPS），但它修另一个真实故障：
   丢包丢 SPS 会让流**永久**死掉，而 OpenH264 自己的 issue #3448 确认它
   用灰/绿色填补丢失区域——**那正是「彩色噪点」的来源**。有 `reinjections()` 计数可观察。

4. **接收端会报告「声称 vs 实测」**——以前状态行只印 metadata，
   而 iOS 那个 metadata 的码率是**算出来的**（被 `Quality` 覆盖，实际无效），
   所以「streaming @ 30fps (9331 kbps)」可能是流量的 1/8。现在会打：

   ```
     ⚠ MEASURED 3.5 fps / 1878 kbps against a claim of 30 fps / 9331 kbps
        the phone is not sending what it says.
   ```

5. **触控板方向问题已结案**（如果你还记得那条线）：真机
   `REMOTECRAB_E2E_TRACKPAD_DIR=1` 跑了 86 个采样，`in.dx` 与 `cursor_dx`
   **零反号**。方向是对的。之前几轮追的方向反转**不存在**。
   真正的问题是 §2 的丢帧，以及 WiFi 延迟。

---

## 5. 一条方法论，建议 Mac 也照着做

这一整轮最贵的浪费不是 bug，是**测错了还在往下走**。同一个 session 里：
- 「码率太低」——手机报的码率是**算出来的**，从来没人量过
- 「阈值 8% 判断像素坏了」——那个阈值是在**平铺合成测试图**上量的，
  而真实场景量到 12.31%
- 我自己的工具也说了一句假话（把有纹理的画面判成「镜头对着空白墙」，
  因为 `detail()` 多除了一个帧数）

三个都是同一类：**看起来像测量，其实是拿错输入的猜测。**

**每条要写进代码/文档的数字，先问「谁在什么输入上量的」。** 继承来的数字是最可能错的，
因为没人会去复核不是自己产出的东西。

详见 `docs/lessons/windows.md` lesson 113-117。

---

## 6. 验收清单（Mac 侧做完之后）

- [x] 抓当前构建的码流，`ffprobe` 确认 `has_b_frames`
      → **2026-10-05 做了，而且不需要手机**：`scripts/vt-bframe-probe.swift`
      拿 `H264Encoder.createSession` 的原样 key 跑真实 VideoToolbox，
      `has_b_frames=0`，对照组（`AllowFrameReordering=true`）报 **2**
      —— 探针看得见 B 帧，所以 0 是读数。见 `docs/HANDOFF-WINDOWS-2026-10-05.md` §3
- [x] ~~如果 > 0：加 `NumberOfBFramesBetweenReferenceFrames: 0`~~
      → **测出来是 0，所以这一条作废，不要加。** 下面那条「为什么这个文件不算数」
      才是真正的答案：`docs/demo/remotecrab-demo.mp4` 是
      `scripts/demo-video.sh:99` 用 `-c:v libx264` 从 macOS 录屏生成的，
      ffprobe 读出 `1468x1180` 的并排合成画面，而产品码流是 `1080x1920`。
      `High profile` / `has_b_frames=2` 是 libx264 的产物。
      另外「Main profile 本身不允许 B 帧」这个理由本身也不对 —— Main 是允许
      B-slice 的，真正压制它们的是 `AllowFrameReordering: false` + `RealTime: true`
- [ ] 重装 iOS app，Windows 侧再跑一次 `decode_file`，帧数与 ffmpeg 对得上
      → **需要 Windows 机器**，已交出去
- [ ] ~~`handleEncodedFrame` 的发送移出 VideoToolbox 回调线程~~
      → **这一条的前提是错的，没有做。** `handleEncodedFrame` 根本不在
      VideoToolbox 回调线程上：两个调用点都是 `Task { @MainActor in … }`
      （`CaptureEngine.swift:470` / `1096`）。真实链路是
      采集队列 → VT `outputHandler` → `queue.async` → 编码队列 → `onFrame`
      → MainActor → `connection.send`，**网络发送早就和编码输出解耦了**，
      「移出回调线程」是空操作。
      顺带两处纠正：`didDrop` 不是委托，只是 `captureOutput(_:didDrop:from:)`
      的私有计数器；真正的风险是 `connection.send` 跑在**主线程**，
      背压会卡 UI（规则 1），那是另一个问题，**需要重新测量**再决定改不改
- [x] 实现接收 `0x25 requestKeyframe`
      → 已实现：`Kind.requestKeyframe (0x25)` + `handleKeyframeRequest()` +
      `H264Encoder.requestForceIntraFrame()`。**但目前没有任何接收端会发它** ——
      Windows 侧的发送逻辑缺失，已交出去
- [ ] 再抓一段码流，确认 fps 接近 30（现在 4）
      → **需要真机**，未做

### 额外补的一条（你 10-04 没提，但更危险）

`IBWire` 对不认识的 kind 字节回退到 `.video`（`Kind(rawValue:) ?? .video`），
所以**任何本 build 不认识的 kind 都被当成 H.264 NAL 喂进解码器** —— 包括
`0x24` 和 `0x25`。你给 Rust 的 `from_u8_or_video` 加守卫测试是对的，Swift 侧
当时什么都没有。现在未知 kind 走 `.unknown`，并有测试断言未知帧**后面那一帧
仍然能解析**，避免一个坏字节吞掉整条流。