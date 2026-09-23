# RemoteCrab 1.1 发版计划

_2026-09-23 · 当前 1.0 在 App Store 审核中；本文件是 **下一版（1.1）** 的发布清单。
改动清单见根目录 `CHANGELOG.md`。_

---

## 0. 一句话
这一版同时改了 **iOS 和 Mac 两端**，且 iOS 的连接稳定性 / 退出 App 依赖 Mac 端修复，
所以 **两个安装包都必须更新**：iOS 走 App Store，Mac 走 `vgoapp.com` 的 DMG。

---

## 1. 版本与构建号（唯一来源 = xcodegen 的 yml）
`xcodegen generate` 会**整体重写** `Info.plist`，只改 plist 会被下次生成冲掉。

- [ ] `project-ios.yml`：`MARKETING_VERSION: 1.1`、`CURRENT_PROJECT_VERSION` 递增（1.0 是 `2026091802`）
- [ ] `project-mac.yml`：`MARKETING_VERSION: 1.1`、`CFBundleVersion`（注意：**相机扩展的
      `CFBundleVersion` 若改要重新审批**——本版没改扩展，保持不动即可）
- [ ] `ITSAppUsesNonExemptEncryption: false` 保持在 yml 内
- [ ] `xcodegen generate --spec project-ios.yml` + `--spec project-mac.yml`

## 2. 双端发版
- [ ] **iOS**：`./scripts/release-ios.sh 1.1 --all --create-version`（升版本 → 归档 → 导出 IPA →
      上传元数据/截图 → 上传构建）
- [ ] **Mac**：`./scripts/release-mac.sh 1.1`（Developer ID 重签 + 公证 + staple，产出
      `dist/RemoteCrab-1.1.dmg`）→ 上传到 `vgoapp.com/downloads/RemoteCrab.dmg`
      （`VGOAPP/scripts/deploy.sh`，见 AGENTS lesson 35）
- [ ] TestFlight 内测：`scripts/ios-app-store-testflight.py` 把新构建挂到 Internal 组

## 3. App Store 元数据更新（`scripts/ios-metadata.json`）
`description` 要加新卖点；`whatsNew` 是本版新增字段。已存在的 8 组截图标题见第 4 节。

### 3.1 What's New（release notes，草稿）
**zh-Hans**
```
• 全新「情境快捷键」：按 Mac 当前前台 App 自动切换，覆盖 演示/访达/备忘录/浏览器/邮件/
  信息/日历/Xcode/代码编辑器/文本/媒体/聊天/会议/图片/笔记 等 17 类，一键发音量、翻页、
  回复、构建、静音…
• 发送到 Mac 支持多选文件/图片，并新增「发送最新截图」一键发送
• 触控板滚动大幅优化：更跟手的惯性、可调速度、自然滚动开关
• 后台/锁屏不再掉线；连接更快、更稳（重连秒级恢复）
• Mac 端修复「退出 App」；窗口切换器退出后卡片即时消失
```
**en-US**
```
• New contextual shortcut pads — 17 suites (Presentation, Finder, Notes, Browser,
  Mail, Messages, Calendar, Xcode, code editors, text, media, chat, meeting, image,
  notebook…) that follow the Mac's frontmost app.
• Send multiple files/photos at once, plus one-tap "Latest Screenshot".
• Much better trackpad scrolling: tuned momentum, adjustable speed, natural-direction.
• Stays connected in the background / when locked; faster, more reliable reconnect.
• Mac: the window picker's Quit works; cards disappear the moment an app quits.
```

### 3.2 其它字段
- [ ] `description`：加一段「情境快捷键」+「多选发送 / 最新截图」+「后台保活」
- [ ] `keywords`：追加 `快捷键,自动化,演示控制,翻页,静音`（en: `shortcuts,automation,presentation,remote`）
- [ ] `promotionalText`：换成情境快捷键那句（可随时改，不需要审核）
- [ ] `subtitle`：可不变（`Mac camera, mic & trackpad`）
- [ ] **App Review Notes（重要，浏览器里填）**：必须解释 `UIBackgroundModes: [audio]`——
      「后台音频用于保持与 Mac 的连接并推流麦克风；用户在 设置→输入 可关闭
      后台保持连接」。理由与开关都要写清，避免 2.5.4。
- [ ] `privacyPolicyUrl`：**ASC API 不暴露**，必须在浏览器里设置（1.0 时的遗留项）

## 4. 截图重拍（关键）
1.0 的截图是 09-16 用模拟器合成的，**早于 V1.1 的 UI 改版**（当时还有 FeatureDock），
所以本版必须重拍。ASC 现有 8 组（`scripts/ios-metadata.json` → `screenshotTitles/`）：

| 组 | 是否要重拍 | 原因 |
|---|---|---|
| 01-concept | ✅ | 顶栏/底栏布局改了 |
| 02-camera | ➖ 复核 | 相机界面基本没变，确认后可用 |
| 03-mic | ➖ 复核 | |
| 04-trackpad | ✅ | 底栏 PTT 行取代了旧 dock |
| 05-keyboard | ✅ | 快捷键行变化（⏎/⌫ 前置、键盘模式不再被 PTT 遮挡） |
| 06-voice | ➖ 复核 | |
| 07-files | ✅ | 发送菜单新增「最新截图」+ 多选 |
| 08-privacy | ➖ 复核 | 文案不变 |
| **09-context（新增）** | 🆕 | **本版头号卖点：情境快捷键面板** |

- [ ] 建议再加一组 **10-settings**（展示 滚动速度 / 自然滚动 / 后台保持连接）
- [ ] 规格：`en-US` + `zh-Hans` × **iPhone 6.9"** + **iPad 13"**（沿用 1.0 的规格）
- [ ] 流程：`scripts/capture-asc-raw.sh`（模拟器抓原始图）→ `scripts/compose-asc-screenshots.py`（合成）
- [ ] 已装的真机截图走查放在 `screenshots/`（本仓库只放 mockup/合成图）

## 5. 风险与回归
- **`UIBackgroundModes: [audio]`（2.5.4）**：理由 = 麦克风推流 + 连接保活；给用户开关。
- **Mac 沙盒移除**：Developer ID 公证无碍；但非沙盒后首次写 `~/Downloads`/`~/Movies`
  可能弹一次「文件与文件夹」授权——e2e 已 10/10 通过（当前机器已授权）。
- **设置迁移**：`SandboxDefaultsMigration` 已处理旧容器 → `~/Library/Preferences`，含
  `mac.id`（否则 iPhone 视 Mac 为陌生人 → busy）。
- [ ] 发版前跑：`./scripts/test.sh`（151 tests + 双端构建）+ `./scripts/e2e-device.sh`（10/10）

## 6. 人工待办（Agent 代不了）
- [ ] ASC 浏览器：设 `privacyPolicyUrl`、填 App Review Notes（含后台音频说明）
- [ ] 上传重拍后的截图（`release-ios.sh --all` 会带，或脚本单独传）
- [ ] 确认 Mac 1.1 DMG 已替换网站下载链接
- [ ] 提交审核（浏览器）
