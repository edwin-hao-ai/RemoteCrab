# AI Session Status

> Shared across all active AI sessions. Update your entry when you start, make
> significant progress, or finish. Delete your entry when done. If this file is
> older than 24h, treat it as stale.

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
