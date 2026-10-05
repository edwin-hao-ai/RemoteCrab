# Handoff: Windows receiver — install, camera, and the unresolved corruption

> **Read this first.** Windows session, 2026-10-03 → 2026-10-04. Everything in
> "Done" was measured on this machine. The corruption at the bottom is **not
> solved** and the forensics probe that will solve it has never produced a
> verdict, because the phone kept refusing the connection.

- Repo: `E:\RemoteCrab`, branch `main`
- Last commit at handoff: `dd74571`, in sync with origin, tree clean
- Windows: 34 test suites green, clippy `-D warnings` clean

## Done

- [x] `.NET SDK 9.0.318` + `WiX 4.0.5` installed. WiX 7 was installed first and
      removed again — it demands accepting the OSMF EULA, which nobody should
      do on the user's behalf.
- [x] **`windows/tools/RemoteCrab.wxs` compiles.** It had never been built.
      Six defects fixed, worst first: it unregistered a CLSID
      (`{8B2C4D19-…}`) that exists nowhere in the product; used the WiX **v3**
      `Schedule="installRemoveInitializeVersion"`; guarded the MinGW runtime
      behind a preprocessor variable nobody defined; duplicated cleanup logic
      the app already owns; `sed` ate the backslashes in `@PAYLOAD@`; plus
      schema drift.
- [x] **The installer registers the virtual camera** (`9a0e742`). The package is
      perMachine, so it is elevated for its whole run; it was spending that on
      copying files and then telling users to open an elevated PowerShell. One
      UAC prompt at install time, which is what every Windows app does; **no
      second prompt during use**.
- [x] Cleanup runs the product's own `--uninstall-vcam-machine` as a deferred
      SYSTEM action (type 3170, sequence 3499, just before `RemoveFiles`).
      Machine-wide only — under SYSTEM `%APPDATA%` is the *system profile's*,
      so the full command deleted the wrong user's data. Never prompts. The COM
      keys are in the Registry table now, so Windows Installer removes those
      itself; the action is there only for the ring file's NULL DACL.
- [x] MSI built and verified: `dist/RemoteCrab-1.0.0.msi`, 1,794,048 bytes.
      File table holds **exactly** `remotecrab.exe` + `rc_vcam_source.dll` —
      the `MsvcBuild` guard works. 393 tests pass, clippy `-D warnings` clean.
- [x] **Full install→use cycle verified on the real machine.** Installed with
      `msiexec /i` and one UAC click, no other command:
      CLSID written to `C:\Program Files\RemoteCrab\rc_vcam_source.dll` ·
      `ThreadingModel = Both` · DLL present · `remotecrab.exe --vcam-selftest`
      from the installed copy → `vcam_consume` reports
      **`PASS — 11 samples, 34560 changing bytes`**.
- [x] **No second elevation after install.** A non-admin process can create
      files in `%ProgramData%\RemoteCrab` (the `Users` ACE carries `Write`), and
      the self-test that published those frames was itself non-elevated.
- [x] The MSI is **unsigned**, so `verify` still exits nonzero. That is correct,
      not a bug. See the SmartScreen note below.

## 预览窗口花屏 — 已排除一半，另一半需要手机

用户截图（`RemoteCrab Preview — 1080x1920`）：**沿高对比边缘的彩色噪点 + 周期性横向条带**，
画面内容仍可辨认。

### ⚠️ 下面这段判决规则是**错的**，不要照着它读

本文件上一版写着「`harsh horizontal > 8%` → 像素已坏 → 坏在上游」。**那个 8% 是在
一个平铺的合成测试图上量出来的阈值。** 同一批改动里的 `renderer_fidelity` 把一段
**可证明完好**的 1080x1920 流推过同一个解码器和 `window.rs` 那一模一样的 blit，
逐级确认无失真——它在**干净流上量到 12.31%**。真实高对比场景本来就有这么多边缘。
旧规则会判它「像素已坏」，把责任推给手机，理由是渲染层有 bug，而那个 bug 不存在。

### ✅ 已用证据排除的（这次是量出来的，不是读出来的）

`cargo run --release -p rc-render --example renderer_fidelity` — 退出码 0，
逐级检查全部通过：

| 阶段 | 检查 | 结果 |
|---|---|---|
| 1 解码 | 14 个 NAL → 12 帧，几何 1080x1920 | 通过（SPS 读取正确） |
| 2 缓冲 | 每帧 `pixels.len() == w*h` | 0 帧不符 |
| 3 通道序 | 逐 thirds 判定主通道（红\|绿\|蓝 场景） | 12/12 帧一致，`red\|green\|blue` |
| 4 blit | 复刻 `window.rs` 三句话，含 resize 分支 | resize 1 次，0 帧被改动 |
| 5 画面 | 逐帧对流自身中位数 | **uniform**，无离群帧 |

**所以渲染层被证明是忠实的：它没法把一条正确的流变成一幅错误的画面。**
花屏产生在解码器**之前**。

### ✅ 真机活流也拿到了判决（这次是第一次真的跑通）

`vcam_forensics` 连上真 iPhone 跑了 180 秒（`Accepted`，`camera_on=true`）：

```
  video NALs received    : 361
  of those, keyframes    : 6
  frames decoded         : 307  (3.6 fps, wall clock)
  NALs refused           : 54
  saturated pixels       : 0.35%
  harsh horizontal       : 0.02%
  harsh vertical         : 0.02%
VERDICT:
  uniform. Every frame carries about the same amount of edge energy ...
```

**像素是健康的**，没有任何一帧离群。渲染层第二次被排除，这次是对着真手机。

**但这次测量有个必须说清楚的弱点**：`harsh horizontal 0.02%` 意味着**画面几乎没有细节**
（0.04% pooled，对比 `renderer_fidelity` 那段可证明完好的流是 24.6%）——
拍的时候镜头没对着有纹理的东西。**这种输入本来就不可能显出花屏**，
所以"没发现异常"在这一次**不能**证明解码器没问题。

工具现在会把这种情况单独报成 `TOO LITTLE DETAIL TO JUDGE — and that is not a pass`
并告诉你把镜头对准有纹理的高对比物体再跑。**那一次才是能真正复现花屏的测量，还没做。**

### 🔴 同时查出来一个更严重的问题：码流本身是坏的

| | 实测 | 声称 |
|---|---|---|
| 帧率 | **~4 fps** | 30 |
| 码率 | **820 kbps** | metadata 说 6220 |
| 关键帧间隔 | **14.1s** | 1s（现在是 2s） |
| 解码器拒绝的 NAL | **54** | 0 |

`harsh vertical 0.00%` + `keyframe every 14.11s` + 一堆 1.2 KB 的 NAL，
和 `H264Encoder` 里那个 `lumaProbe` 注释描述的"相机在送黑帧"是同一类症状。
**这是 iOS 侧的 encoder/transport 问题，和"花屏"是两个独立的问题，别混在一起报。**

探针现在会把这些直接标出来（`** the phone promised 30 fps and delivered 4.2`），
不会再出现"像素正常"掩盖"码流根本不对"。

### ❌ 码率这条线已经断了（不是被排除，是被证明从来没测过）

`6220 kbps` 是手机**自己算出来写进 metadata** 的，从来没有任何东西量过它。
`H264Encoder` 同时设 `AverageBitRate` 和 `Quality`，**iOS 上 `Quality` 直接覆盖前者**——
要 6,220 和要 9,331 产出**逐字节相同**（见 `dd7022d`，
`scripts/vt-bitrate-probe.swift` 实测 `quality 0.70 → 9,179 kbps`）。

**9.2 Mbps 对 1080p30 是正常码率**，所以「码率不够」这个解释现在也站不住。
`docs/HANDOFF-IOS-QUALITY.md` §1 的 `0.1 → 0.15` 改法**是惰性的**，别再照着做；
那边该文件的结论已被 `dd7022d` 推翻，正确的旋钮是 `Quality`。

## 🔴 花屏根因：OpenH264 的 `DecodeFrameNoDelay` 解不了带 B 帧的流

**这是本次最重要的结论，测出来的，不是读出来的。**

### 决定性实验（本仓库自己的文件）

`docs/demo/remotecrab-demo.mp4` —— **本产品录的** demo 视频。同一份字节：

| 解码器 | 结果 |
|---|---|
| **ffmpeg** | **721 帧，零错误** |
| **我们的管线**（OpenH264） | **27 帧，728 个 NAL 里 694 个被拒** |

让 OpenH264 自己开口之后：

```
Error:DecodeCurrentAccessUnit()::::::PrefetchPic ERROR, pSps->iNumRefFrames:4.
Warning:parse_nal(), no exist Sequence Parameter Sets ahead of sequence...
Info:ResetDecoder(), context error code is 16384
```

**第一个 IDR 就失败 → `ResetDecoder()` 把 SPS 丢掉 → 之后每个 NAL 都报「没有
SPS」→ 永久性死亡。**

### 变量分离：触发条件是 **B 帧**，不是参考帧数

同一画面重新编码，每次只改一个变量：

| refs | B 帧 | 我们的解码器 |
|---|---|---|
| 4 | 2 | **27 帧**（原文件） |
| 1 | 2 | **33 帧** ← 还是坏 |
| **2** | **0** | **721 帧 全过** |
| 1 | 0 | 721 帧 全过 |

**是 B 帧。** 参考帧数降到 1 也没用，去掉 B 帧立刻全过。

原因就在 API 名字里：`openh264::Decoder::decode()` 调的是
**`DecodeFrameNoDelay`**——「no delay」就是**不做重排序**，因此**无法解码带 B 帧的流**。

### 为什么 Mac 清楚、Windows 花

同一台手机、同一个编码器、同一个 WiFi：

- **Mac** 用 **VideoToolbox** 编解码 → 天然支持 B 帧重排序 → 清楚
- **Windows** 用 **OpenH264** 解码 → 不重排序 → 花屏

**这就是为什么「码率是不是太低」这个问题从一开始就是错的。** 手机没变过。

### iOS 侧要做什么（需要 Mac / Xcode）

`H264Encoder.swift:107` 已经有 `kVTCompressionPropertyKey_AllowFrameReordering: false`
+ Main profile，而 **Main profile 本身不允许 B 帧**，所以**当前构建理论上不该产生 B 帧**。
但 `docs/demo/remotecrab-demo.mp4` 是 **High profile + `has_b_frames=2`**，
说明**这份 demo 录自更早的构建**（那个 key 加入之前）。

**所以还差一步验证**：抓一段**当前构建**的码流确认有没有 B 帧。

```cmd
remotecrab.exe --record --no-preview --no-tray --connect <ip>:8765
remotecrab.exe        # 另一个窗口：输入 record 开始录制，quit 停止
```

```sh
ffmpeg -i <录制>.mp4 -c copy -bsf:v h264_mp4toannexb -f h264 x.h264
ffprobe -v error -select_streams v:0 -show_entries stream=has_b_frames,profile -of default=nw=1 x.h264
```

- `has_b_frames=0` → 当前构建没问题，**B 帧不是活跃病因，别急着改**，
  回到下面「参考帧丢失」那条线
- `has_b_frames > 0` → **确认**。iOS 侧修法是在 `AllowFrameReordering: false`
  之外**显式**加 `kVTCompressionPropertyKey_NumberOfBFramesBetweenReferenceFrames: 0`
  （iOS 15+ / iOS 26 SDK 都有，比 `AllowFrameReordering` 更明确），
  并放进 `VideoEncodingPolicy` 加断言，和 `quality` / `keyframeIntervalSeconds`
  一样被测试钉住

⚠️ **不要在没验证 `has_b_frames` 之前就改 iOS。** 上表证明 B 帧**能**解释
「解不出来」，但没说当前构建一定产生了它。

### Windows 侧已经做完的（可验证，不需要手机）

1. **新增 `decode_file` 工具**：任何 `.h264`（`.mp4` 先抽流）走**和线上完全相同**
   的管线，输出 NAL 普查、拒绝计数、健康判决。这正是前三轮 session 缺的东西。

   ```sh
   cargo run --release -p rc-render --example decode_file -- file.h264
   # --dump out.rgba  与 ffmpeg 输出逐字节对比
   # --debug          打开 OpenH264 自己的 trace
   ```

   `demo.h264` 现在就是它的回归素材：27/694 → 一眼看出解码器坏了。

2. **取证探针会主动点名这个故障**：关键帧到了但一个都没解出来时，它明确说
   「不是网络的错，是解码器拒绝了自包含的画面」，给出 B 帧这条已知原因和上面
   那条 `ffprobe` 命令。**以前的行为是永远显示一幅看起来合理的错误画面**——
   这正是花屏花了三轮 session 说不清的原因。

3. **SPS/PPS 重新注入**：`H264PreviewDecoder` 记住参数集并在失败时重送。
   **对 B 帧无效**（OpenH264 是从根本上解不了，不是丢了 SPS），但它修另一个
   真实故障：丢包导致的 SPS 丢失会让流**永久**死掉，而 OpenH264 自己的
   issue #3448 确认丢包时它用灰/绿色填补丢失区域——**那正是「彩色噪点」的来源**。
   `reinjections()` 计数可以观察它有没有在触发。

### 还没排除的

- **参考帧丢失**（下面那条线）仍然成立：若 `has_b_frames=0` 就回到它。
- **WiFi 延迟**：median 97ms / max 641ms，代码侧只能降码率缓解。
- **iOS 只发 4fps**（承诺 30）：`CaptureEngine.swift:1280`
  `alwaysDiscardsLateVideoFrames = true` + 发送线程阻塞，机制已定位，需 Mac 改。

### 剩下的活假设：参考帧丢了（**B 帧排除后才轮到它**）

渲染层排除 + 码率解释排除之后，剩下能同时解释「彩色噪点沿高对比边缘」「内容仍可辨认」
「**周期性**横向条带」的就是**帧丢失导致参考帧断链**。

`NALs refused: 54` 和 `keyframe every 14.11s` 都和这个方向一致，但**都不算证据**。

**判决需要手机，而且需要把镜头对准有纹理的东西。** 下一次要跑的：

```sh
cd windows
cargo run --release -p rc-render --example vcam_forensics -- \
    --connect 192.168.31.148:8765 --seconds 180
```

- 确认输出里不是 `TOO LITTLE DETAIL`（把镜头对准桌面上的手、或一屏文字）
- 看 `VERDICT` 是 `uniform` 还是 `a few frames are broken`
- 如果是后者，看 **`of those, N came from a keyframe`**：关键帧自包含，不可能被预测错，
  **离群帧一个都不是关键帧 → 排除码率，只剩参考帧丢失**
- 同时看 `** the phone promised 30 fps and delivered ...` 那几行，它们是独立的一个问题

（新版探针会自动重试 refused 的连接，所以 listener 闪断不会再让你重敲命令。）

### 每次跑取证都失败的原因（不要重复踩）

| 症状 | 真实原因 |
|---|---|
| `sessionReply: Busy` + `held by: <某个名字>` | **看那个名字。** 新版探针会打印手机给出的 `ownerName` |
| `held by: forensics`（或任何已经退出的客户端） | **不是 Mac。** 手机上有一个**过期的 pending 连接**在占位，它会拒绝所有电脑并报出死掉那台的名字。见下面「已定位的 iOS bug」 |
| `held by: <一台确实在跑的机器>` | 那台机器占着手机。必须**退出应用**，"断开连接"没用，它几秒内会抢回来 |
| `sessionReply: Pending` | 取证工具是**手工握手**，手机会把它当新电脑，要单独批准 |
| `ping 通但 8765 无响应` | 手机在网内但 **iOS listener 没启动**。实测 listener 会**闪断**（连续 13 次 refused，中间成功过一次），探针现在会自动重试 15 次 |
| `Connection refused` 一直不变 | 手机离开网络了（锁屏/换 AP/休眠），不是 listener 的问题 |

## 🔴 交给 Mac / iOS 的一行修复：一个死掉的 pending 连接会把手机锁死

**位置**：`RemoteCrabCapture/CaptureEngine.swift:1883`

```swift
private func handleCandidateState(_ state: NWConnection.State, token: UUID) {
    guard handshakeToken == token else { return }
    switch state {
    case .failed, .cancelled:
        handshakeTask?.cancel()
        candidate = nil                          // ← 1888 先置 nil
        candidateParser = nil
        if pendingConnection === candidate {     // ← 1890 于是变成 pendingConnection == nil
            pendingConnection = nil              // ← 这三行永远进不去
            pendingHello = nil
            pendingMacName = nil
        }
    default:
        break
    }
}
```

`candidate` 在 1890 行已经是 `nil`，所以判断**只在 `pendingConnection` 本来就是
nil 时成立**，而那种情况下面三行没东西可清。**清理 pending 槽位的代码是死代码。**

再叠加两件事：

1. **`pending` 槽位没有 watchdog。** `checkOwnerLiveness()`（`CaptureEngine.swift:2531`）
   的守卫是 `guard connection != nil || ownerMac != nil`，只管**已授权的 owner**。
2. `CaptureEngine.swift:1492-1513`：只要 `pendingConnection` 还挂着，
   **任何**电脑连进来都拿到 `replyBusy(on:ownerName: pendingMacName)` ——
   报的是那个已经死掉的连接的名字。

### 完整失效链（有证据，不是推理）

现场抓到的日志（新版 Windows 取证探针会打印 `ownerName`）：

```
  sessionReply: Busy
    held by: forensics
  THE PHONE IS HELD BY ANOTHER COMPUTER.
```

`held by: forensics` —— 占用者**就是探针自己**。它的 client id 在早前一次
「用户点了允许」之后被登记成 owner；那次连接随后进程退出、socket 死掉，
`.cancelled` 触发，但因为上面那个 bug 清不掉。从那以后**每一次**新连接都收到
`Busy`，并且报的是那个已经不存在的东西。

所以：某个接收端连上来 → 手机弹批准框、`pendingConnection` 挂上 → 那个进程在
批准前退出（我那次的 25 秒探针窗口到点退出就是这样）→ **手机从此对所有电脑说
Busy，并报出一个根本没在运行的名字**，直到 App 重启。

**这解释了前面三个 session 里最贵的那个 `Busy`。它从来不是 Mac 抢手机。**
本文件旧版那张表的 `Busy` 一行是错的。

### 修法（一行，需要 Mac / Xcode 验证）

```swift
case .failed, .cancelled:
    handshakeTask?.cancel()
    let dying = candidate      // 先抓住正在死掉的那个连接
    candidate = nil
    candidateParser = nil
    if pendingConnection === dying {   // 再比较
        pendingConnection = nil
        pendingHello = nil
        pendingMacName = nil
    }
```

### 配套建议：给 pending 槽位加 watchdog

光修上面那一行还不够健壮，因为 `NWConnection` 的 `.cancelled` 并非在所有退出
路径上都会到达。`pending` 应该和 owner 一样有超时释放——现在只有
`grant()`（`CaptureEngine.swift:1605`）会 `startOwnerWatchdog()`，
pending 从来没有对等物。

**验收方式**：Windows 侧不用改，跑取证探针即可，它现在会打印 `ownerName`：

```sh
cd windows
cargo run --release -p rc-render --example vcam_forensics -- \
    --connect <iphone-ip>:8765 --seconds 180
```

- 批准探针 → 跑完 → **杀掉探针进程**
- 立刻再跑一次
- **修好之前**：第二次会拿到 `sessionReply: Busy` + `held by: forensics`
- **修好之后**：第二次会拿到 `sessionReply: Pending`（因为这是一个新客户端）

Windows 侧的探针已经就位并打印 owner 名，所以这条修复可以在 Mac 上做完立刻验证，
不需要 Windows 机器配合。

### 顺带发现（1 已修，2 已修，3 仍未验证）

1. **iOS 侧 listener 静默不启动。** 手机 IP 正确、ping 通、二层可达，但 8765
   无任何监听，且 iOS 侧似乎不报错。**2026-10-04 补充：这条其实是 listener
   会「闪断」**——实测连续 13 次 `Connection refused`，中间成功过一次，之后又
   长时间不通。所以「不启动」和「启动但不持续」要分开看。取证探针现在会自己
   重试 15 次，不再因此让人重敲命令。
2. ~~**`Parser::try_parse_next` 静默丢弃整个缓冲区。**~~ **已修**
   （`b42d50b`）。原实现遇到坏长度就 `self.buffer.clear()`，把损坏点**之后**
   已收到的完整帧一起丢掉，且不计数不上报 → 画面卡死而控制台一切正常。
   现在改成**向前逐字节重同步**，恢复损坏之后的帧而不是之前的；新增
   `Parser::resyncs()` 计数，`rc-net` 的 supervisor 打印
   `[net] wire resynchronised N time(s)`。6 个测试，其中 2 个通过**恢复旧的
   `clear()` 行为**反向验证过会红。附带修掉一个隐患：分片到达的帧（先来
   `00 00`）曾会被误判成零长度损坏。
3. **`rc-render/src/window.rs:81` 的指针生命周期。** `update_with_buffer(&buffer, …)`
   传切片，minifb 异步持有指针；下一轮若因尺寸变化 `buffer = vec![…]` 重分配，
   minifb 可能正在读已释放内存。1080x1920 恒定所以当前不触发，但切分辨率就会。
   **仍未验证**——`renderer_fidelity` 复刻了 buffer 的搬运逻辑，但证明不了
   minifb 在 `update_with_buffer` 返回之后还持有什么。切一次分辨率即可判定。

## Blocked — needs the user

- [ ] **iPhone 保持在同一 WiFi、App 前台打开、摄像头开启**，然后让 Mac 接收端
      **完全退出**（菜单栏 → RemoteCrab → 退出）。这是上面所有真机验证的前提。

- [ ] **SmartScreen, not UAC, is the real install-time complaint.** An unsigned
      exe triggers "Windows protected your PC", which needs *More info* →
      *Run anyway*. That is a more confusing screen than the UAC prompt users
      already expect, and it cannot be removed by any amount of installer work —
      only a code signing certificate (OV ≈ $150–300/yr) clears it. Decide
      whether to buy one before any public distribution.

## Done — verified on this machine

Install and uninstall are both proven, not assumed:

- [x] **Install**: `msiexec /i` + one UAC click, then the camera works with **zero
      manual steps**. The MSI registers the CLSID itself (it is perMachine, so it
      is already elevated — spending that on copying files while telling users to
      open an admin PowerShell was the original defect).
- [x] **Full chain**: installed exe + real iPhone → `vcam_consume` reports
      `PASS — 11 samples with 34560 changing bytes`.
- [x] **Uninstall, 9/9 checks**: CLSID · Program Files · ring file ·
      ProgramData directory · HKCU Run · HKCU markers · Start Menu entry ·
      product registration · `%APPDATA%\RemoteCrab` (which held `tokens.json`).
- [x] **`--uninstall-vcam` is idempotent**: twice in a row, both `exit 0` and
      "已清理干净".
- [x] **`msiexec /f` self-heals a wrong CLSID**: deliberately pointed the
      registration at the dev build, ran repair, and it was rewritten to the
      installed path. So a user who ends up misregistered recovers without help.
- [x] **No second elevation after install**: a non-admin process creates files in
      `%ProgramData%\RemoteCrab`, and the self-test that published frames was
      itself non-elevated.
- [x] **Two registration bugs found by running**, not reading: a `runas`
      recursion that prompted forever, and a "fix" that made a mismatched
      registration **permanent** (nothing could re-register, including the process
      holding the rights). Both fixed, both verified by reproducing first.
- [x] **UX audit** (`rc-phone-sim`, seven fault scenarios): the tray no longer
      claims "streaming" with zero frames, and an unexpected disconnect is now
      reported. `drop` never dropped — empty arm. The tool's own docs claimed to
      prove "video decode" while emitting synthetic bytes no decoder accepts.
- [x] **`0x24 SpeakerAudio`** cannot be mistaken for video in dispatch — pinned
      by a test, because an unknown byte falls through to `Video` and hands a JSON
      payload to the H.264 decoder.

## Blocked — needs the user

- [ ] **Still unverified: a human looking at the picture in the Windows Camera
      app.** `vcam_consume` proves Media Foundation hands over changing bytes;
      it does not prove the picture is the right way up.
- [ ] The tray's UAC row is now a fallback rather than the main path (the
      installer registers), so it is rarely exercised — worth one deliberate run.
- [ ] Uninstall **idempotency** is still unticked: running `msiexec /x` twice, and
      `--uninstall-vcam` twice, should both report success. The helper functions
      treat "already gone" as done and there is a test for that, but no one has
      watched the real installer do it twice.
- [ ] `docs/WINDOWS-GAPS-2026-10-03.md` §5.6 is a checklist the Mac session left
      for a real Windows machine — 10 items (⊞L really locks, ⊞E/⊞R, modifier
      hints not crossing, Ctrl-C stays interrupt in Windows Terminal, the
      brightness buttons are gone, the browser button's label matches, three
      suites match and every button acts, `POWERPNT` falls through, a custom
      profile JSON takes effect and a broken one does not affect the rest).
      **Every one needs an iPhone running the new iOS build**, which needs a Mac
      to build. `--doctor` currently finds no phone on the network either
      (PC is 192.168.31.103, no route, no mDNS).
      The Rust half that *can* be checked here does pass: `meta_maps_to_the_
      windows_key_and_never_to_ctrl`, `meta_bit_is_the_unused_one`,
      `meta_composes_with_shift_and_alt`, rc-input 43 green.

## Bugs found while testing — fixed in `9a0e742`

- [x] **`VcamError::Stale` was unreachable.** `win.rs` already compared the
      registered DLL path against its own; on a mismatch it fell through to
      `RegCreateKeyExW`, got `ACCESS_DENIED`, and returned the generic
      `NeedsElevation` — so the one error that could explain "your camera is
      registered to a copy you deleted" never reached a user, who was told they
      were not an administrator. Usually they were. Now returned, with a test
      holding its message to the standard the other arms meet.

- [x] **The one-shot flags never self-elevated while their error text promised
      a UAC window** — *"approve the Windows prompt and it is done"*. The tray
      self-elevated; `main.rs` did not. A terminal user was told to approve a
      dialog that never appeared, which is exactly how this session got stuck.
      `run_elevated_job` is now `run_one_shot`, which prompts when it needs to
      and says plainly when the user declines or a policy blocks the prompt.

  Two WiX v4 traps, both of which compile to a manifest that installs nothing
  useful, were hit on the way: a nested `RegistryKey` rejects `Root` (WIX0064),
  and its `Key` is *appended* to the parent rather than relative — repeating the
  full path produced `…\CLSID\{9D4B…}\CLSID\{9D4B…}\InprocServer32`.


## Drift, deliberately not started

- [x] ~~Mac/iOS side (`docs/WINDOWS-GAPS-2026-10-03.md`): Windows key row in
      `KeyboardScreen.swift`; `ContextProfiles.swift` should match on
      `AppInfo.name` for Windows. Needs a Mac toolchain — unavailable here.~~
      → **2026-10-05 由 Mac session 复核：两条都早已落地，不是待办。**
      ① `KeyboardScreen.swift:241` 是
      `IBModifierBar.visibleModifiers(for: engine.peerPlatform)`，且
      `IBModifierBar` 的 `platform` **没有默认值**（编译器强制表态，所以四个
      调用点不可能有一个忘记传）；`meta = "⊞"` 顶替 ⌘，由
      `visibleModifiers(for:)` 保证两者永不同时出现。
      ② `ContextProfiles.profile(for:platform:in:)` 在 `.windows` 下走
      `normalizedProcessName(app.name)` 对 `windowsProcessNames`，在 macOS 下走
      `bundleIDs.contains(app.id)` —— 正是要的「按进程名匹配」。
      **仍需真机确认的是那 10 条 §5.6，不是这两条代码。**
- [ ] The user decided **not** to split the seven oversized files. Recorded in
      `docs/WINDOWS-DECISIONS-2026-10-03.md`. Do not reopen unless asked.
      （这是一个决定，不是待办；留着是为了下个 session 别把它当漏掉的活。）
