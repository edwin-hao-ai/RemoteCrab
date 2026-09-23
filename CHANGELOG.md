# Changelog

RemoteCrab 的版本记录。版本号对应 App Store 的 marketing version
（`project-ios.yml` / `project-mac.yml` 是唯一来源，xcodegen 会重写 Info.plist）。

---

## [1.1] — 未发布（下一版上架，当前 1.0 在审核中）

> 这一版把 V1.1–V1.3 的全部改动一起发。**iOS 与 Mac 两个安装包都要更新**——
> 连接稳定性、退出 App、滚动手感都依赖 Mac 端的新版本。

### 新增
- **情境快捷键面板扩到 17 套件**：演示 · 智能体 · 访达 · 备忘录 · 浏览器 · 邮件 ·
  信息 · 日历 · Xcode · 代码编辑器 · 文本 · 媒体 · 聊天 · 会议 · 图片 · 笔记 · 控制台。
  按 Mac 当前前台 App 自动切换；每个快捷键都对着 App 的真实菜单栏校验过
  （见下「快捷键校验」）。
- **多选发送**：一次选多个文件/图片发给 Mac（串行队列，保证不交错损坏），
  Mac 端只揭示一次 Finder。
- **「发送最新截图」**一键发送（新增相册读取权限，onboarding 里一并申请）。
- 连接信息页新增**「选择 Mac」**入口；设置新增**滚动速度 / 自然滚动 / 后台保持连接**。
- 窗口切换器：**退出 App 后卡片立即消失**。

### 改进
- **触控板滚动手感**：速度相关动量（猛甩滑得远、轻扫很快停）、滚动加速度、
  事件合并（120Hz→≤60Hz，Wi-Fi 更稳）、自适应触觉 + 滑行阶段不震动、
  pinch 去抖、**滑行中轻点 = 刹车而不是点击**。
- **玻璃按钮整块可点**：原来只有图标/文字可点，卡片右半边是死的。
- 键盘模式下快捷键行不再被底部 PTT 行遮挡。

### 修复
- **Mac 端「退出 App」完全失效**：根因是 App 沙盒禁止终止其他进程
  （`terminate()` 静默返回 false）→ **移除 Mac 端沙盒**（Developer ID 分发不需要），
  并加一次性设置迁移（保留已配对 Mac / 设置 / Mac 身份 id）。
- **演示模式**：Keynote / PowerPoint 支持 ← → 翻页、B 黑屏、W 白屏、
  ⌥⌘P 播放/退出、esc 退出（⌥⌘P 已对菜单校验）。
- **媒体键（音量 / 静音 / 亮度）**编码修复（`data1` 之前多移了一次，设备上完全无效）。
- 切换器漏掉**最小化 / 隐藏 / 其他 Space** 的 App（现以 App 卡片补齐）。
- 快捷键行改为前置 ⏎ / ⌫；情境卡片按下有按压反馈。

### 连接与稳定性（本版重点）
- **Mac 主动拨号任何发现的 iPhone**（不再要求先有配对 token）——修掉「重装/迁移后
  永远连不上」。
- **握手超时**：TCP 通了但 6 秒收不到 sessionReply 就放弃重连——修掉半开连接
  永久卡死（"连不上"的头号根因）。
- **iPhone 侧 owner 静默 10 秒释放**：半开（Wi-Fi 掉、Mac 冻结）不再永久占用会话。
- **Mac 侧 8 秒无 pong 判定死链**，几秒内开始重连。
- **后台 / 锁屏保活**：`UIBackgroundModes: [audio]` + 静音音频会话，切 App 或锁屏
  不再掉线（修复前 App 一后台就被 iOS 挂起、监听关闭、Mac 再也连不上）。设置里可关。

### 已知限制
- **后台/锁屏时相机停止**（iOS 平台限制，回前台点一下相机按钮恢复）；连接本身不断。
- 不支持**蓝牙 / USB** 直连；当前是 Wi-Fi，且已开 **AWDL 点对点**（无路由器也能直连）。
- **会议套件以 Zoom 键位为准**；Teams / 腾讯会议键位不同（装了可按实测调整）。
- Electron 类 App（VSCode / Discord / 飞书 / 微信）无法用 AppleScript 读菜单，
  快捷键按官方文档写。

### 快捷键校验（方法）
用 AppleScript 读每个 App 真实菜单栏的 `AXMenuItemCmdChar` +
`AXMenuItemCmdModifiers`（0=⌘ 1=⇧ 2=⌥ 4=⌃ 8=无修饰）。已核实：访达、Safari、
日历、备忘录、邮件、Music、Keynote、Pages/Numbers、Xcode、Obsidian。
据此修正了三处错误绑定：
- 邮件「删除」：⌫ → **⌘⌫**
- 信息「发送」：⏎ → **⌘⏎**
- 备忘录「删除」：语义含糊 → 换成 **⇧⌘N 新建文件夹**

并拆分了 `editor` 套件（`⌘B` 在 Xcode=构建、TextEdit=加粗、VSCode=切换侧边栏）。

---

## [1.0] — 2026-09-19（已提交 App Store 审核）

- 首发：iPhone/iPad 变身 Mac 的摄像头（1080p H.264 虚拟摄像头，CMIO 系统扩展）、
  麦克风（`RemoteCrab Microphone` HAL 驱动）、触控板、键盘、按住说话（本地语音识别）。
- 本地 WiFi + Bonjour 直连；无账号、无云、无订阅。
- Mac 端菜单栏 App、录制、文件接收、剪贴板、App 切换器、首次运行设置助手。
- App Store 文案 / 隐私政策 / Demo 视频 / 截图就绪；Mac 1.0 Developer ID 公证 DMG
  在 `vgoapp.com/downloads/RemoteCrab.dmg`。
