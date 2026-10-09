# HANDOFF — Windows：手机主动连接（`IBPhoneHello` / 0x27）

> **From:** Mac session，2026-10-08
> **To:** Windows session（Windows 真机 + 工具链）
> **规范：** [`docs/superpowers/specs/2026-10-08-phone-initiated-connection-v2-design.md`](superpowers/specs/2026-10-08-phone-initiated-connection-v2-design.md) §3 / §4 / §5 / §6 / §8.3
> **基线：** `main` @ `dbe5c0c`（本端已 `git fetch`）
> **为什么本端只写文档：** 接收端运行时改动只能在 Windows 上编译/验证；按仓库跨端规矩
> （「只有对端才能测的，本端只写带数字的交接」），本端**不改任何 `windows/` 运行时代码**。

---

## 1. 这个功能是什么（一段话）

手机从「被动服务端」改成「主动发起者」：点「选择电脑」里的一台已配对电脑，手机直接
**TCP 连到该接收端的 presence / knock 端口 `8766`**（就是它已经广播出去的那个口，
`rc-discovery::KNOCK_PORT`，`windows/crates/rc-discovery/src/lib.rs:45`），并在
**连接后的第一帧**发 `IBPhoneHello { phoneId, phoneName, targetPcId, appVersion, nonce, capabilities }`。
接收端读到第一帧后：若 `targetPcId == 本机 pc_id`，就**以服务端身份运行现有握手**
（发 `clientHello`，`token = nil`，读 `sessionReply`，跑 `peer_auth` 挑战）；
若没有帧 / 非 hello，就保持今天的「敲门」语义（回拨 `connect_manual(peer.ip(), DEFAULT_PORT)`）。

**关键：协议角色不反转。** 反转的只是 **TCP socket 的发起方**。`clientHello` 仍由电脑发出
（Mac 侧 `ReceiverSession.beginServerSession`，`RemoteCrabReceiver/ReceiverSession.swift:2310`），
手机仍回 `sessionReply`。因为手机才是仲裁者、token 由手机签发，`clientHello` 由「持有身份与
token 的电脑」发出是最小改动的正确抽象（spec §3）。

---

## 2. 四项 Windows 待办（§8.3），逐条带锚点

### 2.1 `spawn_knock_listener` 读第一帧分辨 hello / knock

**现状锚点**（`windows/crates/rc-app/src/main.rs`，整段 `#[cfg(windows)]`）：

- `:433-434` `const KNOCK_MIN_INTERVAL: Duration = Duration::from_secs(2);`
- `:452` `fn spawn_knock_listener(session: rc_net::Session)`
- `:455` `TcpListener::bind(("0.0.0.0", rc_discovery::KNOCK_PORT))`
- `:477` `listener.accept()`
- **`:486` `drop(stream);` —— 这就是「不读任何东西」的地方**
- `:488` 守卫一：`matches!(*state.borrow(), rc_net::State::Streaming { .. })` → 直接忽略
- `:492` 守卫二：`last_acted.elapsed() < KNOCK_MIN_INTERVAL` → 静默忽略
- `:508` `session.connect_manual(&host, rc_net::DEFAULT_PORT);`（敲门回拨）

**要改成：** 不要 `drop`，而是**在 ~500 ms 预算内用增量解析器读第一帧**
（复用 `rc_protocol::Parser`，`windows/crates/rc-protocol/src/wire.rs:420`），按
**与 Mac 完全一致的三态分类**决定走向。Mac 的纯函数是
`InboundHelloClassifier.classify`（`RemoteCrabCore/Sources/RemoteCrabCore/Networking/InboundHelloClassifier.swift:54-63`），
返回值 `data` / `knock` / `foreign` / `busy`：

| 读到的第一帧 | 动作 |
|---|---|
| `Kind::PhoneHello` 且 `targetPcId == pc_id` 且无冲突 owner | 交给会话做**服务端握手**（见 2.2） |
| `Kind::PhoneHello` 但 `targetPcId != pc_id` | 礼貌关闭（`foreign`） |
| `Kind::PhoneHello` 且本机正被**另一台手机**服务 | 回**裸** `sessionReply{result: busy, ownerName}` 后关闭（`busy`）——不能顶掉在线会话 |
| 无帧 / EOF / 超时 / 非 `PhoneHello` | **敲门**：`connect_manual(peer.ip(), DEFAULT_PORT)`（今天的路径，`:508` 原样保留） |

**两个守卫必须为数据路径重新设计**（spec §8.3(1)）：

- **`KNOCK_MIN_INTERVAL`（2 s）不能限流掉真握手。** 它的原意是「敲门去重，防止 LAN 上任
  何东西把我们打进回拨循环（对用户自己的会话的 DoS）」。真 `PhoneHello` 是数据路径，不是
  敲门；把它按 2 s 丢掉会让「点一下就连」在快速连点时随机失败。建议：**按帧种类分流守卫**
  —— 握手帧只受「同时只允许一条会话」约束，不看 `KNOCK_MIN_INTERVAL`；只有 `knock`
  （无帧）才吃 2 s 限流。
- **streaming 时重复 hello 要回 `busy`，不要静默忽略。** 现在的 `:488-491` 是
  `ignored`（只打日志）。原文案的假设是「敲门的那台手机通常就是正在用的那台」——对敲门成立，
  对握手不成立：另一台已配对电脑拨进来时，手机端在等 `clientHello`，若我们什么都不发，
  手机会走到它自己的看门狗超时。回 `busy` 才是诚实且能自我解释的（与 Mac `sendBusyAndClose` 对齐，
  `RemoteCrabReceiver/ReceiverSession.swift:2269`）。**注意 owner 身份**：手机侧拨入的
  owner 有 `phoneId`；如果 owner 只知名字（旧出站路径），Mac 的做法是**一律回 `busy`**
  （identity 无法证明时，误判 `busy` 远比顶掉在线会话便宜，见 `InboundHelloClassifier.swift:51-53` 注释 / `:61` 的那条 guard）。

**另外：** 目前 `accept` 后立刻 `drop(stream)`，所以那个 `TcpStream` 必须**交给 `rc-net`**
（一个 `Command`，见 2.2），不能在 listener 里自己写。

### 2.2 `rc-net` 新增「被拨入」服务端握手入口

**现状：没有任何服务端握手入口。** 现有 `run_connection`
（`windows/crates/rc-net/src/supervisor.rs:803`）是**客户端**路径，且**起手就发
`clientHello`**（`:842-864`，`token` 取自 store）；它需要一个 `Target` 并自己拨号
（`:816-825`）。

**好消息：所有 wire 零件都已存在，可直接复用：**

- `encode_client_hello` / `decode_session_reply` / `encode_client_proof`：
  `windows/crates/rc-protocol/src/wire.rs:290-307`
- `answer_challenge(token, pc_id, client_nonce, reply, write_half)`：
  `windows/crates/rc-net/src/supervisor.rs:772` —— **语义完全适用**：手机发
  `sessionReply{pending, nonce: c_s, mac: serverMac(token, pc_id, r_s, c_s)}`，
  这里 `client_nonce = r_s`（我们 `clientHello` 里发的），`reply.nonce = c_s`，
  与函数现有参数一一对应；它已会回 `ClientProof`。
- 帧分发 `dispatch_frame`（`windows/crates/rc-net/src/dispatch.rs`）。

**要做的是新增一个入口**（建议 `Session::accept_inbound(stream, phone_hello)` +
内部 `Command::AcceptInbound` + `run_server_session(...)`，让 supervisor 继续做 store 的
唯一写者——理由同 `Command::ForgetPhone` 的注释，`windows/crates/rc-net/src/lib.rs:330-336`）：

1. **按 `phoneId` 查 token**（**id 优先，miss 则按 `phoneName` 回退并 backfill**）。语义
   逐字照搬 Mac 的 `PeerTokenIndex.token(phoneId:name:)`
   （`RemoteCrabCore/Sources/RemoteCrabCore/Networking/PeerTokenIndex.swift:36-41`）。
   Windows 现存 store 只有 **按名字** 的 `tokens: HashMap<String, String>`
   （`windows/crates/rc-net/src/token.rs:20-22`，读写 `token_for`/`set_token` `:93-102`）。
2. **发 `ClientHello { token: None, nonce: r_s, ... }`** —— 这一条是**真正的新行为**：
   现有路径永远出示 store 里的 token，服务端路径必须 **token = nil**（手机拨入时不带秘密，
   只靠 HMAC 证明，spec §9）。
3. 读 `sessionReply` → 调 `answer_challenge`（`:772`）→ 发 `ClientProof`。
4. 被接受后：**标记该 `phoneId` 的 `supportsPhoneInitiated`**、把 token 按 `phoneId`
   持久化（同时镜像名字表，供旧出站路径继续用）、状态转 `State::Streaming`
   （复用 `ConnMsg::Accepted { host, port, token, key }`，`windows/crates/rc-net/src/lib.rs:349-357`，
   `key` 用 `phoneId`）。

**存储改动（必须 additive，规则 2 / lesson 117 的反面）：**
`TokenStoreData`（`token.rs:12-45`）新增两个 `#[serde(default)]` 字段：
- `tokens_by_phone_id: HashMap<String, String>`
- `phone_initiated: Vec<String>`（或 HashSet 序列化）
- 可能还要 `phone_id_by_name: HashMap<String, String>`（2.3 需要；对应 spec §5.3 的 `phoneIdByName`）

**绝不要重命名 / 改类型现有字段**，并补一条「旧 `tokens.json` 原样加载、什么都没丢」的测试
（现有范式见 `token.rs:407-439 an_older_token_file_loads_without_losing_anything`）。
`TokenStore::load` 会吞掉解码错误退回 `default()`（`token.rs:57-61`），少一个 `#[serde(default)]`
就会**静默清空所有人的配对 token**。

### 2.3 停掉对 `supportsPhoneInitiated` 手机的自动重连

**现状自动重连锚点（`supervisor.rs`）：**
- `:393-395` `ConnEndKind::Lost | HandshakeTimeout` → `reconnect_at = now + RECONNECT_DELAY`（3 s，`lib.rs:47`）
- `:397-406` `Busy` → `now + STANDBY_RETRY_DELAY`（60 s，`lib.rs:57`）
- `:428-434` `Off` → 同样 60 s
- `:585 maybe_autoconnect`，选择逻辑在 `:603-607`（先按名字挑已配对，否则第一台）

**要改成：** 对**已被标记 `supportsPhoneInitiated`** 的手机**不再自动拨**
（它自己会拨，结构上消除「抢」）。**保留**：
- 手动 `Retry`（`Command::Retry`，`supervisor.rs:261`）
- 敲门一次性回拨（`Command::ConnectManual`，`:236`，`connect_bound` 已 pin）
- **对未标记的手机（旧手机 / 尚未连接）保持今天的自动拨号** —— 苹果此刻正在审核的旧手机
  **不主动拨**，一旦接收端也停拨，「旧手机 + 新接收端」就永远连不上（spec §6 硬要求）。

**一个必须补的映射：** 标记是按 `phoneId` 存的，而发现事件给的是 `DiscoveredPhone`
（`rc-discovery/src/lib.rs:286-294`，只有 `id` = mDNS fullname、`name`、`host`、`port`，
**没有 phoneId**）。所以 `maybe_autoconnect` 需要一张 `name → phoneId` 才能判断「这台发现到的
手机该不该自动拨」。Mac 的做法 `isPhoneInitiated(name:)`
（`RemoteCrabReceiver/ReceiverSession.swift:1151-1157`）+ 名字由
`bonjourServiceName(deviceName:)` 派生（`:2328`）。`phone_id_by_name`（2.2）就是为此。

### 2.4 ⚠️ VPN 缺口（v2 新引入）：accepted socket 的回程没被 pin

**现状：只 pin 了出站。** `057e1c6` 新增
`force_unicast_interface`（`windows/crates/rc-discovery/src/lib.rs:492`，私有、`#[cfg(windows)]`），
**只被 `connect_bound`（`:453`）调用**；`connect_bound` 又被两处出站调用方使用：
出站拨号 `supervisor.rs:737 dial()`，以及探测 `rc_discovery::probe_tcp`
（`rc-discovery/src/lib.rs:436`，内部 `:438` 调 `connect_bound`）。**两处都是出站**
（`probe_tcp` 用来探测候选手机地址），所以「回程未被 pin」的结论不变。commit 里量到的现象：TUN（Mihomo Party / Clash）
`auto-route` 下 `Find-NetRoute` 把 LAN 目标解析成**隧道** —— `192.168.31.50` →
`Mihomo 198.18.0.1`，只有默认网关还在 `WLAN`。

**缺口：** 手机现在**拨进来**。listener 绑 `0.0.0.0:8766`（`rc-app/src/main.rs:455`）能
`accept`，但 **accepted socket 的 egress / 回程没有被 pin**。TUN `auto-route` 下，回给手机的
`clientHello` 仍可能进隧道，表现成 **「listener 看到了连接、握手仍然失败」** —— 从外面看
和「手机没发 hello」几乎一样。

**要改成（二选一，推荐前者）：**
- **在 accepted socket 上设 `IP_UNICAST_IF`**。用一个 `pub` 包装（如
  `rc_discovery::pin_unicast_interface(stream: &TcpStream, ifindex: u32)`），内部仍是
  `IPPROTO_IP` / `IP_UNICAST_IF`、IfIndex **网络字节序**（与 `:492-505` 完全一致）。
  接口选择：从 `stream.local_addr()` 的目的 IP 反查
  `pick_lan_adapter(&adapters(), phone_ip)`（`:130`）——注意是对**对端**手机 IP 选适配器，
  和出站同一套。
- **或按接收接口绑定**：listener 对每个本机地址各绑一份，accept 后按本地接口 pin。

**为什么这必须真机验：** `setsockopt` 对 accepted socket 是否被 Windows 采纳、以及
TUN 在 `auto-route` / `gvisor` / `system` 不同栈下回程是否真的绕开隧道，本端（macOS）无法测。

---

## 3. 已做 vs 未做（务必如实，勿把运行时当已做）

### ✅ 本 session 已做，且**已在 macOS 上跑过测试**（`cargo test -p rc-protocol phone_hello`
→ `wire_keys.rs` 4 passed + `wire` 单元 2 passed）

**仅 wire 契约**（不涉及任何接收端运行时），commit **`dbe5c0c`**：

| 项 | 锚点 |
|---|---|
| `Kind::PhoneHello = 0x27` | `windows/crates/rc-protocol/src/wire.rs:118` |
| `Kind::from_u8(0x27) → PhoneHello` | `wire.rs:190` |
| 未知 kind → `Kind::Unknown`（**不再落 `Video`**，lesson 152） | `wire.rs:119-127`、`:149-193` |
| `encode_phone_hello` / `decode_phone_hello` | `wire.rs:308-313` |
| `PhoneHello` serde 结构（camelCase，`nonce`/`capabilities` 可选） | `events.rs:417-444` |
| 键名 / raw值 / 解析器回归测试 | `windows/crates/rc-protocol/tests/wire_keys.rs`（`phone_hello_*`）、`wire.rs:648-678` |

### ✅ 已实现（本机编译 / 交叉检查通过；**Windows 真机未验**）

实现 commit **`cff9eb6`**（`feat(windows): serve phone-initiated connections on
the presence port`）。**这一节是运行时改动，`cff9eb6` 只在本机（macOS host）编译并跑过
host 测试 + `x86_64-pc-windows-gnu` 交叉检查 —— 没有在 Windows 上运行过一行。**
验收仍必须按第 4 节在真机重跑。

| 待办 | 落地 | 关键锚点 |
|---|---|---|
| **2.1** 监听口读首帧分流 | `spawn_knock_listener` 在 500 ms 预算内读首帧（`read_first_inbound_frame`），按 `rc_net::inbound::classify_inbound` 三态分流；真 hello → `session.accept_inbound`，别机 → 礼貌关闭，占用中 → 裸 `sessionReply{busy}`（`send_busy_and_close`）；无帧/非 hello → 原敲门回拨。**`KNOCK_MIN_INTERVAL` 现在只限敲门**，握手帧不受它限流 | `windows/crates/rc-app/src/main.rs:428-625` |
| **2.2** 被拨入服务端握手 | `Session::accept_inbound` + `Command::AcceptInbound` + `start_inbound` + `run_server_session`；与出站共用 `run_session`（解析/`answer_challenge` 一处）。`clientHello.token = nil`；token 按 `phoneId` 查（name 回退 + backfill）；接受后按 id 持久化 + 镜像名字表 + 标记 `phoneInitiated` | `rc-net/src/lib.rs:296-306,374-387`、`supervisor.rs:748-836,1013-1104` |
| **2.2st** 存储（additive） | `TokenStoreData` 新增 `tokens_by_phone_id` / `phone_initiated` / `phone_id_by_name`，全部 `#[serde(default)]`；`token_for_phone_id` id 优先、name 回退并 backfill；`forget` 同步清 id 半边。旧文件加载测试已扩展 | `rc-net/src/token.rs:45-73,129-215`；测试 `token.rs::an_older_token_file_loads_without_losing_anything` / `a_name_keyed_token_backfills_into_the_id_table` |
| **2.3** 去自动重连（按能力） | `maybe_autoconnect` 跳过 `is_phone_initiated_name` 为真的发现项；未标记（旧手机）保持原自动拨。保留手动 Retry、敲门一次性回拨 | `rc-net/src/supervisor.rs:651-669` |
| **2.4** accepted socket 回程 pin | 新增 `pub rc_discovery::pin_unicast_interface(stream, ifindex)`（`IP_UNICAST_IF`，网络字节序，与出站同一 `setsockopt`）；listener accept 后按对端 IP 选物理网卡并 pin，被拒则打印一行 | `rc-discovery/src/lib.rs:503-527`；调用 `rc-app/src/main.rs:556-563` |

**本机已验证**（命令与结果见本节末）：

- `cargo test --workspace --lib` → **326 passed / 0 failed**（含新增 `inbound::tests::*` 6 条、token 迁移回归）。
- `cargo build --workspace` → 通过（host 全 target 编译，覆盖 bin）。
- `cargo check --workspace --all-targets --target x86_64-pc-windows-gnu` → 通过；`cargo clippy --workspace --all-targets --target x86_64-pc-windows-gnu -- -D warnings` → 0 warning。
- ⚠️ 逐字的 `cargo test --workspace`（不带 `--lib`）在本机**红**，原因是既有的
  `rc-vcam-source` 示例 `dump_ring` 是 Windows-only（`scripts/test.sh` 早有注释），
  **与本改动无关**；仓库的 host 门禁本就是 `--lib` + `cargo build --workspace`。

**未验 / 边界（如实）**：Windows 真机运行（第 4 节全部）；`IP_UNICAST_IF` 施加在
accepted socket 上是否被 Windows 采纳、TUN 各栈下回程是否真绕开隧道；服务器播入
实时行为（`rc-phone-sim --dial` 尚未实现，见 4.2）。**未做**：本机无 Windows 运行时，
这些只能由 Windows session 补。

> 依据 lesson 117 / 148：交接里写「已实现」是最强的断言（对端无法核验），所以上面
> 每一项都附了可 `git show cff9eb6` 复核的文件/行锚点，并明确区分「本机编译通过」与
> 「Windows 真机已验」——后者没有发生。

---

## 4. 验收清单（可复现命令 + 预期日志）

> 运行前：接收端在 Windows 真机 `/Applications` 等价目录 / `target\release` 下运行
> （不要用 `/tmp` 之类的临时路径启动，见 AGENTS 的扩展注册注意事项）。
> 下面的 marker 里有几个是**建议新增**的（当前不存在），实现时请按建议字符串加 os_log / println，
> 好让 e2e 与人工都能断言；标 **(新)** 的即为此类。

### 4.0 新协议不污染视频（wire 契约）

```powershell
cargo test -p rc-protocol phone_hello
cargo test -p rc-protocol unknown_kind_is_not_video
```
预期：全绿；`0x27` 不会落 `Kind::Video`（否则 JSON 会被喂给 OpenH264）。

### 4.1 knock 监听口能读首帧并分流

```powershell
# 用 PowerShell 当「假手机」：连 8766，发一帧 PhoneHello，读回第一帧
$pcId = (Get-Content "$env:APPDATA\RemoteCrab\tokens.json" | ConvertFrom-Json).pc_id
$json = '{"phoneId":"e2e-phone","phoneName":"E2E Phone","targetPcId":"' + $pcId + '","appVersion":"test","capabilities":["phoneInitiated","peerAuth"]}'
$payload = [Text.Encoding]::UTF8.GetBytes($json)
$len = $payload.Length + 1
$frame = [byte[]]::new(4 + $len)
$frame[0] = ($len -shr 24) -band 0xFF   # 4-byte BE length
$frame[1] = ($len -shr 16) -band 0xFF
$frame[2] = ($len -shr  8) -band 0xFF
$frame[3] = ($len       ) -band 0xFF
$frame[4] = 0x27                         # kind
[Array]::Copy($payload, 0, $frame, 5, $payload.Length)
$c = New-Object Net.Sockets.TcpClient("127.0.0.1", 8766)
$s = $c.GetStream(); $s.Write($frame, 0, $frame.Length); $s.Flush()
Start-Sleep -Milliseconds 300
$buf = New-Object byte[] 4096
$n = $s.Read($buf, 0, 4096)
"first byte kind = 0x{0:X2}" -f $buf[4]   # 期望 0x0A = clientHello
$c.Close()
```

预期接收端日志：
- `[knock] <ip> phoneHello for this PC — beginning server handshake` **(新)**
- `[net] TCP connected ...` / 发出的第一帧是 `clientHello`（`:878` 已有 `[net] TCP connected to …` 风格）

对照（敲门仍工作）：`$c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1',8766); $c.Close()` →
预期 `[knock] ... asked us to dial back — dialing <host> now`（`:507` 原文，保持不变）。

对照（stray / 别机）：把 `targetPcId` 改成别的 UUID → 预期 `[knock] phoneHello for a different PC — ignored` **(新)**，且**不**回拨。

### 4.2 服务端握手 + 能力协商

最省事：给 `rc-phone-sim` 加一个 `--dial <host:port> --target-pc <id>` 模式
（**这是新代码，不是现状**；现在 `rc-phone-sim` 只当监听端，见
`windows/crates/rc-phone-sim/src/main.rs:21-24`）。运行：
```powershell
cargo run -p rc-phone-sim -- --dial 127.0.0.1:8766 --target-pc $pcId
```
预期：接收端发 `clientHello{token:null}` → 假手机回 `pending`/`accepted` →
接收端跑 `answer_challenge` 并回 `ClientProof{mac}` →
接收端状态进 `Streaming{authenticated:true}`；`%APPDATA%\RemoteCrab\tokens.json` 出现
`tokens_by_phone_id["e2e-phone"]` 与 `phone_initiated:["e2e-phone"]`。

### 4.3 去自动重连（能力协商）

```
1. 上述握手成功一次（该手机被标记）。
2. 断开该链路。预期：接收端【不再】自动拨它（tray 停在 OFFLINE / LOOKING，无 3 s 重拨）。
3. 手动点 tray 的 Connect：仍能连（保留手动）。
4. 用一台【未标记】的手机（旧手机，不发 PhoneHello）跑 presence，
   预期：接收端照旧自动拨它（自动拨号对旧手机零降级）。
```
断言点：`supportsPhoneInitiated` 集合里没有的 name 仍走 `maybe_autoconnect:603-607`。

### 4.4 VPN：accepted socket 回程（本端无法验，必须真机）

```
# 让 TUN 处于 auto-route（Mihomo Party / Clash / sing-box 任一）
Find-NetRoute -RemoteIPAddress <phone_ip>
```
**修复前的预期（`057e1c6` 量到的形状）**：`NextHop` / 接口指向隧道
（例：`192.168.31.50` → `Mihomo 198.18.0.1`），只有网关在 `WLAN`。
这解释「listener accept 了、握手还是失败」。

**修复后要证明的**：手机拨入时，回程**不从隧道出**。可复现判定：
1. 开着 TUN，手机拨入 → 预期握手成功、`State::Streaming`。
2. 抓 `Get-NetTCPConnection -LocalPort 8766 -State Established` 看 `LocalAddress`
   落在物理网卡 IP（不是 TUN 虚拟地址）。
3. 在 `pin_unicast_interface` 里加一行临时日志打印 IfIndex 与 `stream.local_addr()`，
   对照 `Get-NetAdapter | Select Name,ifIndex`。

**边界（写进代码注释，别当成 bug）：** `setsockopt` 对 accepted socket 是 best-effort；
若被拒，行为退化为「和 `057e1c6` 之前一样」，不比现状差。

---

## 5. 一个推迟的 Swift 小尾巴（本 session 留的）

`WindowsWireContractTests.test_the_rust_side_uses_the_same_kind_numbers`
（`RemoteCrabCore/Tests/RemoteCrabCoreTests/WindowsWireContractTests.swift:127-141`）
现在只断言 Rust 侧 `0x22` / `0x23` / `0x25`。它**应当也断言 `0x27`**
（`wire.contains("PhoneHello = 0x27")`），否则这条「契约测试」漏掉本 session 新增的那个 kind ——
正是它会漏的那类漂移。**归 Mac/iOS session**（改 Swift 测试），不属 Windows 侧。

---

## 6. 提交与推送约定

- 本文件由 Mac session 写入并**已提交**（按跨端规矩；本 session 不 push）。
- Windows 侧实现后请**先 `git fetch`**，确认没有别人已改同一处，再动手。
- 若 Windows 侧要回交，请把带数字的结果写进本文件末尾或新建
  `docs/HANDOFF-WINDOWS-*.md`，并按规矩 `git show --name-status` 复核提交只装自己的文件。
