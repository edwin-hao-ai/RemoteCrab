# Session 收尾记录 — Windows 接收端对齐

> 2026-09-30。本 session 的完整进度、验证状态、以及**没有解决的部分**。
> 面向在 Windows 上接手的人。

## 一句话结论

功能对齐完成并已推送。剩下的**必须在那台 Windows 电脑上做**，外加**一个既有崩溃待查**。

---

## 1. 状态（提交 `2bc41b5`）

```
Windows 测试  362        Core 测试 367（359 + 8 跨实现协议契约）
macOS build   0 error / 0 warning
win-gnu check 0 error / 0 warning
clippy -D warnings  两平台均 0
Windows 目标下死代码   0
Mac↔iPhone 真机 E2E   26 / 26 绿（iPhone 14 / iOS 26.6.2）
协议 kind 三方对照     36 / 36 全部对齐
```

## 2. 本 session 做了什么

### 2.1 补齐 Mac 有而 Windows 完全没有的界面

| Mac | Windows |
|---|---|
| `SetupAssistantView` | `wizard_win.rs` — 5 页向导窗口，必做步骤禁用「下一步」 |
| `PreferencesView` | `settings_win.rs` — 通知拒绝列表**编辑器**、配对手机管理、画质 |
| `TestWindowView` | `selfcheck_win.rs` — 四象限，200 ms 刷新 |
| `CameraExtensionCard` | 托盘安装行 + 设置里的按钮（同一条 UAC 路径） |

### 2.2 补齐功能缺口

- **通知中继 0x22** — 此前 `rc-protocol` 里**连结构体都没有**，整条链是空的
- **`0x23` commandResult 的 dispatch 分支** — 此前能识别但丢弃，手机上点「打开应用」什么都不会发生
- **`rc-phone-sim`** — 假 iPhone 进程，让接收端**不需要手机**就能测（见 §4）
- 自动更新空闲门控、配对手机 forget、`--version`、`--record` 不再自动开录
- PE version resource + 20 格托盘图标、自提权安装摄像头、完整卸载（含 NULL-DACL ring 文件）
- 开机自启**过期绿勾**修复（解析 Run 值并检查文件是否真在）
- `check-windows-deps.sh`、`release-windows.sh` + WiX 清单、`rust-toolchain.toml`

### 2.3 审计抓到的、否则不会发现的

- 托盘图标**从第 4 格起整体错位**（摄像头行画着切换图标，退出行画着停止方块）
- 14 处笼统 `allow(dead_code)` → 改精确后 Windows 目标**零死代码**
- 两条测试**永远跑不到**（`#[cfg(windows)]` + macOS 无 `%APPDATA%`），且「通过」是因为读回默认值
- 向导动作按钮**只能点一次**（`take()` 取走闭包）
- 设置窗口摄像头行**只有文字没有按钮**（分发分支读了值就丢弃）
- `999 999 999` 会被当成合法分辨率

## 3. ❌ 没有解决的部分

### 3.1 既有崩溃（**优先级最高**，已大幅缩小范围）

```
[net] sessionReply: Accepted
fatal runtime error: Rust cannot catch foreign exceptions, aborting
```

**已确认的事实**：

| 观察 | 结论 |
|---|---|
| `git stash -u` 回到改动前重建，**同样崩** | **不是本次引入** |
| macOS 上同样复现 | **不是 Windows 特有** |
| `--scenario silent`（不发视频）同样崩 | 与视频/解码无关 |
| `--doctor` 正常、`--version` 正常、纯启动不崩 | **与网络探测、参数解析无关** |
| 连接到一个只 accept 不说话的端口，**也崩** | **与真手机、与握手成功与否无关** |
| 不带 `--connect` 也崩（它自己 mDNS 发现了真手机） | 与连接触发方式无关 |
| 崩溃前最后打印的是 `[CONNECTING] handshaking…` | 崩在 **`set_state` 之后、`Event::State` 的处理里** |
| panic hook 已安装但**日志里没有 panic 记录** | panic 未走 Rust 的 hook → **发生在 `extern "C"` 边界** |

**最可能的范围**（未最终确认，需要在有 lldb 的机器上抓栈）：

`main.rs` 里 `Event::State` 分支中，`[CONNECTING]` 打印之后紧接着的两行：

```rust
tray.set_status(&status::tray_status(&st));           // ← 安全，纯字符串
{
    let h = health.borrow().clone();                   // ← watch 锁
    let verdict = doctor::route_verdict(&h);           // ← 做 UDP connect（阻塞）
    tray.set_diagnosis(
        &doctor::panel_summary(&h, &verdict, zh),
        &doctor::panel(&h, &verdict, zh),
    );
}
```

**嫌疑**：`doctor::route_verdict` 在 async 上下文里做同步 UDP `connect`，
而这一段又持有 `health` 的 watch 锁；`panel()` 在 `RouteVerdict::Tunneled`
分支上做字符串拼接。**任何一个在 `extern "C"` 边界里 panic（macOS 上很可能
涉及系统调用 / FFI）都会产生这条消息，并让 panic hook 拿不到信息。**

**下一步**（在 Windows 或装了 lldb 的 Mac 上）：

```sh
# 抓原生栈——这是唯一能确定的办法，我这个 session 的上下文不够了
lldb -- ./remotecrab --connect 127.0.0.1:9999 --no-tray
# 崩时：bt 40
```

**临时规避**（如果急着验证别的东西）：把那段 route verdict 的探测
`tokio::spawn_blocking` 出去，或在 `Event::State` 分支里先跳过
`set_diagnosis`——诊断面板不是连接的前提。

它会在开始任何真机验证之前就挡住人，所以建议先解决。

### 3.2 需要 Windows 环境

- **代码签名**（采购周期最长，唯一无法用代码解决的事）
- **MSI 构建**（清单已就位，需 WiX v4 + Windows）
- **MSVC 构建**（去掉 GNU 构建的 `libstdc++-6.dll` 依赖）
- 三个新窗口的**排版 / DPI / 字体**——一次都没在 Windows 上打开过
- 20 格托盘图标的**实际观感**

### 3.3 需要真机

- 真 iOS 编码器、摄像头、真通知、真实 WiFi 发现
- **视频编码器画质对比**（Mac VideoToolbox vs Windows OpenH264，从没比过）

### 3.4 明确不做

虚拟麦克风（签名 WDK 驱动）、扩展显示器（WDDM 驱动）、自绘托盘面板、AWDL。

---

## 4. 不需要 iPhone 的测试方式

```sh
# 终端 1
cargo run -p rc-phone-sim -- --port 8765
# 终端 2
remotecrab.exe --connect 127.0.0.1:8765
```

七个场景：`normal` / `pending` / `denied` / `busy` / **`silent`** / `no-token` /
**`drop`**。后两个最值钱——「连上后什么都不发」和「连上就断」这两类故障，
界面看起来完全正常，手测最难抓。

**能证明**：握手、token、metadata、视频解码、ping/RTT、功能开关、重连循环，
以及二进制里所有只在有数据流动时才走的路径。
**不能证明**：真 iOS 编码器、摄像头、真通知、真实 WiFi 发现、真机 UI。

---

## 5. 文档地图

| 文件 | 用途 |
|---|---|
| **`docs/WINDOWS_TODO.md`** | **主清单**——做什么/为什么/怎么验/怎么算做完 |
| **`docs/PROMPT-WINDOWS-SESSION.md`** | 开新 session 时直接粘的 prompt |
| `docs/WINDOWS_HANDOFF_2026-09-30.md` | 背景、架构约束、详细进度 |
| `docs/lessons/windows.md` **95–107** | 本 session 的 13 条经验 |
| `docs/lessons/windows.md` **68** | 连接可靠性的 11 个根因 |

---

## 6. 我在这个 session 里反复犯的错

值得写下来，因为它比任何一条技术结论都更影响你明天的判断：

**我至少六次把「做完了」说得太早，每次都是你对，每��次你都对了。**

根因不是忘了检查，而是**检查的层次错了**：

| 我以为完成了 | 实际是 |
|---|---|
| 「通知中继做完了」 | 有读写、有测试，**但没有任何 UI 能改它** |
| 「文件级对齐做完了」 | 文件都在，**但控件是死的** |
| 「自检做完了」 | 面板在，**但 `session_live` 永远为 false** |
| 「开机自启不撒谎已修」 | 修了存在性，**没修过期路径**——同一个 bug 第二次 |
| 「测试都在跑」 | 两条**在一个平台都跑不到**，其中一条不可能失败 |
| 「死代码为零」 | 14 处 `allow` 压着，**Windows 根本没在审计** |

**教训**：声明完成之前，必须逐个**动作**问「它真的做事吗」，
而不是「它存在且能编译」。文件存在 ≠ 功能可用。

另外两次技术性失误，也记在这里：

- 一个原始字符串少了一个 `"`，导致编译器**第一条错误指向了三行之后的下游症状**。
  第一条错误才是要看的那条。
- 一个测试在源码树里**真的创建了目录** `crates/rc-app/C:\Users\Default\AppData\Roaming`，
  因为回退路径是真实 Windows 路径而 macOS 上 `%APPDATA%` 不存在。

---

## 7. 交接时请带上这句话

> Mac 上能做的全部做完并验证了。**Windows 上能做的已全部写好，
> 但没有一件在 Windows 上跑过**——交叉编译只证明「能编译」，证明不了「能跑」。
> 另有一个既有崩溃（`git stash` 已确认非本次引入）待查。