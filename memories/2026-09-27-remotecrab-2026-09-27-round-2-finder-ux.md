---
type: memory
title: RemoteCrab 2026-09-27 (round 2): 投屏切 Finder 不更新的根因 + 桌面语义 + 窗口选择器 UX
created: 2026-09-27T06:41:49.675171+00:00
source: cli
---

# RemoteCrab 2026-09-27 (round 2): 投屏切 Finder 不更新的根因 + 桌面语义 + 窗口选择器 UX

# RemoteCrab / iBridge 会话记忆 — 2026-09-27 (round 2)

## 1. 投屏模式下用 iOS 切应用不更新（只有切 Finder 不行）
用户报"投屏模式下通过 iOS 端切换应用，画面无法显示最新应用，只能关掉投屏再打开"，
随后**自己把范围缩小到**："只有切换 Finder 的时候不行，切换其他的应用好像是可以的"——
这一句就是根因。

**根因**：`ScreenTargetResolver.resolveKeepingPrevious` = `resolve(frontmostPID:) ?? previous`。
当新最前台 app **没有合格窗口**时保留旧窗口。Finder 停在桌面时没有窗口 → 保留旧 app 窗口
→ `resolveAndStart` 的 `same` 判断为 true → **静默 return**（不重新配置）→ 画面卡住。
关掉投屏会清空 `previous`，所以重开就正常。

Mac 日志（新加的诊断）直接坐实：
```
activated app 访达
activation recheck scheduled (isRunning=true)
recheck: running=true extended=- pinned=- front=访达/942 policy=0
resolve: target=922:80 same=true reason=frontmost    ← 解析回旧窗口！
```

**修复**：Finder 且无窗口 = **桌面**（本身就是该显示的东西）→ 给
`resolveKeepingPrevious` 加 `desktopIsShowing:` 参数，为 true 时返回 nil →
`resolveAndStart` 落到整屏捕获路径。+3 个纯单测（`ScreenTargetResolverTests`）。
注意 ⌘-Tab 从没踩到：它切到的 app 有窗口。"我做 X 时是好的" 是**关于哪条输入路径不同**
的证据，不是噪音。

**保留诊断日志**：`activation recheck scheduled` / `recheck: running/extended/pinned/front`
/ `resolve: target/same/reason`（每次激活一行）——正是它们让问题可定位。

## 2. 点"桌面"应该隐藏所有应用、只留桌面
`SystemCommandHandler.showDesktop` 用 `!$0.isActive` **跳过了当前正在看的 app**，
还去 `activate()` Finder（可能顶出一个 Finder 窗口）。改为隐藏**所有**常规 app
（含 Finder），不激活任何东西 —— Win+D 语义。

## 3. 投屏左上角"窗口下拉"太难懂 → 重做
原来是"应用名 + 纯数字窗口数 + chevron"，看着像状态读数、占了三分之一行宽；
菜单里"跟随前面的应用"也没解释。现在：
- 自动跟随 = **单个 40pt 圆形图标**（和 fit/fill/2× 同尺寸，最省地方）
- 钉住 = pin 图标（强调色）+ 短标题
- 菜单加 "Show which window" 标题、把模式写成 "Auto — follow current app" 并打勾
- 首次教练提示增加一行说明
- 新 `IBLocale.Mirror` key（windowPicker / autoFollow / pinned / windowPickerHint）+ zh-Hans

提交 `60c33ba`；206 测试 + 双端编译通过；用户确认投屏切换已正常。

## 当前状态 / 下一步
- iOS + Mac 主功能全部用户验证过；Windows 接收端只剩**虚拟摄像头/虚拟麦克风**
  （见 `docs/WINDOWS_HANDOFF.md` §5a/§5b；下一步：用户在 Win11 跑
  `cargo run -p rc-vcam -- RemoteCrab 20` 回报 3 行输出，再写 COM IMFMediaSource）。
