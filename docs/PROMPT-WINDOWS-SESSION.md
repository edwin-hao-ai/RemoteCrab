> **复制下面全部内容，粘进新 session。**

---

# RemoteCrab Windows 接收端 —— 收尾与发布

你在**一台 Windows 电脑**上，前一个 session 在 Mac 上把 Windows 接收端做到了
「Mac 上能做的全部做完」的位置。剩下的**必须在这台机器上做**。

代码基线：`baff770`。仓库在 `windows/` 子目录里，是一个独立的 Rust workspace。

本 session 的完整收尾记录：**[`docs/WINDOWS_SESSION_CLOSEOUT.md`](WINDOWS_SESSION_CLOSEOUT.md)**。

## 先读这三份，按顺序

1. **`docs/WINDOWS_TODO.md`** —— 主清单。每一条都有「做什么 / 为什么 / 怎么验证 /
   **怎么算做完**」。从 §2 开始，那是三个上线阻塞。
2. **`docs/lessons/windows.md` 第 95–107 条** —— 前一个 session 踩的十三条坑。
   **至少读 95、98、100**，每一条都造成过一整轮的返工。
3. **`AGENTS.md`** —— 项目规则。中文，重要。

## 第一个动作：启动代码签名证书采购

**这件事周期最长，且所有其他发布工作都排在它后面。** 先确认证书渠道
（CA/Browser Forum 2023 的 HSM 规则下，便宜的 OV 证书已经没有，要确认
**含 Code Signing EKU**），再继续别的。

如果证书还没到，**不要干等**——按 `WINDOWS_TODO.md` §3 顺序做真机验证。

## 前一个 session 已经做完的（不要重做）

- **界面**：5 页设置向导窗口、设置窗口（通知拒绝列表编辑器 / 配对手机管理 /
  画质）、四象限自检面板。Mac 有而 Windows 完全没有的，全部补齐。
- **通知中继 0x22**：整条链（协议结构体 + 纯决策逻辑 + WinRT 捕获 + 去重 +
  托盘开关 + 第 16 格图标）。**此前 `rc-protocol` 里连结构体都没有。**
- **`0x23` commandResult** 的 dispatch 分支——此前能识别但丢弃，手机上点
  「打开应用」什么都不会发生。
- 自提权安装虚拟摄像头（`ShellExecuteW` + runas）、完整卸载（含带 NULL DACL
  的 ring 文件）、`--version`、PE 版本资源 + 20 格托盘图标、
  `check-windows-deps.sh`、`release-windows.sh` + WiX 清单。
- 连接可靠性的 11 个根因（token 持久化、幽灵地址、busy 反压、mDNS 静默失效…）。

## 前一个 session **没有**验证的（所以需要你的眼睛）

**它的交叉编译只证明「能编译」，证明不了「能跑」。** 三个新窗口**一次都没在
Windows 上打开过**。请优先看：

- 三个窗口在 **125% DPI** 下排版是否错乱
- 自检面板四个象限的**文字是否被截断**
- **20 格托盘图标**在真实菜单里的可辨识度（对照 `windows/assets/menu-icons.png`）
- 「显示桌面」按**第二次**是否有反应（应该没有——它是幂等的，不是 Win+D 开关）

## 三个必须先知道的坑

1. **跑 E2E 之前 `pkill` 掉手动开的接收端**（见下）。
2. **`windows` 依赖必须 target 化，而且挪到 `[target.'cfg(windows)'.dependencies]`
   也不够**——Cargo 会跨 workspace 统一 feature，所以 WinRT 代码必须**独立成
   crate**（`rc-notify` 就是为此存在）。这是 lesson 95。
3. **别用笼统的 `allow(dead_code)`**。前一个 session 有 14 处，全部改成
   `cfg_attr(not(windows), allow(dead_code))` 之后，Windows 目标下才真正开始
   审计死代码。保持这个纪律，否则新写的死代码不会有人告诉你。

## ⭐ 第一件想做的事：不用 iPhone 也能测

仓库里有一个**假 iPhone 进程**：

```sh
# 终端 1
cargo run -p rc-phone-sim -- --port 8765
# 终端 2
remotecrab.exe --connect 127.0.0.1:8765
```

七个场景（`normal` / `pending` / `denied` / `busy` / `silent` / `no-token` /
`drop`）让故障可以故意复现。其中 `silent`（连上后什么都不发）和 `drop`
（连上就断）手测最难抓——**界面看起来一切正常**。

详见 `docs/WINDOWS_TODO.md` §0'，以及 `docs/lessons/windows.md` 第 105 条。

## 第 0 优先任务：~~定位这个崩溃~~ → 2026-10-02 复查后无法复现

接收端曾经**一连接就崩**：

```
[net] sessionReply: Accepted
fatal runtime error: Rust cannot catch foreign exceptions, aborting
```

### 前一个 session 已经查到的（别重复）

| 实验 | 结论 |
|---|---|
| `git stash -u` 回到改动前重建，**同样崩** | **不是新代码引入的** |
| macOS 上同样复现 | **不是 Windows 特有** |
| `rc-phone-sim --scenario silent`（不发视频）也崩 | 与解码无关 |
| `--doctor` / `--version` / 纯启动都正常 | 与网络探测、参数解析无关 |
| **连一个只 accept 不说话的端口，也崩** | 与真手机、与握手成功无关 |
| **不带 `--connect` 也崩**（它自己 mDNS 发现了真手机） | 与连接触发方式无关 |
| 最后打印的是 `[CONNECTING]  handshaking…` | 崩在 `set_state` 之后、`Event::State` 的处理里 |
| panic hook 已在启动时安装，但**日志里没有 panic 记录** | panic 没走 Rust 的 hook → 发生在 **`extern "C"` 边界** |

### 2026-10-02 复查：这些现在都跑得过去了

在这台 Windows 机器上用当前代码，以下全部**不崩**，接收端一直活到被杀：
accept-only 端口（`--connect 127.0.0.1:9999`）、`rc-phone-sim` 的四种握手结果
（`normal` 一路走到 `[LIVE] streaming: 1080p`）、带托盘（下面那段嫌疑代码会
真的执行）、`--no-tray`。`%LOCALAPPDATA%\RemoteCrab\RemoteCrab.log` 里也只有
启动行，没有 panic。

**所以别再照着下面那段去改代码** —— 没有复现路径的修改违反项目纪律
（"prohibited: fixing without a failing test"）。如果你在**真机**上又撞上，
下面这套还是唯一能定案的办法。

### 嫌疑代码块（`rc-app/src/main.rs`，`Event::State` 分支内）

打印状态行之后紧接着的这一段：

```rust
tray.set_status(&status::tray_status(&st));      // 纯字符串，安全
{
    let h = health.borrow().clone();              // ← 持 watch 锁
    let verdict = doctor::route_verdict(&h);      // ← 阻塞式 UDP connect，async 上下文里
    tray.set_diagnosis(
        &doctor::panel_summary(&h, &verdict, zh),  // 字符串拼接
        &doctor::panel(&h, &verdict, zh),
    );
}
```

**「async 上下文里做同步系统调用 + 同时持锁」**符合全部观察，包括
「panic hook 拿不到信息」——在 macOS 上这个 `connect` 可能跨进系统框架。

**但这只是嫌疑，没有确认。** 请这样确定它：

```sh
cd windows
cargo build -p rc-app
lldb -- ./target/debug/remotecrab --connect 127.0.0.1:9999 --no-tray
# 崩之后：bt 40
```

栈顶会直接告诉你是不是这里。

### 如果急着验别的东西（绕过方案）

诊断面板**不是连接的前提**。任选其一：

```rust
// 方案 A：先跳过诊断，连接路径立刻可用
//   把 set_diagnosis 那三行注释掉

// 方案 B：把阻塞探测挪出去（正解）
let verdict = tokio::task::spawn_blocking({
    let h = h.clone();
    move || doctor::route_verdict(&h)
}).await.unwrap_or_default();
```

## 验证命令

```sh
cd windows

# 逻辑层：359 个测试，任何平台都能跑，不需要手机也不需要 Windows
cargo test --workspace

# 静态：这两项都必须是 0 error / 0 warning
cargo clippy --workspace --all-targets -- -D warnings
cargo build  --release -p rc-app --target x86_64-pc-windows-msvc

# 运行时依赖（发布前的判据，必须输出 OK）
scripts/check-windows-deps.sh target/x86_64-pc-windows-msvc/release/remotecrab.exe
```

> `scripts/` 在仓库根目录，不在 `windows/` 里面。

**当前基线**：Windows 测试 362 / Core 367 / 两平台 build+clippy 全 0 /
Windows 目标死代码 0 / Mac↔iPhone 真机 E2E 26/26 绿。

## 如果要跑真机 E2E

```sh
# 脚本假设 Mac 接收端**没在跑**——你手动开一个的话，它的启动就是空操作，
# 断言会去读一个空日志，而 iPhone 其实在正常推流。表现成「23 条全红」。
pkill -f "RemoteCrab.app/Contents/MacOS/RemoteCrab"
./scripts/e2e-device.sh
```

**E2E 只能在 Mac 上跑**（它测的是 Mac 接收端 ↔ iPhone），对 Windows 接收端
**零信息量**。你在这台机器上要做的是 `WINDOWS_TODO.md` §3 的手动验证。

## 工作纪律（这个项目踩过的）

- **动手前先说清根因。** 「跑不通」不是原因，「token 没持久化」才是。
- **不要只做文件级对比。** 前一个 session 反复把「做完了」说得太早，
  被指出四次——因为它比的是**文件存在**，缺的是**动作正确**：
  窗口在但控件是死的（读了值就丢弃、没有控件用那个 ID、回调被 `take` 走
  只能点一次）。**逐个控件问「它真的做事吗」。**
- **新加的持久化字段必须 `#[serde(default)]`。** 这个项目的 loader 会吞掉
  解码错误，一个漏掉的 default 会静默清空用户数据。
- **跨连接测试。** 只连一次的测试抓不到「第二次连接才出现」的问题。
- **别改 Mac / iOS 侧**，除非任务明确要求。
- **不要 commit 别人正在改的文件。** 前一个 session 有并行会话在改
  `RemoteCrabCore` 和 `RemoteCrabCapture`；提交前先 `git status`，
  只 stage 自己的。

## 交付

做完后请在 `docs/WINDOWS_TODO.md` 里把验证过的项勾上并注明**怎么验的**，
以及把新踩的坑写进 `docs/lessons/windows.md`（编号接着 107 往下）。

---

# 追加：iOS 侧的 Windows 兼容修完了（2026-10-03 晚，`33e2183` / `7fbbf81` / `84f30fa`）

Mac 这边把 iOS 上残留的 Mac 假设查了一遍并修掉了。**这一段和上面的清单并行，
不冲突**；下面每一条都需要**真机 + 真 Windows 接收端**才能验证，本机验不了。

## 三个提交做了什么

| 提交 | 改了什么 | Mac 侧影响 |
|---|---|---|
| `33e2183` | 修饰键行。`IBShortcutBar`（**触控板 + 投屏**共用）调 `IBModifierBar` 时**没传 `platform`**，走缺省 `.mac` —— 所以 Windows 用户在最常用的两个界面上看到的还是 `⌃⌥⌘⇧`，只有键盘界面对。三处 `platform` 现在**都没有默认值**，编译器强制表态 | 零 |
| `7fbbf81` | Windows 系统区三个说谎的按钮 + macOS 独有的「屏幕录制」提示 | 零 |
| `84f30fa` | iOS 设备列表一个电脑一行（见下） | 零 |

`console` / `gridActions` / `systemActions(for: .mac)` / `voiceHero(for: .mac)` /
`appActions` 的 Mac 分支**一行都没改**，原有 41 个 `ContextProfilesTests` 全绿。
444 测试 + 两个 app target + Windows 套件全绿。

## ⚠️ 先做这件事：重新编译并部署接收端

`c9c0463`（MachineGuid 机器身份）**已经在 main 上，但你的机器上跑的还是旧版**。
旧版每装一次换一个 `pc_id`，后果不只是列表难看：

- token 跟着 `pc_id` 走 → **每次重装都要重新批准**
- 手机上「选择电脑」里会堆积同名行

iOS 侧现在会**按名字合并 + 30 天过期**（`84f30fa`），所以列表不再堆了，
但**根因在接收端**。不部署 `c9c0463`，重装后仍然要重新配对。

## 需要真机打勾的（本轮新增，接到 `WINDOWS-GAPS-2026-10-03.md` §5.6）

**修饰键（`33e2183` 的全部意义就是这几条）**

- [ ] 触控板界面：修饰键行显示 `Ctrl Alt ⊞ Shift`，**没有 ⌘**
- [ ] 投屏界面：同上
- [ ] 键盘界面：`Ctrl Alt ⊞ Shift`（这条本来就是对的，用来对照）
- [ ] ⊞ 单独按 = Windows 键；⊞ 单独用（不点 ⌘）能开资源管理器 / 运行
- [ ] 三个界面**互不串**（`platform` 现在是必填参数，理论上不可能串，但要人眼确认一次）

**情景模式系统区（`7fbbf81`）**

- [ ] 「显示桌面」真的**最小化全部窗口**（本轮从 ⊞⌥D 改成走
      `IBSystemCommand.showDesktop`；旧按钮发的是 **keycode 53 = Escape**，什么都不会发生）
- [ ] 「浏览器」图标是**地球**（不再是 Safari 罗盘），点开是默认浏览器
- [ ] 语音 hero **只出现一次**（全宽那个）。系统区里不该再有一个
- [ ] **没有**亮度按钮（`system_keys.rs` 对它 `return false`）
- [ ] 「锁屏」是 ⊞L，锁屏而**不是**退出应用

**切换 / 断开（本轮新增，iOS 侧，与你的代码无关但和你的机器有关）**

- [ ] 手机上「⋯ / 状态胶囊 → 断开连接」能**立刻**放开当前这台电脑（1 跳可达）
- [ ] 选另一台电脑切换，**30 秒内**接上
- [ ] 切到一台**被你 deny 过**的 PC：旧版永远接不上（`denied` 不排重试），
      新版 30 秒后自动放弃并对所有人恢复
- [ ] 你的 `autoReconnect` 关闭时，手机 30 秒后不再傻等（这是同一处修复）

**设备列表（`84f30fa`）**

- [ ] 手机「选择电脑」里同名电脑**只有一行**
- [ ] 重装接收端后**不需要**重新配对（这才是 `c9c0463` 真正的验证）

## 一个会让 e2e 全红的坑，先看这个

Mac 上 `./scripts/e2e-device.sh` 现在跑出 **22 个失败**，看起来像全线崩了，
**其实只有一条根因**：手机正被**另一台** RemoteCrab 接收端占着。

```
[receiver] sessionReply: busy owner=EDWIN
```

手机上的 `seenComputers` 读出来是这样（真实数据）：

```
EDWIN                    …-98db-0bce2018971c   streaming   ← 另一台机器
EDWIN                    …-98db-023a844ff7a4   streaming   ← 同一台，旧身份
MacBook Pro de Edwin     ECBDD7BA-…            refusedBusy ← 本机，被正确拒绝
```

`…98db…` 两条 **node 相同、id 不同** —— 同一台机器的两个身份。

**所以：跑 e2e 之前先确认那台机器没连着手机。** 不然 22 条断言会因为一个
被拒绝的握手全部变红，而你会以为是自己刚改的东西坏了（lesson 111）。

## Mac 侧真机已经验过的（不用重做）

- iPhone 装上、启动、不崩、渲染正常（自截图确认，修饰键行在 Mac peer 下是 `⌃`）
- Mac 接收端真机启动、摄像头 sysex 注册、发布已安装应用列表
- `84f30fa` 在**真机上**：设备列表 5 行 → 3 行，同名归零，正在 streaming 的那台保留
- `/Applications/RemoteCrab.app` 在 e2e 前后 CDHash 完全一致
  （`d9dacda991ffaa8a1a32aff7abacf9b38b945549`，Developer ID，build 11）——
  lesson 80 的备份/还原陷阱有效

## 还没验的（本机不可能验）

- 上面所有带 ☑ 的条目
- `docs/WINDOWS-GAPS-2026-10-03.md` §5.6 原有那 11 条

---

# 2026-10-04 Mac session 回信：⚠️ 你那个码率修法**改了也不会有效果**

`docs/HANDOFF-IOS-QUALITY.md` 里的两条我都做了，但**第 1 条的前提是错的**。
先说这个，因为它会让你在真机上白跑一轮。

## 🔴 `kVTCompressionPropertyKey_Quality` 在 iOS 上**完全覆盖** `AverageBitRate`

`H264Encoder.createSession` 同时设了两个属性，而硬件编码器**只认 Quality**：

| Quality | 实测码率 |
|---------|----------|
| 0.50 | 4,989 kbps |
| **0.70（原来在发）** | **9,179 kbps** |
| **0.75（现在）** | **10,886 kbps** |
| 0.80 | 13,552 kbps |
| 0.90 | 22,404 kbps |

（1920x1080@30，`AverageBitRate` 固定 9,331,200，90 帧合成高细节画面）

**决定性的一条**：请求 6,220 kbps 和请求 9,331 kbps，输出**字节数完全相同**
（3,442,273 bytes，一模一样）。所以 `AverageBitRate` 不是「不太准」，是**完全没有作用**。

`VTCompressionProperties.h` 里既没写谁优先，也没写 `Quality` 会忽略码率 ——
这个行为只能测出来，不能读出来。

## 为什么这条对你重要

你的 §1 记的是「Windows 接收端独立测到 `6220 kbps`，正好等于
`1920 × 1080 × 30 × 0.1`」。那个 6220 是**手机自己请求的值**，从
`IBStreamMetadata` 读回来的 —— 不是链路上的测量值。

所以如果我照你说的把 `0.1 → 0.15`、上限提到 16M：

- 手机会打印 **≈9,300 kbps**，你 §3.1 的验收**会通过**
- 编码器还是吐 **9,179 kbps**，**一个字节都没多**
- 用户的「画面软 / 边缘彩色噪点」**一点没变**

**这就是「断言在自己要测的分支没执行时还能通过」**（lesson 111），
只不过这次 vacuous 的是验收标准本身。

## 实际改了什么

| | 原来 | 现在 |
|---|---|---|
| `kVTCompressionPropertyKey_Quality` | 0.70 | **0.75**（实测 9,179 → 10,886 kbps，+19%） |
| `kVTCompressionPropertyKey_MaxKeyFrameInterval` | `fps`（每秒一个 I 帧） | **`fps * 2`**（用秒表达，测试保证 ≤ 2s） |
| `AverageBitRate` 系数 | 0.1 | 0.15（**在 iOS 上仍然无效，留着给别的编码器**） |

选 0.75 而不是 0.80：0.80 是 13,552 kbps，比你的目标多 45%，WiFi 上风险大；
0.75 的 10,886 kbps 接近你要的 ~9.3 Mbps，**是量出来的**，不是我挑的整数。
这是一个旋钮，链路过满或过空随时可调。

新增 `RemoteCrabCore/Input/VideoEncodingPolicy.swift`（纯函数，13 个测试）+ 
`scripts/vt-bitrate-probe.swift`（上面那张表就是它打的，可以自己重跑验证）。
**要改画质请改 `VideoEncodingPolicy.quality`，改 `bitsPerPixel` 之前先重跑那个探针。**

## 验收请这样做（重要）

1. **不要用 metadata 里的 kbps 判断画质** —— 那是请求值。要判断就量像素：
   `vcam_forensics` 的 `saturated pixels` / `harsh horizontal` / `harsh vertical`
   才是真信号。你的 §3.2 已经写对了，是 §3.1 需要删掉。
2. **手机日志会给出真实码率**。新 build 加了
   `REMOTECRAB_E2E_BITRATE=1`：每 2 秒一行
   `[video-forensic] rate req=… kbps achieved=… kbps ratio=… frames=… gop=…`
   —— `achieved` 是编码器真的吐出来的字节。这是你能拿到的最便宜的真值。
3. **§3.3 的人眼仍然不能替代**，而且现在理由更充分了：0.70 实际跑在
   9,179 kbps（比你以为的 6,220 高 48%），画面仍然是软的。

## 触控板方向：Windows 侧现在有测试了，你可以自己跑

用户报「Windows 上手指往左，光标往右」。上一轮结论是两端都没取负、修不了 ——
**这个结论是对的**，我这一轮把每一环都查完并加了测试：

- `rc-input` 的 `TouchPhase::Move` 以前只有 `move_clamps_to_screen` 一个
  负 dx 测试，而 **`+5.0` 和 `-5.0` 都 clamp 到 0**，所以取反了也照样过。
  现在加了 `a_move_preserves_the_sign_of_its_delta` 和
  `a_move_preserves_the_sign_of_a_vertical_delta`：从屏幕正中出发、**小** delta、
  正负成对，两轴各一个。逆向验过 —— 把 `dx` 取负，前者 FAILED、后者 ok；
  把 `dy` 取负则相反。两条都不是对方的影子。
- 也顺手确认了链路其余部分不改符号：serde `f32` 原样解码 → `dispatch` 纯透传
  → `perform_mouse` → `normalize_axis`（对 coord 单调递增，多显示器 origin 也对）。

**所以 Windows 侧的指针移动方向现在是被测试证明的，不是被读代码证明的。**

剩下唯一没排除的就是手机。等用户滑一次手机读 `[dir]` 日志，
若 `out.dx` 与手指同向，那结论就是你这台机器上的 `SendInput` /
虚拟屏 / 驱动层面有问题 —— 到时候我会在
`docs/HANDOFF-IOS-QUALITY.md` 里把测量数字给你。

## 一个和你有关的坑

`send_mouse` 用的是 `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`
+ `normalize_axis` 归一化到 0–65535。多显示器时依赖
`virtual_screen_size()` 的 `origin_x/origin_y`，**这块没有测试**。
单显示器看不出问题；如果你的机器是双屏而单屏测试都正常，
方向类症状优先怀疑这里。

---

## 2026-10-04 追加：触控板方向 —— 手机侧**已用测量排除**，现在只剩你那台机器

上一条我说「Windows 侧已被测试证明，等 `[dir]` 日志」。日志拿到了，
**结论是手机没问题**。所以方向的反转如果真实存在，就在 Windows 这一侧，
而代码路径已经全测过了 —— 请看下面第 2 步。

### 1. 手机实测：每一行 `out.dx` 都和手指同号

`REMOTECRAB_E2E_TRACKPAD_DIR=1` + 触控板界面，用户左右各滑几下：

```
n=1  fx=230 finger.dx=+0.02844 out.dx=+0.08221 speed=0.979
n=25 fx=211 finger.dx=-0.00474 out.dx=-0.00865 speed=0.323
n=49 fx=224 finger.dx=-0.00079 out.dx=-0.00116 speed=0.102
n=85 fx=259 finger.dx=+0.01738 out.dx=+0.04753 speed=0.883
```

- **符号永远一致**：`fx` 从 230 → 211 → 197（往左）时 `finger.dx` 与
  `out.dx` 都为负；往右时都为正。
- **幅度也对得上** `TrackpadMath`：speed=0.979 → 增益 2.89
  = 1.3（sensitivity 3 的 baseGain）× 2.22（boost）。没有失控。

**手机发的方向是对的。** 手机日志现在打的是 `finger.dx` 而不是原来的 `prev` ——
`prev` 读的是已经推进过的 `lastDragLocation`，永远等于 `fx`，等于没打（已修）。

### 2. 请跑这个（一个环境变量）

我加了 `REMOTECRAB_E2E_TRACKPAD_DIR=1` 在 **`rc-app`**，每 12 个 move 打一行：

```
[dir] n=25 in.dx=-0.00474 cursor_dx=-16.4 cursor_dy=-8.2 at=(413,271)
```

**一行就能定案**：

| 现象 | 结论 |
|---|---|
| `in.dx` 与 `cursor_dx` **同号** | 这一层也是对的 → 反转在 `perform_mouse` 之下（SendInput / 驱动 / 多屏） |
| `in.dx` 与 `cursor_dx` **反号** | 反转就在 `rc-input`，把那几行发我 |

```cmd
set REMOTECRAB_E2E_TRACKPAD_DIR=1
remotecrab.exe
```
然后手机上左右各滑几下，看控制台。

### 3. 顺手发现的一个**既有**测试失败（不是我改的）

> **2026-10-04 更新：这条已经转绿。** 下面保留原文，因为「用
> `git clone --no-local` + checkout 到 session 之前的 commit 复现」这个做法
> 本身值得留着——它能把「既有缺陷」和「我这轮弄坏的」分开，我当时就是靠它
> 确认这条与本轮无关。现在 `cargo test -p rc-app` 112 项全过。

`cargo test --workspace` 里 `rc-app` 有 1 条红的：

```
status::no_video_tests::a_latency_reading_never_replaces_the_waiting_notice
  assert!(line.contains("等待画面"))  →  实际 "Streaming from iPhone — connected, waiting for video…"
```

`i18n::t` 在非中文 locale 下选了英文，于是断言里的中文字面量匹配不上。
我用 `git clone --no-local` + `checkout 7f0d646`（本 session 任何提交之前）
复现了**完全相同**的失败，所以**与本轮无关**，是既有缺陷。
`./scripts/test.sh` 只跑 `rc-net` 那些 crate，所以一直没暴露。
这条归你：要么让 `i18n::t` 在测试里可确定化，要么断言用 `i18n::t` 自己取文案。

---

## 2026-10-04 追加（本轮总结 + speaker 实现交接）

### 触控板方向：iOS 侧已排除，**只剩一个环境变量**

真机滑动日志拿到了，结论是**手机没问题**：

```
n=1  fx=230 finger.dx=+0.02844 out.dx=+0.08221 speed=0.979
n=25 fx=211 finger.dx=-0.00474 out.dx=-0.00865 speed=0.323
n=85 fx=259 finger.dx=+0.01738 out.dx=+0.04753 speed=0.883
```

`out.dx` **每一行都和手指同号**，而 `fx` 从 230→211→197（往左）时符号为负；
增益精确对得上 `TrackpadMath`（speed 0.979 → 2.89 = 1.3 base × 2.22 boost）。
**手机发的方向和幅度都是对的。**

Windows 侧的代码路径也全部测过了：`rc-input` 的 Move 有了配对断言
（`a_move_preserves_the_sign_of_its_delta` / `..._vertical_delta`），
`normalize_axis` 对坐标单调，多显示器 origin 也对。
**所以两侧代码都是对的，反转如果真实存在，只能在 `SendInput` 之下那层。**

`rc-app` 已经加好 `REMOTECRAB_E2E_TRACKPAD_DIR=1`：

```
[dir] n=25 in.dx=-0.00474 cursor_dx=-16.4 cursor_dy=-8.2 at=(413,271)
```

**一行定案**：`in.dx` 与 `cursor_dx` 同号 → 这层也对，往下查（驱动/多屏）；
反号 → 就在 `rc-input`，把那行发我。

⚠️ 一个已知空白：`send_mouse` 走 `MOUSEEVENTF_ABSOLUTE|VIRTUALDESK` +
`normalize_axis` 归一化到 0–65535，多显示器依赖 `virtual_screen_size()` 的
`origin_x/origin_y`，**这块没有测试**。单屏看不出问题，双屏 + 单屏测试都正常时
优先怀疑这里。

### 🔴 Speaker（用 iPhone 当音箱）：Windows 端可以开始了

Mac 端**已修好并经用户亲耳验收**（"现在好多了，基本上没啥问题了"）。
Windows 端协议早就绪，只差「采集系统声音」。

**动手之前先读 [`docs/WINDOWS-SPEAKER-HANDOFF-2026-10-04.md`](WINDOWS-SPEAKER-HANDOFF-2026-10-04.md)
第 6 节**，那是我自己踩的三个坑，和平台无关：

1. **定时器不是调度器** —— 一个 20 ms 定时器无条件补静音（为了保活
   `isPlaying`，故意的）+ 来包时播真实音频 = 每秒喂 100 包给只能消费 50 包的
   播放器 = 每秒积压 50 包。表现为「乱 + 关不掉 + e2e 全绿（没检查填充比例）」。
   而且即使只让定时器喂音频也不行：`Task.sleep(20 ms)` 实测 ~30 ms，
   `played=33 包/秒` 而到达 46。**真实音频必须由数据到达驱动，队列深度当反馈项。**
2. **buffer 布局声明和写法必须是同一个** —— `interleaved: true` 配平面写法，
   两个 channel 指针差 **2 字节**，右声道被下一个左声道覆盖 →
   尖锐 + 不清晰 + 梳状滤波杂音。**测地址差，不要猜。**
3. **别用 tap 做诊断** —— 我加的 `installTap` 把 app 打成 signal 5，
   而且坏的时候报「静音」，看起来像功能坏了。

**可直接照抄的跨平台部分**（纯函数 + 测试）：
`RemoteCrabCore/Sources/RemoteCrabCore/Audio/SpeakerSchedule.swift`、
`SpeakerPCMWriter.swift` 及对应测试。**只有采集部分（CoreAudio tap →
WASMAPI loopback）要你自己写。**

iOS 端入口在 `speakerAvailable = !engine.connectedIsWindows`，实现完删掉 `!` 即可。

### 码率：那条建议作废，别照做

见上面 2026-10-04 的两节。核心：**`Quality` 覆盖 `AverageBitRate`，
你之前测到的 6220 kbps 是手机的请求值不是链路测量值**，
所以「改成 0.15 → 打印 ≈9300 → 验收通过」会是**验收空过而画面不变**。
实际改的是 `Quality 0.70 → 0.75`。验收请量像素，不要读对端打印的数字。

### 本机不可能验、留给你的

* `rc-app` 有 **1 条既有测试失败**（locale 相关，非本轮引入，
  在 `7f0d646` 上同样失败）
* `speaker` 采集（见上）
* `virtual_screen_size()` 多显示器 origin 无测试
