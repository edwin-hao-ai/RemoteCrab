---
title: Mac 接收端：身份验证（与 Windows 半边对齐）
type: handoff
status: implemented 2026-10-07
last_verified: 2026-10-07
prerequisite: 先读 docs/HANDOFF-IOS-PEER-AUTH.md（协议细节 + 测试向量都在那里）
---

# Mac 接收端要做的：验证手机

> **2026-10-07：已实现。** `ReceiverSession.sendClientHello` 带 nonce +
> `peerAuth`；`answerChallenge` 验手机的 `server_mac` 并回 `clientProof`；
> 失败 → 断开且不重试（`IBLocale.Error.cannotVerifyiPhone`）；老手机无 nonce →
> 照常接受并标记未验证（菜单栏 `exclamationmark.shield.fill`）。wire 类型是共享的，
> 无需第二遍。§验证 1 的向量测试见 `RemoteCrabCore/Tests/…/PeerAuthTests.swift`。
> 仍未做：§验证 2–4 的真机验收。

## 为什么这份文档存在

Mac 接收端和 Windows 接收端是**同一个角色**（"电脑"），因此有**同一个洞**：

> 任何在手机那个端口应答 `sessionReply accepted` 的机器都被相信，
> 随后它发来的 touch / key / systemCommand / clipboardSet / fileOffer 全部执行。

也就是说，同网段任何人起一个 listener 就能操纵这台 Mac 的键盘。
2026-10-06 的 Windows 会话把 Windows 那半边做完了，Mac 这半边**没动**（改不了、也测不了 Swift）。
这份文档把 Mac 侧要做的单独列出来，免得它只出现在 iOS 文档的最后一节里没人看到。

## 协议细节不在这里

**逐字节的 MAC 定义、wire 改动、测试向量、流程分支** 全在
[`HANDOFF-IOS-PEER-AUTH.md`](HANDOFF-IOS-PEER-AUTH.md) 的 §2–§4。先读那份，这一份只说
Mac 特有的部分。

## Mac 特有的三点

### 1. wire 类型是**共享**的 —— 改一次，两端都生效

`IBClientHello` / `IBSessionReply` / `IBClientProof` 都在
`RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift`，Mac 和 iOS 共用。
所以 iOS 会话加上 `nonce` / `mac` / `capabilities` 之后，**Mac 侧自动就有了这些字段**，
不需要第二遍。

要单独做的是**流程**：Mac 接收端发 `clientHello`（它是"客户端"角色），所以它要：

1. 生成自己的 `nonce` 并放进 `clientHello`；
2. 在 `capabilities` 里声明 `peerAuth`；
3. 收到带 `nonce` + `mac` 的 `sessionReply` 时，用**存的 token** 验证手机的 MAC
   （`server_mac`，见 iOS 文档 §2）；
4. 验证通过 → 发 `clientProof { mac }`（`client_mac`）；
5. 验证**不通过** → **断开**，且不要重试 —— 那不是网络故障，是有人冒充手机。
   文案也不要套用"用户拒绝了连接"。

### 2. 不要复用 Rust 的实现，复用**向量**

Mac 侧是 Swift，`rc-protocol/src/peer_auth.rs` 用不上。但那个文件里钉死了一对
测试向量（`peer_auth::tests::the_wire_format_is_pinned_for_the_other_language`），
Swift 侧的测试断言**同一对字符串**即可。这是两端唯一能互相确认"算出的是同一串字节"
的手段 —— 没有它，两边会各自"看起来对"而互相不认，且表现为网络故障。

### 3. Mac 的 `macOS Accessibility` 授权不受影响

这次改动不碰 TCC / 辅助功能授权。但注意：**验证失败的断连**和**辅助功能没授权**
是两件完全不同的事，别共用一句文案 —— 用户会照着错的那句去改错的地方。

## 验证

1. **向量测试**先过（iOS 文档 §3 的两条字符串）。
2. **真机**：删掉 Mac 上的配对 → 重新配对一次 → 之后每次重连都不该再弹 Allow，
   且 Mac 侧不再报告"未验证"。
3. **负面**：把 Mac 存的 token 临时改掉 → 重连必须被拒且不重试。
4. **老手机兼容**：手机 App 还没更新时，`sessionReply` 不带 `nonce`/`mac`，
   Mac 必须**照常接受**（这是 Windows 侧同一个决定：拒绝老 App 等于上线当天把产品弄坏），
   但要**标记**该会话未验证 —— 别假装安全，也别让产品停摆。

## 顺带

- iOS 文档 §4 末尾讲了 `CaptureEngine.swift:1545` 的「clientHello 超时就放行」——
  那个洞比 token 更大（不需要任何凭据）。**检查 Mac 接收端有没有同款兜底**，
  有就一起修。
- Windows 侧的实现、测试与状态标记可作参考：
  `windows/crates/rc-net/src/supervisor.rs`（`answer_challenge`）、
  `windows/crates/rc-protocol/src/peer_auth.rs`。
