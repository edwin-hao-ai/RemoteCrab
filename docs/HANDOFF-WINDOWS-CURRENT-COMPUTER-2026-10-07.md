---
title: 交接给 Windows session —— 手机只服务一台「当前电脑」，其余的待命（standby）
type: handoff
status: current
last_verified: 2026-10-07
code_baseline: 0643695
---

# 交接：current-computer 待命行为，Windows 侧镜像

读者：**Windows session**。写的人：**Mac session**（2026-10-07）。

> **先读这一段就够开工：**
>
> 1. 手机现在**持久地服务一台「当前电脑」**（`MacPairingStore.current`）。
>    任何其它电脑拨进来，一律被 `sessionReply` 回 **`busy(owner=<当前电脑名>)`**；
>    如果用户在手机上按了断开，则回 **`off`**。
> 2. 你要改的是 **`rc-net` 在收到 `busy`/`off` 之后的动作**：从「每 10 秒 / 5 秒
>    重拨」改成**待命** —— 快速重连循环停掉，只保留一个 **~60 秒的安全网重拨**，
>    并且「敲门」（knock）一到**立即**重拨。**敲门监听器早就在调拨号路径，不用动。**
> 3. 状态行要**说清发生了什么 + 该做什么**（中英双语，和 Mac 一致）。**和 Mac 的
>    `IBLocale.Error.iphoneBusy` 逐字对齐**（这条被测试
>    `testTheBusyMessageSaysWhereTheActionLives` 钉住）：
>    *"This iPhone is being used by %@ — pick this computer in the iPhone's Choose a
>    Computer list. Retry on its own will keep failing."*（`%@` = 当前电脑名）。
> 4. **没有协议改动。** 全部在接收端。用现成的 `busy` / `off`，不加新的 wire kind。
> 5. 验收：两台接收端对一台手机 —— 非当前那台**只拨一次**、被拒 `busy`、然后安静；
>    一次敲门让它重新拨。

Spec / plan：

- `docs/superpowers/specs/2026-10-07-current-computer-design.md`（§3 是本次行为）
- `docs/superpowers/plans/2026-10-07-current-computer.md`（Task 6 就是这份交接）

Mac 侧对应实现（**已合并进工作树**，供你逐行对照）：

- `RemoteCrabReceiver/ReceiverSession.swift:1760-1792`（`.busy` / `.off` 两支）
- `RemoteCrabReceiver/ReceiverSession.swift:1813-1850`（`standbyRetry = 60` + `scheduleSlowRetry`）
- `RemoteCrabReceiver/ReceiverSession.swift:1802-1811`（`retryNow` —— 敲门走的路径）

> ⚠️ **这份 Mac 实现当前还在工作树里（未提交）**，会随同一个改动一起落地。在另一个
> clone 上的 Windows session **等它提交并推送之后再逐行比对** —— 否则你 grep 到的
> 只是旧基线，看不到本 doc 描述的 `standbyRetry = 60`（lesson 148 的形状：交接里
> 「没做」比「做了」更容易过期）。

---

## 0. 三句话

1. **这不是一个新协议**，也不是新状态。手机以前就会回 `busy`/`off`；改的只是
   接收端**被拒之后怎么等**。Mac 已经把 `/busy` 的 15 秒和 `/off` 的 5 秒都改成了
   同一个 60 秒待命间隔。
2. **待命不是「停死」**：60 秒安全网存在的唯一理由是「敲门可能进不来」
   （Bonjour 被挡 / VPN / 客户端隔离）。它不是抢连接 —— 手机对**非当前电脑永远**
   回 `busy`，所以一分钟一次的拨号永远抢不走会话。
3. **敲门是快速路径，而且已经实现**：`windows/crates/rc-app/src/main.rs` 的
   `spawn_knock_listener`（:451）收到入站连接就 `session.connect_manual(host, DEFAULT_PORT)`
   （:508），而 `Command::ConnectManual` 在 supervisor 里会 `reconnect_at = None`
   并立刻拨（`windows/crates/rc-net/src/supervisor.rs:236-252`）。**这条链路不要改。**

---

## 1. 现象与状态语义

手机上多了一个**持久**字段：这台 iPhone 服务的「当前电脑」。规则（spec §2）：

| 拨入者 | 手机的回答 | 接收端应当做什么 |
|---|---|---|
| 当前电脑（或用户刚在手机上点选、正在切换过来的那台） | `accepted` | 正常连上 |
| 任何别的电脑（包括已配对、token 有效的） | `busy(owner=<当前电脑名>)` | **待命**：停快速循环，60 秒安全网 + 敲门即时 |
| 用户按了断开后的**所有**电脑 | `off` | 同上：待命，不自动恢复，只在用户重选/敲门时回来 |

Mac 侧代码（照抄即可）：

```swift
// RemoteCrabReceiver/ReceiverSession.swift
private static let standbyRetry: Double = 60   // :1817

case .busy:                                     // :1760
    ...
    scheduleSlowRetry(interval: Self.standbyRetry)

case .off:                                      // :1782
    ...
    scheduleSlowRetry(interval: Self.standbyRetry)
```

> 注意 Mac 在 `.busy`/`.off` 里都 `suppressReconnect = true`。Windows 现在的
> `suppress_auto` 没有在这两支里被置位，靠的是 `reconnect_at` + `target` 一起把
> `maybe_autoconnect` 与子网扫描挡住。改的时候留意：**只要 60 秒计时器在，
> 待命期间就不会有别的东西拨号**（见 §2 的调用点分析），不需要额外加 suppression 标志 ——
> 但如果你更愿意显式表达，加也可以，别破坏敲门路径（敲门要能清掉它）。

---

## 2. 改哪里（精确位置）

### 2.1 重拨间隔 —— `rc-net`

`windows/crates/rc-net/src/lib.rs:47-61` 现在是：

```rust
pub(crate) const RECONNECT_DELAY: Duration = Duration::from_secs(3);
pub(crate) const BUSY_RETRY_DELAY: Duration = Duration::from_secs(10);   // ← busy 用
pub(crate) const OFF_RETRY_DELAY: Duration = Duration::from_secs(5);     // ← off 用
```

改成 Mac 的待命语义：新增一个常量，并让 `busy` / `off` 都用它。

```rust
/// 非当前电脑被 `busy`/`off` 之后的安静重拨间隔。它是安全网，不是抢连接：
/// 手机对非当前电脑永远回 `busy`，所以它抢不走会话 —— 只负责在敲门被
/// （VPN / 客户端隔离 / 热点）挡住时不把一台电脑永久困住。
pub(crate) const STANDBY_RETRY_DELAY: Duration = Duration::from_secs(60);
```

（`BUSY_RETRY_DELAY` / `OFF_RETRY_DELAY` 可以删掉，也可以留作常量但两支都指向
`STANDBY_RETRY_DELAY`。删更干净，但先确认没有别处引用。）

消费点在 **`windows/crates/rc-net/src/supervisor.rs:397-440`**：

```rust
ConnEndKind::Busy { owner } => {
    if !suppress_auto {
        reconnect_at = Some(tokio::time::Instant::now() + STANDBY_RETRY_DELAY); // was BUSY_RETRY_DELAY
    }
    set_state(&state_tx, &events_tx, State::Busy { owner });
}
...
ConnEndKind::Off => {
    if !suppress_auto {
        reconnect_at = Some(tokio::time::Instant::now() + STANDBY_RETRY_DELAY); // was OFF_RETRY_DELAY
    }
    set_state(&state_tx, &events_tx, State::Error("...".to_string()));
}
```

**为什么只改这里就够（待命期间唯一的拨号入口）** —— 逐个调用点核对：

- `maybe_autoconnect`（`supervisor.rs:585-621`）开头
  `if active.is_some() || suppress_auto || reconnect_at.is_some() || target.is_some() { return; }`。
  被 `busy` 拒之后 `target` 是 `Some`（`start_connection` 设置，见 :635-642），
  且 `reconnect_at` 也 `Some`，所以发现新手机也不会触发自动拨。
- 子网扫描 / fallback 由 `fallback_allowed(active, suppress_auto, target.is_some())`
  把关（`supervisor.rs:499` 附近）：`target` 为 `Some` 时返回 false，不扫。
- 唯一剩下的计时拨号就是 `reconnect_at` 触发的 `Action::Reconnect`
  （`supervisor.rs:210-212`、:466-481）。
- 敲门走 `Command::ConnectManual`，会先 `reconnect_at = None` 再拨（:236-252）。

### 2.2 `ConnEndKind` 的文档注释 —— `rc-net`

`windows/crates/rc-net/src/lib.rs:364-397` 里 `Busy` 与 `Off` 的注释仍写着
「we keep retrying」，与新的 60 秒待命不符。同步改掉（注释是下一个人唯一的路标）。

### 2.3 状态行（双语） —— `rc-app`

Windows 托盘/控制台的状态来自 **`windows/crates/rc-app/src/doctor.rs`**：

- `panel_summary`（:452-487）—— Win32 菜单行，**不能换行，故意短**。`Busy` 现在渲染
  `t(zh, "iPhone 正被「{owner}」使用", "the iPhone is in use by {owner}")`。
- `state_line`（:491-525）—— 详情行。
- `hints`（:528-556）—— **「该做什么」放在这里**（菜单行装不下整句）。
  `Busy` 现在说：「another computer is using the iPhone, so this one is waiting」+
  「This PC retries every 10s and will pick it up on its own — unless … pick this PC in
  "Choose a computer"」。**这个「每 10 秒重试」现在已经不成立，必须改。**

要求的文案：**逐字对齐 Mac 已上线的 `IBLocale.Error.iphoneBusy`**（不是 spec 早期的短句）。

英文（`%@` = 当前电脑名，`owner`）：

```
This iPhone is being used by %@ — pick this computer in the iPhone's Choose a Computer list. Retry on its own will keep failing.
```

中文（Mac 对同一个 key 已有的 zh-Hans，逐字引用自
`RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings`）：

```
这台 iPhone 正被 %@ 使用 —— 请在手机「选择电脑」里切到这台电脑；单独点重试不会成功。
```

| | 英文 | 中文 |
|---|---|---|
| `busy` 状态行 / hint（**要求**） | This iPhone is being used by %@ — pick this computer in the iPhone's Choose a Computer list. Retry on its own will keep failing. | 这台 iPhone 正被 %@ 使用 —— 请在手机「选择电脑」里切到这台电脑；单独点重试不会成功。 |
| `off`（已暂停） | Disconnected on the iPhone — open Choose a Computer there and pick this one to reconnect. | 已在 iPhone 上断开——请在手机的「选择电脑」里重新选中本机来连接。 |

> 上面第一版菜单行曾写过一个更短的 `This iPhone is set to …`，**不采用** —— 那是
> spec 的早期措辞，Mac 没有采用它。

双语通过 `windows/crates/rc-app/src/i18n.rs` 的 `t(zh, en)` 提供（现有约定）。

> **和 Mac 对齐**：这条的权威来源是 `IBLocale.Error.iphoneBusy(owner)`，位于
> `RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift:960`，被
> `testTheBusyMessageSaysWhereTheActionLives` 钉住 —— 照它抄，不要照 spec 的短句。
> `off`（暂停）对齐 `IBLocale.Error.connectionOff`。**不要改 Mac 的字符串。**
> 已验证的 Mac 行为（`busy`/`off` 间隔 60 秒、敲门即时）与本文一致。

### 2.4 敲门 —— 不用动

`windows/crates/rc-app/src/main.rs:436-511` 的 `spawn_knock_listener`：入站连接 =
「马上拨回我」。它已经 `#[cfg(windows)]`、忽略「正在 streaming」的敲门、2 秒限流，
并 `session.connect_manual(peer.ip(), DEFAULT_PORT)`。**这就是待命期间的快速路径。**

---

## 3. 测试计划

### 3.1 纯/单元（可在任何平台跑）

1. **待命间隔是一个决定，不是一个字面量**。把「busy/off → 用哪个间隔」抽成一个小纯函数
   （或至少断言常量），加测试：
   - `busy` 的间隔 `>= Duration::from_secs(60)`；
   - `off` 的间隔 `== busy` 的间隔；
   - 它 `>` 普通 `RECONNECT_DELAY`（否则就不是「待命」而是「快速重连」）。
   位置：`windows/crates/rc-net/src/supervisor.rs` 的 `#[cfg(test)] mod tests`
   （现有 `being_busy_is_the_only_thing_that_blocks_the_fallback` 就在 :1285 附近）。
2. **敲门清掉计时器**：断言 `Command::ConnectManual` 的处理把 `reconnect_at` 置 `None`
   且 `suppress_auto = false`（这是敲门能立刻拨的前提）。
3. **文案**：扩展 `doctor.rs` 里既有的状态文案测试（:788-880 附近），断言
   `Busy` 的 hint / state_line 在中英两种语言下都**同时**包含「谁在用」和「去手机上点」，
   例如中文含 `选择电脑` / `单独点重试`，英文含 `pick this computer` / `Retry on its own`。断言语义而不是断死字符串。

    命令（Windows 主机）：
    ```
    cargo test -p rc-net -p rc-app
    cargo clippy --workspace --all-targets -- -D warnings
    ```

### 3.2 集成：假手机 `busy` 场景（可脚本化，Mac 主机也能跑第一部分）

`rc-phone-sim` 有现成的 `busy` 场景（`windows/crates/rc-phone-sim/src/main.rs:68,83`）。

```
rc-phone-sim --scenario busy            # 会在 127.0.0.1:<port> 回 busy(owner=另一台)
remotecrab --connect 127.0.0.1:<port>   # 另一台终端
```

断言：

- 接收端日志**恰好一次**拨号尝试，随后 `state=Busy{owner}`；
- 之后 **>60 秒内没有第二次拨号**（旧的 10 秒轮询会在这里露馅）；
- 60 秒到点后**再看一次**拨号（安全网活着）。

> ⚠️ 敲门这一段是 `#[cfg(windows)]`，只能在 Windows 主机上验。假手机模式下
> 没有手机来敲门，可以手工制造一次：
> ```
> # Windows PowerShell
> $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', 8766); $c.Close()
> ```
> 断言日志出现 `[knock] … asked us to dial back — dialing …`，并且**紧接着**又一次拨号
> （不等 60 秒）。若 `[knock] could not listen`，先照 `windows/tools/RemoteCrab.wxs:320-339`
> 的防火墙规则放行 TCP 8766（仅 private）。

### 3.3 两台接收端对一台手机（真机，最终验收）

两台 `rc-app` 在同一台 Windows 上会被**单实例守卫**挡住，所以用
**一台 Mac + 一台 Windows**（这正是真实场景），或两台 Windows 机器/VM：

1. 先让 A（假设 Mac）配对 → A 成为当前电脑。
2. 启动 B（Windows）：**只拨一次**，被回 `busy(owner=A)`，然后**保持安静**。
   需要看到：
   - 手机侧 `sessionReply: busy owner=A`；
   - B 侧 `state=Busy{owner=A}`，状态行说「这台 iPhone 正被 A 使用 … 请在手机「选择电脑」里切到这台电脑」；
   - B 侧在 60 秒内**没有**第二次拨号。
3. 在手机上「选择电脑」→ 点 B：B 应**立即**（敲门）连上，秒级。
4. 手机上按断开：B 回到 `off` 待命，**不自动重连**；手机上重新点 B → 回来。
5. 手机 app 重启：当前电脑自动重连，另一台继续安静。

把日志 marker 记下来（手机 `sessionReply: busy owner=…`；Windows
`[knock] … dialing …`；状态行原文）—— 交接必须带数字/原文（AGENTS 跨端规矩）。

---

## 4. 明确不做的

- **不加 wire kind**，不改 `SessionReplyResult`，不碰数据面（spec non-goals）。
- **不改敲门链路**：它已经是对的（收到就拨）。
- **不改 `Denied` / `Impersonated`**：那是拒绝/冒充，语义不同，维持现状。
- **不改 `RECONNECT_DELAY`（3 秒）**：那是断链后的正常重连，不是待命。
- **不改假手机**：`rc-phone-sim --scenario busy` 已够用。

---

## 5. 验收清单（照打勾）

- [ ] `rc-net`：`busy` 与 `off` 都指向 60 秒待命间隔；旧的 10 秒 / 5 秒常量删掉或统一。
- [ ] `ConnEndKind::{Busy,Off}` 的文档注释更新，不再写「keep retrying」。
- [ ] `doctor.rs`：状态行/hint 逐字对齐 `IBLocale.Error.iphoneBusy`（谁在用 + 去手机「选择电脑」里选它 + 为什么单点重试不会成功），中英各一份，
      且删掉「每 10 秒重试」那句。
- [ ] 单元测试：`busy/off` 的间隔 ≥60 秒且彼此相同；敲门清计时器；文案双语含动作。
- [ ] `cargo test -p rc-net -p rc-app` 与 `cargo clippy --workspace --all-targets -D warnings` 全绿。
- [ ] 集成（Windows 主机）：假手机 `busy` 下只拨一次、>60 秒无第二次；手工敲门立刻重拨。
- [ ] 真机：两台接收端对一台手机，非当前那台一次拒绝后安静、敲门即连、断开不自动回来。
- [ ] 两端文案统一：逐字对齐 `IBLocale.Error.iphoneBusy` / `connectionOff`（**不改 Mac 的字符串**）。

---

_写完即提交并推送（AGENTS 跨端规矩 3）。先 `git fetch` 看对面有没有写过同一件事。_
