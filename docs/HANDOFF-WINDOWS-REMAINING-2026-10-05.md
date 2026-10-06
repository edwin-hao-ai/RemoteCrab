---
title: Windows 端剩余项 —— 每一项为什么不能只做半套
type: handoff
status: current
last_verified: 2026-10-06
code_baseline: bf351bf
---

# 剩下的：为什么没有「顺手修掉」

2026-10-05 的审计列了 22 项 Windows 侧问题，18 项已修；2026-10-06 又修了 6 项
（含 2 个只有打开窗口才会发现的）。下面每一项都不是没时间，而是**单独做半套会让
产品更糟**，或者需要另一侧的资源。写清楚为什么，以及要动的话应该怎么动。

---

## 1. 🔴 对端不验证身份 —— **Windows 半边已做完，iOS 半边待做**

### 现象

`rc-net` 里没有任何 `verify` / `challenge` / `proof` / `authenticate`。手机验证电脑
（token），电脑从不反向验证手机：任何在 8765 应答 `SessionReply{Accepted}` 的机器
都会被当作手机连上，随后它发来的 `Touch` / `Key` / `SystemCommand` / `QuitApp` /
`Clipboard` / `FileOffer` 全部被执行 —— 等于把键鼠和文件系统交给同网段陌生人。

### 已定方案：双向 HMAC（token 从「徽章」变成「密钥」）

TLS 是更彻底的方案（连明文问题一起解决），但它需要 iOS 侧生成自签名证书 + 起 TLS
server，而**这台机器上 Swift 编译不了也测不了**。所以先做能真正做完的那一半：

- token 不再作为凭据**出示**，而是作为 HMAC 密钥，双方各出一个随机数互相证明。
- 重放旧 MAC 无效（随机数每次都新），反射攻击无效（两个 label 域分离）。
- **做的**：冒充。**没做的**：加密 —— 剪贴板和文件内容在同网段仍可读。

被冒充的**受害者是电脑**（攻击者假冒手机 → 给电脑发键盘事件），所以关键的一半是
**电脑验证手机**，而那一半已经落地并测试：

| 位置 | 内容 |
|---|---|
| `rc-protocol/src/peer_auth.rs` | MAC 构造、常量时间比较、10 个单测、**跨语言测试向量** |
| `rc-protocol` | `ClientHello.nonce`、`SessionReply.{nonce,mac,capabilities}`、新帧 `ClientProof`（`0x26`） |
| `rc-net` 握手 | 发挑战 → 验手机 → 回 `clientProof`；验证失败 → `ConnEndKind::Impersonated`（不重试） |
| `State::Streaming` | 带 `authenticated`；状态行在未验证时显示「（未验证身份）」 |
| `rc-net/tests/session.rs` | 三个真实 TCP 端到端测试：证明成功 / 不能证明 / 拿错 token 冒充 |

**老 App 不会被拒绝**（拒绝它等于上线当天把产品弄坏，而接收端没法更新手机），
但会话会被**如实标注**为未验证 —— 不是假装安全，也不是让产品停摆。

### 还需要做的（见 [`HANDOFF-IOS-PEER-AUTH.md`](HANDOFF-IOS-PEER-AUTH.md)）

- iOS 侧按那份文档实现（含**必须先过的测试向量**），并顺带修掉
  `CaptureEngine.swift:1545` 的「clientHello 超时就放行」—— 那个洞比 token 更大。
- Mac 接收端是同样的"电脑"角色，有同一个洞，本轮没动。

---

## 2. 画质设置是死控件（两端都是）—— **仍未做**

`rc-net/src/settings.rs` 的 `Quality`（自动 / 720p / 1080p / 1080p60）只被写进
`%APPDATA%\RemoteCrab\quality` 文件，**从不发给手机**。协议里没有承载它的字段
（`events.rs` 的 `Feature` 枚举只有 camera/microphone/voice/trackpad/keyboard/screen）。

**Mac 端同样是死的**：`PreferencesView.swift` 的 `@AppStorage("remotecrab.resolution")`
和 `remotecrab.audioQuality` 只在 Picker 里读写，全仓没有第二个引用。

所以这不是 Windows 落后于 Mac，是**两端都没实现**。

建议：`IBScreenControl` 已经有 `maxPixel`（用于镜像），可以照它的形状加一个
`receiver → iPhone` 的 `StreamPreference { width, height, fps }`，iOS 侧落到
`VideoEncodingPolicy`。**注意 iOS 的 `AverageBitRate` 是 inert 的**（见
`VideoEncodingPolicy.swift` 的注释），能真正改变画质的是 `Quality` 系数和分辨率，
所以字段要选对。在协议存在之前，Windows 侧保留这个控件（与 Mac 一致）比单方面撤掉
更好，但应当在 UI 上如实标注为未生效。

---

## 3. 需要别的资源 —— **仍未做**

- **代码签名证书**：无免费方案；Azure Artifact Signing $9.99/月，但最便宜档**地域
  限制为美/加/欧/英，`Beijing VGO Co.,Ltd` 不适用**。CA OV 约 $99–200/年。
  自动更新**不需要**证书（Ed25519 已解决）。
- **扩展显示器**：Windows 需 **IddCx 间接显示驱动**（UMDF + `.cat` 签名）。
- **虚拟麦克风**：Windows 需 **sysvad 类 WDK 驱动**。两者都是独立驱动项目。
  本机现状：**WDK 未安装**（`IddCx.h` 不存在、`km` 头目录不存在、testsigning 未开启），
  Windows 11 家庭版 26200 → 连编译都还做不了。
- **DPI 清单**：故意没改 —— `PerMonitorV2` 会移动注入和镜像几何的坐标来源，没有高 DPI
  多屏机器验证就盲改，可能把现在正好抵消的东西弄坏。

---

## 4. 已在本轮做完，从「剩余」移出

| 项 | 提交 |
|---|---|
| 对端不验证身份的**前置**：Windows 发 `commandResult` + 声明 capability | `0cdf67a` |
| 自动更新（Ed25519 钉公钥 + 验签 + 静默安装 + 发布脚本产 feed） | `52ce88d` |
| 定时任务提权（让接收端能驱动管理员窗口，登录自动、无弹窗） | `bae9cfb` |

**自动更新的剩余**：feed URL 尚未发布（`https://vgoapp.com/downloads/windows/manifest.json`
当前 404），所以启动时的检查恒为 404 —— 按设计只记日志、不弹窗。

**定时任务的剩余**：任务由 MSI 在安装时创建，因此**要装一次才生效**。在此之前应用以
medium 完整性运行，向导第 2 页会如实报告。

---

## 2026-10-06 本轮修掉的问题

| 问题 | 级别 | 提交 |
|---|---|---|
| **完整性判定把指针当 SID 解析** —— 随机报成「低权限」，向导据此让用户去提权 | BLOCKER | `4c41d00` |
| **关闭向导会连带杀掉整个接收端**（向导 `WM_DESTROY` 里 `PostQuitMessage`，与托盘共用线程） | BLOCKER | `bce06ae` |
| **托盘图标一碰就弹菜单**（回调对每个事件都响应，包括 `WM_MOUSEMOVE`） | 我发 | `9c360c1` |
| **向导每个控件都是顶层窗口**（`0x0001` 当 `WS_CHILD`、`0x0020` 当 `WS_VISIBLE`） | BLOCKER | `718c301` |
| **自检面板每秒泄漏约 90 个窗口句柄**（标签 id 全是 0，重建时删不掉） | SHOULD | `0d260c1` |
| **设置窗口复选框永远不显示勾**（`if on` 分支加的是已在样式里的标志） | SHOULD | `0d260c1` |
| **`rc-input` 四个测试共用一个全局日志**，并行跑互相清空（单独跑能过） | NIT | `bf351bf` |
| 向导 / 设置 / 自检三窗口对齐产品配色与字体 | — | `51cb58a` `0d260c1` |

---

## 仍未验证

- **iPhone → Windows 端到端**：连接、在线、敲门已由用户真机确认；**输入注入 /
  剪贴板 / 文件**现在有假 iPhone 覆盖，但**真手机的编码与手势**没跑过。
- **定时任务真的创建成功**：需要装一次 MSI（UAC）。无管理员时已验证行为诚实
  （`--install-logon-task` 退出 1 并打印解码后的 `拒绝访问`）。
- **MSI 卸载**只反编译 / 读表确认过表项，**没真跑**（本机 UAC 弹窗一直被取消）。
- **虚拟摄像头在相机 App 里出现**：画面正确已证，但「选得到这台相机」需要人开一次
  Camera / Zoom / OBS。
- **speaker 出声**（Windows 采集已验，最后一段没跑）。
