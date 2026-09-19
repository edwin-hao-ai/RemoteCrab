# RemoteCrab — 发布就绪度（V1.0）

_2026-09-19 · 已提交 App Store 审核 · 附当前状态与剩余事项_

## 0. 结论

技术层面**全部就绪**：iOS 1.0 已提交审核（`WAITING_FOR_REVIEW`），Mac 1.0 已
Developer ID 签名 + 公证、可分发。剩下的只有**人工操作**（ASC 隐私政策 URL）
和**等审核结果**。

上架对象只有 **iOS 端 `RemoteCrab Capture`**；Mac 端 `RemoteCrab Receiver`
因需要 Accessibility + CMIO system extension，**不走 Mac App Store**，单独以
公证 DMG 分发。所以"过审"只针对 iOS 包，但 iOS 包的核心价值依赖 Mac 端 ——
这仍是最大风险点（见 §3）。

---

## 1. 已提交/已发布的产物

| 产物 | 状态 |
|---|---|
| iOS build `2026091802`（version 1.0） | ✅ ASC app 6811599153，`WAITING_FOR_REVIEW`，已挂版本 1.0 + TestFlight Internal 组 |
| iOS 元数据（en-US + zh-Hans：description/keywords/subtitle/promo/marketing/support） | ✅ 已推送并回读 |
| iOS 截图（iPhone 6.9" + iPad 13"，32 张） | ✅ COMPLETE（模拟器 UI 合成；如需可换真机） |
| Mac 安装包 `dist/RemoteCrab-1.0.dmg` | ✅ Developer ID 签名 + 公证 + staple；`spctl` = accepted |
| 虚拟麦克风 pkg（内嵌于 app） | ✅ Developer ID Installer 签名 + 公证 |
| 官网产品页 `vgoapp.com/remotecrab/` | ✅ 上线（200） |
| 隐私政策页 `vgoapp.com/remotecrab/privacy/` | ✅ 上线（200） |
| Mac 下载 `vgoapp.com/downloads/RemoteCrab.dmg` | ✅ 上线（200） |
| 演示视频 `vgoapp.com/downloads/RemoteCrab-demo.mp4` | ✅ 上线（200）+ 写进审核备注 |
| 审核备注（App Review Information → Notes） | ✅ 已写（Demo Mode / Mac 下载 / 权限 / 隐私 / 视频） |

`./scripts/test.sh` 全绿（94 测试 + 两 app 构建）。

---

## 2. 旧缺口清单的现状（对照 2026-09-13 版）

| # | 旧缺口 | 现状 |
|---|---|---|
| F1 | Camera Extension 用户激活 + 真机验证 | ✅ 已跑通（真机像素验证 avg=111，用户已批准 sysex，设备正常发布） |
| F2 | 虚拟麦克风 | ✅ 驱动签名 + 公证，随 DMG 内嵌 pkg，一键安装（HAL 经 UDP 环回喂数据） |
| F3 | 手动输入 IP 兜底 | ✅ 已完成 |
| F4 | 审核员可测试路径（演示模式） | ✅ 已完成（设置里的 Demo Mode） |
| F5 | App Store 素材 + 托管 URL | ✅ 截图 + 双语元数据 + vgoapp.com URL |
| F6 | 录制合轨 | ✅ 已完成 |
| F7 | 锁屏/后台提示 | ✅ 已完成 |
| — | Opus 编码 | ✅ 已完成（2026-09-15，Apple AudioConverter，零依赖） |

---

## 3. App Store 过审评估（提交后）

### 结论
权限、隐私、API 均合规。已把此前最大的硬风险（**审核员无法测试**）用
「审核备注 + 演示视频 + App 内下载引导」三件套缓解。若被拒，最可能是
"请提供真机演示视频"，属于可快速补救。

### 风险点
| 风险 | 指南 | 严重度 | 现状/缓解 |
|---|---|---|---|
| **审核员无法测试**：核心功能依赖配套 Mac app（不在 Mac App Store） | 2.1 Completeness / 4.2 | 🔴 高 | 已写审核备注（含 Demo Mode 免 Mac 预览路径）+ 演示视频 URL + App 内「下载 Mac 版」按钮 |
| 后台音频模式用途 | 2.5.4 | 🟢 低 | **实际未声明** `UIBackgroundModes`（旧文档有误）——见 §4 |
| 营销夸大（"在 Zoom/OBS 当摄像头"） | 2.3 | 🟢 低 | 相机扩展已真机跑通，文案属实 |
| 本地网络 + Bonjour / 语音识别权限 | 5.1.1 | 🟢 低 | 用途字符串就位 |
| 出口合规 | 加密 | 🟢 低 | `ITSAppUsesNonExemptEncryption=false`（且已写进 `project-ios.yml`，防 xcodegen 冲掉） |
| 付费/账号 | 3.1 / 5.1.1 | 🟢 低 | 免费、无 IAP、无账号、无追踪 |
| App Privacy 问卷 | — | 🟢 低 | 应为 **Data Not Collected**（与实现一致） |
| App Store 隐私政策 URL | 5.1.1 | 🟡 中 | **待人工**：API 不开放该字段，需在浏览器填 `https://vgoapp.com/remotecrab/privacy/` |

---

## 4. 仍需人工 / 后续

- **[人工]** ASC → App 信息 → 隐私政策 URL 填 `https://vgoapp.com/remotecrab/privacy/`。
- **[人工]** 装 TestFlight `2026091802` 确认引导第 3 页 / 「等待 Mac 连接」卡片的下载按钮。
- **[可能]** 若审核要求真机摄像头演示：录一段 iPhone 屏（控制中心 → 录制），
  用 `scripts/demo-video.sh` 的思路重新并排合成，替换同一 URL 即可。
- **后台麦克风并未实现**：`UIBackgroundModes` 在代码库中不存在 → 进后台 iOS 挂起，
  mic 停止。要启用需加进 `project-ios.yml` 并能向 Apple 解释（当前反而规避了 2.5.4）。
- **VoiceOver / Dynamic Type 真机走查**（核心批已做，剩真机确认）。
- **崩溃上报**（OSLog + 第三方，隐私优先）。
- **iOS 端发起选择 Mac**（架构改动）。

---

## 5. 明确不做（守住定位）

云 LLM 听写清理、agent 状态 / Live Activity、MCP bridge、窗口缩略图（需屏幕录制权限）、
任何人脸/滤镜。**不加** CloudKit / Firebase / 分析/追踪依赖（产品核心是"无云"）。
