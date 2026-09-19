---
type: memory
title: 2026-09-19 RemoteCrab V1.0 提交审核 + Mac 公证分发 + vgoapp 站
created: 2026-09-19T08:28:44.738470+00:00
tags:
  - remotecrab
  - v1.0
  - app-store
  - release
  - notarization
  - vgoapp
---

# 2026-09-19 RemoteCrab V1.0 提交审核 + Mac 公证分发 + vgoapp 站

# 2026-09-19 RemoteCrab V1.0 发布 session

## 成果（都已提交）
- **iOS 1.0 已提交审核**：build `2026091802` → ASC app 6811599153 → version 1.0 + TestFlight Internal 组（`IN_BETA_TESTING`）。`WAITING_FOR_REVIEW`。
- **Mac 1.0 公证分发**：`dist/RemoteCrab-1.0.dmg`（Developer ID + 公证 + stapled，`spctl` accepted），由 `scripts/release-mac.sh 1.0` 产出；内嵌虚拟麦克风 pkg 也签名+公证。
- **域名切到 vgoapp.com**：`~/VGOAPP` 新增 `/remotecrab/` 产品页 + `/remotecrab/privacy/` 隐私页（Vite 多入口静态页），部署在 VPS `/var/www/vgoapp`（Caddy），`VGOAPP/scripts/deploy.sh` 发布；DMG + demo 视频在 `/downloads/`。
- **iOS 下载引导**：`RemoteCrabCore.State.RemoteCrabLinks` 单一来源；引导第 3 页 / 「等待 Mac 连接」卡片 / 设置 都有「下载 Mac 版」。
- **审核备注 + 演示视频**：notes 写清 Demo Mode / Mac 下载 / 权限 / 隐私 / 视频 URL；视频 `vgoapp.com/downloads/RemoteCrab-demo.mp4`。

## 关键踩坑（详见 AGENTS.md lessons 29-36）
1. `xcodebuild -exportArchive` → `Cloud signing permission error`（API key 无 cloud-managed distribution cert 权限）。改为 archive 后**手工逐层 Developer ID 重签** + 删开发 profile + notarize；**不需要任何 provisioning profile**。
2. 内嵌 mic pkg 是公证唯一失败点：driver 要 `--timestamp`，pkg 要 `productsign`（Developer ID Installer）；productsign 首次弹钥匙串密码框。
3. `xcodegen generate` 会用 project-*.yml **重写 Info.plist**，版本号/出口合规必须写进 yml。
4. 审核备注是必需的，且 `appStoreReviewDetails` 在 `WAITING_FOR_REVIEW` 也能 PATCH；但 App Store **`privacyPolicyUrl` 不在 API**，只能网页填。
5. 演示视频：macOS **无法 CLI 录 iPhone 屏幕**；`simctl io recordVideo` 还会莫名早停。可行方案 = 桌面并排两窗口 + `screencapture -V` 整屏 → ffmpeg crop+hstack。
6. `UIBackgroundModes` 其实不存在 → **后台麦克风从未生效**（旧文档写错了），也顺带规避了 2.5.4 风险。

## 待人工
- ASC 网页填隐私政策 URL：`https://vgoapp.com/remotecrab/privacy/`。
- 装 TestFlight `2026091802` 验证下载按钮；等审核结果。
