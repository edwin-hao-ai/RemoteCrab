# Windows 交接（2026-10-11）：传输加密 F1

> 读者：Windows session。本文件是 **Mac→Windows** 的交接，遵循仓库的交接约定
> （见 AGENTS.md「跨端交接」）：带数字、不写"已实现"除非那行代码真的在、写完 fetch+提交。
>
> 一句话：**iOS/Mac 两端的传输加密已经做完并真机验收；Rust 侧的加密原语已实现并与
> Swift 逐字节对齐；Windows 侧要把它接进 `rc-net`/`rc-app` 的连接路径，然后真机联调。**

---

## 1. 背景（为什么做）

之前那条 TCP 连接上的一切（H.264/音频/触摸/按键/**剪贴板**/文件）都是**明文**。
`peer_auth` 只解决"你是谁"，不加密内容。产品卖点是"纯本地"，但"本地"≠"共享 WiFi 上保密"。

设计：`docs/superpowers/specs/2026-10-11-transport-encryption-design.md`（方案 B：
应用层 ChaCha20-Poly1305，密钥从配对 token + 握手双方 nonce 用 HKDF 派生；旧端回退明文）。

## 2. 已完成（Mac/Swift，已真机验收）

- **Core**：`RemoteCrabCore/Networking/TransportCipher.swift`（HKDF-SHA256 +
  ChaCha20-Poly1305 + 防重放窗口）、`IBWire.seal/open`、`TransportNegotiation`。
- **两端接入**：iOS `CaptureEngine` + Mac `ReceiverSession` 在握手后派生密钥并
  seal/open；**真机 e2e 25/0**，Mac 日志实测 **`transport: sealed (aead-v1)`**。
- **Rust 原语已实现**：`windows/crates/rc-protocol/src/transport.rs`（`session_key` /
  `seal`），并有测试 **`rust_seal_matches_the_swift_vectors` 通过**——与 Swift 产出**逐字节一致**。
- **共享测试向量**：`RemoteCrabCore/Tests/RemoteCrabCoreTests/Fixtures/transport-vectors.json`
  （Swift 生成，Rust 断言；**改任何一端都必须两端都过这组向量**）。

## 3. Windows 需要做的

### 3.1 已就绪（不用重做）
- `rc-protocol::transport`（HKDF + ChaCha20-Poly1305）——**已与 Swift 对齐**。
- 测试向量文件 + `tests/transport_vectors.rs`。

### 3.2 要接的（对照 Swift 语义照抄）
1. **`rc-net` 的接收路径**：会话授予后，每帧先按 `kind` 路由，再用 opener `open` 出 payload
   （握手帧 `clientHello`/`sessionReply`/`phoneHello`/`clientProof` 始终明文；授予后才封）。
   参考 `RemoteCrabReceiver/ReceiverSession.swift` 的 `processFrames`（open 在授予后）。
2. **发送路径**：给发送器加一个可选的 `sealer`；非空时把每帧的 payload 封后再发
   （`kind` 保持明文，且作为 AEAD 的 AAD）。参考 `IBEventBroadcaster.send(kind:_:)`。
3. **广告能力**：`clientHello` 加 `transport: "aead-v1"`（字段已可选、缺省即旧端）。
4. **读对端能力**：手机的 `sessionReply` 会带 `transport` + `nonce`（accepted 回复带手机 nonce）。
5. **派生密钥**：`TransportNegotiation` 的等价物——
   `peerTransport == "aead-v1" && token != nil && clientNonce != nil && serverNonce != nil`
   → `session_key(token, clientNonce.utf8, serverNonce.utf8)`；否则**明文**。
   （`clientNonce` = 你发出的 `clientHello.nonce`；`serverNonce` = 手机 `sessionReply.nonce`。）
6. **两条路径都要接**：**拨号路径**（Mac 拨手机）**和手机主动路径**（手机敲 8766 / 拨入）
   ——⚠️ **我们就是漏了"手机主动路径有它自己的 sessionReply 处理"这条，一度两端一个加密一个
   明文、帧全解不开（e2e 11/14）**。Windows 有对称的"拨入"路径，务必两条都接。

### 3.3 关键坑（我们踩过的）
- **两端必须用同一对 nonce**：`clientHello.nonce`（你发）‖ `sessionReply.nonce`（手机发），
  按这个顺序拼 salt。用别的顺序 → 两端密钥不同 → 全部解不开。
- **旧端回退**：对端没带 `transport` → 明文（不要拒绝，别在升级窗口砖掉旧手机）。
- **不要自造 nonce 顺序/编码**：nonce 用其 **UTF-8 字节**（和 Swift 一致）。

## 4. 验收（Windows 真机）

1. `cargo test -p rc-protocol`（含 `rust_seal_matches_the_swift_vectors`）+ clippy 干净。
2. **真机**：Windows 接收端 ↔ iPhone；日志出现"sealed"；视频/音频/触摸/键盘/文件/剪贴板全通。
3. **抓包**：发一个已知剪贴板字符串，抓包断言**线上不含该明文**（Mac 侧的对应断言在
   `TransportWireTests.testThePlaintextMarkerNeverAppearsOnTheWire`）。
4. 旧端：用不带 `transport` 的旧 iOS 构建连一次 → 明文可用（不崩）。

## 5. 规矩（照旧）

- **交接里的"已实现"是最强的断言**——写之前回去确认那行代码真的在；不确定就写"准备做"。
- 数字优先：「跑通了吗」要带命令 + 输出。
- 写完 `git fetch` 看 Mac 侧有没有同题进展，再提交（只 stage 自己的文件）。

---

## 6. 归属

- 加密原语/向量：**已完成**（`rc-protocol::transport`，`121b84a`）。
- `rc-net`/`rc-app` 接入 + 真机：**Windows session**。
- 若发现 Swift 与 Rust 语义分歧：以 **共享向量** 为准，两端都改到过为止。
