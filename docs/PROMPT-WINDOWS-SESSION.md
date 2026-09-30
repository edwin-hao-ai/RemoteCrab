> **复制下面全部内容，粘进新 session。**

---

# RemoteCrab Windows 接收端 —— 收尾与发布

你在**一台 Windows 电脑**上，前一个 session 在 Mac 上把 Windows 接收端做到了
「Mac 上能做的全部做完」的位置。剩下的**必须在这台机器上做**。

代码基线：`d5b6ea3`。仓库在 `windows/` 子目录里，是一个独立的 Rust workspace。

## 先读这三份，按顺序

1. **`docs/WINDOWS_TODO.md`** —— 主清单。每一条都有「做什么 / 为什么 / 怎么验证 /
   **怎么算做完**」。从 §2 开始，那是三个上线阻塞。
2. **`docs/lessons/windows.md` 第 95–104 条** —— 前一个 session 踩的十个坑。
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
以及把新踩的坑写进 `docs/lessons/windows.md`（编号接着 104 往下）。
