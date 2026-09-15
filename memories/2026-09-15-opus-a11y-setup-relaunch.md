# 2026-09-15 下午：Opus 落地、设置向导重启入口、无障碍核心批、卡片状态修复

## 完成（全部已提交 main，未 push——push 由用户决定）

| Commit | 内容 |
|---|---|
| `ed49e8a` | Opus 编码：Apple 原生 AudioConverter（零依赖），48kHz mono 24kbps，20ms 包；`AudioPacket.codec` 字段向后兼容（旧 JSON 解出 pcm）；编码失败 >10 次永久回退 PCM；两个 converter 陷阱（input proc 返回 noErr+0 包会永久 finalize；packet description 数组必须按实际包数分配否则栈溢出）。87/87 测试绿 |
| `138ddf2` | 设置向导「已开启？重启 RemoteCrab」按钮：TCC 辅助功能授权按进程缓存（踩坑 #10），授权后运行中的 App 永远读不到；`SetupStatus.relaunchApp()` 开新实例退旧实例。已部署 /Applications 并真机截图验证：重启后辅助功能 ✅ |
| `2def247` | 测试计数标签 49/74 → 87（test.sh + AGENTS.md） |
| `0849338` | 无障碍核心批：iOS IBFont 9 个非 mono token 映射系统 Text Style（macOS 保持固定，mono 系保持固定）；`IBLocale.A11y` 42 键 + Connection 5 键双语；PiP/ToggleRow/菜单栏图标/侧栏/状态卡 5 项功能阻断修复；12 处装饰图标 hidden；PTT 胶囊 minHeight。模拟器 large + AX2 两档截图自查无溢出 |
| `0442068` | CameraExtensionCard 状态改为 1s 轮询真实 CMIO 设备列表（原来只看本进程激活回调，系统设置里手动开关不回调、状态永远 stale） |
| `52673fb` | AGENTS.md V1.0 清单更新到当日状态 |

## 关键结论

- **AXIsProcessTrusted() 按进程缓存是真实行为**（iOS 26/macOS 26 实测）：TCC db 已 auth_value=2，运行中进程仍返回 false。唯一可靠解是重启 App；向导里已有按钮和说明文案。
- **Opus 带宽**：~1Mbps(base64 PCM)→ ~35kbps。iOS 真机编码器可用性待 e2e 确认（看 forensic.log `[e2e] opus encoder ready`）。
- **相机扩展用户已批准**（2026-09-15），设备正常发布，向导虚拟摄像头步 ✅。
- **MenuBarMenu 4 个 ToggleRow 标题**曾在中文系统下显示英文（title 走 LocalizedStringKey 硬编码），0849338 顺手修成 IBLocale。

## 环境状态

- iPhone 14 UDID 866A1921-… available (paired)；USB 连接正常（之前 tunnel unavailable 是数据线问题，用户换线解决）
- Mac 挂 fake-ip VPN：Bonjour 走 WiFi 会死，USB 插入后 Bonjour 走 USB 接口可用；api.appstoreconnect.apple.com TLS 被杀，需 python monkeypatch socket.getaddrinfo 走 DoH
- /tmp/rc-verify worktree 已清理
- 两个旧 python http.server 8765 已 kill（曾占住 App 监听端口）
- 旧 Familiar TCC 条目已 tccutil reset

## 待办（下一会话）

- 真机 VoiceOver 走查（#9 Announcement 时机、#4 PiP 双击）、#19/#20/#21 收尾
- 虚拟麦克风 pkg 安装验证（dist/RemoteCrabMicrophone.pkg）
- App Store 提审（release-ios.sh --all + 浏览器手动提交）
- iOS 反向选 Mac（架构改动，2-3 天）
- ASC 截图是模拟器采集非真机，如审核有意见需换真机截图
