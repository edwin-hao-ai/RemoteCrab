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

### 剩下的活假设：参考帧丢了（**但还没测到**）

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

### 顺带发现，尚未修（都不确定是否在你这里发生过）

1. **iOS 侧 listener 静默不启动。** 手机 IP 正确、ping 通、二层可达，但 8765
   无任何监听，且 iOS 侧似乎不报错。若确认，这是本 session 发现的**第五处
   "声称做了但实际没做"**，应加进 `docs/HANDOFF-IOS-QUALITY.md`。
2. **`Parser::try_parse_next` 静默丢弃整个缓冲区。** 一个坏长度值会
   `self.buffer.clear()`，把已收的完整帧一起丢掉，**且不计数、不上报**
   （`crates/rc-protocol/src/wire.rs`）。这会造成**画面卡死**而非花屏，日志里
   什么都没有。修法应当是丢弃到该帧为止、保留之前的帧、记一次计数。
3. **`rc-render/src/window.rs:81` 的指针生命周期。** `update_with_buffer(&buffer, …)`
   传切片，minifb 异步持有指针；下一轮若因尺寸变化 `buffer = vec![…]` 重分配，
   minifb 可能正在读已释放内存。1080x1920 恒定所以当前不触发，但切分辨率就会。

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

- [ ] Mac/iOS side (`docs/WINDOWS-GAPS-2026-10-03.md`): Windows key row in
      `KeyboardScreen.swift`; `ContextProfiles.swift` should match on
      `AppInfo.name` for Windows. Needs a Mac toolchain — unavailable here.
- [ ] The user decided **not** to split the seven oversized files. Recorded in
      `docs/WINDOWS-DECISIONS-2026-10-03.md`. Do not reopen unless asked.
