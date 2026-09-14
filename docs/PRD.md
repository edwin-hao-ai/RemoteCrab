# RemoteCrab 产品需求文档 (PRD)

> V0.4 状态文档 — 2026-09-13
> 配合 `HANDOFF.md`（状态）、`AGENTS.md`（项目 context）、
> `docs/RELEASE_READINESS.md`（发布就绪度 + 过审评估）一起看

## 1. 产品愿景

把 iPhone / iPad 变成 Mac 的**无线外设** — 摄像头、麦克风、触控板、键盘。**完全本地**、**零订阅**、**零云端**。

## 2. 用户场景

### 2.1 目标用户
1. **Mac mini / Mac Pro 用户**（无摄像头 / 麦克风）
2. **多设备办公人群**（同一 iPhone 给多台 Mac 用）
3. **临时需要外设的用户**（出差、家庭场景）

### 2.2 核心场景
- "Mac mini 没有摄像头" — 解决方案：iPhone 当前置 / 后置摄像头
- "蓝牙 app 走订阅 + 隐私顾虑" — 解决方案：RemoteCrab 完全本地
- "工作流需要动触控板但不在 Mac 旁" — 解决方案：iPhone 当触控板

## 3. 范围

### 3.1 V0.1（已交付）
- iOS app：模拟器 e2e（wire 协议 + Bonjour + capture + encode）
- Mac app：模拟器端接收
- 完整 26 测试 e2e + 单元

### 3.2 V0.2（已交付 ~95%）
- 完整 UI（设计系统 + Liquid Glass + iOS 17 fallback）
- iOS Capture：摄像头 + 麦克风 + 触控板 + 键盘事件
- Mac Receiver：Bonjour browse + 解码 + 播放 + 触控板/键盘注入
- 中英双语（.xcstrings）
- 完整 simulator e2e 脚本
- 真机可装（iPhone 14 装上了，**唯一阻塞：Mac 端 Accessibility 权限**）

### 3.3 V0.3（待做）
- Camera Extension（macOS 26 完整 XPC wiring）
- 虚拟麦克风（AUv3 extension 装到 Mac）
- Settings UI 完整版
- 错误状态 UI
- 崩溃报告

### 3.3b V0.4（已交付，真机验证）
- 多 Mac 配对（`clientHello`/`sessionReply`，TOFU token，busy 退让）
- 应用切换器（iPhone 列出 Mac 运行 App，一键拉起）+ 键盘 ⌘⇥ 等 chords
- 文件传输（照片/视频/文件 → `~/Downloads/RemoteCrab` + Finder）
- 剪贴板互通（双向）
- Mac 端录制（`~/Movies/RemoteCrab` 的 `.mov` + `.wav`）
- 语音：hold-to-talk 听写 + "打开 X" 切应用 + "改写为…" 变换选中文本（本地、离线）
- 多语言跟随系统（en + zh-Hans）
- 74 单测 + `scripts/e2e-device.sh`（真机 10/10）

### 3.4 V1.0（待做）
- **Camera Extension 用户激活 + 真机验证**（否则"UVC 摄像头"卖点不成立）
- **虚拟麦克风（CoreAudio HAL 插件）**（否则"麦克风设备"卖点不成立）
- 手动 IP 兜底、审核材料 + 演示模式、真机截图/隐私 URL
- Apple Developer Program ($99/年)、App Store 审核与上架、Notarization
- 完整 VoiceOver / Dynamic Type、更多语言
- 详细缺口见 `docs/RELEASE_READINESS.md`

### 3.5 不做（明确划线）
- ❌ Windows 支持
- ❌ Android 支持（短期）
- ❌ ASR / 语音输入
- ❌ 多 iPhone 协同
- ❌ 实时滤镜 / 美颜
- ❌ 录屏 / 视频剪辑

## 4. 核心差异化

| 对手 | 模式 | RemoteCrab |
|---|---|---|
| EpocCam | 订阅 $8 一次性 | 免费、本地、零订阅 |
| Camo | $40/年订阅 | 一次性安装、零订阅 |
| Iriun | 免费 + 广告 | 零广告、纯本地 |
| Apple Continuity Camera | 仅 Apple Silicon 套件 | 任何 iOS 14+ 设备 |

## 5. 用户故事

### 5.1 v0.2 范围
- US-1: 作为 Mac mini 用户，我需要把 iPhone 当摄像头开 Zoom 会议
- US-2: 作为 Slack 视频通话用户，我希望通话时 iPhone 麦克风能用
- US-3: 作为远程工作用户，我希望能在 iPhone 上当触控板控制 Mac
- US-4: 作为临时用户，我希望能用 iPhone 给 Mac 输入文字

### 5.2 v0.3+ 待做
- US-5: 作为多设备用户，我希望在不同 Mac 间切换 iPhone 流
- US-6: 作为开发者，我希望 Bonjour 不可用时手动输入 IP 连接

## 6. 核心约束

### 6.1 技术
- iOS 14+ → 已升级到 iOS 17（兼容 iPhone 14 / iOS 18.6.2）
- macOS 26+（需要 Camera Extension / AudioUnit v3 / Liquid Glass）
- Bonjour / mDNS（要求同一 multicast 域，USB-tether 边界是坑）
- Swift 6 strict concurrency
- 不依赖云、不依赖账号

### 6.2 产品
- 不订阅、不收费、不打广告
- 永远本地优先
- 始终开源（Wire 协议文档化、模块化）
- Apple-原生设计（Liquid Glass、Apple Native 风格）

## 7. 核心指标

- 端到端延迟 < 200ms（vs 蓝牙 Webcam 500ms+）
- CPU 占用 < 15%（H.264 硬编）
- 内存 < 200MB
- Bonjour 发现 < 2s
- 真机 e2e 跑通（一个 iPhone + 一台 Mac）

## 8. 风险

| 风险 | 严重度 | 缓解 |
|---|---|---|
| Bonjour 不在同子网 | 高 | 加手动 IP 输入（v0.3） |
| Apple 拒绝 App Store 审核 | 中 | 完整权限描述 + 隐私政策 |
| macOS 14+ 拒绝 Accessibility 弹窗 | 高（已踩坑）| 用户手动加（一次） |
| Camera Extension 装不上 macOS 26 | 中 | ad-hoc → 真实 signing 流程化 |
| iOS 17 兼容 iPhone 14 | 低 | 已完成 |
| Liquid Glass 装旧 iOS | 低 | fallback 已实现 |

## 9. 里程碑

| 阶段 | 目标 | 状态 |
|---|---|---|
| M0 | 26 测试 e2e | ✅ |
| M1 | 完整 UI + 真机装上 | ✅ |
| M2 | iPhone ↔ Mac 真机 e2e 通 | 🔄 阻塞 Accessibility |
| M3 | Camera Extension + 虚拟麦克风 | ⏳ |
| M4 | App Store 发布 | ⏳ 需 Apple Developer Program |

## 10. 设计原则

1. **Apple Native**: 永远不脱离 Apple-原生设计风格
2. **本地优先**: 数据不离开用户的 WiFi
3. **零摩擦**: 设备之间 Bonjour 自动发现
4. **零账号**: 不需要注册
5. **零订阅**: 一次安装

## 11. 核心产品 / 体验原则

- 启动后立即在 Bonjour 上 advertise，用户在 Mac 上 2 秒内看到
- 三模式（Camera / Trackpad / Keyboard）切换无延迟
- 模式切换不打断流（Camera → Trackpad 不掉线）
- Mic 可独立开关
- iPhone 锁屏 Mac 端显示 RECONNECTING（不卡住）
- 错误状态清晰：没权限、没找到 Mac、网络断
- 所有动作有 Liquid Glass 动画（标准 Apple 风格）

## 12. 商业模型

**完全免费**。无内购、无订阅、无广告。
- Apple Developer Program $99/年（个人或公司）
- 开发时间成本已投入
- 如果需要钱来源：Apple Developer Program 折扣码 或者众筹

## 13. 反馈循环

- 真实用户测试（先 iPhone 14 + MacBook）
- Simulator e2e 自动化
- 26 个单元 + e2e 测试
- 19 张 UI 截图

## 14. 未来扩展（v2+）

- Windows 支持（libusbmuxd / libimobiledevice 协议）
- Android（Camera2 API over WiFi）
- 多 iPhone 协同
- 录屏 + 视频剪辑
- 实时滤镜
- Apple Watch 控制

## 15. 明确划线（明确不做）

- ❌ 任何云端 / 服务器
- ❌ 账号 / 注册
- ❌ 订阅 / 收费
- ❌ 实时滤镜（v0 不做）
- ❌ Android（短期）
- ❌ Windows（v0 不做）
- ❌ 云端 ASR / LLM 听写清理（语音识别只在设备端；不接任何云服务）
