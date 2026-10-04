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
| 3 通道序 | 逐 thirds 判定主通道（红\|绿\|蓝\|白块 场景） | 12/12 帧一致，`red\|green\|blue` |
| 4 blit | 复刻 `window.rs` 三句话，含 resize 分支 | resize 1 次，0 帧被改动 |
| 5 画面 | 逐帧对流自身中位数 | **uniform**，无离群帧 |

**所以渲染层被证明是忠实的：它没法把一条正确的流变成一幅错误的画面。**
花屏产生在解码器**之前**。

### ❌ 码率这条线已经断了（不是被排除，是被证明从来没测过）

`6220 kbps` 是手机**自己算出来写进 metadata** 的，从来没有任何东西量过它。
`H264Encoder` 同时设 `AverageBitRate` 和 `Quality`，**iOS 上 `Quality` 直接覆盖前者**——
要 6,220 和要 9,331 产出**逐字节相同**（见 `dd7022d`，
`scripts/vt-bitrate-probe.swift` 实测 `quality 0.70 → 9,179 kbps`）。

**9.2 Mbps 对 1080p30 是正常码率**，所以「码率不够」这个解释现在也站不住。
`docs/HANDOFF-IOS-QUALITY.md` §1 的 `0.1 → 0.15` 改法**是惰性的**，别再照着做；
那边该文件的结论已被 `dd7022d` 推翻，正确的旋钮是 `Quality`。

### 剩下的唯一活假设：参考帧丢了

渲染层排除 + 码率排除之后，剩下能同时解释「彩色噪点沿高对比边缘」「内容仍可辨认」
「**周期性**横向条带」的就是**帧丢失导致参考帧断链**：P 帧丢了 → 解码器用错参考 →
画垃圾 → 直到下一个 IDR 才恢复（`MaxKeyFrameInterval` 当时是 1 秒，**正好是周期**）。

**它还是假设**，判决需要手机。`vcam_forensics` 已经重写，现在直接打印能定因的事实：

- `video NALs received` vs `frames decoded`
- **`video NAL(s) produced no picture after the stream had started`** ← 最直接的证据
- `keyframe every Ns on average`
- NAL 字节 min/max、实测 kbps
- 离群帧里**有几个来自关键帧**。关键帧是自包含的，不可能被预测错；
  **离群帧一个都不是关键帧 → 排除码率，只剩参考帧丢失。**

```sh
cd windows
cargo run --release -p rc-render --example vcam_forensics -- \
    --connect 192.168.31.148:8765 --seconds 25
```

它的判决不再是绝对阈值，而是「这一帧是不是这条流自己中位数的三倍」，所以换个
真实场景也不会误判。（顺手修了它的 kind 标签错位：`0x10` 标成 `ping`，实际是 `0x09`；
`0x13` 标成 `featureState`，实际是 `0x08`。）

### 每次跑取证都失败的原因（不要重复踩）

| 症状 | 真实原因 |
|---|---|
| `sessionReply: Busy` | **Mac 接收端占着手机**。它会自动重连抢回去，必须在 Mac 上**退出**应用而不只是"断开连接" |
| `sessionReply: Pending` | 取证工具是**手工握手**，手机会把它当新电脑，要单独批准 |
| `ping 通但 8765 无响应` | 手机在网内（ARP 有 `42-64-27-b1-92-be`）但 **iOS listener 没启动**。疑似 iOS 侧静默失败，见下 |
| `Connection refused` | 本次新见：8765 先 200、`Pending`，几分钟后连 ping 都不通了。**手机离开网络了**（锁屏/换 AP/休眠），不是 listener 的问题 —— 先确认手机还在同一 WiFi 且 App 在前台 |

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
