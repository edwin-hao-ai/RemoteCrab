---
title: Windows 端审计收尾 —— 剩下的四项需要跨端或基建设计
type: handoff
status: current
last_verified: 2026-10-05
code_baseline: fa67529
---

# 剩下的四项：为什么没有「顺手修掉」

2026-10-05 的审计一共列出 22 项 Windows 侧问题。**18 项已修**（见文末）。
剩下 4 项不是没时间，而是**每一项单独做半套都会让产品更糟**。这里写清楚为什么，
以及要动的话应该怎么动。

---

## 1. 🔴 对端不验证身份（发布硬门槛）

### 现象

`rc-net` 里没有任何 `verify` / `challenge` / `proof` / `authenticate`。手机验证电脑
（token），电脑从不反向验证手机：任何在 8765 应答 `SessionReply{Accepted}` 的机器都会
被当作手机连上，随后它发来的 `Touch`/`Key`/`SystemCommand`/`QuitApp`/`Clipboard`/
`FileOffer` 全部被执行——等于把键鼠和文件系统交给同网段陌生人。

### 为什么不能只加一个 HMAC 就算了

**这条链路是明文 TCP。** ClientHello 里的 pairing token 是明文 JSON 发出去的。
在这个基础上加 HMAC 挑战-应答，只能挡住「不知道 token 的人」，**挡不住同一个 WiFi 上
抓包的攻击者**——token 和随后的 HMAC 都在同一条可读的流里。

而「只在 Windows 侧加校验」还有一个更直接的后果：iOS 现在不会回 proof，那么所有
**已存在的配对**都会被判为未验证。要么全部断掉输入（产品坏掉），要么加个
「对端没报支持就放行」的降级——那等于什么也没修，却让人以为修了。

### 建议的正解（需要 iOS 配合）

二选一，都是协议级：

**A. TLS（推荐）**
- 配对时双方各生成一个自签名证书，把对方证书的指纹存进 pairing store（TOFU）。
- 之后每次连接走 TLS 1.3，双向校验指纹。
- 明文问题、身份问题一起解决；文件传输和剪贴板也顺带加密。
- Rust 侧 `rustls` + `tokio-rustls`；iOS 侧 `Network.framework` 的 TLS。

**B. PAKE（SPAKE2 / Noise XX）**
- 配对时协商一个共享密钥，之后用它做认证密钥交换。
- 比 A 多写代码，但不需要证书管理。

**在这之前不要加「Windows 单侧校验」**：它给的是false confidence，
而用户会因此以为咖啡厅 WiFi 上是安全的。

### 顺便要一起处理的

- `learn_phone_identity` 直接采纳对端自报的 `device_name` 并据此 `rekey_token`
  （`supervisor.rs:654`）。这一条被本次的身份问题覆盖——鉴权落地后它才有意义。
- pairing token 明文落盘（`%APPDATA%\RemoteCrab\tokens.json`）。已加 `icacls`
  收紧到当前账户，但没有 DPAPI 加密（同用户下任意进程仍可读）。TLS 方案会
  把 token 降级为「设备指纹」而非 bearer secret，届时这条自然消失。

---

## 2. 🔴 没有自动更新

### 现象

全仓没有任何 HTTP 客户端（`ureq`/`reqwest`/`winhttp` 均无）。`rc-net/src/update_gate.rs`
是一整套**门控策略**（`should_install` / `should_install_after`），但：

- 没有任何生产代码调用它（只有 `pub mod` 和它自己的测试）；
- 没有版本检查、下载、签名校验、替换、重启。

发版后用户升级的唯一途径是手动下载新 MSI。

### 为什么不能顺手接上

**RemoteCrab 没有更新源。** Mac 端走 Sparkle，需要一条 appcast feed；Windows 端
连 feed 的 URL 都不存在。这不是「写个下载循环」，是「先决定 Windows 包从哪里分发、
谁签名、怎么回滚」。

### 建议

1. 先定分发源（可以复用 Mac appcast 的托管位置，加一个 Windows channel）。
2. MSI 已经**签名**（`release-windows.sh sign`），所以校验可以用 Authenticode：
   下载 → `WinVerifyTrust` → 比对版本号 → `msiexec /i` 静默安装 → 重启。
3. `update_gate::should_install` 的语义是现成的（「注入输入后 3 秒内不要更新」这类），
   接上去即可。
4. 在 `rc-app` 加一个托盘行「检查更新」，并把结果写进日志。

**在签名证书到位之前，这条不应该开工**——未签名的自动更新是投毒面。

---

## 3. 「画质」设置是死控件（两端都是）

### 现象

`rc-net/src/settings.rs` 的 `Quality`（自动 / 720p / 1080p / 1080p60）只被写进
`%APPDATA%\RemoteCrab\quality` 文件，**从不发给手机**。协议里没有承载它的字段
（`events.rs` 的 `Feature` 枚举只有 camera/microphone/voice/trackpad/keyboard/screen）。

**Mac 端同样是死的**：`PreferencesView.swift` 的 `@AppStorage("remotecrab.resolution")`
和 `remotecrab.audioQuality` 只在 Picker 里读写，全仓没有第二个引用。

所以这不是 Windows 落后于 Mac，是**两端都没实现**。

### 建议

`IBScreenControl` 已经有 `maxPixel`（用于镜像），可以照它的形状加一个
`receiver → iPhone` 的 `StreamPreference { width, height, fps }`，iOS 侧落到
`VideoEncodingPolicy`。**注意 iOS 的 `AverageBitRate` 是 inert 的**（见
`VideoEncodingPolicy.swift` 的注释），能真正改变画质的是 `Quality` 系数和分辨率，
所以字段要选对。

在协议存在之前，Windows 侧保留这个控件（与 Mac 一致）比单方面撤掉更好；
但要在 `WINDOWS_TODO.md` 里标成「已知未接线」，别让它看起来能用。

---

## 4. ✅ Windows 已发 `commandResult`（`0cdf67a`）

**2026-10-05 已实现**，这一条从「剩余」移出。

两半，缺一不可：

1. **接收端**：`ActivateApp` / `QuitApp` / `SystemCommand` 现在会反序列化手机发来的
   `requestId`（iOS 端 `IBActivateApp` / `IBQuitApp` / `IBSystemCommand` 一直有，
   Rust 结构体只是忽略了），三处执行完回发 ok/failed。**没有 id 就不回**——这是
   兼容规则：手机不带 id 说明它读不懂回执，不能告诉它「失败」。

2. **声明**：手机**不会**给没在 clientHello 里声明 `commandResult` 的接收端发
   `requestId`。所以只做第 1 半的话，代码永远不会跑，按钮照样没反应——同一个症状，
   深了一层。`latencyProbe` 一并声明（`rc-net::ping` 确实回显对端发起的探测）。

线格式由测试钉死：capabilities 是裸字符串数组、按声明顺序
（`["latencyProbe","commandResult"]`），与 Swift 的 `Capability: String` 原始值对应。

**未做端到端验证**：模拟器能观察 `commandResult` 帧，但 testkit 没有对外的发送 API，
没法让它发一条带 requestId 的命令。最后一跳靠协议测试覆盖，不是真机跑出来的。
要让它能跑，需要给 `rc-testkit::FakeIphone` 加一个 public send。

**还需要 iOS 侧确认的一件事**：Windows 发来的 `commandResult` 会不会被 iOS 当成
「来自 Mac」而报错。结构相同、kind 相同，理论上直接可用，但没有实机验证过。

---

## 已完成的 19 项（code_baseline `0cdf67a`）

| 项 | 级别 | 提交 |
|---|---|---|
| 三个窗口从来不可见（向导/设置/自检） | 我发现 | `e24578d` |
| 托盘无设置/向导/自检入口 | BLOCKER | `cd8b4c2` |
| MSI 无启动快捷方式 / 不自启 / 提权启动 | BLOCKER | `cd8b4c2` |
| 预览窗口默认打开 | 我发现 | `e24578d` |
| 控制台黑框（`FreeConsole`，兼容 ConPTY） | SHOULD | `ee859c6` |
| 日志在断控制台后丢失（我引入的回归） | 我发现 | `091d485` |
| Frame Server `lock().unwrap()` ×5 | SHOULD | `03c6a9b` |
| vcam writer 句柄泄漏 | SHOULD | `03c6a9b` |
| ring view/mapping/file 泄漏 | SHOULD | `03c6a9b` |
| audio / loopback 锁毒化 | NIT | `03c6a9b` |
| 音频只支持 F32（U8/I16 设备静音） | 我发现 | `03c6a9b` |
| token 落盘静默失败 + 无 ACL | SHOULD | `387febf` |
| `is_registered()` 带写副作用 | SHOULD | `387febf` |
| 文件写入无上限 | SHOULD | `387febf` |
| `FileAck` 编码失败发空帧 | NIT | `387febf` |
| `encode_bgra` / `copy_from_slice` 越界 | NIT | `387febf` |
| `discovery_rx.unwrap()` | NIT | `387febf` |
| `doctor` / `--scan` / 窗口标题 / 画质名 / Forget 文案 / 状态英文泄漏 | SHOULD+NIT | `387febf` `0e42985` `fa67529` |
| 自检每 200ms 重建控件闪烁 | NIT | `fa67529` |
| `wire.rs` 陈旧注释 | NIT | `fa67529` |
| MSI 卸载残留 ring 文件 | SHOULD | 本次 |


## 验证状态（2026-10-06 更新）

- `cargo test --workspace --release` → **588 passed / 0 failed**
- `cargo clippy --workspace --all-targets --release -- -D warnings` → clean
- **四个窗口全部响应**（`SMTO_ABORTIFHUNG` 2 秒内）：向导 / 设置 / 自检 / 托盘。
  之前**一个都没有**被泵过消息——托盘的消息循环过滤了自己那个窗口，而向导建在
  没有循环的运行时线程上。向导白屏卡死就是这条（`f0a387c`）。
- **presence 在网络上可见**：`rc-fe3a662f._remotecrab-computer._tcp.local.`
  与 Mac 并列，地址是 WiFi 的 `192.168.31.103`、端口 8766（`2fc1137`）。
  两个故障：广播的是隧道地址（`local_ipv4_addresses` 问了路由表），以及
  mdns-sd 的 15 字节上限**校验的是服务类型**（`_remotecrab-computer` = 21）。
- **虚拟摄像头的画面有人看过了**：假 iPhone 发真 H.264 → 150/152 帧解码 →
  写进环 → 导出 PNG → 图正确。`dump_ring` 让这条一分钟能重跑（`3826914`）。
- **假 iPhone 现在能驱动接收端**（`FakeIphone::send`，`9bb3671`）：
  - 剪贴板 → Windows 剪贴板拿到标记字符串 ✓
  - 文件 → `Downloads\RemoteCrab\remote-crab-drive.txt` 内容正确 ✓
  - `commandResult "drive-1" failed` 往返 ✓（发的是 Windows 拒绝的亮度命令，
    零副作用）
- **顺带发现并修复一个真 bug**：触控板会把指针**瞬移到左上角**——协议发的是
  相对位移，而 `last_cursor` 初始 `(0,0)` 且只被 `Move` 更新，所以会话第一次
  移动从角落算起。实测 (1200,800) → (0,0)。修法：注入前用 `GetCursorPos`
  锚定真实位置（和 Mac 让窗口服务器跟踪是同一个思路）。
- MSI：卸载清 `vcam-ring.bin`、清 `%LOCALAPPDATA%`（日志 + 已下载的更新包）、
  加 knock 端口的**私有网络**入站防火墙规则（`d80c3a5`）。
- 自动更新：Ed25519 钉公钥 + 下载验签 + 静默安装；发布脚本会产出签名和 feed
  （`52ce88d`）。

## 仍未验证

- **iPhone ↔ Windows 端到端**：连接、在线、敲门已由用户真机确认；**输入注入 /
  剪贴板 / 文件**现在有假 iPhone 覆盖（上面），但**真手机的编码与手势**没跑过。
- **MSI 卸载**只反编译确认过表项，**没真跑**（本机 UAC 弹窗一直被取消）。
- 虚拟摄像头**在相机 App 里出画**：画面正确已证，但“选得到这台相机”需要人开一次
  Camera/Zoom/OBS。
- **speaker 出声**（Windows 采集已验，最后一段没跑）。

## 剩下需要别的资源的

- **代码签名证书**：无免费方案；Azure Artifact Signing（$9.99/月，最便宜）**地域
  限制美/加/欧/英，`Beijing VGO Co.,Ltd` 不适用**。CA OV ≈ $99–200/年。
  自动更新**不需要**证书（Ed25519 已解决）。
- **扩展显示器**：Windows 需 **IddCx 间接显示驱动**（UMDF + `.cat` 签名）。
- **虚拟麦克风**：Windows 需 **sysvad 类 WDK 驱动**。两者都是独立驱动项目。
- **无 DPI 清单**：故意没改——`PerMonitorV2` 会移动注入和镜像几何的坐标来源，
  没有高 DPI 多屏机器验证就盲改，可能把现在正好抵消的东西弄坏。
