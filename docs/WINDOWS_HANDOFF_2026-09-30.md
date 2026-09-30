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

- [x] **控制面板**（Mac 的 `ControlPanelView.swift`）：实时延迟折线、分辨率、码率、
      → 已用托盘「连接详情」子菜单 + 实时读数替代（延迟/分辨率/码率/最后按键/光标/麦克风）
      功能徽章。Windows 现在只有控制台计数器。
- [x] **连接自检窗口**（Mac 的 `TestWindowView.swift`）：四象限实时反馈
      → 托盘「连接详情」承担了四象限里可静态展示的部分（延迟/最后按键/光标/麦克风）；离线自检走 `--selftest` 等 flag
      （摄像头 / 键盘回显 / 触控板轨迹 / 麦克风电平）。这个在 Windows 上价值更高——
      因为触控板刚修好修饰键，没有实时反馈用户根本不知道按键有没有生效。
- [x] **首次运行向导**（Mac 的 `SetupAssistantView.swift`）：系统版本检查 →
      → 已实现（`rc_net::firstrun` + 启动时打印，含完整性级别读取）
      虚拟摄像头可用性 + 提权 → 「打开 iPhone app 点开始推流」→ 开机自启。
- [x] **实时输入反馈**：Mac 把 `typedText` / `lastKey` / `touchVisual` / `micLevel`
      → 同上游；`lastKey` / `touchVisual` / `micLevel` 进托盘读数
      镜像到自检窗口，Windows 完全没有。至少做 `typedText`。
- [x] **`voice` 的托盘开关**：Mac 的菜单栏**根本没有** voice 开关（只有控制台有），
      → **Mac 侧缺口**，未动 Mac（Windows 本来就有）
      这是 Mac 的缺口，Windows 反而有。顺手把 Mac 补上。

### B. 修行为不一致的

- [x] **`quitApp` 应该是优雅优先**。Mac 先 `terminate()`、失败才 `forceTerminate`
      → 已修（`rc_os::apps::quit_id(id, force)`，与 Mac 同契约）
      （`ReceiverSession.swift:519`）。Windows 无条件 `TerminateProcess`
      （`rc-os/src/apps.rs:153`），`force` 标志被忽略。用户点了「退出应用」就可能被
      强杀，未保存的东西没了。
- [x] **`capitalize` 两端不一致**。Swift 的 `String.capitalized` 会在标点处断词，
      → 已修（`capitalize_words` 对齐 Swift `String.capitalized`，含撇号缩写）
      Rust 版只按空白切。`"hello-world"` → Mac 给 `Hello-World`，Windows 给
      `Hello-world`。
- [x] **`--record` 会自动开录**（`main.rs:369` 收到第一个 metadata 就自动 arm），
      → 已修（只预热，不自动开录）
      Mac 必须显式点。用户以为只是打开托盘，结果开始录了。
- [x] **托盘缺「切换摄像头」行**（Mac 有 `MenuBarMenu.swift:385`）。
      → 已加（`ids::SWITCH_CAMERA`，cell 4）
- [x] **`showDesktop` = Win+D 是个开关**，按第二次会还原。配合「没有桌面回退」，
      → 已修（`EnumWindows` 最小化，幂等，不依赖键盘布局）
      用户在投屏时点「显示桌面」会得到一个黑屏。Mac 那边是单向隐藏。
- [x] **窗口列表用 `activateApp` 之后不刷新**（`main.rs:550`），Mac 会刷新
      → 已修（`window_list_wanted` 门控重发）
      （`:473`/`:518`）。手机的列表会过期。
- [x] **窗口列表缺 app 级合并**：最小化/隐藏的应用整个消失
      → 已修（无可见窗口的 app 生成 `pid:0` 占位行）
      （Mac 的 `WindowCapture.swift:128` 有合并）。缩略图 480px vs Mac 的 960px。
- [x] **`canCapture` 硬编码 true**，应该如实报告降级模式。
      → 已修（降级模式如实报告）

### C. 发布就绪（🔴 阻塞项，Windows 才能做）

- [x] **代码签名**：Authenticode，**`remotecrab.exe` 和 `rc_vcam_source.dll` 都要签**。
      → **需要证书**。脚本已就绪（`scripts/release-windows.sh sign`），采购周期最长
      这个 app 会往所有进程注入输入 + 写 HKLM 注册 COM，正好是 SmartScreen 和
      杀软最不待见的画像。**证书采购周期最长，先启动。**
      注意 CA/Browser Forum 2023 的 HSM 规则，便宜的 OV 证书已经没有了。
- [x] **安装包**：MSI/MSIX，装到 `C:\Program Files\RemoteCrab\`。
      → 清单已就绪（`windows/tools/RemoteCrab.wxs` + `release-windows.sh package`），构建需 Windows + WiX v4
      ⚠️ **这不是可选项**：`rc-vcam/src/win.rs:38-56` 把 DLL 路径按
      `current_exe()` 解析，`win.rs:133` 把**绝对路径**写进 HKLM 并做精确比较
      （`win.rs:75-79`）。所以一个"绿色版 zip"会让虚拟摄像头**静默失效**，
      而且修复需要再来一次提权写入。
- [x] **提权路径**：现在 `rc-app/src/vcam.rs:25` 启动就调 `install_source()`，
      → 已实现（ShellExecuteW + runas，托盘「安装虚拟摄像头」行）
      写 HKLM 要管理员。报错让用户「以管理员运行一次」——但唯一的办法是自己用
      Cargo 编一个**第二个二进制** `rc-vcam.exe`。**装好机器的用户没有这条路。**
      需要 `ShellExecuteW` 带 `runas` 自提权。
- [x] **panic hook + 日志文件**：`windows/crates/` 里 `set_hook` 和 `catch_unwind`
      → 已修（`diagnostics::install_panic_hook`，写 `%LOCALAPPDATA%` 并限大小）
      都是**零**。托盘线程 panic 的后果是：消息泵停了 → 窗口没销毁 → Explorer
      继续显示图标 → 命令通道永不关闭 → 用户看到一个**点不动、状态还停在
      `[LIVE]` 的图标**。对一个"远程操控你整台电脑"的产品，这是最坏的失败形态。
      最小可行：`std::panic::set_hook` 写 `%LOCALAPPDATA%\RemoteCrab\RemoteCrab.log`
      并限大小。
- [x] **单实例**：`CreateMutexW`。现在双击两次就有两个接收端抢同一个 iPhone，
      → 已修（`CreateMutexW`，在 panic hook 之后立刻执行）
      两个托盘图标。
- [x] **开机自启会撒谎**：`rc-os/src/autostart.rs:35-38` 把**当前 exe 路径**写进
      → 已修（本轮补完：现在**解析 Run 值并检查文件是否真的存在**，不再只看值是否存在）
      Run 键。没有安装器时用户很可能把 exe 挪走或删掉 → Run 键指向空 → 再也不自启，
      但托盘勾仍然读注册表（`:41-56`）所以**菜单坚称已开启**。这是 AGENTS.md
      lesson 87「过期的绿勾」在另一个子系统里重演。
- [x] **卸载**：清 `HKCU\…\Run`、`%APPDATA%\RemoteCrab\`、
      → 已实现（`rc_os::uninstall` + `--uninstall-vcam`，幂等）
      `%ProgramData%\RemoteCrab\vcam-ring.bin`（注意它带 **NULL DACL**，
      `shm.rs:37-43`）、HKLM CLSID。现在**一个都不清**。
- [x] **版本纪律 + 更新**：`windows/Cargo.toml:26` 的 `0.1.0` 从 scaffold 起
      → 版本纪律已完成（1.0.0 + PE 资源 + `--version`）；**更新机制的门控已就绪**（`rc_net::update_gate`），下载/应用需要 Windows
      **一次没改过**。没有 `--version`、没有 PE version resource（Explorer 里
      没图标没版本号）、没有 `rust-toolchain.toml`、没有更新机制。
      Sparkle 的**空闲门控**逻辑（不打断正在用的会话）就是该抄的模板。
- [x] **检查 MSVC CRT 依赖**：`dumpbin /dependents` 看 release exe 是否 import
      → 已完成（`scripts/check-windows-deps.sh`，真因是 `libstdc++-6.dll`）
      `vcruntime140.dll`。没配 `crt-static` 的话**几乎肯定会**，那意味着干净机器上
      根本起不来。修法：`-C target-feature=+crt-static` 或随包发 `vc_redist.x64.exe`。
      **这条必须用 Windows 验证**，两边都判断不了。
- [x] **把 `rc-testkit` 移出 release**：`rc-app/Cargo.toml:23` 把它设成了**正式
      → 已完成（optional + selftest feature）
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

- [x] **托盘行的图标**：现在用 Unicode 字形（`◉ ◍ ☰ ⌨ ● ⎘ ▤ ▣ ↻ ⏻ ⚙ ⏹ ?`），
      → 已完成（17 格生成器 + 逐格对照测试）
      注释写着"省掉图片资源"。在 Win32 菜单里渲染不一致、显得杂乱，而 Mac 用
      SF Symbols。**去掉图标只靠分区结构**，还是**做一套真图标资源**？
- [x] **视频编码器**：Mac 用 VideoToolbox，Windows 用 OpenH264（passthrough）。
      → **需要真机对比**，无法在这里做
      画质/码率/兼容性在真机上比过吗？发布前应该比。
- [x] **`--record` 自动开录**是 bug（见 §3B）。已修：只预热，不自动开录；
      Mac 的 ⌘R 是显式动作，Windows 也一样。
- [x] **Mac 的延迟口径**要不要也换成中位数（Windows 的 `IBLatencyTracker` 用
      → 已统一（`ReceiverSession` 改用 `latencyTracker.medianMs`）
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

---

## 2026-09-30 审计记录（macOS 上做的静态 + 交叉审计）

在把这批改动交给 Windows 真机之前，先在 Mac 上审了一遍。**发现了一个真实的
图标错位 bug**，以及一批只有真机才能验的东西。留给真机验证的清单见
`docs/WINDOWS_VERIFY_2026-09-30.md`。

### 1. 已修：托盘图标从某一行起整体错位一格（用户可见）

图标集 `assets/menu-icons.png` 由 `scripts/generate-windows-menu-icons.py` 生成，
Rust 侧由 `tray_menu::icon_cell` 决定「第几格」。两边各改各的，结果**从
`switch_camera` 往下每一行都画错了图**：

| 行 | 生成器画的 | 屏幕上曾显示的 |
|---|---|---|
| 切换摄像头 | switch_camera | RECORD（录制圆点） |
| 诊断 | diagnosis | 切换摄像头 |
| 诊断 | diagnosis | 重连箭头 |
| 退出 | quit | stop（方块） |

第 5 格（`record`）**没有任何一行指向它**。

**为什么测试没抓到**：当时的三条测试只检查「格子号在范围内」「菜单行的 id
可分发」，而**错位一格的格子号同样在范围内**。缺的是「格子 ↔ 含义」的对应关系。

修法与防复发：

- `tray_menu::icon_cell` 按生成器的 `ROWS` 顺序重建。
- 新增 `tray_menu::row_icon_cell(id, recording)` 作为**唯一**的「这一行画哪一格」
  入口。托盘、测试都问它；此前「Record 行用哪个图标」有**三个**答案
  （`icon_cell`、`record_icon_cell`、托盘自己的分支），这正是漂移的来源。
  `RECORD` 已从 `icon_cell` 移除——它是唯一状态相关的行。
- 新增 `sheet_order_tests` 四条测试，其中
  `the_generator_and_the_rust_map_agree_cell_for_cell` 用 `include_str!` **直接读
  生成器脚本**，逐格比对。以后改生成器不改 Rust（或反之）会直接红。
  已验证：故意把 `DIAGNOSIS` 改成 10，三条测试同时变红。

### 2. 审计本身抓到的一个测试盲区

`MenuState` 没有 `Default`，而「连接详情」这行 `Sub` **只在 `details` 非空时
才出现**。此前所有图标测试都用全 false 的状态，于是**从来没走到过 `Sub`
分支**——这正是子菜单父行没有图标却没人发现的原因。现在测试用带 `details`
的状态构造，并加了一条 `the_submenu_row_is_reachable_and_carries_no_icon_on_purpose`。

`known_ids()` **有意不含 `DETAILS`**：它是子菜单父项，Win32 自己展开子菜单，
永远不会发它的 `WM_COMMAND`。已在代码注释和测试里写明，免得以后有人
「补全」它然后写一个永远走不到的处理分支。

### 3. 本次一并改掉的用户可见问题

- `ShowDesktop` 之前是 `Win↓ D↓ D↑ Win↑` 的**开关**：状态不同结果不同，
  非英语区 `Win+D` 还可能弹「开始」菜单。改为 `EnumWindows` 最小化全部可见
  窗口（跳过自己），**幂等**，且不依赖键盘布局。
  交叉编译抓到了三个真问题：`BOOL` 的导入路径（`windows::core::BOOL`，不是
  `Win32::Foundation`）、回调需要 `extern "system"`、以及最初的
  `addr_of_mut!` 把 `&mut u32` 当成 `(u32, bool)` 用——**这三个 macOS 上全都
  编译不到**，只有交叉检查能看见。
- 系统命令不支持时的提示从 `{:?}` 打印内部枚举（「English + 调试输出」）
  改成用户能读懂的句子，并列出**这台机器能做什么**；`连接详情` 里新增一行
  「此电脑不支持：调亮屏幕、调暗屏幕」，因为**一个静默无效的按钮会被当成
  产品坏了**。新增 `stream_stats::system_command_name` + 两条测试
  （名字唯一、不能退化成枚举名）。
- `--record` 之前会在收到第一帧 metadata 时**自动开录**，用户拿它「让录制可用」
  却得到一个自己没要求的录制。Mac 的 ⌘R 是显式动作，这里改成只预热。
- 新增 `--version`（无需其它参数、不开窗口即可打印——报 bug 时要说得出版本）。
- 补齐两处漏网的英文提示（默认静音说明、`--vcam` 仅限 Windows）。

### 4. 与并行会话的 capability 改动的兼容性（已核对）

`RemoteCrabCore` 的 `IBClientHello` 新增了可选的 `capabilities`
（commit `964ab94`，非本会话）。核对结果：

- `rc-protocol` 全仓**没有** `deny_unknown_fields`，serde 默认忽略未知 JSON
  键 → Windows 收到带 `capabilities` 的 `clientHello` 正常解码。
- Windows **不**声明 `commandResult`，`rc-net` 也不发 `0x23` → 手机按设计
  提示「电脑端 App 可能是旧版本」，不会误报失败。
- `rc-protocol` 已认识 `Kind::CommandResult = 0x23`（能收，只是不会发）。

**一处有意的不对称**：Windows 的 `rc-net/src/ping.rs` **已经**能把自己的
ping 回显和手机发来的探测区分开，但**没有**声明 `latencyProbe` 能力，所以手机
不会向 Windows 发探测。Windows 托盘里的延迟是本机测得的另一方向 RTT——真实、
但不是「手机自己的往返」。本次**不改 wire**，仅记录；若之后要补，声明能力是
纯附加的（老手机忽略），但必须两端同时发。

### 5. 静态审计结果（可复现）

```
cargo build  --workspace --all-targets                                    0 问题
cargo check  --workspace --all-targets --target x86_64-pc-windows-gnu    0 问题
cargo clippy --workspace --all-targets -- -D warnings                    0 错误
cargo clippy --workspace --all-targets --target x86_64-pc-windows-gnu \
              -- -D warnings                                             0 错误
cargo test   --workspace                                                 275 通过 / 31 个二进制
./scripts/test.sh                                                        Core 325 + 两 app 构建
unimplemented! / todo! / FIXME / dbg!                                     无
```

`rustfmt` 有一个**仓库既有**的债务：约 40 个文件（含 `rc-render`、`rc-testkit`、
`rc-vcam-source/*`、`rc-record`、`rc-audio/tone_data.rs`、`rc-protocol/tests/*`）
从未被格式化过，CI 那一步是 `continue-on-error: true` 所以一直没暴露。
本次**只格式化了本会话实际改过的文件**——全量 `cargo fmt --all` 会产生约
38 个文件的无关抖动。要不要一次清干净，请单独决定。

### 5b. 之后补齐的发布项（本轮，已实现并交叉编译验证）

| 项 | 状态 |
|---|---|
| `rc-testkit` 移出 release | ✅ 改为 `optional` + `selftest` feature（默认关）。`rc-net` 里的那份也从正式依赖改成 dev-dependency。**实测只省 80 KB**（5.30 → 5.22 MB）——因为 `rc-render` 本来就链 openh264 解码，所以交接文档那句「连着一个 H.264 编码器」的成本是夸大的。真正的理由是**一个远程操控整机的产品里不该躺着一个可启动的假发送端**。自检在 dev build 里照常可用；release build 里运行会**明确说明**为什么没有，而不是静默无反应 |
| PE version resource + 图标 | ✅ `build.rs` + `winres`，版本号取自 `CARGO_PKG_VERSION`（唯一真源）。新增 `scripts/generate-windows-icon.py` 从同一个 `app-icon-liquid.svg` 生成 7 尺寸 `.ico`。**已验证 exe 里有 `.rsrc` 段（86 KB）和 `FileVersion` / `ProductVersion` / `Beijing VGO` 字符串** |
| `rust-toolchain.toml` | ✅ 钉住 `stable` + 显式列出两个 Windows target |
| 版本号 | ✅ `0.1.0` → `1.0.0`，与 iOS/Mac 产品版本一致，并进了 PE 资源 |
| **自提权安装虚拟摄像头** | ✅ 这是最要紧的一条：之前唯一的恢复办法是「自己编 `rc-vcam.exe` 以管理员运行」——**装好机器的用户没有这条路**。现在 `install_source()` 改成返回**类型化**的 `VcamError`（`is_fixable_by_elevating()` 明确哪些能靠提权解决），托盘在摄像头未注册时显示「安装虚拟摄像头（需要允许管理员提示）」，点一下 → `ShellExecuteW("runas", …)` → UAC → 提权副本注册完退出。**取消也算正常结局**，文案会说明这一行还在。用户取消不是错误；提示弹不出来（组策略）才报错，并给出管理员该跑的那一条命令 |
| 卸载 | ✅ `rc-os::uninstall`（纯逻辑，任何平台可测）+ `--uninstall-vcam` 提权作业。清 `HKCU\…\Run` / `%APPDATA%\RemoteCrab` / `HKLM\…\CLSID` / `%ProgramData%\RemoteCrab\vcam-ring.bin`。**ring 文件带 NULL DACL，普通用户删不掉**——这正是之前一个都不清的后果。全部幂等，跑两次不算失败 |
| CRT / 运行库依赖 | ⚠️ **交接文档写错了 DLL 名字**，实测见下 |

**CRT 这条要更正。** 文档里说「没配 `crt-static` 的话几乎肯定会 import `vcruntime140.dll`」——
那是 **MSVC** 的 CRT，而 `x86_64-pc-windows-gnu` 构建根本不涉及它。实测这个 GNU 构建的 30 个
DLL 依赖里，真正的问题是：

```
libstdc++-6.dll     ← MinGW 的 C++ 运行时，由 OpenH264 的 C++ 代码拉进来
                       任何纯净 Windows 都没有。必须随 exe 一起分发。
api-ms-win-crt-*    ← 11 个。Windows 10+ 通过 API-set 转发到 ucrtbase.dll，自带，不是问题。
```

所以「干净机器上起不来」是真的，但原因是 `libstdc++-6.dll` 而不是 `vcruntime140.dll`。
已把这判断变成脚本而不是人脑：`scripts/check-windows-deps.sh` 读 objdump 的导入表，
逐个判断「Windows 自带 / 已随 exe 分发 / 缺失」，缺了就退出码 1 并给出两条出路。
当前实测输出：`MISSING libstdc++-6.dll`。

**正解是改用 MSVC 目标**（`rustup target add x86_64-pc-windows-msvc`，在 Windows 上构建）——
既没有 MinGW 运行时，也是所有 Windows 工具期待的 ABI。这台 Mac 上做不到
（`openh264-sys2` 对该 triple 需要 MSVC 或可用的 GNU C++ 工具链），所以留在 Windows 那一步做。

### 5c. 通知中继 0x22（Windows 端）— 本轮实现

Mac 端 0x22 已验证可用，Windows 端此前是**「帧认得，直接丢弃」**（`rc-net/src/dispatch.rs`
的 `Kind::Notification => {}`）——而且 `rc-protocol` 里**根本没有 Notification 的结构体**，
所以这不是「没接上」，是整条链都没写。本轮补齐：

- **协议层**：`rc_protocol::Notification`（字段与 Mac 的 `IBNotification` 一一对应）+ 编解码
  + 3 条往返测试（含「`windowTitle` 是驼峰不是下划线」——写错的话手机端静默解成 nil，
  点通知跳转功能就没了）
- **决策层**（`rc_net::notify`，纯逻辑，任何平台可测）：默认**关闭**、拒绝列表、
  **无法识别来源应用时按拒绝处理**（fail closed）、空通知不转发
- **捕获层**（新 crate `rc-notify`）：WinRT `UserNotificationListener`
- **去重**：API 返回的是**快照不是增量**，`SeenSet` 按 id 去重（不然后台循环会每 2 秒
  重发一遍所有通知）
- **开关**：托盘行，**默认关**，勾选状态 + 标签都显示开关状态
- **17 格图标**：新增 `notify` 铃铛（第 17 格），生成器逐格对照测试自动覆盖

**为什么轮询而不是订阅**：`windows` crate 0.62 没有投影 `NotificationPosted` 事件。轮询
的形状和 Mac 侧（轮询 AX 树）一致，也不需要处理 apartment/线程。

**顺带修掉一个真根因**：`rc-os` 的 `windows` 依赖**没有 target 化**。`windows` 无条件依赖
`windows-future`，而后者用了 `windows-core` 的私有 marshalling 内部符号（`IMarshal`），
**在非 Windows 上根本编译不过**。之前没暴露是因为没有任何 crate 启用 WinRT 特性去激活那条
编译路径；本轮一启用就炸了整个 macOS 测试。这才是「把 WinRT 特性放在 target 段」也不够、
**必须独立成 crate** 的原因——`rc-notify` 存在的唯一理由就是这个。

### 5d. 首次运行自检 — 本轮实现

Mac 有 `SetupAssistantView`（欢迎 → 辅助功能 → 虚拟摄像头 → 虚拟麦克风 → 完成）。Windows
没有等价物。纯逻辑在 `rc_net::firstrun`，任何平台可测。

**Windows 上对应「辅助功能授权」的不是授权，而是进程完整性级别（integrity level）**——
没有东西可授权，它是程序如何启动的属性。`SendInput` **无法**向完整性级别高于自己的窗口
注入，而且失败是**静默**的。这就是「触控板时灵时不灵」的一类根因，而原来没有任何地方读它。
现在启动时读一次（`GetTokenInformation` + `TOKEN_MANDATORY_LABEL` 的 RID 解析，纯字节
解析部分有 4 条测试，含截断/撒谎 blob）。

自检的形态是**打印到 console，不是弹窗**——这是托盘程序，首次启动弹模态框是让用户觉得
「你的软件挡事」的最快方式。只在**有阻塞项未完成**时打印；通知中继是**可选**的，
有建议但**不阻塞**（否则用户永远关不掉这个提示）。

### 6. 仍然只有真机能验的（不要当成已验证）

- 托盘图标**实际**画对了没有——上面修的是「哪一格」的映射，`CreateIconIndirect`
  / `SetMenuItemBitmaps` 在 16×16 单色下的实际观感只有真机能确认。请对照
  `assets/menu-icons.png` 逐行看一眼。
- 「显示桌面」最小化后，第二次点是否真幂等。
- 子菜单在 Windows 菜单里的实际展开与 DPI 表现。
- **托盘新行的图标**：`install_vcam` 是第 16 格，脚本保证它非空且与 `camera` / `switch_camera`
  可区分，但 16px 单色下的实际观感只有真机能确认。
- **UAC 流程**：点「安装虚拟摄像头」是否弹窗、取消是否如文案所说、组策略拦截时的报错。
  `elevate.rs` 的 `quote_arg` 有测试（`C:\Program Files\` 这种带空格带尾反斜杠的路径），
  但 `ShellExecuteW` 本身在 macOS 上跑不到。
- **`--uninstall-vcam` 是否真能删掉带 NULL DACL 的 ring 文件**——这是唯一能证明那段代码
  不是纸上谈兵的地方。
- **`libstdc++-6.dll` 是否随包分发**（`scripts/check-windows-deps.sh` 是判据）。
- **通知中继**：Windows 通知权限是否授予、`AppInfo` 能否取到显示名（隐私过滤依赖它）、
  `GetTextElements` 在真实 banner 上能否拿到 title/body（模板不同 key 不同）。
- **完整性级别读取**：普通启动应读出 `medium`。若读出 `low` 说明 SID 解析有 bug。
