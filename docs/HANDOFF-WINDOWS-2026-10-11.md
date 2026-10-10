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

---

## 7. Windows 回交（2026-10-11，Windows session）

> 基线 `1bee84c`。**状态：`rc-net` 接入已实现并在本机（Windows，host target）通过
> 全部测试 + clippy；真机互通与抓包仍需在真 Windows 上跑一次（见 §7.4）。**
> 与上文的区别：下文每一条都附了可 `git show` 复核的文件/行锚点。

### 7.1 已实现（`rc-net`/`rc-app` 连接路径）

| 项 | 落地 | 锚点 |
|---|---|---|
| 状态化加密原语 | `transport::Sealer`（单调计数器）与 `transport::Opener`（防重放/过期窗口 1024、seen 上限 4096），与 Swift `TransportCipher.Sealer/Opener` 一一对应；`Error{Malformed,Replay,TooOld,Auth}` | `rc-protocol/src/transport.rs` |
| 帧级 seal/open | `wire::seal_frame`（取 kind 作 AAD，kind 明文保留）与 `wire::open_frame` | `rc-protocol/src/wire.rs` |
| 握手能力字段 | `ClientHello.transport` / `SessionReply.transport`，均 `#[serde(default, skip_serializing_if="Option::is_none")]` | `rc-protocol/src/events.rs` |
| 广告能力 | `clientHello.transport = Some("aead-v1")` | `rc-net/src/supervisor.rs::run_session` |
| 派生密钥 | `reply.transport=="aead-v1" && token && reply.nonce` → `session_key(token, clientHello.nonce(UTF-8), reply.nonce(UTF-8))`；否则**明文**（永不半加密） | 同上 |
| 收：open | 授予后：流循环 + 握手缓冲队列里的帧都先 `open_frame` | 同上 |
| 发：seal | 授予后一切：`outbound_rx` 帧、ping 探针、pong 回显，统一走 `write_sealed`；握手帧（clientHello/clientProof）保持明文 | 同上 |
| 两条路径都接 | 拨号路径与手机主动路径**共用** `run_session`，一处接入覆盖两条（正是 Mac 漏过的那条） | `run_session` 被 `run_connection`/`run_server_session` 共用 |

### 7.2 测试（含可证伪）

- `transport.rs` 单测：round-trip + kind 绑 AAD、重放拒绝、过期拒绝但乱序接受、截断 malformed、首计数器为 0。
- `wire.rs` 单测：**sniffer 断言**（`RemoteCrab-e2e-OK` 明文不出现在密文里）+ kind 明文保留的 round-trip。
- `wire_keys.rs`：`transport` 字段 additive（旧 JSON 无该键仍解码为 `None`、`None` 不序列化、有值逐字节 round-trip）。
- `rc-net/tests/session.rs::a_sealed_session_opens_both_directions`：真 TCP 上，手机（`rc-testkit`，新增 `transport: true`）与接收端**双向**密封会话；断言 metadata（手机→接收端）到达 = 接收端会 open，且接收端的 featureControl 到达手机 = 接收端会 seal。
  - **反向验证过两次**：把接收端 `sealer` 置 None → 该测试在「featureControl 未到达」失败；把 `opener` 置 None → 在「metadata 未到达」失败。两个方向都不是空过。
- `rc-testkit` 假手机也支持密封（`FakeIphoneConfig::transport`，默认关，旧明文测试不受影响）。

### 7.3 本机验证命令与结果

```
cargo build --workspace                                # Finished（无 error）
cargo test  --workspace                                # 全部 ok，0 failed
cargo clippy --workspace --all-targets -- -D warnings  # 0 warning
```

（`x86_64-pc-windows-gnu` 交叉检查本机**未跑**——该 target 未安装；本机 host 就是
Windows，`#[cfg(windows)]` 代码已被原生编译，故不构成缺口。）

### 7.4 仍需真机（本机不可能验）

1. **真机互通**：Windows 接收端 ↔ iPhone，日志出现 `[transport] sealed (aead-v1)`（接收端 stderr），
   且视频/音频/触摸/键盘/文件/剪贴板全通。
2. **抓包**：发已知剪贴板串，抓包断言线上不含该明文（帧级断言已在 §7.2 覆盖，
   链路级抓包是另一件事）。
3. **旧端明文降级**：用不带 `transport` 的旧 iOS 构建连一次 → 明文可用、不崩。
4. **用户可见的「未加密」徽标**（spec §4.5）：**未做**。接收端在连接时会把
   `[transport] sealed` / `not sealed` 打到 stderr，但托盘/控制台**没有**常驻徽标。
   这是有意的范围控制——它是 UI 呈现决定（放哪、怎么写），且**不在本次 F1 交接的
   §3 清单里**；需要与设计一起定，故留作小尾巴，而不是自作主张加一行。

### 7.5 ⚠️ 给 Mac session 的一条代码读取发现（非本端能验）

读代码：接收端（Mac）自己的延迟探针与 pong 回显走的是**裸 `connection.send`**
（`RemoteCrabReceiver/ReceiverSession.swift:2201` 与 `:2935`），**没有经过 broadcaster
的 sealer**。而手机侧 `CaptureEngine.handleInbound` 在传输密封后会用 opener 打开
**每一帧**（`:4017`），打不开就 `continue` 丢弃。一个 8 字节的**明文** ping 会被
opener 判为 malformed 而丢掉。

**若如此**：密封会话下，接收端的 ping 探针手机收不到 → 手机不会回显 → 接收端测不到
RTT；接收端对手机探针的回显同样明文 → 手机也测不到。**watchdog 不会误断**（手机的
密封探针仍能到达并刷新 `lastPongAt`），所以这是一个静默的延迟读数失效，不影响数据面。

这条是**读代码结论，未真机验证**（本端没有 Mac/手机）。请 Mac session 用真机确认：
密封会话里两端是否还有延迟读数；若是空，则把这条 ping 路径也接进 sealer（或让手机
对 ping 回显走 broadcaster）。

