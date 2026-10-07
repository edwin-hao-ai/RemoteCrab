# AI Session Status

> Shared across all active AI sessions. Update your entry when you start, make
> significant progress, or finish. Delete your entry when done. If this file is
> older than 24h, treat it as stale.
>
> ⚠️ **Everything below is stale** — nothing here has been touched since
> 2026-09-28, and the sessions it names are long finished. For current state read
> `docs/HANDOFF-WINDOWS-REMAINING-2026-10-05.md` (Windows), `docs/HANDOFF-IOS-PEER-AUTH.md`
> (the iOS half of peer auth), and `docs/HANDOFF-MAC-SIDE-2026-10-04.md` (Mac).

## Session: opencode (2026-10-07) — peer auth: iOS + Mac halves

- Branch: `main`, no worktree. **Finished; this entry can be deleted.**
- Status: **完成（本端可验证部分）**
  - `RemoteCrabCore/Networking/PeerAuth.swift`（新）：与 Rust `peer_auth` 逐字节一致，
    断言了同一对测试向量。wire 加了 `nonce`/`mac`/`capabilities`/`clientProof`(0x26)。
  - iOS `CaptureEngine` 挑战-应答流程 + 「clientHello 超时即放行」改为 `denied`。
  - Mac `ReceiverSession` 发 nonce、验手机、回 `clientProof`、失败不重试、老手机标记未验证。
- Touched: `RemoteCrabCore/Sources/…/PeerAuth.swift`(新), `…/Networking/{IBEvents,IBWire}.swift`,
  `…/DesignSystem/IBLocale.swift`, `…/Resources/Localizable.xcstrings`,
  `RemoteCrabCapture/CaptureEngine.swift`, `RemoteCrabReceiver/{ReceiverSession,MenuBarMenu}.swift`,
  `RemoteCrabCore/Tests/…/{PeerAuthTests,PeerAuthWireTests}.swift`(新),
  `docs/HANDOFF-{IOS,MAC}-PEER-AUTH.md`
- Verified: `swift test` 627 绿；两个 app target 构建通过；Windows `cargo test --workspace --lib` 绿；
  `rc-net --test session` 20/20。
- **Pre-existing red (not this session)**: `cargo build --workspace` (host) fails in `rc-app`
  — `mod autostart`/`mod vcam`/`spawn_update_check` are not `#[cfg(windows)]`-gated.
  Confirmed identical at pre-pull `527712b`. Windows session's to fix.
- Not done: real-device verification (needs an iPhone + a Mac).


## Session: opencode (2026-10-06) — Windows: peer authentication, native UI, 8 bugs

- Branch: `main`, no worktree. **Finished; this entry can be deleted.**
- Status: **完成**
  - 双向 HMAC 身份验证的 **Windows 半边**（token 从"出示的凭据"改为 HMAC 密钥）；
    iOS 半边是文档，不是代码 —— Swift 在 Windows 上编译不了也测不了。
  - 三个原生窗口对齐产品配色/字体；托盘、向导生命周期、完整性判定等 8 个 bug。
  - 提权改了机制：`HKCU\Run` → 登录计划任务（`run level highest`，装 MSI 时创建）。
- Touched: `windows/crates/rc-protocol/src/peer_auth.rs`(新), `rc-net/src/{supervisor,lib}.rs`,
  `rc-app/src/{theme,wizard_win,settings_win,selfcheck_win,tray,status,autostart,args}.rs`,
  `rc-os/src/{logon_task,autostart}.rs`, `tools/RemoteCrab.wxs`,
  `docs/HANDOFF-IOS-PEER-AUTH.md`(新)
- Pushed: `cf745f8` ← `c9f3c11` ← `0d260c1` ← `bce06ae` ← `9c360c1` ← `bae9cfb`
  ← `bf351bf` ← `7db54db` ← `4c41d00` ← `51cb58a` ← `718c301`
- Will touch: nothing — session closing. Remaining work needs a macOS session (iOS)
  or the user (installing the MSI to create the logon task, real-device input).


## Session: opencode (2026-09-27) — website landing pages + promo video

- Branch: `main` in both repos (`~/iBridge`, `~/VGOAPP`). No worktree.
- Status: **完成**(收尾中,HANDOFF.md 已写)
- Touched:
  - `scripts/capture-feature-shots.sh`(新),`scripts/_shot_ok.py`,
    `scripts/marketing-video.sh`(新,未用)
  - `RemoteCrabCapture/ScreenRecorder.swift`(新,**`#if DEBUG` only**),
    `ContentView.swift`(新增 E2E sheet 钩子),`IOSSettingsView.swift`
  - `IBLocale.swift` + `Localizable.xcstrings`(Recorder 5 keys)
  - VGOAPP:`src/pages/RemoteCrab{Feature,Suites}Page.tsx`、`src/i18n/remotecrab{Features,Suites,Content}.ts`、`vite.config.ts`、`public/remotecrab/features/`
- Pushed: iBridge `c3a77d8`,VGOAPP `eb40913`。
- Will touch: 无

## Session: (2026-09-27) — Sparkle 自动更新

- Branch: `main` — **13 个 commit 仍未推送**(`dce0367`…`ef71cd2`)。
- 注意:该线改的是发布行为(给用户机器装自动更新),别的会话的成果,未测。
- Will touch: `RemoteCrabReceiver/*`、`project-mac.yml`、`scripts/release-mac.sh`、`scripts/make-appcast.sh`

## Session: (2026-09-27) — MacSlim

- 未提交:`vite.config.ts`(+macslim 入口)、`macslim/`、`public/downloads/`、`.gitignore`。
- 注意:与本会话改过同一个 `vite.config.ts`,提交前先看 diff。
