---
title: 手机主动连接 v2 —— 点一下就连、随点随切、三端兼容
type: design
status: draft
date: 2026-10-08
supersedes_direction: docs/superpowers/specs/2026-10-05-phone-initiated-connection-design.md (被列为 non-goal 的「敲门」过渡方案)
weakens: docs/superpowers/specs/2026-10-07-current-computer-design.md (current 门卫)
---

# 手机主动连接 v2 设计

> 读者：实现者 + 三端（iOS / Mac / Windows）。本文取代 2026-10-05 那份
> 「把手机发起列为 non-goal、用敲门过渡」的设计；并弱化 2026-10-07 的
> 「一台手机记住一台电脑（current 门卫）」模型。

---

## 1. 背景与根因

用户报：**「这台能连、那台不能连，甚至都连不上」**，以及切换慢、要重新确认。
根因（已在代码里逐条确认）：

1. **手机是被动服务端。** 数据连接永远是「电脑 → 手机」（Bonjour
   `_remotecrab._tcp`，手机监听）。「点一下连上」是用**敲门**模拟——手机拨电脑的
   8766 催它回拨。于是每次点击都依赖「目标在线 + 收到敲门 + 能拨回」，任一环断就
   没反应。这也是 VPN/跨网难做的根。
2. **`PairingPolicy.decide` 在 owner / preferred / current 三处都回 `busy`**，
   配合持久化 `current` → 只服务一台、其余被拒。`current` 失效或换 id（重装/关机）
   就把所有人锁死——「这台能连那台不能连」「都连不上」的元凶。
3. 发现走 mDNS/Bonjour，只在同一链路。
4. 身份可能不稳（Windows 旧版重装换 `pc_id` → 当新设备 → 重新配对），破坏「配对一次」。

**约束（商业产品）**：三端都要稳；线上已发布的 Mac / 手机 / Windows 继续可用；
苹果此刻正在审核旧版手机 app，**向后兼容是硬要求**。

---

## 2. 目标 / 非目标

### 目标
- 第一次配对一次；之后在「选择电脑」里点任意一台**已配对**电脑，~1s 内连上并可控制，
  **不再有任何确认 / 配对 / 等待**。
- 在 A/B/…/N 台电脑之间**随点随切**，Mac 与 Windows 一视同仁。
- 手机是唯一仲裁者；**从结构上消除「抢」**。
- 三端同一套语义；新手机 ↔ 旧接收端、旧手机 ↔ 新接收端**全部可用**。
- 列表在 N 台（含同名、离线）下都正确、可切、**可逐行删除**。

### 非目标（本迭代不做）
- 中继 / rendezvous 服务器（只在 §12 写清可行路径，不实现）。
- 传输加密（TLS）：身份验证 ≠ 加密，剪贴板/文件在同一网段仍可被抓包。
- 一台手机同时服务多台电脑（仍单会话）。
- Linux 接收端。

---

## 3. 连接模型：角色反转的意义

选择 **组合 X**：复用敲门端口 8766，不新增端口；手机拨号时**第一帧发
`IBPhoneHello`** 报身份。相比「新增独立数据端口」，X 的体验更好，因为：

1. **不新增端口** → Windows 不依赖新的防火墙放行。组合 Y 一旦哪台机器漏配放行，
   就正好复现「这台能连那台不能连」——我们正在修的 bug。X 没有这个失败面。
2. **首帧即身份** → 接收端零歧义：有 `IBPhoneHello` 就是「连我」，没有就是旧手机的
   「敲门」。消除「手机一边拨号、电脑一边回拨」的重复连接竞态。
3. **旧手机敲门路径原样保留** → 迁移期不 brick。

### 角色
| | 谁 | 职责 |
|---|---|---|
| **发起者** | 手机 | 点谁拨谁；启动/回前台自动拨「最近一台」；点离线电脑 = 待它上线就拨 |
| **仲裁者** | 手机 | 决定接受哪台（`PairingPolicy`）；`busy`/`off`/`denied` 仍由手机发 |
| **监听者** | 接收端 | 只监听 + 被拨时握手；**不再自动重连**（见 §6 能力协商例外）；保留手动 Retry + 敲门一次性回拨 |

### 握手语义不变（关键）
**电脑仍发 `clientHello`、手机仍回 `sessionReply`；peer-auth 的方向与 label 完全不变。**
反转的只是 **TCP socket 的发起方**，不是协议角色。原因：手机是仲裁者，配对审批、
token 签发都在手机侧；`clientHello` 由「持有身份与 token 的电脑」发出，是最小改动的
正确抽象（10-05 spec 的原意）。

---

## 4. 握手时序

### 4.1 首次配对（手机拨号）
```
Phone   --TCP connect-->  Receiver:8766
Phone   --IBPhoneHello{phoneId, phoneName, targetPcId, nonce, capabilities}-->
Receiver  targetPcId == my id?  -> 按 phoneId 查凭证（miss 则按 name 回退并 backfill）
         标记该 phone supportsPhoneInitiated = true
Receiver --IBClientHello{name, id, token: nil, nonce: r_s, capabilities:[...]}-->
Phone   decide(hello, paired, userInitiated=true) -> 未配对 -> pending
Phone   --IBSessionReply{result: pending}-->            (首配无 nonce/mac，TOFU 窗口)
        [手机弹审批卡]
User 点 Allow
Phone   --IBSessionReply{result: accepted, token: fresh}-->
Receiver 存 token（按 phoneId），streaming
```

### 4.2 重连（已配对、手机拨号、peer-auth）
```
Phone   --TCP connect + IBPhoneHello-->  Receiver
Receiver --IBClientHello{token: nil, nonce: r_s}-->
Phone   paired 命中 + hello.nonce 存在 -> 挑战：
Phone   --IBSessionReply{result: pending, nonce: c_s, mac: serverMac(token, pcId, r_s, c_s)}-->
Receiver  answerChallenge（用 phoneId 查到的 token 验 serverMac）通过
Receiver --IBClientProof{mac: clientMac(token, pcId, r_s, c_s)}-->
Phone   验 clientProof 通过
Phone   --IBSessionReply{result: accepted}-->   streaming
```
> 与现状的唯一差别：**这条连接是手机拨出的**，且电脑的 `clientHello.token` 为
> `nil`（不再出示秘密）。其余 `PeerAuth`/`IBSessionReply` 逻辑一字不改。

### 4.3 接收端拒绝（手机拨号但接收端不能服务）
接收端若正服务另一台手机，或用户已在本机断开：回一个**裸**
`IBSessionReply{result: busy, ownerName}`（或 `off`）后关闭。
**iOS 拨出连接的接收循环必须能接受「首帧即 `sessionReply`」**（现状只等
`clientHello`）——否则会当成 timeout。

### 4.4 旧接收端（无数据监听）
手机拨 8766 并发 hello；旧接收端把它当敲门：**不读、直接 cancel、回拨手机**。
手机发现「hello 已发但对方只回拨、无 clientHello」→ 放弃这次出站，转而
**走现有入站路径**接受回拨（`clientHello` → `decide` → `accept`）。
即：旧接收端兼容 = **自动回退到今天的入站模型**，无新代码路径。

---

## 5. 协议改动（全部增量、可降级）

### 5.1 新 kind `0x27` `IBPhoneHello`
```jsonc
{
  "phoneId":    "<uuid>",        // 必填。稳定，iOS 持久化键 remotecrab.ios.phoneId
  "phoneName":  "Edwin's iPhone",
  "targetPcId": "<uuid>",        // 手机这次要连的电脑 id（= 它拨的端点）
  "appVersion": "1.1",
  "nonce":      "<base64>",      // 可选，32B；用于去重/未来扩展，不参与鉴权
  "capabilities": ["phoneInitiated", "peerAuth", "latencyProbe"]
}
```
- Swift `struct IBPhoneHello: Codable, Sendable, Equatable`；`capabilities` 用
  `[String]` 解码再 `compactMap`（前向兼容，同 `IBClientHello` 的做法）。
- Rust：`rc-protocol` 登记 `PhoneHello = 0x27` + serde 结构。
- **未知 kind 必须丢弃**：Swift 已落 `.unknown`；Rust 必须确认不是
  `_ => Video`（lesson 152）——`0x27` 一旦被当 H.264 NAL 会污染预览。

### 5.2 不改的东西（护住旧端）
- `IBClientHello` / `IBSessionReply` / `IBClientProof` 的 wire 值全部不动。
- `SessionReplyResult` 不新增值（复用 `busy`/`off`/`denied`）。
- `IBServiceType` / TXT 不变：`_remotecrab-computer._tcp`、TXT `port` 仍 = 监听口
  `8766`（它现在既是敲门口、也是数据入口）。
- `IBStreamMetadata`、音视频帧、事件帧全部不动。

### 5.3 token 存储迁移（name → phoneId）
- **iOS 侧**：`PairedMac.id` 一直是电脑 id，不动。
- **接收端侧**：现有 `tokenStore` 按**手机名**存（`remotecrab.mac.tokens`），
  legacy 出站发现路径（按 Bonjour 实例名匹配）依赖它，**保持不动**。
  新增一张 **按 phoneId 的 token 表**，供手机拨入路径使用：
  - 手机拨入时先查 id 表；miss 则按 `phoneName` 查旧表（迁移），命中即 backfill 到 id 表。
  - 同步维护 `phoneIdByName`，供「发现后是否该自动重连」判断（见 §7）。
- 全部**新增键**，旧数据不动 → 满足规则 2（新增字段必须 additive）。

---

## 6. 兼容矩阵（能力协商，硬要求）

苹果正在审旧手机（被动服务端）。**不能一刀切地让接收端停止自动重连**——否则
「旧手机 + 新接收端」将永远连不上（旧手机不拨、新接收端也不拨）。

**改法**：接收端按「这台手机会不会自己拨」决定是否保留自动重连。
- 接收端给每台手机记持久标记 `supportsPhoneInitiated`（键 `remotecrab.mac.phoneInitiated`，
  值为 phoneId 集合）。
- 收到过该手机的 `IBPhoneHello` → true → **永不自动拨它**（它自己会拨，结构上无抢）。
- 从未收到过（旧手机 / 尚未连接）→ 保持**原有自动拨号**行为不变。

| 组合 | 行为 |
|---|---|
| 旧手机 ↔ 旧接收端 | 完全不变 |
| 旧手机 + 新接收端 | 保留原自动拨号（能力协商），**零降级** |
| 新手机 + 旧接收端 | 手机回退「敲门 + 等回拨」（§4.4） |
| 新手机 + 新接收端 | 手机拨号快路径，接收端不拨 |
| 新接收端收到旧手机敲门（无 hello） | 照旧一次性回拨（`connect_manual(source IP)`） |

**唯一有界降级**：旧手机不点 + 接收端不拨 —— 不会发生，因为旧手机永远收不到
`IBPhoneHello`，标记永远 false，接收端永远自动拨它。
**混合网络下的竞态**：新手机拨 A 的同时，旧接收端 B 自动拨进来。手机用**瞬态**
`outboundTarget`（§8.1）把 B 判 `busy`——这是临时门卫，不是持久锁。

---

## 7. 数据模型：current 退役 / 删除

### 7.1 `current` → `lastComputer`（弱化，不删除存储）
- **存储键不变**（`...currentId` / `...currentName`），避免清空用户数据（规则 2）。
- **语义改变**：只表示「最近一次成功连接的电脑」，仅用作**启动/回前台的自动拨号目标**；
  **不再作为 `decide` 的拒绝依据**。
- `PairingPolicy.decide` **删除 `current` 硬 `busy` 分支**。
- 「切换时别的电脑要 busy」改由**瞬态** `outboundTarget`/`owner` 承担（§8.1）。

### 7.2 取消按名合并
- `MacPairingStore.pruned` **只按 id 去重 + TTL（30 天）**，不再按显示名合并。
  理由：稳定 id 上线后（Mac `remotecrab.mac.id`、Windows `MachineGuid`），按名合并
  的收益消失，代价却变成「两台同名真机被并成一行、无法切换」。
- 历史遗留的同机多行：靠 30 天 TTL + 新增的逐行删除清理。
- 保留 `noteSeen` 的 id 去重与 `seenLimit`。

### 7.3 逐行删除（列表里真的消失）
`forget(id)` 现有实现已清 `paired + seen + preferred + disconnected + current`；
本迭代补：
- 若 `ownerMac?.id == id` → **先断开**；
- 清 `outboundTarget` / `lastComputer`（若命中）；
- 清 `CaptureEngine` 里该 id 的图标/缩略图缓存（`PeerIdentity` 已负责 app/window 列表）；
- UI 二次确认（避免误删已配对设备）。

**不变量**：删除后该电脑
1. 不在 picker 任何分区；
2. 手机不再自动拨它（`lastComputer` 已清）；
3. 若它（旧接收端）敲门，手机 `decide` → `pending`（非 paired）→ **需重新审批**，
   不再自动接受。

### 7.4 接收端对称的「忘记此手机」
- Mac `Preferences → Paired iPhones → Forget`、Windows 对应入口保留/补齐。
- `forgetPhone` 除删 token 外，**同时删 `supportsPhoneInitiated` 标记**，使该手机
  回到「会被自动拨」的初始态（下次若仍是新手机，会立刻重新 dial 并重新标记）。
- 手机忘记电脑无需通知电脑：下次手机无 paired 记录 → pending → 重新配对 →
  新 token 覆盖旧 token，**自愈**。

---

## 8. 各端改动

### 8.1 iOS（`RemoteCrabCapture`）
- **新帧**：`IBEventBroadcaster.send(IBPhoneHello)`；`IBWire` 加 `decodePhoneHello`。
- **稳定 phoneId**：持久化键 `remotecrab.ios.phoneId`（首次生成 UUID）。
- **出站拨号** `CaptureEngine.connect(toComputer:)`：
  1. 清该目标的 `disconnected`；
  2. 设 `outboundTarget = computer`（瞬态，用于 §6 竞态门卫）；
  3. `NWConnection` 到 presence 解析出的端点（Bonjour endpoint / 候选地址）；
  4. `.ready` 后发 `IBPhoneHello`，启动握手看门狗（~4s 等 `clientHello`）；
  5. 收到 `clientHello` → 现有 `handleHello` 路径（`userInitiated=true`）；
     首帧是 `sessionReply{busy/off}` → 如实显示「电脑正忙/已断开」；
     连接在 `clientHello` 前关闭 → **回退入站模型**（§4.4）。
- **picker 行点击** = `connect(toComputer:)`（不再只是 `setPreferredComputer` + knock）。
  点**离线**电脑 = arm「待它上线就拨」（复用 `preferred`，由 presence 触发）。
- **启动/回前台**：`lastComputer` 存在则自动拨它；同时保留监听（旧接收端拨入）。
- **`decide`** 去掉 `current` 分支；新增 `userInitiated: Bool = false`，为 true 时
  跳过 `owner`/`preferred` 的 `busy` 分支（用户已明确选择目标）。入站（旧接收端）
  路径参数不变。
- **多候选地址**：`ComputerAddress`（Bonjour `.local` + 最近成功 IP）按序试；
  本迭代**不实现中继**，只把地址抽象与重试做出来。
- **删除 UI**：`ComputerPickerView` 每行 swipe/长按 → 确认对话框 →
  `engine.forgetComputer(id:)`。

### 8.2 Mac（`RemoteCrabReceiver`）
- **`PresenceAdvertiser` 入站连接交给会话**：现在 `onKnock` 只触发 `retryNow`。
  改为把接受的 `NWConnection` 交给一个新的会话入口 `handleInboundData(_:)`：
  1. 用增量解析器在 ~500ms 内读**第一帧**；
  2. `kind == .phoneHello` 且 `targetPcId == macId` → 设 `currentTokenKey = phoneId`，
     标记 `supportsPhoneInitiated`，执行**服务端握手**（`sendClientHello`，token=nil，
     然后复用 `handleSessionReply` / `answerChallenge`）；
  3. `phoneHello` 但 `targetPcId != macId` → 礼貌关闭；
  4. 无帧 / EOF → **敲门** → 现有 `retryNow()`（`connect_manual(sourceIP)`，经
     `connect_bound` 钉物理网卡）；
  5. 正服务另一台手机 → 回裸 `sessionReply{busy}` 后关闭。
- **移除自动重连（对支持手机发起的手机）**：`handleDiscovered` 不再无条件
  `connect(to:)`；`scheduleReconnect` / `startFallbackLoop` 不再自动。保留：
  - 手动 `Connect`；
  - 敲门一次性回拨；
  - 对 `supportsPhoneInitiated == false` 的手机**保持原自动拨号**（§6）。
- **等待态文案**：从「正在寻找 iPhone」改为说清动作（「请用手机上的
  RemoteCrab 连接本机」），中英双语。
- token：新增 id 表 + `phoneIdByName`（§5.3）。
- `kIBCameraDevice` 等无关模块不动。

### 8.3 Windows（交接，本端只写带数字文档）
1. **监听口读首帧**：`rc-app/src/main.rs:452 spawn_knock_listener` 现在
   `drop(stream)` 不读任何东西。改成读第一帧：`PhoneHello` → 交给会话做服务端握手；
   无帧 → 敲门 `connect_manual(source IP)`。
   - 现有两个守卫要**为数据路径重设计**：真握手不能被 `KNOCK_MIN_INTERVAL` 限流丢掉；
     `streaming` 时的重复 hello 要回 `busy` 而不是忽略。
2. **服务端握手**：`rc-net` 新增「被拨入」入口（发 `clientHello`、读 `sessionReply`、
   跑 `peer_auth`），token 按 phoneId 查（迁移同 §5.3）；`supportsPhoneInitiated` 集合。
3. **去自动重连（仅对 supportsPhoneInitiated 的手机）**：`supervisor` 的自动拨号对这类
   手机停掉；保留手动 + 敲门一次性回拨（`connect_bound` 已有）。
4. **⚠️ 新增、且是 v2 引入的 VPN 缺口**：`057e1c6` 只把**出站**拨号钉到物理网卡
   （`IP_UNICAST_IF`）。手机**拨入**时，Windows 的 listener 绑 `0.0.0.0:8766` 能
   accept，但 **accepted socket 的回程**未被覆盖——TUN `auto-route` 下回给手机的包
   仍可能进隧道，表现成「listener 看到了连接、握手仍失败」。需在 accepted socket 上
   也设 `IP_UNICAST_IF`（或按接收接口绑定），并真机验（用 `Find-NetRoute` + 假手机）。
5. **协议登记**：`rc-protocol` 加 `PhoneHello = 0x27`；确认未知 kind 丢弃（lesson 152）。

---

## 9. 安全模型

- **peer-auth 双向 HMAC 挑战-应答完全保留**，方向/标签/label 一字不改
  （手机算 `RemoteCrab/v1/server`，电脑算 `RemoteCrab/v1/client`）。
- **token 仍不出示**：phone-dialed 连接上电脑的 `clientHello.token = nil`，只靠 MAC 证明。
- **`phoneId` 非机密**，仅作 key 选择；真正的证明是 HMAC。一个陌生人拿到 phoneId
  也伪造不了 MAC（没有 token）。
- **首配是 TOFU 窗口**（现状如此）：手机弹审批卡，用户点 Allow 才签发 token。
- **陌生人拨入**：无 token → `pending`（审批）或 `busy`（已有会话）；不能自动进入。
- **重放**：每次 `clientNonce`/`serverNonce` 都是新的，旧 MAC 无效。
- **未做**：TLS（剪贴板/文件仍明文）。明确写清，不混淆「身份已验证」与「已加密」。

---

## 10. 失败与回退

| 场景 | 行为 |
|---|---|
| 新手机 + 旧接收端 | 出站无 clientHello → 回退入站「敲门 + 等回拨」 |
| 直连失败（VPN / mDNS 被吞） | 候选地址按序重试；Windows 侧靠 `IP_UNICAST_IF`（出站）+ §8.3(4)（入站回程） |
| 链接断开 | **手机**自动重拨目标；接收端不拨（对 supportsPhoneInitiated 手机） |
| 目标离线后点了它 | arm「待上线就拨」；presence 出现即拨 |
| 接收端正忙（服务另一台手机） | 裸 `sessionReply{busy}`；手机如实显示 |
| 手机彻底拨不到新接收端 | 接收端手动 `Retry` 兜底（本迭代不做自动安全网，记为已知边界） |
| 旧手机 + 新接收端 | 保留原自动拨号，零降级 |

---

## 11. 两件小事

### A. 相机系统扩展的文字指引 + 统一 `openExtensionSettings`
- **文案**（仅未启用时显示，中英双语，**不用截图**——系统版本/语言/内容因人而异）：
  `通用 → 登录项与扩展 → 向下滚动到「扩展」→ 相机扩展 → 打开 RemoteCrab Camera`
- **统一两份实现**：
  - `RemoteCrabReceiver/CameraExtensionCard.swift`（现用 pane 裸 URL）；
  - `RemoteCrabReceiver/SetupStatus.swift`（现把**无效**的 `?CameraExtensions` 排第一，
    而 `NSWorkspace.open` 对无效锚点也返回 true，导致后面的 fallback 永不执行）。
  统一为一个 helper：只**可靠打开「登录项与扩展」pane**，删掉臆造的锚点。
- 依据：Apple 没有受支持的深链能跳到某个具体扩展分类（开发者论坛 thread 765970）；
  lesson 159（换签名会注销扩展 + 开关在「登录项与扩展」不在「隐私与安全性」）。

### B. N 台不串/不抢的 Core 测试（纯逻辑）
- `roster` 在 N=10 时**全部列出**（含同名不同 id、离线）。
- 只有被选中/`owner` 一台被 `accept`，其余 `busy`。
- 切换后**仅一台** owner / `lastComputer`。
- `userInitiated=true` 时目标不被 `current` 误判 busy。
- 删除后该 id 不再出现在 rows、不再被自动拨、入站走 `pending`。

---

## 12. 跨网/VPN 路径（写清，不实现中继）

- **同网段快路径**：Bonjour presence → 拨 `.local`/SRV。
- **同网段但 mDNS 被吞**（TUN / 客户端隔离）：手机存**最近成功 IP**，按候选地址直拨。
- **接收端出站**（回退/敲门回拨）：Mac 用系统路由；Windows 用 `IP_UNICAST_IF`
  （`057e1c6` 已做），并补 accepted socket 回程（§8.3(4)）。
- **用户侧兜底**：代理软件里把手机网段加直连（`IP-CIDR,192.168.x.0/24,DIRECT`）+
  fake-ip-filter；此提示已在 Windows `route::describe` 里，后续可对齐到 Mac。
- **中继 / rendezvous**：未来项。形态：接收端在公网 rendezvous 注册 `pcId → 中继地址`，
  手机查中继后经中继建立会合，再打洞；本迭代**不实现**，仅留接口位置
  （`ComputerAddress` 可扩展为 `.relay(...)`）。

---

## 13. Impact surface（AGENTS 规则 4）

| 改动 | 调用方 / 共享状态 | 影响 |
|---|---|---|
| `PairingPolicy.decide` 去 `current` 分支 + `userInitiated` | `CaptureEngine.handleHello`、`PairingTests` | 入站旧路径行为不变；出站路径绕开门卫。需新增/更新测试 |
| `MacPairingStore.pruned` 去按名合并 | `pruneStale`、picker、`PairingTests`（多条按名合并测试） | 同名真机不再并成一行；旧测试需改成断言「都保留」 |
| `PresenceAdvertiser` 交给会话 | `ReceiverSession.init`、`onKnock` | 数据入口与敲门共用 8766；`retryNow` 保留 |
| 移除接收端自动重连 | `handleDiscovered`/`scheduleReconnect`/`startFallbackLoop` | 仅对 supportsPhoneInitiated 手机；旧手机不变 |
| 新帧 `IBPhoneHello` | `IBWire.Kind`、`IBEventBroadcaster`、Rust `rc-protocol` | 两端登记；未知 kind 丢弃 |
| `forget` 补断开 + 清缓存 | `CaptureEngine.forgetPairedMac`、picker | lesson 131 的回归面（列表读 seen、Forget 只清 paired）必须再验 |
| `openExtensionSettings` 统一 | `CameraExtensionCard`、`SetupStatus` | 只影响指引，不影响扩展注册 |

---

## 14. 测试计划

### Core（纯逻辑，TDD）
- `PairingPolicy`：`userInitiated` 绕过 owner/preferred/current；`current` 分支删除后无锁死。
- `MacPairingStore.pruned`：只按 id；同名不同 id 都保留；TTL 仍生效。
- `forget`：清 paired + seen + preferred + disconnected + current + lastComputer。
- `ComputerRoster` N=10（§11B 的不变量）。
- `IBPhoneHello` round-trip + 前向兼容（缺字段）。
- token name→id 迁移：旧 blob 能读、命中 name 后 backfill id。
- `PeerAuth` 向量不变（回归）。

### 集成 / e2e
- Bonjour + TCP e2e：新接收端读 hello → 客户端握手 → 帧流动。
- `scripts/e2e-current-computer.sh` 扩展：多台已配对电脑点一下 <2s、无再确认、无 busy 锁死。
- 删除后：列表无行、不再被自动拨、入站走 pending。
- 旧接收端兼容：新手机对其走回退入站路径。
- 真机（iPhone 14 + 本机 Mac；Windows 按交接文档）。

---

## 15. 迁移与上线

- 全部**增量 + 可降级**：新帧只在手机拨出的连接出现；旧端不读 → 不崩。
- 旧手机永不发 hello → 永远 `supportsPhoneInitiated=false` → 接收端永远自动拨它。
- 首次上线：`lastComputer` 若已有旧 `current` 值即复用；否则启动时不自动拨，
  用户点一台即可。
- 旧测试（按名合并、`current` 分支）需同步更新，禁止「改断言来让测试变绿」以外的静默。
- Mac 用 Sparkle 静默更新；iOS 需过审；Windows 走其发布渠道。

---

## 16. 风险与未验

- 真机多电脑切换（iPhone 14 + Mac）——必须真机验（规则 5）。
- Windows accepted-socket 回程的 `IP_UNICAST_IF`（§8.3(4)）——本端无法验，交接并要数字。
- 旧手机零接触自动重连降级：仅「不点」时降级，手动点仍可用（§6）。
- 混合网络竞态（新手机拨 + 旧接收端拨）：靠瞬态 `outboundTarget`，需专项测试。
- 苹果审核中的旧版：新接收端对旧手机零降级是本设计的硬验收项。

---

## 17. 交付物（对应任务书）

1. 本设计文档。
2. `writing-plans` 出的实施计划（三端分步，每步 Core 测试 + 真机 e2e）。
3. device e2e：多台已配对电脑「点一下切换」<2s、无再确认、无 busy 锁死；删除后列表正确
   且不再被连；旧接收端兼容。
4. A（相机扩展指引 + 统一 `openExtensionSettings`）、B（N 台 Core 测试），含测试。
