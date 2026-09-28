---
type: memory
title: "RemoteCrab 2026-09-29: 通知点击跳转 + 幽灵回环 IP + iOS 1.0 送审(build 2026092404) + Mac build 8"
created: 2026-09-29T00:30:00+08:00
source: cli
---

# RemoteCrab / iBridge 会话记忆 — 2026-09-29

主线是**收尾验证与发版**，但过程中又抓到 3 个真 App bug。本次会话的核心结论：
**能在 Mac 侧修的绝不动 iOS**（Mac 走 Sparkle 不审核，一天能发 5 个 build；iOS 一天只能等一次审核）。

## 1. 情景模式动作标签永远不本地化（iOS 端唯一的真 bug，已在审包里）
`Text(LocalizedStringKey(label))` 查的是 **`Bundle.main`（app bundle）**，而 catalog 在
**Core 包**里 → 79 条动作标签在中文 UI 全是英文，译文一直在。修法：`IBLocale.string(_:)`
（`String(localized:bundle:.module)`）用在 4 个渲染点。**只有截图能发现，单测测不到**。
修复 17:34 提交 → 审核包 **19:21** 构建，**就在 build 2026092404 里，无需重提**。（lesson 84）

## 2. 「时灵时不灵」= 我自己留下的幽灵回环连接（Mac 端，已发 build 8）
截图工作留下两个**开着的模拟器**在 `127.0.0.1:8765` 监听，接收端的直连回退连上了它，
把 `remotecrab.lastPhoneIP = 127.0.0.1` **持久化**，此后每连一次再存一次 —— 自我强化。
`DirectDialAddress.isUsable` 在**写入点和读取点**都拒绝 loopback / link-local / `%en0` / 非点分四段。
两条铁律：截图/仿真做完 `xcrun simctl shutdown all`；会被持久化并再次拨号的地址**写入时就校验**。（lesson 83）

## 3. 通知点击跳转（本会话新功能，已上线 Mac build 7/8）
中继收到横幅后点一下 → Mac 激活对应 App **并恢复该 App 的前台窗口**。
iOS 侧：`NotificationTapRouter` + `UNUserNotificationCenterDelegate`（**必须在
`didFinishLaunching` 装**，冷启点击会丢）+ `willPresent`（否则前台时系统吞横幅）。
Mac 侧：无需改动，`activateApp(id:windowTitle:)` 早已支持。`windowTitle` 需要屏幕录制权限，
nil 不是错误（只激活 App）。App 已退出则**明确不动作**（激活用户已退出的 App 是意外）。（lesson 82）

## 4. e2e 三个 harness bug（都是我自己写错的，不是产品 bug）
(a) 扩展显示器钩子**固定 sleep 2s**，但虚拟显示器要 ~3s 才存在 → 改**轮询状态**；
(b) `showDesktop` 钩子和应用切换钩子**竞态**（前者隐藏了后者需要的 App，按设计回退整屏）→ 钩子**排序** + 断言**意图**（「恢复跟随」）而非某个 `reason=`；
(c) `check "[notify] tap:"` 在 BRE 里 `[notify]` 是**字符类**，点击真发生了却报失败 → 转义。
**通则：e2e 断言红了，先怀疑断言。**（lesson 85）

## 5. 发布面结论
- **iOS 1.0**：`WAITING_FOR_REVIEW`，build **2026092404**，32 张新截图（8 故事 × 2 设备 × 2 语言），
  送审文案**清零 "Mac"**（5.2.5）。**ASC API 不能撤回**（`reviewSubmissions` 无 DELETE），
  已送审再换包要人点浏览器。app 名改 en `Phone as Cam & Pad` / zh `手机变 电脑 外设`。
- **Mac build 8**（`sparkle:version 8`）公证上线，含中继崩溃 + 幽灵 IP 两个真修复。
- 摄像头对外只宣称 **1080p 输出**（虚拟摄像头只声明 1920×1080@30；4K 只是采集下采样更锐利），
  网站 + ASC 文案已统一。

## 6. 诚实清单（未验证）
- 幽灵过滤后的回环是否在**真机重连**下彻底干净（我清掉后尚未让用户复跑）
- 投屏/扩展显示器的**真机** App Store 截图（模拟器无 Mac）
- Sparkle **空闲门控在真实活跃会话**下是否推迟安装（只测过无会话）
- iPhone 4K 采集档位的真机效果
