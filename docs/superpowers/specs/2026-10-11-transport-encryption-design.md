---
title: 传输加密（F1）—— 局域网里的按键/剪贴板/音视频必须保密
type: design
status: draft
date: 2026-10-11
related: docs/BASIC_CAPABILITIES_TODO.md §7 (F1)
---

# 传输加密（F1）设计

> 读者：实现者 + 三端（iOS / Mac / Windows）。本文只说清「为什么、改哪里、
> 怎么验、有什么坑」，不写实现。**未批准前不动任何代码。**

---

## 1. 背景与根因

RemoteCrab 的一条 TCP 连接上跑的是：H.264/音频/触摸/按键/**剪贴板**/文件分片/app 列表/系统命令。
今天它们是**明文**。

- `PeerAuth`（`RemoteCrabCore/Sources/RemoteCrabCore/Networking/PeerAuth.swift`）解决的是
  **「你是谁」**（HMAC 挑战-应答），它自己的文档就写了 **"does not encrypt anything"**。
- 产品卖点是「**无云、纯本地**」。但 **「本地」≠「在共享局域网上保密」**：办公室 WiFi、
  合租路由、任一能嗅探/ARP 欺骗的主机，都能**读到你的按键和剪贴板**，甚至**注入**事件。

**这不是安全洁癖**：一个会转发键盘输入和剪贴板的产品，在共享 WiFi 上明文，是可被利用的真实缺口。

### 威胁模型（明确边界）
- **在**：同一二层/三层网络的被动嗅探者、能 ARP 欺骗的主动攻击者（读+改+重放）。
- **不在**：能拿到手机/电脑本机 root 的攻击者；云端（我们根本没有）；流量分析（包长/时序）。

---

## 2. 目标 / 非目标

**目标**
- 握手之后的一切：**机密性 + 完整性 + 防重放**。
- 不引入账号/服务器/CA；密钥**从既有配对里派生**。
- 三端互通：iOS(Swift) ↔ macOS(Swift) ↔ Windows(Rust)。
- 视频是实时的，**额外延迟要可忽略**。

**非目标**
- 云中继、PKI、CA 证书；隐藏元数据（包长/时序）。

---

## 3. 两个方案

### 方案 A —— 直接套 TLS（`NWProtocolTLS` / rustls）
- 两端用 `NWParameters.tls`，身份用**自签证书 + 配对后 TOFU 固定**（或 PSK）。
- **优点**：系统级、成熟，重协商/防重放都替你做了。
- **缺点**：证书的生成/交换/轮换/固定是一整套活；iOS 侧 `NWProtocolTLS` 的 identity 处理
  繁琐；Rust 侧 rustls 要同一套证书；**跨语言一致性测试比方案 B 难**。

### 方案 B —— 应用层 AEAD（ChaCha20-Poly1305，会话密钥）★推荐
- 握手结束后，两端用 **HKDF** 从**配对 token + 双方 nonce** 派生会话密钥 `k`。
- 之后每一帧用 `k` 做 **AEAD 封装**：nonce = 每方向单调计数器，AAD = 帧 kind。
- **优点**：不需要证书；密钥来自**已经存在的配对**（token 本来就认证身份）；与现有
  `PeerAuth` 的挑战-应答同源；`IBWire` 已有帧结构；**两端都有 ChaCha20-Poly1305**
  （CryptoKit / `chacha20poly1305` crate），可**用同一组测试向量跨语言断言**。
- **缺点**：nonce 计数与防重放要自己写；密钥轮换策略要有（见 §7）。

**推荐 B**：它与既有配对/握手组合得最自然，无证书负担，且**可测**（同一向量两端一致）。

---

## 4. 设计（方案 B）

1. **能力协商**：`IBClientHello` / `IBSessionReply` 各加一个字段
   `transport: String?`（`nil` = 旧端 = 明文；`"aead-v1"` = 支持）。
   加字段必须**向后兼容**（`#[serde(default, skip_serializing_if=Option::is_none)]`，规则 2）。
2. **密钥派生**：`k = HKDF(HMAC-SHA256, ikm = token, salt = initiatorNonce || responderNonce,
   info = "remotecrab-transport-v1")`。**不复用 token 本身**（token 已用于 PeerAuth 的 HMAC，
   跨用途复用是坏味道——派生一把独立的传输密钥）。
3. **帧格式**：保持 `[4B len][1B kind]` 前缀（receiver 靠 kind 路由，不必先解密）；
   其后为 `[12B nonce][ciphertext ‖ 16B tag]`。kind 作为 AAD。
4. **方向与计数**：发起方/应答方各一条单调计数器（0,1,2…），12 字节 nonce = 计数器。
   **绝不重用**。收端维护一个滑动窗口拒绝重复/过旧的 nonce。
5. **旧端降级**：任一端没有 `transport=aead-v1` → **明文**，但新端必须**显眼标注
   「未加密」**（复用现有 `sessionAuthenticated` 那枚 `exclamationmark.shield` 的做法），
   而不是假装安全。**建议不拒绝**（拒绝会在升级窗口把旧端直接砖掉——与现有 legacy 兜底同精神）。
6. **握手本身**（clientHello/sessionReply/配对）不加密——它们本来就是公开的协商；
   `IBPhoneHello`/nonce 同理。真正的机密从**第一帧流数据**开始。

---

## 5. 影响面（读代码后逐条列）

- `RemoteCrabCore/Networking/IBWire.swift`：帧的 encode/decode/seal/open（解析器要能处理
  加密后的 payload 长度）。
- `RemoteCrabCore/Networking/IBEvents.swift`：`IBClientHello`/`IBSessionReply` 加字段。
- `RemoteCrabCore/Networking/PeerAuth.swift`：派生传输密钥的 HKDF（与现有 HMAC 同源）。
- `RemoteCrabCapture/CaptureEngine.swift`（iOS）+ `RemoteCrabReceiver/ReceiverSession.swift`（Mac）：
  连接建立后切换读写路径为 seal/open。
- `windows/crates/rc-protocol` + `rc-net`（Rust）：同款 AEAD + 同款握手字段。
- 测试：跨语言 AEAD 向量、重放窗口、明文降级、握手字段兼容。

---

## 6. 验证

- **单元**：AEAD round-trip；**同一组向量 Swift 与 Rust 断言出相同密文**（这是跨端正确性的硬证据）。
- **集成**：两端真 TCP；被动嗅探到的字节**不含**已知明文标记
  （发一个 `RemoteCrab-e2e-OK` 剪贴板，抓包断言线上不含该串）。
- **重放**：重放一帧必须被拒。
- **真机**：手机 ↔ Mac 正常流；D2/D3 的延迟/帧率**不退化**。
- **Windows**：Rust 端互通（真机打勾）。

---

## 7. 未决问题（请你定）

1. **旧端**：明文放行 + 显眼标注（推荐），还是直接拒绝？
2. **密钥轮换**：每会话一把（推荐，简单），还是定期重派生？
3. **握手期**：`IBPhoneHello`/nonce 明文可接受？（我认为可，它们无敏感内容。）

---

## 8. 工作量与边界

- **大工程**，跨 Swift + Rust 两端。**必须**先有跨语言向量测试再落地，否则两端对不上会
  极难查。诚实边界：我能在本端写 Swift + 测 Swift；**Rust 端只能对着我的向量写 + 交叉编译
  检查，真机互通要 Windows session 验**（见 `docs/HANDOFF-WINDOWS-*.md` 的交接约定）。
