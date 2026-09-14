# 多设备管理：Mac 配对记忆（Multi-Mac Pairing）设计

Date: 2026-09-12 · Status: approved by user

## 问题

RemoteCrab 的 iPhone 端是 Bonjour 服务端，Mac 端是客户端。当前行为：

- iPhone `NWListener` 的 `newConnectionHandler` → `accept()` **无条件踢掉已有连接、接受最新一台**
- Mac `ReceiverSession` 发现后**自动连 `discovered.first`**，掉线后每 3 秒重连

同一局域网有多台 Mac 时：每台 Mac 都看到同一个 iPhone、都自动连接，
iPhone 只保留最后一个 —— 结果互相抢占、连接抖动（flapping），
且没有"哪台 Mac 在使用"的概念。

## 目标

一台 iPhone 明确地只服务一台被授权的 Mac，其他 Mac 优雅退让：

1. 首次连接在 iPhone 上弹窗授权（TOFU + 配对令牌）
2. 授权过的 Mac 按稳定 ID 记住，之后免弹窗自动接入
3. 已被占用时，其他 Mac 收到 `busy` 并**停止 3 秒重连风暴**，显示原因，可手动重试
4. iPhone 可查看/重命名/移除已配对的 Mac，可主动断开当前 Mac

## 不做（YAGNI）

- 加密握手 / 证书轮换（TOFU + token 足够家用/办公局域网）
- 跨网段 / 中继
- Mac 主动广播自己（iPhone 侧选择 Mac 列表）—— 维持"Mac 浏览、iPhone 服务"
- 多 iPhone 同时服务的负载均衡

## 身份

- **Mac**：`remotecrab.mac.id`（`UUID()` 持久化于 UserDefaults）+ `remotecrab.mac.name`
  （`Host.current().localizedName`，回退 `SCDynamicStoreCopyComputerName`）
- **iPhone**：已配对列表 `[PairedMac]`（Codable，UserDefaults）：
  `{ id, name, pairedAt, token }`
- **配对令牌**：iPhone 在首次批准时生成 `UUID().uuidString`，随 `sessionReply`
  下发；Mac 持久化 `token`（按 iPhone 的 Bonjour 实例名或稳定的 iPhone id 索引）。
  之后 `clientHello` 带上 token，iPhone 校验，防止局域网里冒充已配对 ID。

## Wire 协议（新增 2 个 kind）

| Kind | Code | 方向 | Payload |
|---|---|---|---|
| clientHello | `0x0A` | Mac → iPhone | UTF-8 JSON `IBClientHello {name, id, token?, appVersion}` |
| sessionReply | `0x0B` | iPhone → Mac | UTF-8 JSON `IBSessionReply {result, ownerName?, token?}` |

`result ∈ accepted | pending | busy | denied`。

握手时序：

```
Mac                                    iPhone
 │  TCP connect (Bonjour)                │
 │ ── clientHello ─────────────────────► │  等 hello（超时 3s）
 │ ◄──────────── sessionReply ─────────  │  按策略回一个 result
 │                                       │
 │  accepted:                            │
 │ ◄──────────── metadata / SPS / PPS ── │  成为 owner
 │ ◄──── featureState / video / audio ── │
 │ ── featureControl / ping ───────────► │  仅 owner 生效
 │                                       │
 │  pending:                             │
 │ ◄──────────── sessionReply(pending) ── │  iPhone 弹窗授权
 │   （用户 Allow → 补发 accepted+token） │
 │                                       │
 │  busy / denied:                       │
 │ ◄──────────── sessionReply(busy) ───── │  关闭连接
```

兼容：若 3 秒内收不到 `clientHello`（旧版 Mac），按 legacy 处理 ——
首次到来自动放行（不写配对表），保证升级期不砖。

## iPhone 状态机（CaptureEngine）

状态：`ownerMac: PairedMac?`、`pendingHello: IBClientHello?`、
`pendingConnection: NWConnection?`、`pendingTimeout: Task?`

`accept(connection:)`：
1. 存入 `pendingConnection`，开始收包（只等 hello）
2. 超时 3s 未收到 hello → legacy 放行
3. 收到 hello → `PairingPolicy.decide(hello, paired, owner)`：
   - `.busy(ownerName)` → 发 `sessionReply(busy)`，关闭
   - `.accept` → 发 `accepted` + 已有 token，`becomeOwner`
   - `.pending` → 发 `pending`，`pendingHello = hello`（UI 弹窗）

`becomeOwner(hello)`：写配对表（新配对则生成 token）、设 `ownerMac`、
建 broadcaster、发 metadata + SPS/PPS、发 featureState。
`approvePending()` / `denyPending()` 供 UI 调用。
断开（`.failed`/`.cancelled`）→ 清 `ownerMac`/`pending*`。
`handleInbound` 的 `.featureControl` 仅在 owner 已确立且非 pending 时应用。

## Mac 状态机（ReceiverSession）

- `.ready` → 发 `clientHello`，`state = .handshaking`，**不**发 metadata 等待
- 收到 `sessionReply`：
  - `accepted` → 持久化 token，`state = .streaming`，启动 ping
  - `pending` → `state = .awaitingApproval`，不重试
  - `busy(ownerName)` → `state = .error("正被 <owner> 占用")`，**停止 3s 重连**，
    改为 30s 低频重试 + 手动「重试」
  - `denied` → `state = .error("被拒绝")`，只手动重试
- 其他（video/audio/touch/...）在 `accepted` 之前一律忽略

## UI

- **iOS**：
  - 首页浮层「允许 <Mac 名称> 连接？」+ 允许/拒绝（pending 时）
  - 设置 →「已配对的 Mac」列表：重命名 / 移除
  - 已连接时显示当前 Mac 名称 + 「断开」
- **Mac**：
  - 状态 pill 增加"等待授权 / 正被占用 / 被拒绝"
  - 菜单栏 popover 顶部显示原因 + 「重试」按钮
  - 不需要自己的配对列表（客户端只存 token）

## 测试

- `IBWireTests`：`clientHello` / `sessionReply` round-trip（含 token 有无）
- `PairingTests`：
  - 策略纯函数：未配对→pending、已配对+token 对→accept、
    token 错→pending、有 owner 且不同 id→busy、owner 重连→accept
  - `MacPairingStore`：pair 生成 token、verify 正确/错误、forget、rename、持久化（独立 UserDefaults suite）
- `EventPipelineEndToEndTests`：握手帧走 TCP → 解析 → 决策
- 真机：Mac A 配对占用，Mac B 显示"正被占用"且不刷屏

## 风险

- **协议新增**：两端必须同版本；legacy 超时回退覆盖旧 Mac
- **CaptureEngine 重构面大**：`accept`/`handleConnectionState`/`handleInbound`
  都要改；小步提交、`./scripts/test.sh` gate
- **并行 session**：`.ai-handoff/STATUS.md` 登记领地后再动 Mac 文件
