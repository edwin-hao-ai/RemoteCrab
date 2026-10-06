---
title: iOS 侧身份验证改动 —— 让手机证明自己是谁
type: handoff
status: current
last_verified: 2026-10-06
code_baseline: (待提交)
windows_side: 已实现并测试（rc-protocol::peer_auth + rc-net 握手）
---

# iOS 侧要做的：对端身份验证

## 为什么

在这之前，**任何**在手机上那个端口应答 `sessionReply accepted` 的机器都被当成手机，
随后它发来的 `touch` / `key` / `systemCommand` / `clipboardSet` / `fileOffer` 全部执行。
也就是说：同一个 WiFi 上任何人起一个 listener，就能操纵这台电脑的键盘。

原设计的防线是 pairing token。但 token 是**被出示**的 —— 接收端每次都在 `clientHello` 里
明文把它发出去，手机拿它做比较。**交出去的秘密不是证明，是徽章，而同网段谁都能复制徽章。**

新设计：token 不再被出示，而是变成**挑战-应答的密钥**。双方各出一个随机数，各算一个
HMAC，互相验证。任何能让人冒充其中一端的字节都不再上线；重放旧 MAC 也会因为随机数变了而失败。

**这不做加密。** 剪贴板内容和文件内容在同网段仍可被抓包看到 —— 那是另一个问题（TLS），
不要把它和"身份已验证"混为一谈。

## Windows 侧已经做完的部分（`branch: main`）

- `rc-protocol/src/peer_auth.rs`：MAC 构造 + 常量时间比较 + 10 个单测。
- `rc-protocol`：`ClientHello.nonce`、`SessionReply.{nonce,mac,capabilities}`、
  新帧 `ClientProof`（kind `0x26`）。
- `rc-net`：握手时发挑战、验手机、回 `clientProof`；验证失败 → 新结束态
  `ConnEndKind::Impersonated`（不重试，且不套用 "denied" 的文案）。
- 会话状态带 `authenticated` 标记，状态行在未验证时显示「（未验证身份）」
  —— 老 App 仍然连得上，但**会被如实标注**，而不是假装安全。
- 三个端到端测试（对端是 `rc-testkit` 的假手机，真实 TCP）：
  证明成功的、不能证明的、拿着错 token 冒充的。

## iOS 要改的东西

### 1. `IBWire` / `IBEvents`

```swift
public struct IBClientHello: Codable, Sendable, Equatable {
    // ... 现有字段不变 ...
    /// base64 的 32 字节随机数。老 Mac 不发，所以必须 decodeIfPresent。
    public let nonce: String?
}
```
```swift
public struct IBSessionReply: Codable, Sendable, Equatable {
    public let result: IBSessionReplyResult
    public let ownerName: String?
    public let token: String?
    /// 手机这一侧的随机数（base64）。
    public let nonce: String?
    /// HMAC-SHA256，见下面的字节定义。
    public let mac: String?
    /// 手机声明自己会什么。用 [String] 解码再 compactMap，理由同
    /// `IBClientHello.capabilities`：新接收端可能声明没听过的能力。
    public let capabilities: [String]?
}
```
```swift
/// 接收端 → iPhone，kind `0x26`。接收端对挑战的应答。
public struct IBClientProof: Codable, Sendable, Equatable {
    public let mac: String
}
```

`IBWire` 加 `case clientProof = 0x26` 与 `decodeClientProof`。**注意**：Swift 侧未知 kind
必须落到 `.unknown` 并丢弃，绝不能落成 `.video`（发送端那个 Rust 解析器正是这样设计的，
见 `Kind::Unknown` 的注释）。

### 2. MAC 的字节定义（逐字节）

```
msg = label || 0x00 || pc_id || 0x00 || client_nonce || 0x00 || server_nonce
mac = base64(HMAC-SHA256(key = token_utf8, message = msg))
```

| 名字 | 取值 |
|---|---|
| `label` | 手机算的用 ASCII `RemoteCrab/v1/server`；接收端算的用 `RemoteCrab/v1/client` |
| `pc_id` | 收到的 `clientHello.id` |
| `client_nonce` | 收到的 `clientHello.nonce` |
| `server_nonce` | 手机自己生成本次 `sessionReply.nonce` 的那个值 |
| `key` | 这台电脑的 pairing token（你存的那个字符串的 UTF-8 字节） |

分隔符是 **NUL（`0x00`）**，`pc_id` 是 UUID、两个 nonce 是 base64，都不含 NUL，所以不会歧义。
没有分隔符的话 `("a","bc")` 和 `("ab","c")` 会算出同一个 MAC。

**两个 label 必须区分**：否则手机可以把自己收到的 MAC 原样弹回去，并被相信。

### 3. 测试向量（必须先过这一关）

固定输入：

```
token        = "pin-token"
pc_id        = "pin-pc"
client_nonce = "pin-c"
server_nonce = "pin-s"
```

期望输出：

```
server_mac = "mk6oqPyEKo9XCtvvvYQhTx1jDlC62M2JOi974PubYRA="
client_mac = "8DT4HKeN9V5qqo+lrkRYhCTXeFVfpqcQLY0CBFj3WFg="
```

用 Swift 算出这两个字符串之前，不要动 `CaptureEngine`。Rust 侧这两个值被
`peer_auth::tests::the_wire_format_is_pinned_for_the_other_language` 钉死，
**如果它们变了，这份文档和 Swift 测试必须同一个改动里一起改**。

### 4. `CaptureEngine.handleHello` 的流程

```
收到 clientHello
  ├─ 按 id 查 token
  │    ├─ 有 token，且 hello.nonce 不为 nil：
  │    │     server_nonce = random
  │    │     mac = server_mac(...)            ← 上面那套字节
  │    │     回 sessionReply { pending, nonce: server_nonce, mac, capabilities:["peerAuth"] }
  │    │     等一个 clientProof 帧（超时 ~5s）
  │    │       ├─ 收到且 client_mac 匹配  → 回 sessionReply { accepted }（不带 token，已有配对）
  │    │       └─ 不匹配 / 超时           → 回 sessionReply { denied }
  │    ├─ 有 token，但 hello.nonce 为 nil（老接收端）：
  │    │     保持现状（按 token 直接 accepted），并在日志里标注该会话未经身份验证
  │    └─ 没有 token（首次配对）：
  │          保持现状：pending → 人类点 Allow → accepted { token }
  │          （这一段的明文是 TOFU 窗口，绕不过去；改的是它之外的每一次重连）
  └─ ...
```

**顺带修掉一个洞**（`CaptureEngine.swift:1545` 附近）：

```swift
Self.log.info("clientHello timeout → admitting legacy Mac")
self.sendSessionReply(IBSessionReply(result: .accepted), on: conn)
```

这段的意思是「等不到 clientHello 就直接放行」。它比 token 那个洞更大：**完全不需要
token**，连上这个端口就够。新版接收端总会发 clientHello，所以这条路径今天只对"非
RemoteCrab 的连接"触发 —— 而那恰恰是唯一该被拒绝的东西。建议改成超时即 `denied`。

### 5. Mac 接收端

Mac 接收端（`RemoteCrabReceiver`，macOS 角色）**同样**是"电脑"一侧，有和 Windows 一样的
洞。上面的 Rust 实现可以直接搬（或通过 `rc-protocol` 的等价逻辑），但本次没有动它 ——
Windows 会话改不了也测不了 Swift/macOS。请在同一轮里一并处理，否则 Mac 侧仍然是敞开的。

## 验证要求

按仓库规矩，这个改动**不能只靠编译通过**：

1. **向量测试**先过（第 3 节的两条字符串）。
2. **真机**：删除手机上的配对 → 重新配对一次 → 之后每次重连都应**不再弹 Allow**，
   且 Windows 状态行**不显示**「（未验证身份）」。
3. **负面**：临时把 Windows 侧的 token 文件改掉（`%APPDATA%\RemoteCrab\tokens.json`）→
   重连应被拒绝，Windows 状态显示「无法验证 iPhone」，且**不**重试。
4. **老接收端兼容**：在没发 `nonce` 的旧接收端上连，手机仍应正常接受（走第 4 节
   的 `hello.nonce == nil` 分支）。

## 这一轮没做的

- **加密**（TLS）。剪贴板和文件在同网段仍可读。
- **Mac 接收端的同一改动**。
- 手机侧对 `IBClientProof` 之外任何新帧的处理（目前不需要）。
