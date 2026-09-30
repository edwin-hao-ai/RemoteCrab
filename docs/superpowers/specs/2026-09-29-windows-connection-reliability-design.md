# Windows ↔ iPhone 连接可靠性 + 多电脑切换 — 设计文档

日期：2026-09-29
状态：设计已批准，待实现
范围：Windows 接收端 + Mac 接收端 + iOS 端（**不动协议，不动版本号，不出新 build**）

---

## 1. 问题

用户在 Windows 电脑上测试 RemoteCrab 时，iPhone 经常连不上；或者反过来，
Windows 扫描不到 iPhone。同时用户有 Mac 和 Windows 两台电脑，需要随时切换
iPhone 的连接。

原始要求：**先找根因，不做修改**。本文档是根因调查的结论 + 修复设计。

---

## 2. 根因（9 个，按严重度）

全部是代码级证据，标注 `文件:行号`。

### R1 · Windows 接收端从不保存配对 token 🔴

`windows/crates/rc-net/src/supervisor.rs:510-514` 拿到 iPhone 签发的 token 后直接丢弃：

```rust
// The token the iPhone issued (when accepted) is persisted by the
// supervisor via the `FeatureState`/`Metadata` path; ...
let _accepted_token = match reply.result {
    SessionReplyResult::Accepted => reply.token,   // ← 扔了
```

**这条注释是假的**：`FeatureStateSnapshot` / `StreamMetadata` 里没有 token 字段，
代码里也不存在这条路径。`TokenStore::set_token`（`token.rs:68`）在生产代码里
**零调用**，只有 `#[cfg(test)]` 里被测过。

后果链：
1. `supervisor.rs:389` 的 `tokens.token_for(...)` 永远是 `None` → `clientHello.token` 永远为空
2. iOS `PairingPolicy.decide`（`MacPairingStore.swift:85-90`）要求 `hello.token == match.token` 才 `.accept`
3. → **每一次连接、每一次重连，iPhone 都要弹「允许这台电脑」卡片**，哪怕已批准过
4. Windows 在 `AwaitingApproval` 等 120 秒（`supervisor.rs:523`），超时 `Lost`，3 秒后重连 → 无限循环的授权卡片

对照可用的 Mac：`ReceiverSession.swift:1184-1186` 确实存了
（`tokenStore[key] = token; saveTokens()`）。Windows 移植时漏了这一步。

**子问题**：token 的 key 是 `target.token_key()` = `target.name()`，而
`Target::Phone` 是 mDNS 实例名（`RemoteCrab — iPhone`）、`Target::Manual` 是
`iPhone (192.168.1.5)`。**同一台手机两个 key**，所以走直连（也就是 TUN 场景
唯一能走的路）永远带不上 token。Mac 在 `ReceiverSession.swift:1586`
`rekeyDirectConnection` 已经解决，Windows 没有对应实现。

### R2 · 直连兜底被一个「已修过的死锁条件」重新引入 🔴

`supervisor.rs:263` 的兜底门槛是 `discovered.is_empty()`。

Mac 修好的版本在 `ReceiverSession.swift:921`：

```swift
!self.discovered.contains(where: { self.tokenStore[$0.name] != nil })
// "A stale or unpaired Bonjour record must not suppress the direct-IP probe
//  — that was the 'iPhone stuck on 连接中' deadlock."
```

即 AGENTS.md **lesson 21(b)** 早已在 Mac 侧填掉的坑，判定条件是「没有**已发现
且已配对**的手机」。Windows 移植时用的是**修复前**的旧条件。

后果：只要 mDNS 曾解析出**任何一条记录**（哪怕地址根本连不上），直连兜底和
/24 扫描就**永久关闭**，然后每 3 秒对着死地址重试，自己把自己锁死，无恢复路径。

### R3 · TUN 代理下 /24 扫的是错的网段 🔴

`rc-discovery/src/lib.rs:121-138` 的 `local_ipv4_addresses()` 是「连一下
8.8.8.8:80 看看源地址」——拿的是**默认路由的出口网卡**。开了 Mihomo/Clash
TUN 后这个地址是隧道 fake-IP（如 `198.18.0.2`），于是 `subnet_hosts()` 扫的是
`198.18.0.1~254`，**真实 192.168.x.x 网段根本没被扫到**。

`docs/WINDOWS_HANDOFF.md:334-359`（§25）记录的就是这次 bring-up 的失败：
*"no ARP entry, no answer on 8765 anywhere in the /24, mDNS silent for 20 s"*，
结论是 Mihomo TUN 占了默认路由。

附带：`remotecrab doctor` 能识别 TUN，但**只在传 `--connect <IP>` 时**——
`doctor.rs:161` 把 `route` 硬写成 `RouteVerdict::Unknown`。裸跑 doctor 看不出隧道。

### R4 · iPhone 的 pending 槽「先到先得，后来者踢掉先到者」🔴

`CaptureEngine.swift:1277-1288` 的 `accept()` **无条件** cancel 掉已有的
`pendingConnection`。Mac 接收端每 3 秒重试（`RECONNECT_DELAY`）且持有有效
token → `decide()` 直接 `.accept`。

两台电脑同时开着时，Mac 会反复把 Windows 的握手从手机上踢掉。
**R1 修好后此问题基本自动消失**（配对过的电脑直接 `.accept`，不进 `pending`），
但对未配对电脑仍是真实缺陷。

### R5 · 切换是单向的 🔴

| 接收端 | 收到 `busy` 后 | 位置 |
|---|---|---|
| Mac | `suppressReconnect = true` + 只补一次 30 秒慢重试 | `ReceiverSession.swift:1227` |
| Windows | 每 10 秒**无限**重试 | `supervisor.rs:198-212` |

结果：Mac→Windows 能自动切过去，**切回 Mac 必须跑到 Mac 前面点 Retry**。
这是 Mac 侧代码，可在不触碰 iOS 的前提下修。

### R6 · 「让路」机制对未配对电脑是空操作 🟠

`MacPairingStore.preferred`（`MacPairingStore.swift:174-177`）返回
`paired.first(where: {$0.id == id})` —— id 不在已配对名单里就是 `nil`。

而 `CaptureEngine.setPreferredComputer`（`CaptureEngine.swift:1860-1867`，注释在
1857-1859）恰恰是为「还没配对过的电脑」设计的，写了 preference，但读出来是 nil
→ `handleHello`（`CaptureEngine.swift:1362-1363`）传给 `decide` 的 `preferred:` 也是
nil → `decide` 里那条「其他人一律回 busy」的分支（`MacPairingStore.swift:80-82`）
**永远不触发** → Mac 3 秒后拿回会话，切换静默失效。UI 上
`preferredSection(_ preferred: PairedMac)` 也因为拿不到 PairedMac 而不显示
「正在等待 XXX」。

### R7 · 状态行是唯一一行点不动的东西 🟠

托盘菜单（`tray_menu.rs:78-140`）有状态、功能开关、录像、显隐、**重新连接**、
断开、开机自启、退出。状态行是 `Row::Info`，只显示 `LOOKING` / `OFFLINE` /
`IN USE`，**不告诉用户为什么、也不告诉下一步该干什么**，甚至不告诉程序到底有没有
在尝试。

这和 Mac 端相反：Mac 的弹出面板会显示人类可读原因（AGENTS.md lesson 13），
还带「完成设置…」这种可点引导行。

注意：**「重新连接」已经存在**（`tray_menu.rs:112`，`Command::Retry` 已接上）。
缺的是「原因」和「怎么办」。

### R8 · 兜底端口写死 8765，但 iPhone 会回退到随机端口 🟡

`CaptureEngine.swift:1206-1211` 用 `try?` 绑 8765，失败就换动态端口。而
`rc-discovery/src/lib.rs:22 DEFAULT_PORT = 8765` 被 /24 扫描、last-IP 探测、
热点探测、doctor 全部使用。iPhone 落到动态端口时 mDNS 正常，但**所有兜底
路径永远找不到它**。

### R9 · `browse(...).ok()` 一次失败就永久关闭 mDNS 🟡

`supervisor.rs:52` 丢弃错误，无日志、无重试。`ServiceDaemon::new()` 失败一次，
该进程生命周期内 mDNS 彻底死掉且一声不吭。

### R10 · 掉线之后永不重连（复检时发现）🔴

`start_connection` 把 `target` **move 进了 spawn 的任务**，而 supervisor 自己的
`target` 变量**只有 `FallbackTick` 那条分支会赋值**。所以
`Action::Reconnect` 的 `if let Some(t) = target.clone()` 永远是 `None` —— 什么都不做。

后果：手动连接或 mDNS 发现的手机，**任何一次链路抖动（WiFi 切一下、iPhone 锁屏、
笔记本换 AP）都会永久断掉**，而 R2 的门槛又恰好挡住了兜底救援。表现是「连上过一次，
然后就再也连不上了」。

修法：把赋值放进 `start_connection` 本身，让「忘记记录自己在连谁」从结构上不可能再犯。
测试：`link_loss_reconnects_on_its_own`（握手后立刻挂断，断言 30 秒内至少两次连接）。

### R11 · 整个托盘菜单点不动（复检时发现，最严重）🔴

`750790a`（2026-09-29 22:25「feat(windows): bring the tray menu up to the Mac
popover's standard」）把手写的 `append_item(menu, flags, Ids::CAMERA, ...)` 换成了共享
模型 `append_item(menu, flags, row.id as usize, ...)`。

- 菜单行携带的 id 来自 `tray_menu::ids` = **100/101/102…**
- 点击分发仍然匹配局部 `struct Ids` = **1/2/3…**

两套编号**零重叠** ⇒ `match id { … _ => None }` 每次都落空 ⇒ **托盘能弹出、渲染完全
正常，但点任何一项都没有任何反应**。

这解释了「在 Windows 上测试特别痛苦」：主交互界面当时是死的。它能编译、模型测试
（只检查 `menu_rows()` 的布局）全绿 —— 又一次「测试只覆盖了模型、没覆盖接线」。

修法 + 两道防线：
1. 删掉第二套表，id 统一为 `usize`；
2. `tray_menu::known_ids()` + `all_rows_have_a_known_id()`：每个可点行的 id 必须在
   点击处理器的已知集合里；
3. `tray.rs` 的 `debug_assert!`：开发版遇到未知 id 直接报错，而不是静默丢弃。

### 未确认的假设（不算根因，需实测）

**Windows 防火墙无规则。** `grep -rni "firewall|advfirewall|New-NetFirewallRule"
windows/ .github/ scripts/` 只命中 `doctor.rs` 的注释——没有任何规则、清单或
安装步骤。mDNS 收包需要入站 UDP 5353，无例外规则的 exe 在 Windows 上默认被拦
入站。但这**只能解释「扫描不到」，解释不了「连不上」**（Windows 接收端是主动
拨出，出站默认放行），且 `WINDOWS_HANDOFF.md:342-343` 明确写了
"Inbound is unaffected"。所以这是叠加因素，不是主因。B 方案落地后若仍有问题再查。

### 为什么这些 bug 能活下来（测试套件的结构性盲区）

`rc-net/tests/session.rs` **已经有 9 个端到端测试**（假 iPhone + 真实
`rc-net::Session` + 真实 TCP），覆盖 accepted / pending→approved→streaming /
busy 重试 / 握手超时 / ping / featureControl / 断开。质量不差。

但它们有一个**共同的结构性盲区**，正好是 R1 和 R2 藏身的地方：

| 盲区 | 具体表现 | 漏掉了什么 |
|---|---|---|
| **只做一次连接** | 每个测试 `connect_manual` 一次就断言到某个 `State` 为止 | R1 只在**第二次**连接才显形（第一次本来就没有 token） |
| **持久化从未被触及** | `test_config()` 写死 `token_path: None` | token 库纯内存；而且本来就没人调 `set_token`，所以在不在都测不出来 |
| **只断言 `State`，不看手机收到了什么** | 从不消费 `FakeIphone.hellos` 做跨连接对比 | 「第二次的 `clientHello` 有没有带 token」这个断言根本不存在 |
| **从不构造 mDNS 记录** | 一律走 `connect_manual` | R2 的触发条件（`discovered` 非空压制兜底）无法复现 |

一句话：**这套测试验证的是「一次连接的状态机」，而 R1/R2 是「跨连接/跨重启」的
bug。** 修好之后，测试套件必须补上「第二次连接」这个维度，否则同类问题还会再犯。

另外 `cargo test --workspace` 在 macOS 上**编译不过**（`vcam_probe` example 是
Windows-only），CI 在 Windows 跑所以是绿的——也就是说这套 Mac 侧测试在 macOS
开发机上**默认跑不起来**。

---

## 3. 向下兼容约束（硬性验收标准）

**用户明确要求：任何改动都必须保证向下兼容。**

### 3.1 两个静默数据丢失陷阱（必须处理）

| 陷阱 | 位置 | 若不处理的后果 |
|---|---|---|
| `SeenComputer` 加字段**没有** `#[serde(default)]` | `MacPairingStore.swift:242-249`（解析失败 `return []`） | 每个老用户的**已见电脑历史被静默清空** |
| `TokenStoreData` 加字段**没有** `#[serde(default)]` | `token.rs:37-42`（`.ok()` → `unwrap_or_default()`） | 每个老用户的**配对 token 被静默清空**，电脑又被当成陌生人 |

**规则：任何新增持久化字段必须带默认值，且必须有一个测试用「旧格式的 JSON」
证明老数据能加载且不丢字段。**

### 3.2 协议：只做增量，不改格式

- **不新增、不修改、不删除任何 frame kind。**
- `ClientHello.token` / `platform` 已经是
  `#[serde(default, skip_serializing_if = "Option::is_none")]`
  （`rc-protocol/src/events.rs:270,280`），R1 让 Windows 开始发送 `token` 属于
  **纯增量**，老 iOS build 能正确处理（Mac 一直在发）。
- `SessionReply` 同样安全（`events.rs:304,307`）。

### 3.3 交叉兼容矩阵（必须逐条推理并写进测试注释）

| 组合 | 期望行为 |
|---|---|
| 新 Windows + 旧 iOS (2026092404) | 发的 token 被正确接受；无任何回归 |
| 旧 Windows + 新 iOS | 旧 Windows 无 token → 走 `pending`，需点一次允许（R4 改动的公平规则不能把它饿死） |
| 新 Windows + 新 iOS | 全自动 |
| 旧 Mac + 新 iOS | Mac 持有 token，行为不变 |
| 新 Mac + 旧 iOS | Mac 收到 `busy` 后改为轮询重试；旧 iOS 的 owner 机制不变 |
| 老 `tokens.json` + 新 Windows | 加载不报错，pc_id / tokens 全部保留 |
| 老 seen 列表 + 新 iOS | 解码不报错，历史全部保留 |
| iOS 降级回旧 build | 新写的 UserDefaults 键被旧 build 忽略，无副作用 |

### 3.4 网络礼貌

R2 的修复会让 /24 扫描更频繁。**必须有退避**：15s → 30s → 60s（封顶），
任何一次成功发现或连接后重置。避免在空闲时每 15 秒打 254 个 SYN。

---

## 4. 修复方案

### Windows 接收端

**F1 · token 持久化 + 按真名重键**（R1）
- `ConnMsg` 新增 `Accepted { token, key }`，supervisor 收到即 `tokens.set_token()`
  ——**包括 `pending` → 批准那条路径**（`supervisor.rs:536`）。
- 在收到 `Event::Metadata` 时按 `metadata.device_name` 重键：若当前 key 持有
  token 且与 `device_name` 不同，移动并删除旧键。对应 Mac 的
  `ReceiverSession.swift:1586`。
- 兼容性：只新增行为，不改任何现有字段名/类型。

**F2 · 兜底门槛**（R2）
- **精确判据**（取代现在的 `active.is_none() && !suppress_auto && discovered.is_empty()`）：

  ```
  cheap = active.is_none() && !suppress_auto && target.is_none()
  sweep = cheap && (now - last_sweep >= backoff)
  backoff = 15s → 30s → 60s（封顶），任何一次成功发现/连接后重置为 15s
  ```
  即「只要手上没有正在处理的目标就允许兜底」，而不是「发现列表必须为空」。
  **关键配套**：任何一次来自 `Target::Phone` 的拨号失败（`ConnEndKind::Lost`）
  都必须**清掉 `target`**，否则被压制的状态永远解不开——这一条是 R2 死锁的
  真正出口。
- 便宜的探测（last-IP、热点网关）每 tick 跑（5 秒）；昂贵的 /24 扫描按上面退避。
- 判据抽成纯函数 `fallback_gate(active, suppress_auto, target, now, last_sweep, misses) -> FallbackAction`，
  `FallbackAction` = `None | ProbeCheap | Sweep`，表驱动测试。

**F3 · 学会端口**（R8）
- `TokenStoreData` 新增 `last_phone_port: Option<u16>`（**带 `#[serde(default)]`**）。
- 从 `DiscoveredPhone.port` 和实际连上的端口学习；兜底优先用学到的端口，
  没有才退回 8765。
- iOS 侧随机端口回退**本轮不动**（R8 的真正修复在 Windows 侧）。

**F4 · 别静默掐死 mDNS**（R9）
- `.ok()` 改成记日志 + 每 10 秒重建 daemon。
- 退避间隔抽成纯函数便于测试。

**B · 拨号绑物理网卡**（R3 的正面解法）
- 新模块 `rc-net/src/iface.rs`：
  - `candidates()` — Windows 上用 `GetAdaptersAddresses` 枚举，过滤 up +
    非隧道 + 有 IPv4；非 Windows 返回空。
  - `connect_bound(host, port, ifindex)` — Windows 上建 `socket2::Socket`，设
    `IP_UNICAST_IF` 为接口索引，再 `TcpSocket::from_std` + connect；
    非 Windows 走普通 connect。
  - ⚠️ **`IP_UNICAST_IF` 的字节序存疑**：Windows 文档与 Linux 行为不同（Windows
    要网络字节序，Linux 要主机序），我没有 Windows 环境可以查证。实现时把字节序
    做成一个可切换的常量 + 环境变量，**并在真机上分别试两种**，以实测为准。
    写错的后果被「失败即退回普通 connect」兜住，最坏情况是优化不生效。
  - 选网卡逻辑抽成纯函数 `pick_iface(target, ifaces)`，在 Mac 上测。
- **三条硬约束**：
  1. 任何一步失败**立刻退回普通 connect**，绝不比现状更差
  2. `REMOTECRAB_NO_IFACE_BIND=1` 关闭开关
  3. 日志写明走了哪条路
- 依赖：`socket2` + `windows`（`Win32_NetworkManagement_IpHelper` /
  `Win32_Networking_WinSock`），只挂 `cfg(windows)`。
- ⚠️ **这部分在 Mac 上无法验证**，需要用户在 Windows 上配合确认。

**A · 状态行可操作**（R7）
- 托盘「连接」区加一行 **「为什么连不上…」**，**位置固定**（不改变菜单高度，
  遵守 lesson 14 的精神）。状态正常时显示「一切正常」。
- 点击用 `MessageBoxW` 显示 `doctor::rank` 排好序的原因 + 可粘贴的修复配置。
  `rank` 已经是纯函数 + 12 个测试 + 双语。
- 新增纯函数 `status_panel_text(state, evidence) -> String` + 测试；托盘只负责渲染。
- **没有 IP 输入框。** 手输 IP 是把调试手段漏进产品里。

### Mac 接收端

**F8 · 收到 `busy` 不再永久放弃**（R5）
- ⚠️ **推翻既有设计**：现在 `suppressReconnect = true` 是故意的，代码注释写着
  "retrying hard would just be noise"。用户已批准推翻。
- 改为每 15 秒静默重试，UI 明确显示「iPhone 正被 <X> 使用，你可以在 iPhone 上
  选择这台电脑」。
- 理由：单向门是坏体验；iPhone 会在对方断开或 10 秒看门狗超时后自动释放，
  轮询能自己拿回来。
- 降级：旧 iOS 下行为不变（owner 机制没动）。

### iOS 端

**F5 · pending 槽的公平性**（R4）
- 删掉 `accept()` 里那个**无条件 cancel**，让 `handleHello` 已有的分支去判
  （它本来就是「新来的回 busy、保留原来的」）。
- 只加一条：来的是**已配对带 token** 的、挂着的是**没配对**的，才允许顶掉。
  **顶掉时必须清干净 pending UI 状态**（否则用户会去点一张已失效的卡片）。
- 兼容性：旧 Windows（无 token）会留在 pending 而不是被踢，用户点一次允许即可。

**F6 · 让路支持未配对电脑**（R6）
- `MacPairingStore` 新增 `preferredName` 键（旧 build 忽略，无副作用）。
- `preferred` 在已配对名单里找不到时，用 `preferredName` 合成一条
  （token 为空——它会走 `pending`，本来就该要用户批准一次）。
- `PairingTests`（已有 19 个测试）扩这个矩阵。

**C · 敲门记录**
- 关键洞察：**一台连不上手机的电脑没法说话，但一台「找到了手机却被拒绝」的电脑，
  它敲门的动作本身就是证据**——`clientHello` 在做任何判定之前就到了。
- 所以 C 记录每一次敲门**和它的结果**，不需要动协议。
- `SeenComputer` 新增 `lastOutcome: AttemptOutcome`（**必须 `#[serde(default)]`**），
  复用已有的 `lastSeen`。枚举：
  `.streaming` / `.waitingApproval` / `.refusedBusy(owner)` / `.denied`。
- 选择列表每行显示状态。这样用户能区分三种情况：
  - 「X 分钟前尝试过 · 被占用」→ PC 找得到你，被拒了 → 查配对/占用
  - 在列表里但从未「尝试过」→ PC 根本没找到你 → 查网络（TUN/防火墙）
  - 完全不在列表 → 从没连过
- **不做反向通道**（接收端广播 + iOS 主动拨出）：那是先鸡还是先蛋，而且
  TUN 场景下手机同样穿不过隧道去打电脑，买不到任何东西。
  （注：`RemoteCrabReceiver` 目前也没有任何 `NWListener`，AGENTS.md V1.4 声称的
  「Mac 广播 + iPhone 浏览」在代码里并不存在。）

**F7 · 后台自动关摄像头时记下用户选择**
- `WINDOWS_HANDOFF` / lesson 22：切后台会自动关摄像头。用户在 Mac 上切走再切回来
  会发现摄像头是黑的，得手动再开。
- 复用 lesson 62 已有的 `remotecrab.ios.cameraOn` 机制：自动关闭时**也**记下
  之前的开/关意图，回前台恢复。
- 兼容性：无该键的老安装走原有默认值。

---

## 5. 测试策略（全部可在 Mac 上跑，不需要 Windows）

`rc-net/tests/session.rs` 已存在（9 个测试），下面**追加**。`FakeIphone` 已是
`rc-net` 的 dev-dependency，能绑 `127.0.0.1:0` 并交出地址；
`Session::connect_manual(host, port)` 是公开的。

**每个新测试必须跨连接或跨重启**（现有套件的盲区，见 §2）。

| 测试 | 抓哪个根因 | 初始状态 |
|---|---|---|
| `token_is_persisted_after_accepted` | R1 | 🔴 红 |
| `second_connection_sends_the_stored_token` | R1 | 🔴 红 |
| `restart_keeps_the_token`（`token_path` 指向真实临时文件） | R1 | 🔴 红 |
| `token_is_rekeyed_to_the_metadata_device_name` | R1 子问题 | 🔴 红 |
| `link_loss_reconnects_without_asking_again` | R1+R2 | 🔴 红 |
| `fallback_fires_when_a_discovered_phone_is_unreachable` | R2 | 🔴 红 |
| `sweep_backs_off_when_nothing_is_found` | 3.4 | 🔴 红 |
| `old_token_file_loads_without_losing_fields` | 3.1 | 🔴 红 |
| `learned_port_is_used_by_the_fallback` | R8 | 🔴 红 |
| `pick_iface_prefers_same_subnet_and_skips_tunnels` | R3/B | 🔴 红 |
| `mdns_failure_is_retried_not_dropped` | R9 | 🔴 红 |
| `status_panel_text_names_the_top_cause` | R7 | 🔴 红 |
| `busy_reply_shows_the_owner_and_keeps_retrying`（**已存在，守住**） | R5 | 🟢 绿 |

iOS / Core 侧：
- `PairingTests` 扩「未配对电脑的让路」矩阵
- `SeenComputer` 旧 JSON 解码测试
- R4 的公平性逻辑尽量下沉到 Core 的纯函数以便测试

**顺手修**：`cargo test --workspace` 在 macOS 编译失败（`vcam_probe` example 是
Windows-only）→ 加 `required-features`，让文档里那条命令真的能用。

### 验收

```sh
cd windows && cargo test --workspace          # 含新测试
cargo clippy --workspace --all-targets -- -D warnings
cargo check --target x86_64-pc-windows-gnu --workspace   # 交叉检查 cfg(windows) 代码
./scripts/test.sh                            # Core 测试 + 两个 app 构建
```

---

## 6. 明确不做的事

| 不做 | 理由 |
|---|---|
| 新 frame kind / 改协议 | 3.2 的兼容性要求；本轮所有修复都不需要 |
| 接收端广播 + iOS 主动拨出（反向通道） | 先鸡还是先蛋，且 TUN 场景下同样无用 |
| 提 App Review / 出新 build | 用户明确要求本轮不提交，等这轮审核完再一起发 |
| 改 iPhone 的随机端口回退 | 真正修复在 Windows 侧学会端口（R8/F3） |
| Windows 防火墙规则 | 未确认的假设；B 落地后若仍有问题再实测 |

---

## 7. 待用户在 Windows 上验证的项

B（`IP_UNICAST_IF`）在 Mac 上无法验证，需要真机确认：
- 走的是绑网卡路径还是退回普通 connect（日志会写明）
- 开着 Mihomo TUN 时能否连上手机
- `REMOTECRAB_NO_IFACE_BIND=1` 能否关掉

其余部分（token 静默重连、兜底、切换、诊断面板）都可先用 Mac 上的自动化测试证明。
