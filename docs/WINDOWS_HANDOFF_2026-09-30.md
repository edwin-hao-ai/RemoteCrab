# Windows 交接清单

给「在 Windows 那台电脑上干活的人」。写给一个不了解历史、只知道
"RemoteCrab 的 Windows 端在这个仓库的 `windows/`" 的人。

日期：2026-09-30 · 对应代码状态：`main` @ 本文件提交时

---

## 0. 三分钟上手

```powershell
cd <仓库>\windows
cargo test --workspace          # 31 个测试二进制，不需要手机
cargo clippy --workspace --all-targets -- -D warnings
cargo build --release
.\target\release\remotecrab.exe
```

**在 Mac 上开发时的额外能力**（不要浪费）：

```bash
cd windows
cargo test --workspace                                              # 全部测试，不需要 Windows
cargo clippy --workspace --all-targets                              # 0 warning
cargo clippy --workspace --all-targets --target x86_64-pc-windows-gnu  # 交叉检查所有 cfg(windows) 代码
```

交叉检查需要 `brew install mingw-w64` + `rustup target add x86_64-pc-windows-gnu`。
**`cfg(windows)` 里那些 Win32 代码，macOS 的 `cargo test` 是编译不到的**——交叉检查是唯一的
静态验证手段（AGENTS.md lesson 68 记录过一个 `TerminateProcess(...).as_bool()` 的类型错误
就是这样溜过去的）。所以：**改完必须两个都跑。**

`rc-app` 特意做成能在 macOS 上编译并跑测试（41 个），所以托盘菜单、doctor 文案、
help 结构都可以直接在这边验证，不用等 Windows。

---

## 1. 这套代码现在是什么状态

**能用的**：连接（Bonjour + 直连兜底 + /24 扫描）、H.264 预览、触控板、键盘、
音频播放、录制（mp4 + wav）、剪贴板双向、应用切换/窗口列表/缩略图、启动器、
应用窗口投屏、虚拟摄像头（Windows 11 22H2+）、托盘、控制台命令、`--doctor` 诊断。

**还不能用的**（按影响排序）：

| 缺口 | 现状 | 影响的用户 |
|---|---|---|
| 没有安装包 | 用户要自己装 Rust 工具链 + `cargo run` | 🔴 所有人 |
| 没有代码签名 | 未签名，SmartScreen 会拦 | 🔴 所有人 |
| 没有自动更新 | 版本号永远是 0.1.0，用户无法升级 | 🔴 所有人 |
| 崩溃无可见性 | 没有 panic hook、没有日志文件 | 🔴 所有人 |
| 虚拟麦克风 | 不存在 | 🟠 用语音的人 |
| 通知中继（0x22） | 帧认得，直接丢弃 | 🟠 |
| 扩展显示器 | `.extend` 回「不支持」 | 🟠 |
| 亮度调节 | 0x19 的亮度命令直接返回 false | 🟢 |

**功能对等**（Mac 有 / Windows 没有）：控制面板、连接自检窗口、首次运行向导、
偏好设置、菜单栏实时预览、设备选择器、通知中继、虚拟麦克风、自动更新。
Windows 独有、**Mac 反而没有**的：诊断面板、`--scan`、`/24` 扫描、四个离线自检。

⚠️ `docs/WINDOWS_HANDOFF.md` 里的测试数量（153 / 166 / 207）和
`windows/README.md` 里「Not yet implemented: virtual camera, tray UI」都已经过期。

---

## 2. 上次会话做了什么（2026-09-30）

一整轮根因调查 + 修复，**11 个根因**，详见
`docs/superpowers/specs/2026-09-29-windows-connection-reliability-design.md`。

最严重的三个，如果你在旧代码上看到奇怪的东西，先看这里：

1. **托盘菜单曾经完全点不动。** `750790a` 把菜单行换成了共享模型的
   `tray_menu::ids`（100+），而点击分发还在匹配一套私有的 `Ids`（1..14），两套编号
   零重叠 → 每个点击都落进 `_ => None`。现在只有一套表，外加
   `tray_menu::known_ids()` + 一条测试 + 一个 `debug_assert!`。

2. **ping 被当成自己的回显。** `now - sent` 在两台机器之间算出来的是**时钟差**，
   不是往返延迟。两端现在都会主动发探测（iOS 那个 build 已经在测了），所以
   **对着 Windows 接收端时，手机上的延迟读数永远是空的，而 Windows 托盘会显示
   两台机器的时钟差**（可能是几小时）。现在是 `rc-net/src/ping.rs` 的 `PingProbe`
   判定归属，不是自己的就原样回送。

3. **触控板的修饰键被整个丢掉。** `TouchEvent.modifiers` 在 `rc-input` 里
   没有任何地方读过。⇧-点击、⌥-拖拽在 Windows 上全都变成了无修饰的点击/拖拽
   ——也就是**每一次选择文本、每一次"拖走这个窗口"都是错的**。现在翻译层发出
   `MouseAction::ModifierKeys`，由 `send_vk` 真正按住。

### ⭐ 一条给未来的教训

`link_loss_reconnects_on_its_own` 这个测试**曾经是通过的，但它测的不是它声称的东西**。
`ConnEndKind::Lost` 里有一句 `target = None`，而 `Action::Reconnect` 是
`if let Some(t) = target.clone()` 才拨号——所以"第一次失败就清目标"等于**悄悄关掉了
重连**。测试之所以还绿，是因为它当时走的是**兜底路径**救回来的。

后来我们正确地拒绝把 `127.0.0.1` 持久化成手机地址（见下面 lesson 83 那条），
兜底没了候选，**真正的 bug 才暴露**。

所以那条测试现在 30 秒预算，而且**故意让兜底救不了它**。如果你想"顺手"让环回地址
重新可持久化，请先读那段注释。

---

## 3. 立刻能做的事（不需要等 Windows）

按性价比排序。**每一项都请先写测试。**

### A. 修 Mac 有、Windows 没有的（功能对等）

- [ ] **控制面板**（Mac 的 `ControlPanelView.swift`）：实时延迟折线、分辨率、码率、
      功能徽章。Windows 现在只有控制台计数器。
- [ ] **连接自检窗口**（Mac 的 `TestWindowView.swift`）：四象限实时反馈
      （摄像头 / 键盘回显 / 触控板轨迹 / 麦克风电平）。这个在 Windows 上价值更高——
      因为触控板刚修好修饰键，没有实时反馈用户根本不知道按键有没有生效。
- [ ] **首次运行向导**（Mac 的 `SetupAssistantView.swift`）：系统版本检查 →
      虚拟摄像头可用性 + 提权 → 「打开 iPhone app 点开始推流」→ 开机自启。
- [ ] **实时输入反馈**：Mac 把 `typedText` / `lastKey` / `touchVisual` / `micLevel`
      镜像到自检窗口，Windows 完全没有。至少做 `typedText`。
- [ ] **`voice` 的托盘开关**：Mac 的菜单栏**根本没有** voice 开关（只有控制台有），
      这是 Mac 的缺口，Windows 反而有。顺手把 Mac 补上。

### B. 修行为不一致的

- [ ] **`quitApp` 应该是优雅优先**。Mac 先 `terminate()`、失败才 `forceTerminate`
      （`ReceiverSession.swift:519`）。Windows 无条件 `TerminateProcess`
      （`rc-os/src/apps.rs:153`），`force` 标志被忽略。用户点了「退出应用」就可能被
      强杀，未保存的东西没了。
- [ ] **`capitalize` 两端不一致**。Swift 的 `String.capitalized` 会在标点处断词，
      Rust 版只按空白切。`"hello-world"` → Mac 给 `Hello-World`，Windows 给
      `Hello-world`。
- [ ] **`--record` 会自动开录**（`main.rs:369` 收到第一个 metadata 就自动 arm），
      Mac 必须显式点。用户以为只是打开托盘，结果开始录了。
- [ ] **托盘缺「切换摄像头」行**（Mac 有 `MenuBarMenu.swift:385`）。
- [ ] **`showDesktop` = Win+D 是个开关**，按第二次会还原。配合「没有桌面回退」，
      用户在投屏时点「显示桌面」会得到一个黑屏。Mac 那边是单向隐藏。
- [ ] **窗口列表用 `activateApp` 之后不刷新**（`main.rs:550`），Mac 会刷新
      （`:473`/`:518`）。手机的列表会过期。
- [ ] **窗口列表缺 app 级合并**：最小化/隐藏的应用整个消失
      （Mac 的 `WindowCapture.swift:128` 有合并）。缩略图 480px vs Mac 的 960px。
- [ ] **`canCapture` 硬编码 true**，应该如实报告降级模式。

### C. 发布就绪（🔴 阻塞项，Windows 才能做）

- [ ] **代码签名**：Authenticode，**`remotecrab.exe` 和 `rc_vcam_source.dll` 都要签**。
      这个 app 会往所有进程注入输入 + 写 HKLM 注册 COM，正好是 SmartScreen 和
      杀软最不待见的画像。**证书采购周期最长，先启动。**
      注意 CA/Browser Forum 2023 的 HSM 规则，便宜的 OV 证书已经没有了。
- [ ] **安装包**：MSI/MSIX，装到 `C:\Program Files\RemoteCrab\`。
      ⚠️ **这不是可选项**：`rc-vcam/src/win.rs:38-56` 把 DLL 路径按
      `current_exe()` 解析，`win.rs:133` 把**绝对路径**写进 HKLM 并做精确比较
      （`win.rs:75-79`）。所以一个"绿色版 zip"会让虚拟摄像头**静默失效**，
      而且修复需要再来一次提权写入。
- [ ] **提权路径**：现在 `rc-app/src/vcam.rs:25` 启动就调 `install_source()`，
      写 HKLM 要管理员。报错让用户「以管理员运行一次」——但唯一的办法是自己用
      Cargo 编一个**第二个二进制** `rc-vcam.exe`。**装好机器的用户没有这条路。**
      需要 `ShellExecuteW` 带 `runas` 自提权。
- [ ] **panic hook + 日志文件**：`windows/crates/` 里 `set_hook` 和 `catch_unwind`
      都是**零**。托盘线程 panic 的后果是：消息泵停了 → 窗口没销毁 → Explorer
      继续显示图标 → 命令通道永不关闭 → 用户看到一个**点不动、状态还停在
      `[LIVE]` 的图标**。对一个"远程操控你整台电脑"的产品，这是最坏的失败形态。
      最小可行：`std::panic::set_hook` 写 `%LOCALAPPDATA%\RemoteCrab\RemoteCrab.log`
      并限大小。
- [ ] **单实例**：`CreateMutexW`。现在双击两次就有两个接收端抢同一个 iPhone，
      两个托盘图标。
- [ ] **开机自启会撒谎**：`rc-os/src/autostart.rs:35-38` 把**当前 exe 路径**写进
      Run 键。没有安装器时用户很可能把 exe 挪走或删掉 → Run 键指向空 → 再也不自启，
      但托盘勾仍然读注册表（`:41-56`）所以**菜单坚称已开启**。这是 AGENTS.md
      lesson 87「过期的绿勾」在另一个子系统里重演。
- [ ] **卸载**：清 `HKCU\…\Run`、`%APPDATA%\RemoteCrab\`、
      `%ProgramData%\RemoteCrab\vcam-ring.bin`（注意它带 **NULL DACL**，
      `shm.rs:37-43`）、HKLM CLSID。现在**一个都不清**。
- [ ] **版本纪律 + 更新**：`windows/Cargo.toml:26` 的 `0.1.0` 从 scaffold 起
      **一次没改过**。没有 `--version`、没有 PE version resource（Explorer 里
      没图标没版本号）、没有 `rust-toolchain.toml`、没有更新机制。
      Sparkle 的**空闲门控**逻辑（不打断正在用的会话）就是该抄的模板。
- [ ] **检查 MSVC CRT 依赖**：`dumpbin /dependents` 看 release exe 是否 import
      `vcruntime140.dll`。没配 `crt-static` 的话**几乎肯定会**，那意味着干净机器上
      根本起不来。修法：`-C target-feature=+crt-static` 或随包发 `vc_redist.x64.exe`。
      **这条必须用 Windows 验证**，两边都判断不了。
- [ ] **把 `rc-testkit` 移出 release**：`rc-app/Cargo.toml:23` 把它设成了**正式
      依赖**（注释写着 "so it's a real dep"），意味着**用户拿到的二进制里连着一个假
      iPhone 和 H.264 编码器**。用 `#[cfg(feature = "selftest")]` 关掉。

### D. 明确不做（别浪费时间）

- [ ] 虚拟麦克风：需要**签名的 WDK 驱动**（`MakeAuth`），3-6 天 + 签名。
      **未签名的驱动会直接毁掉上面「代码签名」那一条的意义。** 语音先用 `--unmute`。
- [ ] 自绘托盘面板：原生 `TrackPopupMenu` 的**内容**已经和 Mac 对齐且有测试，
      这只是视觉打磨。
- [ ] AWDL：Apple 私有，Windows 不可能有。无路由场景用 iPhone 热点 / USB 网卡共享。
- [ ] 扩展显示器：需要签名的 WDDM/IDD 显示驱动。

---

## 4. 必须知道的架构约束

- **iPhone 是 TCP 服务端**，接收端都是客户端。所以「切换电脑」= 手机端记住
  一个 preference + 断开当前持有者 + 其他人收到 `busy`。
- **AWDL 在 Windows 上不存在**。`rc-discovery::HOTSPOT_GATEWAY`（`172.20.10.1`）
  和 last-IP 探测就是为此存在的。
- **Windows 的发现会静默失败**。mDNS 组播在访客网络、部分 VPN、AP 隔离下直接
  消失。所以 `fallback_gate` + `/24` 扫描不是「可选的后备」，是必需功能。
  ⚠️ **Clash / Mihomo 的 TUN 模式会吃掉默认路由**，`local_ipv4_addresses()`
  返回的是隧道 fake-IP。`sweep_targets` 会过滤掉这些段——如果你改了那里，
  请保留 `a_tunnel_address_is_never_swept` 那条测试。
- **`rc_vcam_source.dll` 的路径是注册进 HKLM 的绝对路径**（见上面安装包那条）。
- **协议只能加字段，不能改。** 新字段一律
  `#[serde(default, skip_serializing_if = "Option::is_none")]`。
- **持久化文件格式是已发布的数据格式。** `TokenStore::load` 吞掉所有解析错误然后
  `default()`，所以新增字段**必须** `#[serde(default)]`，否则全网用户的配对
  token 会被静默清空。AGENTS.md rule 2。

---

## 5. 交接时最容易被忽略的四个坑

按「我踩过 / 差点踩过」排序：

1. **测试只做一次连接 = 抓不到跨连接的 bug。** 原来那 9 个测试全都只连一次，
   所以"token 没保存"这个 bug 上线了——第一次连接本来就没有 token，只有第二次
   才显形。现在 token / 重启 / 重连 / 跨键 都有跨连接测试。
   **新测试如果只连一次，先问自己它在测什么。**

2. **两套 id 编号会静默地把整个界面打死。** 见 §2。

3. **`cargo fmt --all` 会重排你没碰过的文件**（比如 `rc-audio/tone_data.rs` 的字节
   数组会重新折行），`--ignore-all-space` 检测不出来。提交前按白名单核对 diff。

4. **Windows 上 `cargo test` 跑不到 `#[cfg(windows)]` 里的代码。** 改了那里必须
   跑交叉检查。`rc-app` 已经修好了可以在 macOS 上跑，所以**如果某个改动需要
   "只能在 Windows 上编译"，先问是不是少了个 `#[cfg]`**。

---

## 6. 需要问人的问题（我这边定不了）

- [ ] **托盘行的图标**：现在用 Unicode 字形（`◉ ◍ ☰ ⌨ ● ⎘ ▤ ▣ ↻ ⏻ ⚙ ⏹ ?`），
      注释写着"省掉图片资源"。在 Win32 菜单里渲染不一致、显得杂乱，而 Mac 用
      SF Symbols。**去掉图标只靠分区结构**，还是**做一套真图标资源**？
- [ ] **视频编码器**：Mac 用 VideoToolbox，Windows 用 OpenH264（passthrough）。
      画质/码率/兼容性在真机上比过吗？发布前应该比。
- [ ] **`--record` 自动开录**是否算 bug（见 §3B）。
- [ ] **Mac 的延迟口径**要不要也换成中位数（Windows 的 `IBLatencyTracker` 用
      中位数，Mac 的 `ReceiverSession` 还在用 `latencyHistory` 的最新值）？

---

## 7. 反馈格式

出问题时请带上：

1. **控制台输出**（`[net]` 开头的行是特意加的诊断点）
2. `%APPDATA%\RemoteCrab\tokens.json`（字段名保留，token 值可打码）
3. 你当时点了什么 + 看到的现象

诊断点清单：
`[net] mDNS browse could not start` / `mDNS still unavailable` / `mDNS browse running again`
/ `mDNS browse channel closed` / `not persisting <addr>` / `ignoring the stored address`
