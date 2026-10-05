# Windows 接收端：待办清单与验证手册

> 最后更新：2026-09-30 晚。代码基线 `baff770`（Windows 测试 385，Core 367，
> Mac↔iPhone 真机 E2E 26/26 绿）。收尾记录见
> [`WINDOWS_SESSION_CLOSEOUT.md`](WINDOWS_SESSION_CLOSEOUT.md)。
>
> 这份文档是**交接给能在 Windows 上操作的人**的。每一条都写清楚：做什么、为什么、
> 怎么验证、以及**怎么才算做完了**。没有真机的部分我不会替它勾。

---

## 0'. ⭐ 不想等 iPhone？用假手机（推荐先跑这个）

> **2026-10-05 Mac session 审计结论：这份清单里剩下的 37 个框，没有一个是 Mac 侧
> 能靠写代码勾掉的。** 逐条看过，三类：
>
> - **采购 / 签名 / 安装包**（§2 的三个上线阻塞）—— 需要买证书和一台干净 Windows 机器
> - **真机验证**（§3，以及 `WINDOWS-GAPS-2026-10-03.md` §5.6 的 10 条）——
>   需要解锁的 iPhone 跑新 iOS build + 这台 Windows 机器
> - **明确不做**（§4，虚拟显示器 / 虚拟麦克风驱动）—— 是决定，不是漏掉的活
>
> **🆕 2026-10-05 新增：电脑在线状态 + 即时连接 + 断开语义 + VPN。**
> 详细步骤、契约、VPN 破解全在 `docs/HANDOFF-WINDOWS-2026-10-05.md` §8–§12。
> 这里只放勾选总览（Mac/iOS 侧已做完的已勾）：
>
> - [x] **§8 presence**：Mac `PresenceAdvertiser` 已合入；iPhone 浏览 + 在线/离线
>       （下一步的 `[ ]` 只在 Windows 侧）
> - [ ] **§8.3** `rc-app` 启动时接一行 `rc_discovery::advertise(..., "windows")`
> - [x] **§9 `off` 应答**：协议值已加（Swift + Rust，含 round-trip 测试）
> - [ ] **§9.3** Windows 给 `off` 专属文案 + 5s 慢重试（当前映射成 `Denied`，已能断开）
> - [x] **§10 knock**：Mac 已监听 8766、iPhone 已会敲门
> - [ ] **§10.2** Windows 监听 8766，收到就「立刻拨回手机」
> - [ ] **§11 VPN**：枚举适配器 + `bind`/`IP_UNICAST_IF` 让拨号出物理网卡
>       （诊断 `route.rs` 已有，能在面板点名网卡）
> - [ ] **§12** 真机全流程验证（在线显示 → 点一下 ~1s → 断开不再自动重连 →
>       重选恢复 → 开 VPN 仍能连）
>
> Mac / iOS 侧被你 10-04 交接的四条**已全部修完**（`6fff9d5` 起），其中一条
> （B 帧）**前提被证伪所以没做**。**`0x25 requestKeyframe` 的发送端早就在
> `rc-app/src/main.rs` 里**——旧文档写「仍然缺」是错的，且因为是一句「没做」的
> 断言，没人会去验证它（lesson 148）。真正缺的是 **Mac 接收端从不发它**，那是
> Mac 侧的事，不是你要做的。
> 见 `docs/HANDOFF-WINDOWS-2026-10-05.md` —— 那是最新的一份，从它开始读。

```sh
# 终端 1 —— 一个假的 iPhone，端口固定
cargo run -p rc-phone-sim -- --port 8765

# 终端 2 —— 你真正要发的那个接收端二进制
remotecrab.exe --connect 127.0.0.1:8765
```

**为什么重要**：测接收端有个无法消除的硬前提——手机得开着、解锁、在推流、
还在同一网络。于是测试只在有人记得跑的时候跑，不在 CI 跑。假手机把这个依赖
从大部分检查上解绑掉了。

**它能证明**：握手、token 交换、metadata、视频解码、ping/RTT、功能开关、
重连循环，以及**二进制里所有只在有数据流动时才走的代码路径**。

**它不能证明**：真 iOS 编码器、摄像头、真通知、真实 WiFi 发现、真机 UI。
这些仍然需要设备。

**七个场景**，让故障可以故意复现而不是等：

| `--scenario` | 复现什么 |
|---|---|
| `normal`（默认） | 正常路径，含真 H.264 视频 |
| `pending` | 手机上的批准卡片 |
| `denied` / `busy` | 被拒绝 / 被别的 Mac 占用 |
| **`silent`** | **连上后什么都不发**——界面看着一切正常 |
| `no-token` | 不发 token（下次连接又要批准） |
| **`drop`** | **连上就断**——重连逻辑 |

`silent` 和 `drop` 最有价值：这两类故障手测最难抓，因为界面完全正常。

其它开关：`--frames N`（收到 N 帧后退出）、`--seconds N`（超时退出）、
`--help`。假手机会打印它看到的每一帧：clientHello（**含对方有没有带 token**）、
ping、featureControl、touch、key、notification、commandResult。

> **2026-10-02 复查：在当前代码上复现不出来。** 跑过的组合全部正常，接收端一直
> 活到被杀为止：
>
> | 场景 | 结果 |
> |---|---|
> | 连一个只 accept 不说话的端口（`--connect 127.0.0.1:9999`） | 干净地 6 s 握手超时循环，不崩 |
> | `rc-phone-sim` 四种握手结果 `normal` / `pending` / `denied` / `busy` | 全部正常，`normal` 走到 `[LIVE] streaming: 1080p` |
> | 带托盘（`tray.set_status` / `set_diagnosis` 那段嫌疑代码会真的执行） | 不崩 |
> | `--no-tray` | 不崩 |
> | panic hook 日志 `%LOCALAPPDATA%\RemoteCrab\RemoteCrab.log` | 只有启动行，**无 panic 记录** |
>
> 所以它要么已被 `baff770` 之后的某个 commit 修掉，要么只在真机 / 真网络上出现。
> **按项目纪律（"prohibited: fixing without a failing test"），在没有复现路径之前
> 不要改那段代码。** 如果你在真机上又撞上，`lldb -- ./target/debug/remotecrab
> --connect 127.0.0.1:9999` 抓 `bt 40` 是唯一能定案的办法。
>
> 顺带记一笔仍然存在的隐患（不是这个崩溃）：`Event::State` 分支里那段
> `health.borrow()` + `doctor::route_verdict(&h)` 是在 async 上下文里做**同步 UDP
> connect**，同时持着 watch 锁。它不崩，但会阻塞 executor 线程。正解是
> `spawn_blocking`。这是独立的一次改动，别和别的混在一起。

---

## 0. 三分钟上手（如果你只有十分钟）

```sh
# 1. 在 Windows 上（不是 Mac！）装 Rust 和 MinGW
#    rustup target add x86_64-pc-windows-msvc   # 正式发布用这个
#    rustup target add x86_64-pc-windows-gnu   # 交叉检查用

# 2. 构建（未签名，仅供本机测试）
cd windows
cargo build --release -p rc-app --target x86_64-pc-windows-msvc

# 3. 跑测试：全部（数字见 §1.1），不需要手机、不需要 Windows
cargo test --workspace
```

跑完全部测试都是绿的，就说明逻辑层没坏。**剩下的全是 Win32 和真机行为**，
那些只能看、不能推断。

---

## 1. 现在的完整状态

### 1.1 能在 Mac 上验证的部分：**全部通过**

| 检查项 | 命令 | 现状 |
|---|---|---|
| macOS 编译 | `cargo build --workspace --all-targets` | 0 error / 0 warning |
| Windows 交叉编译 | `cargo check --workspace --all-targets --target x86_64-pc-windows-gnu` | 0 error / 0 warning |
| clippy（Mac） | `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| clippy（Windows） | `cargo clippy --workspace --all-targets --target x86_64-pc-windows-gnu -- -D warnings` | 0 |
| Windows 测试 | `cargo test --workspace` | **514 通过 / 37 个二进制** |
| Swift 侧 | `./scripts/test.sh` | Core **578**（含 11 条跨实现契约）+ iOS app + Mac app 全通过 |
| 死代码 | Windows 目标下 `never used` | **0**（`notify_relay` 里 14 处 `allow(dead_code)` 已全部改成精确的 `cfg_attr`，Windows 侧现在真的会审计） |

> **2026-10-05 实测过这几个数字，不是抄上一版的。** 上一版这里写的是
> 「385 通过 / 31 个二进制」和「Core 367」——两个都低了 100 以上，而且低得没道理：
> 那是继承来的数字，没人重新数过（AGENTS.md 规则 3）。当前工作树里有另一个 session
> 未提交的 `ApprovalNotificationPolicy` 等测试，所以 **578 含那部分**；
> 只算已提交的内容是 **567**。要引用就写清楚算的是哪一份。

> **`#[cfg(windows)]` 里也有测试，但一个都没有。** 这是本项目的核心验证方式：
> 所有 `Win32` 代码只在 Windows 目标下编译，macOS 上编译不到，所以「macOS 测试全绿」
> **不能**证明 Windows 能跑。交叉编译是唯一的静态保证，而它连运行时行为都证明不了。

### 1.1b 已经在真机上验过的（Mac ↔ iPhone）

`./scripts/e2e-device.sh` 在 iPhone 14 / iOS 26.6.2 上 **26 / 26 全绿**，
含通知中继与点通知切换应用。

**跑之前必须**：

```sh
pkill -f "RemoteCrab.app/Contents/MacOS/RemoteCrab"   # 脚本假设接收端没在跑
./scripts/e2e-device.sh
```

如果你已经手动开着一个接收端，脚本带环境变量的启动就是**空操作**，断言会去读
一个空日志——而 iPhone 其实在正常推流。这会表现成「23 条全红」但 iPhone 侧
日志写着 `sendSessionReply accepted`。**相信 iPhone 的日志，它比断言更有信息量。**

> 这条验证的是 **Mac 接收端 ↔ iPhone**。它对 Windows 接收端**零信息量**——
> 后者在 macOS 上连运行都做不到。

### 1.2 与 Mac 的功能对等（逐文件核对过，不是凭记忆）

| Mac | Windows | 状态 |
|---|---|---|
| `SetupAssistantView`（6 步向导） | `wizard_win`（5 页：欢迎/输入/摄像头/开机自启/完成） | ✅ 完成 |
| `PreferencesView` | `settings_win`（通知/连接/摄像头/画质） | ✅ 完成 |
| `TestWindowView`（四象限） | `selfcheck_win`（摄像头/键盘/触控板/麦克风，200 ms 刷新） | ✅ 完成 |
| `MenuBarMenu` | `tray_menu`（20 行，20 格图标，逐格对照测试） | ✅ 完成 |
| `PreviewWindow` | `rc-render/src/window.rs` | ✅ 完成 |
| `ControlPanelView` | 托盘「连接详情」子菜单（延迟折线+分辨率+码率+最后按键+光标+麦克风） | ⚠️ **读数齐了，缺实时画面** |
| `CameraExtensionCard` | 托盘安装行 + 设置里的状态行 | ✅ 完成 |
| `UpdaterController`（Sparkle） | `update_gate`（空闲门控逻辑已就绪） | ⚠️ **只有门控，无下载/应用** |
| `NotificationCapture` | `rc-notify` + `rc_net::notify` | ✅ 完成 |
| `InstalledAppsCatalog` | ✅ 完成 |
| `WindowCapture` | ✅ 完成 |
| `ScreenStreamer` | ✅ 完成 |
| `StreamRecorder` | ✅ 完成 |
| `SystemCommandHandler` | `rc-os/src/system_keys.rs` | ✅ 完成 |
| `SystemExtensionManager` | `rc-app/src/elevate.rs`（ShellExecuteW + runas） | ✅ 完成 |
| `VirtualDisplay`（扩展显示器） | ❌ 需签名的 IddCx 间接显示驱动 | 见 §4 |
| `RemoteCrabAudioUnit` / `MicRingWriter`（虚拟麦克风） | ❌ 需签名 WDK 驱动 | 见 §4 |

---

## 2. 🔴 阻塞上线的三件事（必须先做）

### 2.1 代码签名 —— **采购周期最长，第一件事启动**

**为什么必须签**：这个程序往**所有进程**注入输入（键盘+鼠标）、写 HKLM 注册 COM
组件、在全局创建一个虚拟摄像头。这个行为组合正好是 SmartScreen 和杀毒软件最不待见的
画像——不签名的版本大概率被杀软直接隔离，用户连"打开看看为什么被拦"都做不到。

**要签两个文件，不是一个**：

| 文件 | 为什么 |
|---|---|
| `remotecrab.exe` | 主程序 |
| `rc_vcam_source.dll` | COM in-process server，Frame Server（以 LocalService 运行）加载它。**Windows 会单独对它显示发布者提示**——用户会看到"未知发布者"，即使 exe 已签。而且一个未签名的 DLL 躺在已签名的 exe 旁边，杀软会当成篡改证据。 |

**操作**：

```sh
# 1. 买证书（这一步无法在代码里完成）
#    ⚠️ CA/Browser Forum 2023 的 HSM 规则：便宜的 OV 证书已经没有了。
#    问销售时要确认包含 Code Signing EKU。

# 2. 导入 + 签名（脚本会验签）
export RC_CERT_SHA1=<证书指纹>
export RC_CERT_PFX=cert.pfx          # 可选
export RC_CERT_PASS=<密码>            # 用 PFX 时需要
scripts/release-windows.sh sign
```

**怎么算做完**：`scripts/release-windows.sh verify` 输出里 exe 和 dll 都是 `signed`。
然后在**一台干净的 Windows 机器**上运行，确认没有 SmartScreen 弹窗。

**证书没到手之前的临时方案**：`cargo build --release`（不带签名）只能你自己本机测试用，
不要发给别人。

### 2.2 安装包（MSI）—— **不是可选项**

**为什么"绿色版 zip"会让虚拟摄像头静默失效**：

`rc-vcam` 把 DLL 路径按 `current_exe()` 解析，然后把这个**绝对路径**写进
`HKLM\Software\Classes\CLSID\{…}\InprocServer32`，之后每次启动都做**精确字符串比较**。

所以用户一旦移动了文件夹、或者从 `D:\` 复制到 `C:\`：

```
注册表里的路径：D:\RemoteCrab\rc_vcam_source.dll
实际找的文件：C:\RemoteCrab\rc_vcam_source.dll
→ 不匹配 → COM 服务器激活失败 → 相机应用里看不到「RemoteCrab Camera」
→ 而且没有任何错误提示
```

唯一的修复方式是**再提权写一次注册表**。用户不会知道要这么做。

**操作**：

```sh
# 需要 WiX Toolset v4+
dotnet tool install --global wix
export RC_CERT_SHA1=<证书指纹>
scripts/release-windows.sh package
# → dist/RemoteCrab-1.0.0.msi
```

清单在 `windows/tools/RemoteCrab.wxs`，安装目录**硬编码**为 `C:\Program Files\RemoteCrab\`，
理由就是上面那条路径比较。

**怎么算做完**：在一台干净 VM 上装 → 确认无 SmartScreen → 运行
`scripts/check-windows-deps.sh "C:\Program Files\RemoteCrab\remotecrab.exe"` 输出 `OK`。

### 2.3 MSVC 构建 —— ✅ 已通（2026-10-02）

**结论先说**：MSVC 目标现在能构建、能跑，且**没有任何纯净 Windows 没有的依赖**。

**曾经为什么不通**：`rc-app/build.rs` 断言 `winres` 留下 `resource.o`，而微软的
`rc.exe` 出的是 `resource.lib`（它自己 `/fo` 指定的）。所以一切到 MSVC 目标就
直接 panic：`winres reported success but ...\resource.o is missing`。
那个 panic 是护栏在正常工作 —— 只是护栏只认识一种工具链的产物。
现在按 target env 区分文件名（`resource_artifact()`），并且只给 GNU 补
`rustc-link-arg`（`link.exe` 本来就会收 `winres` 要求的 resource 库，补两次
会出现两个 `.rsrc` 段）。

**换工具链本身并不能消除外部依赖**，这是原来写错的另一半。实测：

```
换成 MSVC、没开 crt-static：        26 imports   MISSING VCRUNTIME140.dll
再开 -C target-feature=+crt-static： 19 imports   OK
```

`vcruntime140.dll` **不是** Windows 自带的（它随 VC++ 重分发包来），所以不开
静态 CRT 的 MSVC 构建在干净机器上照样起不来 —— 和 GNU 缺 `libstdc++-6.dll`
是同一类问题。`windows/.cargo/config.toml` 只对 MSVC 目标加 `crt-static`
（用 `[build] rustflags` 会连 build script 一起改，而 build script 是按 host
编译的）。

**怎么验（这台机器上已通过）**：

```sh
export RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-msvc
cargo build --release -p rc-app
scripts/check-windows-deps.sh windows/target/release/remotecrab.exe   # → OK
```

`.rsrc` 段与 `FileVersion` / `ProductVersion` / `Beijing VGO Co.,Ltd` / `1.0.0.0`
都已在 exe 里核对过 —— 这个必须用 `dumpbin` 看，`build.rs` 自己的注释就写了
「nothing warns about this」。

> ⚠️ **这台机器的 host 工具链**：`x86_64-pc-windows-gnu` 的 host **完全无法链接**。
> 它自带的 `dlltool.exe` 能启动，但每次真正干活都失败并报 `CreateProcess`，于是
> 每一个链接步骤都死。1.98.0 与 1.99.0 表现一致，Defender 的 ASR/CFA 全关，也没有
> 第三方杀软。**根因尚未定位。** 目前用用户级
> `RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-msvc` 绕开（本机装有 VS Build Tools
> 2022 + SDK 10.0.26100）。注意 `rust-toolchain.toml` 会覆盖 `rustup default`，
> 所以必须用环境变量，`rustup default` 无效。

> ⚠️ `check-windows-deps.sh` 之前在 Windows 上**根本跑不了**（只认
> `x86_64-w64-mingw32-objdump` / `llvm-objdump`）—— 决定「能不能发布」的那道判据
> 只能在 Mac 上跑。现在它通过 `vswhere` 找 `dumpbin`。而且它解析到 0 个 DLL 时
> **不再报 OK**：Git-Bash 会把 `/dependents` 改写成路径，脚本读到 0 条曾经被当成
> 「干净无依赖」。

---

## 3. 🟠 真机验证清单（代码没错，但没人亲眼看过）

按**价值排序**——从下往上做，前面的失败会掩盖后面的。

### 3.1 托盘图标实际观感（20 格）

**背景**：托盘图标是 `windows/assets/menu-icons.png`，由
`scripts/generate-windows-menu-icons.py` 生成，Rust 侧 `tray_menu::icon_cell` 决定
"第几格"。两者有**自动对照测试**（`the_generator_and_the_rust_map_agree_cell_for_cell`
用 `include_str!` 直接读生成器脚本逐格比对），所以**格子号一定对**。

**没验证的是**：16×16 单色在实际菜单里看起来是否清楚。

```sh
python3 scripts/generate-windows-menu-icons.py
# 对着 windows/assets/menu-icons.png 逐格看
```

**要看的**：

| 格 | 用途 | 容易混淆于 |
|---|---|---|
| 0 | 摄像头 | — |
| 1 | 麦克风 | 喇叭 |
| 4 | 切换前后摄像头 | 摄像头（同一行区） |
| 5 / 14 | 录制中 / 停止 | — |
| 9 | 诊断 | 问号 |
| 15 | 安装虚拟摄像头 | 摄像头 + 「切换」 |
| 16 | 通知中继 | 铃铛 |
| 17 | 设置向导 | 扳手 |
| 18 | 设置 | 齿轮 |
| 19 | 自检 | — |

**发现图标问题时的正确做法**：改 `scripts/generate-windows-menu-icons.py`，
**不要**改 Rust 的格子号。对照测试会立刻发现不一致。

### 3.2 UAC 提权流程（虚拟摄像头安装）

这是本轮改动最大的用户可见流程，**一次都没在真机上跑过**。

```sh
# 1. 首次启动会自动弹出 5 页向导，走到「虚拟摄像头」页
# 2. 点「安装虚拟摄像头」→ 应该弹 UAC
# 3. 允许 → 提权副本注册完退出 → 回到普通实例
# 4. 下次打开托盘菜单，「安装虚拟摄像头」这一行应该消失了
```

**要确认的**：

- [ ] UAC 弹窗**确实出现**，标题是 remotecrab 相关的
- [ ] 允许后 tray 里的安装行**消失**（`is_registered()` 每次重建菜单时重读）
- [ ] **点「取消」** → 弹出的是中文句子「你取消了管理员提示，所以虚拟摄像头还没有安装。
      需要时再点这里。」，**不是**错误弹窗，且那一行**还在**
- [ ] 组策略禁止 UAC 的机器 → 报错并给出「请让管理员运行一次
      remotecrab.exe --install-vcam」
- [ ] 相机应用 / Zoom / OBS 里能看到「RemoteCrab Camera」并能出画面
- [ ] 安装路径含空格（`C:\Program Files\`）时也能工作——
      `elevate.rs` 的 `quote_arg` 对尾随反斜杠做了处理并有测试，
      但 `ShellExecuteW` 本身在 macOS 上跑不到

### 3.3 卸载

```sh
remotecrab.exe --uninstall-vcam    # 需管理员
```

**要确认的**：

- [ ] `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\RemoteCrab` 被删
- [ ] `%APPDATA%\RemoteCrab\` 被删
- [ ] `HKLM\Software\Classes\CLSID\{9D4B0D4D-1D2A-4B3E-9C0A-7F6E5D4C3B2A}` 被删
      （**注意**：安装清单 `RemoteCrab.wxs` 之前写的是 `{8B2C4D19-…}` —— 那个 GUID
      在整个产品里根本不存在，所以卸载清的是一个空键，真正的摄像头注册会留在原地。
      2026-10-02 已改为 `rc_vcam::win::SOURCE_CLSID`，两处同步）
- [x] **`%ProgramData%\RemoteCrab\vcam-ring.bin` 被删** ← 这条最容易失败
- [ ] **跑第二次不算失败**（幂等）

> **ring 文件为什么最容易漏**：它带 **NULL DACL**，这样 Frame Server（以
> `LocalService` 运行）才能映射它。副作用是**普通用户删不掉它**。之前的卸载一个都不清，
> 于是它留在系统里——一个任何人可写的缓冲区，而且下次安装会继承里面的内容。
> 这是唯一能证明那段代码不是纸上谈兵的地方。

#### ✅ 2026-10-03 在真机上跑通了（`6031a5f` 之后）

上面 8 条**全部通过**，方式是 `msiexec /i` → 装完开一次自启（否则「Run 项被删」
那条没东西可删）→ `msiexec /x` → 逐条查。

**但第一次跑的时候挂了 2 条**，而且都不是清单猜的那个：

| 失败项 | 真相 |
|---|---|
| `HKCU\...\Run\RemoteCrab` 没被删 | MSI 的 `RemoveRegistry` 表里**确实有**这一行（`CleanupMarker \| 1 \| …\Run \| RemoteCrab`），**但没生效**。结果是指着一个已不存在的 exe，每次开机都试图启动一个不存在的程序 |
| `%APPDATA%\RemoteCrab\` 没被删 | 里面有 **`tokens.json` —— 配对令牌**。MSI **从来没清过**。卸载后把配对令牌留在磁盘上，比留个日志严重 |
| （附带）`%ProgramData%\RemoteCrab\` 空目录残留 | ring 文件删掉了，目录没删。空目录让下次安装以为「还有东西没卸干净」 |

根因是同一个：**per-user 清理逻辑写在 app 里（`rc_os::uninstall::remove_user_state`
一直都在，自带测试），但安装器从来没调用它**，而是用一条 `RemoveRegistry` 行顶替，
那条行不工作。

修法不是把 `RemoveRegistry` 调对，是**让安装器调用产品自己的清理**——三个 flag：

| flag | 谁调 | 清什么 | 提权 |
|---|---|---|---|
| `--uninstall-vcam-user` | MSI（**模拟用户**） | 自启项 + `%APPDATA%` | 不要 |
| `--uninstall-vcam-machine` | MSI（SYSTEM） | CLSID + ring 文件 + ProgramData 目录 | 已经提权 |
| `--uninstall-vcam` | 人 / 托盘 | 上面两半 | 需要就自己弹 |

**模拟用户那一步是全部重点**：提权安装里 `%APPDATA%` 和 `HKCU` 指向**系统 profile**，
在 SYSTEM 下跑完整卸载会清错 hive，用户的令牌每次卸载都留下来。已验证 MSI 里两个
action 的 Type 位：`UninstallUserState` = 1122（**不含** `0x800` NoImpersonate）、
`UninstallMachineState` = 3170（含该位）。

**仍然保留**：`%LOCALAPPDATA%\RemoteCrab\RemoteCrab.log`。这是**有意的** —— 出问题后
用户能直接把日志发出来。但它确实意味着「卸载 ≠ 磁盘上零字节」，如果将来要承诺完全
清除，得显式处理，别让它是漏的。

### 3.4 通知中继（0x22）

**背景**：Windows 端用 WinRT `UserNotificationListener`，**轮询**而非订阅
（`windows` crate 0.62 没有投影 `NotificationPosted` 事件）。去重用 `SeenSet` 按 id，
因为 API 返回的是**快照**不是增量——不重会每 2 秒重发一遍所有通知。

```sh
# 托盘 → 通知中继：开（Windows 会问一次通知权限）
# 然后在另一台设备上发通知
```

**要确认的**：

- [ ] Windows 弹出通知访问权限请求，允许后**中继才开始工作**
- [ ] 普通应用的通知**出现在手机的通知列表里**
- [ ] **同一个通知不会每 2 秒重复一次**（这是 `SeenSet` 的存在理由）
- [ ] 拒绝列表里的应用**不转发**（设置 → 通知 → 添加 "1Password" 试）
- [ ] **AppInfo 取不到显示名的通知被丢弃**（fail closed——这是隐私规则，不是 bug）
- [ ] 关掉中继后，即使有通知在途中也会被丢弃

### 3.5 首次运行向导与设置窗口

> 审计时在这里抓到两个**只有真机才会暴露**的 bug，都已修：
> 向导的动作按钮用 `take()` 取走了闭包，所以**只能点一次**——用户取消 UAC 后
> 按自己看到的提示再点，什么都不会发生；现在跑两次都有效，且有测试。
> 设置窗口的摄像头那一行**只有文字没有按钮**（分发分支读了状态就丢掉，
> 也没有任何控件用那个 ID）——现在未注册时会出现「安装虚拟摄像头」按钮，
> 走的是和向导、托盘**同一条** `install_with_elevation()`。

- [ ] **首次启动自动弹出**向导（只弹一次，`%APPDATA%\RemoteCrab\wizard-seen`）
- [ ] 「下一步」在**未完成必做步骤时是禁用的**（摄像头没注册 → 灰色）
- [ ] 「上一步」在第一页禁用
- [ ] 设置窗口：拒绝列表**添加/移除**，空和重复被拒绝并给双语原因
- [ ] 设置窗口：**忘记这台电脑**后列表里消失，且下次连接手机会要求重新配对
- [ ] 设置窗口：画质切换后**重连时生效**（当前只写入文件）

### 3.6 四象限自检面板

**为什么在 Windows 上比 Mac 更该有**：输入注入**完全不留痕迹**。
一个键发出去了、一个点击落地了、手势滚动了——用户在另一个没在看的窗口上什么都看不到。

- [ ] 没连接手机时，四个象限都是**「等待」**（不是红色！）
- [ ] 摄像头关掉时是「等待」；**推流中途停止**时是「异常」← 这两者的区分是它的核心价值
- [ ] 键盘象限**逐字显示**最后按下的键
- [ ] 触控板象限显示**手势类型**（drag / scroll / pinch / right down）+ 修饰键
- [ ] 麦克风电平表在 0 时是「等待」不是「异常」

> 已知不足：象限用文字标记（`!`）而不是颜色。Win32 给静态文本上色要么子类化控件
> 要么自绘，对四个词来说都不值。"等待不上色"这条规则仍是测试。

### 3.7 连接可靠性（回归验证）

这些在 2026-09-29 定位过 11 个根因并修完，**全部只做过交叉编译验证**。

对着手机按顺序试：

- [ ] 首次连接 → 手机上批准 → **第二次连接不再要求批准**（token 持久化）
- [ ] 手机改名后再连，token 跟着走（IP→名字映射）
- [ ] 手机不在同一网段但直连可达 → 自动 fallback
- [ ] iPhone 开热点（Personal Hotspot）→ **Bonjour 会失效**，用直连路径
- [ ] 同时两台 Mac 抢同一个 iPhone → 后来的收到 `busy`，先停 3 秒重试循环
- [ ] 「显示桌面」按**第二次**——应该**没有反应**（幂等，不是 Win+D 开关）

### 3.8 视频编码器画质对比（**从没做过**）

Mac 用 **VideoToolbox**，Windows 用 **OpenH264**（passthrough）。两个编码器的
码率控制、色彩空间、GOP 结构都不一样，而**发布前从来没有在真机上比过**。

**建议做一次**：同一场景录 60 秒，同一个播放器播，比：

- [ ] 1080p30 下的**实际码率**（托盘详情里能看）
- [ ] 快速运动画面的**块效应 / 涂抹**
- [ ] 暗部细节
- [ ] 音频-视频**不同步**

**如果差异明显**，需要决定：调整 `metadata` 里的目标码率？换编码器？
这一项我无法代做，也不该替你决定。

### 3.9 自适应更新

`rc_net::update_gate` 已就绪并有 9 条测试（比 Mac 的 `UpdateInstallGate` 多一个
条件：**输入注入后 3 秒内不更新**，因为拖拽中途重启会留下逻辑上仍按下的鼠标键）。

**没有的**：下载、校验、替换、卸载旧的、per-machine 升级。这需要：
签名 + appcast 服务器 + Windows 工具链。**这是最后一个大功能**，建议先跑通 1-2 个月。

### 3.10 ✅ 扬声器模式（用 iPhone 当音箱）—— 采集已实现并在本机验证

`rc-loopback`（WASAPI loopback）+ `rc-app/src/speaker.rs` 已落地，493 个测试绿，
`clippy -D warnings` 全绿，MSVC release + 依赖检查都过。

**先跑这一条** —— 唯一能回答「loopback 在这台机器上听不听得到东西」的命令，
它属于 release build，不需要 `--features selftest`：

```powershell
# 随便放点声音，然后：
.\target\release\remotecrab.exe --speaker-probe
```

本机 2026-10-04 的实测输出：

```
  mix format     : F32 48000 Hz, 2 ch
  endpoint       : {0.0.0.00000000}.{64c98063-2154-46ce-8519-8420311959e7}
  captured       : 153600 frames (3.20 s)
  packets        : 125 in the 2.5s window (480000 bytes of PCM)
  level          : rms=497 peak=1100
  dropped        : 0 frames
```

**还差的**：🔲 **iPhone ↔ Windows 的端到端**（采集侧已验证，`0x24` 的线路还没跑过）。
连上手机后开扬声器，确认手机出声，并且托盘没有出现「扬声器」那一行的报错。

**iOS 端的入口还锁着**（`ContentView.swift:759` 的 `speakerAvailable`），
因为 Mac session 要先修一个会在 Windows 上把麦克风静默关掉的 bug ——
见 [`HANDOFF-IOS-QUALITY.md`](HANDOFF-IOS-QUALITY.md) §6.1。
**在那之前不要删那一行**，否则会得到一个点不掉的扬声器开关。

细节、途中被测试抓到的四个 bug、以及「静音本机」为什么默认关着：
[`WINDOWS-SPEAKER-2026-10-04.md`](WINDOWS-SPEAKER-2026-10-04.md)。

---

## 4. ❌ 明确不做（别浪费时间）

| 功能 | 为什么 | 替代 |
|---|---|---|
| **虚拟麦克风** | 需**签名的 WDK 驱动**（`MakeAuth`），3-6 天 + 签名。**未签名驱动会直接毁掉 §2.1 代码签名的意义**——用户在杀软里看到一个未签名驱动，整个产品的信誉都没了 | 语音功能先用 `--unmute` |
| **扩展显示器**（iPhone 当第二屏） | 需签名的 **IddCx** 间接显示驱动。是**用户态 UMDF**（不是内核态 WDDM），但仍要签名、仍要装成一个设备，且 IddCx 把桌面图像以 DirectX surface 交给驱动并**禁用 GDI / 窗口 API**，所以 Mac 那套「把已有镜像指过去」不能照搬 | 镜像功能已有；**iPhone 端已按 `platform` 隐藏这一项**（`ContentView.swift:766`），不会给用户一个点了没反应的按钮 |
| **自绘托盘面板** | 原生 `TrackPopupMenu` 的**内容**已与 Mac 对齐且有 23 条布局测试，纯视觉打磨 | — |
| **AWDL**（无 WiFi 直连） | Apple 私有，Windows 不可能有 | iPhone 热点 / USB 网卡共享 |
| **`IP_UNICAST_IF` 绕过 TUN** | 在这台 Mac 上**无法验证字节序**（Windows 用反序）。猜着上会静默失败 | 走 mDNS + 直连 fallback |

---

## 5. 交接时最容易忽略的五个坑

### 5.1 Windows 目标和 macOS 编译出来的**不是同一个东西**

`cargo check --target x86_64-pc-windows-gnu` 只保证**能编译**，不保证**能跑**。
macOS 上全部测试全绿，也不代表 Win32 那部分对。AGENTS.md 的核心规则：
改了 `#[cfg(windows)]` 里的代码，交叉编译是唯一保证，而它连运行时都证明不了。

### 5.2 `rc-os` 的 `windows` 依赖**必须** target 化

`windows` crate **无条件**依赖 `windows-future`，而后者用了 `windows-core` 的
私有 marshalling 内部符号（`IMarshal`），**在非 Windows 上根本编译不过**。

之前一直没暴露，是因为没有任何 crate 启用 WinRT 特性去激活那条编译路径。
2026-09-30 加通知中继时一启用，整个 macOS 测试立刻炸掉。

**所以**：任何要用 WinRT 的 crate，必须**独立成 crate**（`rc-notify` 就是为此存在），
仅仅在模块上写 `#[cfg(windows)]` 是不够的——Cargo 会跨 workspace 统一 feature。

### 5.3 托盘图标顺序是**承重**的

`menu-icons.png` 由 Python 生成，格子号由 Rust 决定。这两边曾各自改过，
结果从第 4 格起**每一行的图标都是错的**（摄像头行画着切换图标的图标，
退出行画着停止的方块），而且当时**没有任何测试失败**——因为旧测试只检查
"格子号在范围内"，错位一格的格子号同样在范围内。

现在有 `the_generator_and_the_rust_map_agree_cell_for_cell` 用 `include_str!`
**直接读生成器脚本**逐格比对。改图标请改生成器。

### 5.4 `#[cfg(windows)]` 里的测试等于不存在

2026-09-30 有两条测试是 `#[cfg(windows)]` 的，也就是说**在能跑测试的机器上一个都跑不到**。
其中一条"通过"是因为它读回了默认值——**一个不可能失败的测试比没有测试更糟**。

现在的纪律：**逻辑测试必须任何平台可跑**，平台特有的部分靠注入路径而不是靠 `cfg`。

### 5.5 别用 `allow(dead_code)` 压警告

`notify_relay.rs` 曾经有 **14 处** `allow(dead_code)`。现在全部改成精确的
`#[cfg_attr(not(windows), allow(dead_code))]`——这样 **Windows 目标下
Dead code 检查真的会跑**，加一个没人用的函数会被发现。

---

## 6. 反馈格式

Windows 上遇到问题时，请提供：

```
版本：              remotecrab --version
构建目标：          MSVC / GNU
是否已签名：         是 / 否
系统版本：           winver 的输出
tracer：            %LOCALAPPDATA%\RemoteCrab\RemoteCrab.log（崩溃时）
托盘状态行原文：     （照抄，不要转述）
手机端行为：         什么发生了 / 什么应该发生
是否可复现：         N 次中出现 M 次
```

日志路径由 `rc-app/src/diagnostics.rs` 的 panic hook 写入，装配路径已从
「崩溃无声」变成「崩溃留痕」。

---

## 7. 相关文档

| 文件 | 内容 |
|---|---|
| `windows/README.md` | 构建与命令参考 |
| `docs/superpowers/specs/2026-09-29-windows-connection-reliability-design.md` | 连接可靠性的 11 个根因分析 |
| `docs/WINDOWS_VERIFY_2026-09-30.md` | 逐条验证清单（本文件的精简版） |
| `windows/tools/RemoteCrab.wxs` | WiX 安装清单（含安装目录硬编码的理由） |
| `scripts/check-windows-deps.sh` | 运行时 DLL 依赖检查（发布前的判据） |
| `scripts/release-windows.sh` | 构建 / 依赖 / 签名 / 打包 / 验证 |
| `docs/lessons/windows.md` | Windows 特有的坑（**第 95–104 条是上一个 session 踩的**） |
| `docs/PROMPT-WINDOWS-SESSION.md` | 在 Windows 上开新 session 时用的 prompt |
