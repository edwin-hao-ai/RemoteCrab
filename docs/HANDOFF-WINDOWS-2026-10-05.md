---
title: 交接给 Windows session —— Mac 侧做完了，剩下三件只能在你那台机器上量
type: handoff
status: current
last_verified: 2026-10-05
code_baseline: 25cd33f
---

# 交接：Mac 侧四条已修完，剩下三件只能在你那台 Windows 机器上做

读者：**Windows session**。写的人：**Mac session**（2026-10-05）。

> **你就是那个要拉一下看这份文档的人。先读这一段就够开工：**
>
> 1. **§2 是唯一一件真正等你动手的新活**（iPhone ↔ Windows 扬声器出声）。
> 2. **§1、§4 你已经做完了**（`0x25` 发送逻辑、解析器、minifb）—— 别重做。
> 3. **§3 已经作废**：iOS **不要**加 `NumberOfBFramesBetweenReferenceFrames: 0`。
> 4. **§5 排最后**：它需要一个手机侧还不存在的日志，不是你能在本机了结的。
>
> 拉取之后先 `git log --oneline -1`，确认这份文档里的每一条都还在（本文档的
> `code_baseline` 是**写下时的**基线，不是你必须停在这里的点 —— 关键是内容没被
> 别人推翻，尤其是 §1 的「`0x25` 早就实现了」和 §3 的「别加那个 key」）。

先说清楚**已经不用你做的**，免得你重做：

| 你 10-04 交接的 | Mac 侧状态 |
|---|---|
| `CaptureEngine.swift` 扬声器习惯会静默关麦克风 | ✅ 已修（`SpeakerRestorePolicy` + 5 测试） |
| 4d 形状断言用累计平均，数学上不可能通过 | ✅ 已修（`SpeakerEnvelope`，6 测试） |
| iOS 接收 `0x25 requestKeyframe` | ✅ 已实现（`0x25` + `ForceIntraFrame`） |
| 「加 `NumberOfBFramesBetweenReferenceFrames: 0`」 | 🔴 **别做**，前提无效，见 §3 |
| 你说「需要 Mac toolchain 故意没做」的两条 Mac 侧漂移 | ✅ **早就做完了**，已复核，见 §6 |

---

## 0. 三句话

1. ~~**`0x25` 的协议定义你写对了，但发送逻辑你还没写**~~ → **这条我说错了，见 §1
   的回填。发送逻辑本来就有（`rc-app/src/main.rs:718-738`），是我在一棵没拉取的
   树上 grep 就下了结论。** 我批评交接文档里的「声称做了但没做」，自己却在一件
   **已经做了**的事上写了「没做」——所以下面第 2 条的教训对我自己也成立。
2. **Mac 侧已经把「B 帧是病因」这个结论否掉了**，用一台机器就否掉了，
   `ffprobe has_b_frames=0`，而且探针带对照组。详见 §3。
   （Windows session 也独立得到了同样的结论，并把 AGENTS.md 里那条错误记录
   作废了 —— 真正的病因是显示路径，见 `1744c62`。）
3. 你说「本 session 发现的第五处声称做了但实际没做」的那条 listener 现象，
   我已经补进 `docs/HANDOFF-IOS-QUALITY.md` §7 了，**但标成「未复现也未排除」**。

---

## 1. ✅ `0x25`：定义有了，发送逻辑**其实已经有了**（`code_baseline: 0e9f423` 已过时）

> **2026-10-05 Windows session 回填**：本节写在旧基线 `0e9f423` 上，
> 当时 `grep` 确实只能搜到 `rc-protocol` 里的定义和测试。但发送端
> **早已实现在 `rc-app/src/main.rs:718-738`** —— 上面那条
> 「没有任何一处调用它」**不成立**，不用再做。
>
> 位置与行为（逐条对照你 §1「要满足的三条」）：
>
> | 你的要求 | 实现 |
> |---|---|
> | 收到 `.video` 但解不出来才触发 | `p.refusals_after_start() > last_keyframe_asked_at_refusals`，即**只在新增拒绝**时触发，不在每帧触发 |
> | 不能被手机刷屏 | `KEYFRAME_REQUEST_INTERVAL` 限流 2 秒；且只在「新拒绝」时才重新计时 |
> | payload 为空 | `encode_request_keyframe()` → `encode_frame(Kind::RequestKeyframe, &[])` |
>
> 你建议放在 `rc_net/src/dispatch.rs`（那里有 `tx`），我放在 `rc-app`
> 的解码循环里——同样拿得到 `session.send_frame`，功能等价，只是层次
> 高一点。**如果你觉得该下沉到 `dispatch.rs`，说一声。**
>
> ⚠️ 守卫是 `#[cfg(windows)]`：`rc-app` 在 mac 上也构建（parity harness），
> 非 Windows 平台不发送，避免 harness 干扰。

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

## 4. 两条 Rust 侧的 bug（在你们的 crate 里）— ✅ **两条都做完了**

`HANDOFF_WINDOWS_MSI.md` §"顺带发现" 里这两条我确认成立。本 session 没碰你们的
crate，等你们自己修；**13:25 和 13:53 两个提交都做了，Mac 侧已复核**：

1. **`Parser::try_parse_next` 静默丢掉整个缓冲区** → `b42d50b`。
   改成逐字节前向重同步（找回损坏**之后**的帧而不是之前的），加 `resyncs()`
   计数，supervisor 打 `[net] wire resynchronised N time(s)`。
   **Mac 侧独立复核过**：把旧的 `buffer.clear()` 放回去，
   `a_corrupt_length_does_not_swallow_the_frames_behind_it` 立刻红，失败信息
   是 `the frame after the corruption must survive, got [Metadata]` —— 断言
   是真的会响的，不是摆设。
2. **`rc-render/src/window.rs` 指针生命周期** → `1744c62`。
   `BlitBuffer` 退休被替换的 buffer（`RETAIN_SUPERSEDED = 4`，内存有上界），
   8 条 `window::tests` 全绿，其中 `a_resize_keeps_the_buffer_that_was_handed_over_alive`
   和 `retained_buffers_stay_bounded` 正是这条 bug 的不变量。
   另外补了 `tests/damage.rs` **6 条**，把 OpenH264 遇到损坏时的三种行为钉在
   真实编码上（能预测的解对、不能预测的拒片不出帧、丢了参考图就停），
   我跑过全绿。**「预览花屏的根因是显示路径而不是解码器」这个结论现在有测试撑着。**

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

`6fff9d5` 起的一串提交，**578 Core 测试**（本轮 +38）、两个 app target、
Windows 套件、`cargo build --workspace` 全绿；每一条新断言都反向验过
（改坏生产值看它变红，再还原）。

另外一条你现在可以拿去用的实测：**Windows 上 `fatal runtime error: Rust cannot
catch foreign exceptions` 是托管方式不是 Windows 缺陷**（`--preview` 默认开，
minifb 在 macOS 开不了 Cocoa 窗口），`--no-preview` / `--decode-only` 立刻正常。

### 6.1 你说「需要 Mac toolchain 故意没做」的那两条 —— **复核后：早就做完了**

`HANDOFF_WINDOWS_MSI.md` §Drift 里那条「Mac/iOS side：Windows key row in
`KeyboardScreen.swift`；`ContextProfiles.swift` should match on `AppInfo.name`」
被记成**故意没做**。两条都早已落地：

* `KeyboardScreen.swift:241` 是 `IBModifierBar.visibleModifiers(for: engine.peerPlatform)`，
  且 `IBModifierBar` 的 `platform` **没有默认值**（编译器强制四个调用点表态，
  所以不可能有一个忘记传）；`meta = "⊞"` 顶替 ⌘，由 `visibleModifiers(for:)`
  保证两者永不同时出现。
* `ContextProfiles.profile(for:platform:in:)` 在 `.windows` 下走
  `normalizedProcessName(app.name)` 对 `windowsProcessNames`，macOS 下走
  `bundleIDs.contains(app.id)` —— 正是要的「按进程名匹配」。

**仍然需要真机的是 `docs/WINDOWS-GAPS-2026-10-03.md` §5.6 那 10 条，不是这两行代码。**

## 7. 交付

- [x] `0x25` 的发送逻辑（§1）→ **早就有了，是我写错了。** 我在
      `code_baseline 0e9f423` 上 `grep`，只搜到 `rc-protocol` 的定义，就断言
      「没有任何地方发送」—— 而发送端在 `rc-app/src/main.rs:718-738`。
      Windows session 回填了三条要求的对照，Mac 侧已复核实现存在。
      **教训**：我批评别人「声称做了但没做」，然后自己犯了一次**——差别只在于
      我是在一棵**没拉取的**树上搜的。**交接文档里的「未做」也要先 fetch 再确认。**
- [ ] iPhone ↔ Windows 扬声器出声（§2）—— 唯一还没跑过的一段
- [x] `try_parse_next` 的缓冲区静默清空（§4.1）→ `b42d50b`，Mac 侧复核过
- [x] `window.rs` 的指针生命周期（§4.2）→ `1744c62`，8 条测试 + `damage.rs` 6 条
- [ ] §5 那条 listener 的歧义，等 iOS 侧补了两行日志再动

### 另一件你们已经修掉、但记录里还写着「没做」的

`docs/HANDOFF-MAC-SIDE-2026-10-04.md` §2「把视频发送移出 VideoToolbox 回调线程」
**前提是错的，所以没人做，也不该做**：`handleEncodedFrame` 两个调用点都是
`Task { @MainActor }`，发送早就和编码输出解耦了，那条改动是空操作。
真正该记的是「发送跑在主线程」这件事本身 —— 那一栏我已经改成实测结论，
不再是一个待办。
---

## 8. 🆕 电脑在线状态（presence）—— 你只差接一行

**背景**：iPhone 的「选择电脑」列的是 `seenComputers`（历史见过的机器），
看不出哪台**现在在线**——因为它只广播、从不浏览，而 Mac/Windows 只浏览、从不
广播。修法：接收端**额外广播**一个服务，iPhone 浏览它，列表分「在线 / 离线」。

### 8.1 协议契约（Mac 与 Windows 必须逐字节一致）

| | 值 |
|---|---|
| 服务类型 | `_remotecrab-computer._tcp.local.` |
| TXT `id` | 稳定机器 id（与 `clientHello.id` 同值） |
| TXT `name` | 显示名 |
| TXT `platform` | `macos` \| `windows` |
| TXT `port` | 字符串整数，当前 `8766` —— 手机拨它做「敲门」（见 §10） |
| SRV 端口 | 就是监听口 `8766`（`ServiceInfo` 自动写 SRV） |

⚠️ **不要**复用 `_remotecrab._tcp.local.`：接收端用那个类型浏览 iPhone，复用会
把别的电脑当成 iPhone 来拨。

### 8.2 已合并的 API（`windows/crates/rc-discovery/src/lib.rs`）

- `SERVICE_TYPE_COMPUTER`
- `KNOCK_PORT`（`8766`）
- `presence_service_info(instance, id, name, platform) -> Result<ServiceInfo>`
- `advertise(instance, id, name, platform) -> Result<PresenceAdvertiser>`；退出时
  `PresenceAdvertiser::stop(self)`
- 纯测试 `presence_service_info_carries_the_frozen_txt_contract` 每次提交都跑
  （已 pin `port=8766`）；`knock_port_matches_the_swift_side` 也跑。
  真 mDNS 浏览测试 `#[ignore]`（本机 CLI 被 local-network 权限拒绝，无法在此验证）。

### 8.3 你要做的（勾选）

- [ ] **1. 广播**：在 `rc-app` 启动、已拿到机器 id/名字处（`Session::spawn` 附近）加：
      ```rust
      let _presence = rc_discovery::advertise(&instance, &pc_id, &name, "windows")?;
      ```
      并让它活到进程结束（退出时 `.stop()`）。
- [ ] **2. 确认广播里带 `port=8766`**：收到 presence 的那台 iPhone 会图省事直接读它。
- [ ] **3. 真机验证**：iPhone 打开「选择电脑」→ 这台 PC 应显示**在线**（绿点）；
      结束进程 → **离线 · 最后在线 …**。
- [ ] **4. 若安全软件拦截 mDNS 广播**：广播失败只记日志、不影响会话；
      在安全软件里放行，否则手机上永远看不到这台在线。

> **Mac 侧状态**：`PresenceAdvertiser` 已实现并合并。`NSBonjourServices` 已加入
> `_remotecrab-computer._tcp`（**未声明时 macOS 直接返回 `-65555 NoAuth`**，
> iOS 浏览会静默失败）。macOS 15 的「本地网络」权限按签名身份授予，换签名要重新授权。

---

## 9. 🆕 `sessionReply` 新增 `off`：断开要真的断开

**背景**：iPhone 上点「断开连接」只是关掉 socket，但这台电脑**已配对**，它自己的
重连循环立刻又拨回来、被自动接受——按钮看起来没反应。

### 9.1 协议

`0x0B sessionReply` 的 `result` 新增一个值 **`off`**（`ownerName` 带电脑名）。
- Swift：`IBSessionReplyResult.off`；Rust：`SessionReplyResult::Off`
  （serde lowercase → `"off"`，`rc-protocol/tests/wire_keys.rs` 有 round-trip）。
- 手机在用户点断开后记住这台；它再拨时回 `off`；用户重新选中任意电脑即清除。

### 9.2 你要做的（勾选）

- [x] **1. 协议值**：`SessionReplyResult::Off` 已加、已 pin。
- [x] **2. 行为（最小可用）**：`supervisor.rs` 已把 `Off` 映射成
      `ConnEndKind::Denied` —— **停止自动重连**（断开就真的断开）。
      代价：恢复要手动点 Reconnect（Mac 侧现在是 5s 礼貌重试）。
- [ ] **3. 改进（可选，推荐）**：给 `off` 一个**专属状态文案**
      （「已在 iPhone 上断开，请在手机上重新选中本机」）+ **5s 慢重试**，
      让用户在手机上重新选它后**自动**恢复，不用去点 Reconnect。
- [ ] **4. 真机验证**：在 Windows 上连接 → 在 iPhone「选择电脑」点断开 →
      接收端必须**不再自动重连**、状态说明「已在 iPhone 上断开」。

---

## 10. 🆕 「敲门」（knock）：让「点一下就连」即时

**背景**：iPhone 是服务端、**不能主动开数据 socket**，所以点一台电脑只能等它自己的
重试轮询（Mac 已降到 5s，Windows 默认更久）。体验差。

**做法（Mac 已实现、已 push）**：接收端在一个**固定端口 8766** 上监听（就是它的
presence 监听口）。**任何到该端口的入站连接 = 「马上拨回我」**；接收端收到就立刻拨
手机。手机点一下时，拨这个端口一次然后立刻挂断 —— 只是敲门，不是会话。
**数据会话方向 / 握手 / 配对完全不变。**

### 10.1 你要做的（勾选）

- [x] **1. `KNOCK_PORT` + TXT `port`**：`rc-discovery` 已加。
- [ ] **2. 监听 8766**：接收端要在 `8766` 上监听（可复用 presence 的 accept 路径；
      或单独一个 `TcpListener`）。收到入站连接后：
      ```rust
      // 这就是敲门：不做握手，立刻触发一次拨回手机，然后关闭。
      let _ = session.retry_now();   // 或你现有的“立刻重连”入口
      stream.shutdown();
      ```
- [ ] **3. 端口占用**：8766 若被占用，监听失败只记日志、不影响主流程；
      这时手机会回退到「设为首选 + 等它拨」的老行为（所以不会更差）。
- [ ] **4. 真机验证**：iPhone 点这台 PC → 预期**约 1 秒内**连上（而不是等轮询）。

> 这个模式值得记住（lesson 157）：**当一端被架构固定为「只能被动接受」时，
> 仍可以给它一个「只承载意图、不承载数据」的出口**——它触发对端行动，而不是自己
> 建立会话。代价几乎为零，且向后兼容。

---

## 11. ⚠️ Windows「经常连不上 / 开了 VPN 穿透不了」—— 怎么破解

这是**你要求写详细的那条**。分三层：先**诊断**，再**代码绕过**，最后**用户侧兜底**。

### 11.1 根因（已经能诊断）

TUN 模式的代理（Clash / Mihomo / sing-box 及大多数「加速器」）**接管了默认路由**，
于是连一台**同一 WiFi 下的手机**也被拉进隧道、被丢掉。从 app 看和「手机没开」
完全一样——所以用户不知道该关哪个开关。

`rc-net/src/route.rs` 已经能**点名**接管路由的那块虚拟网卡：
- `route::classify_route(target, &local_ipv4())` 返回
  `Direct` / `Tunneled { source }` / `Unknown`；
- `route::describe` 输出「到目标的连接会被 VPN/代理的虚拟网卡（<ip>）接管。关掉
  该代理软件的 TUN 模式，或把局域网加入直连/排除规则。」
- `--doctor` 和托盘面板已经把它显示出来。

**所以第一步永远是：让用户跑 `remotecrab --doctor`，看面板点名的是哪块网卡。**

### 11.2 代码破解（在你们的 crate 里，只有你的机器能验）

目标：**让拨号 socket 从物理网卡出去，而不是隧道**。两条路线，按可用性选：

- [ ] **A. 把出站 socket `bind` 到局域网网卡的本地地址**（推荐先试）：
      ```rust
      use tokio::net::TcpSocket;
      let sock = TcpSocket::new_v4()?;
      // lan_addr = 物理网卡（WiFi/以太网）的 IPv4，其子网包含手机地址。
      if let Some(lan) = pick_lan_addr_for(phone_addr) {
          let _ = sock.bind(std::net::SocketAddr::new(lan.into(), 0));
      }
      let stream = sock.connect(phone_addr).await?;
      ```
      注意 `route::local_ipv4()` 现在返回的是**默认路由下的地址**，在 TUN 模式下
      那可能正是隧道的地址 —— 所以 `pick_lan_addr_for` 需要**枚举适配器**
      （Windows 用 `GetAdaptersAddresses`，通过 `windows` crate；`getifaddrs` 只在
      Unix），挑出**非隧道**且**子网包含手机**的那块。这块是本条的真正工作量。
- [ ] **B. `IP_UNICAST_IF`（强制出接口）**：比 `bind` 更直接地绕过路由表。
      用 `windows` crate 在 socket 上设 `IP_UNICAST_IF` 为物理网卡的 interface
      index（`GetAdaptersAddresses` 的 `IfIndex`）。对 fake-IP 型 TUN 通常有效。
- [ ] **C. mDNS 也同样被吞**：TUN 模式下 `_remotecrab._tcp` 常常浏览不到手机，
      于是只剩 `probe_tcp` 直连 / `/24` 扫描兜底。确保直连路径**也走 A/B 的绑定**，
      否则兜底同样被拉进隧道。

> **诚实边界**：Mac 侧**无法**验证这三条中的任何一条，所以按交接纪律我只写方案、
> 不改你们运行时。请在你的 Windows 机器上逐条试，把 `--doctor` 的 `route:` 行
> 和是否连上，记回 `WINDOWS_TODO.md`。

### 11.3 用户侧兜底（不写代码也能好）

- [ ] 在代理软件里给**手机所在网段**加直连：Clash 例
      `IP-CIDR,192.168.x.0/24,DIRECT`，并把该网段加入 `dns.fake-ip-filter`；
- [ ] 或临时**关闭 TUN 模式 / 退出加速器**，确认能连上——这就证明是隧道问题；
- [ ] 把这条写进托盘面板的「怎么办」里（`route::describe` 已经说了大意，可再补一句
      「本机网段加直连」）。

---

## 12. Windows 待办总清单（按顺序勾）

- [ ] §8.3 广播 presence（一行 `advertise`，TXT 带 `port`）
- [ ] §10.1 监听 knock 端口 8766，收到就「立刻拨回手机」
- [ ] §9.2 `off` 专属文案 + 5s 慢重试（可选，推荐）
- [ ] §11.2 VPN：枚举适配器 + `bind`/`IP_UNICAST_IF`，让拨号出物理网卡
- [ ] §11.3 托盘面板补「本机网段加直连」提示
- [ ] 真机全流程：在线显示 → 点一下 ~1s 连上 → 断开不再自动重连 →
      手机上重选能恢复 → 开 VPN 后仍能连（或面板正确点名网卡）

> 全部做完后，请回填本文件（把 `[ ]` 改 `[x]`）并把 `WINDOWS_TODO.md` 的
> 对应项打勾，附上 `--doctor` 的实测输出。**这就是本次交接的闭环。**
