# Windows receiver

> 跨编译、虚拟摄像头与托盘

Part of [`AGENTS.md`](../../AGENTS.md). Entries keep their original numbers
so a cross-reference from another lesson still resolves.

68. **Windows parity round 2 + a cross-compile check that actually compiles
    the Windows code (2026-09-26).** Two things:
    (a) **The macOS `cargo check`/`clippy` never type-checks the Windows
    receiver.** Every real Win32 module is `#[cfg(windows)]` (`rc-os::apps`,
    `clipboard`, `windows`, and the `#[cfg(windows)]` arms in
    `rc-app/main.rs`), so on the Mac they are simply excluded — a latent
    compile error (`TerminateProcess(...).as_bool()` on a
    `windows::core::Result`, not a `BOOL`) shipped in the activate/quit
    commit and only surfaced when cross-checked. To actually validate:
    `brew install mingw-w64`, `rustup target add x86_64-pc-windows-gnu`, then
    `cargo check`/`clippy --target x86_64-pc-windows-gnu --workspace`
    (the msvc target can't build OpenH264 from macOS; the GNU target can,
    once mingw is present). The **runtime** paths still need a real Windows
    box — the user runs that.
    (b) **Windows data-plane parity**: `activateApp`/`quitApp` were being
    dropped (fixed — see the activate/quit + feature-control commit);
    `windowListRequest` (0x17) was unhandled, so the iPhone's window-based
    `AppSwitcherView` (it renders `engine.macWindows`, NOT `macApps`) was
    always empty. `rc-os::windows::build_window_list` now enumerates
    top-level windows (`PrintWindow` + `PW_RENDERFULLCONTENT` for
    GPU-composited ones) and returns a JPEG thumbnail per window via the
    pure, unit-tested `rc-os::thumbnail::encode_bgra_jpeg` (box-downscale →
    `jpeg-encoder`); window `id` is `"<pid>:<hwnd>"` (the iPhone keeps only
    ids containing `:`) and `app_id` is `"pid:<pid>"` to match the app list.
    `activateApp` now also matches the tapped card's `windowTitle`. The PC
    clipboard can be pushed to the iPhone with the `clipboard` console
    command (`clipboardSet` 0x13 was receive-only before). And the iOS app
    now hides its mirror button while `connectedIsWindows` (that receiver
    has no window-capture path, so the button only ever dead-ended) —
    `CaptureEngine.startScreenMirror()` guards the other entry points too.
    **Recording**: the new pure crate `rc-record` (`--record` / console
    `record`) muxes the iPhone's own H.264 into an MP4 (passthrough, no
    re-encode) + a PCM WAV sidecar (the `mp4` crate only muxes AAC and the
    project refuses an FFI AAC encoder) under
    `%USERPROFILE%\Videos\RemoteCrab`; unit-tested on the host. **AWDL**:
    Windows cannot do Apple Wireless Direct Link (proprietary Apple link
    layer; `includePeerToPeer` is Apple-only; OWL targets Linux) — the
    router-less paths are the iPhone Personal Hotspot / USB tethering, which
    the direct-IP fallback already covers (`HOTSPOT_GATEWAY 172.20.10.1` +
    last-IP + `/24` sweep). **App-window mirror**: `rc-protocol` now has the
    `ScreenControl`/`ScreenInput`/`ScreenInfo` structs + codecs (tested) and
    `rc-net` dispatches `screenControl`/`screenInput`; the new `rc-mirror`
    crate captures the target window (`PrintWindow` + `PW_RENDERFULLCONTENT`),
    H.264-encodes it with OpenH264, and `rc-app` streams
    `screenSps`/`screenPps`/`screenVideo` + `screenInfo` from a dedicated
    thread (input is mapped via `rc-input`'s absolute `screen_actions`).
    Because Windows now supports it, the iOS mirror button is **no longer
    hidden** for `connectedIsWindows`. **Switcher quick destinations**
    (2026-09-26, both receivers): the switcher's top row now has **Desktop**
    — a new `IBSystemCommand.showDesktop` (0x19) kind; the Mac hides every
    other regular app then activates Finder (hiding is what uncovers it;
    activating Finder alone only raises a Finder window), Windows sends
    Win+D — and **Open app…**, a searchable installed-app launcher on a new
    frame pair (`installedAppsRequest` 0x20 / `installedApps` 0x21):
    `InstalledApp.id` carries exactly what `launchApp` wants as its argument
    (bundle id on the Mac — `InstalledAppsCatalog` scans /Applications
    (+Utilities), /System/Applications, CoreServices and ~/Applications,
    deduped by bundle id — Start Menu `.lnk` path on Windows, so
    `ShellExecuteW` handles it). **Tray + real app icons** (2026-09-26,
    both the P2 experience gap and the switcher's fallback icons):
    `rc-app` puts an icon in the notification area (`Shell_NotifyIconW` +
    a message-only window on a dedicated thread; every menu pick routes
    through a channel to the app's `select!` loop — the tray thread owns
    nothing) and its menu mirrors the Mac menu-bar popover's structure and
    wording (`State::pill_label`/`phone_name`/`pill_latency_ms` for the
    status row; the SAME four toggles the Mac shows — camera/mic/trackpad/
    keyboard — then Start/Stop Recording, Send Clipboard to iPhone,
    Reconnect, Disconnect, Quit; `--no-tray` skips it). `build_app_list`
    now renders each process's 48 px icon (`SHGetFileInfoW` → `DrawIconEx`
    into a 32-bit DIB → RGBA → PNG in the pure, tested `rc-os::icon`),
    cached per exe path — the same fill the Mac does on the explicit
    `appListRequest`. **Still open on Windows**: virtual mic (see
    the blueprint below) and the self-drawn tray panel (§5f of
    `docs/WINDOWS_HANDOFF.md`); `cargo test --workspace` 207 +
    host/windows clippy clean, now enforced by CI.

95. **`windows` 依赖不 target 化，会让整个 macOS 测试套件编译失败**
    （2026-09-30）。`rc-os` 的 `windows` 依赖写成了普通依赖。`windows`
    crate **无条件**依赖 `windows-future`，而后者用了 `windows-core` 的
    私有 marshalling 内部符号（`imp::IMarshal`、`imp::marshaler`），
    **在非 Windows 上根本编译不过**。之前一直没暴露，是因为没有任何 crate
    启用 WinRT 特性去激活 `windows-future/src/bindings.rs` 那条编译路径；
    一加通知中继（`UI_Notifications_Management` + `Foundation`）就炸了
    整个 macOS 构建。

    **而且把 WinRT 特性挪到 `[target.'cfg(windows)'.dependencies]` 也不够**：
    Cargo 会跨 workspace 统一 feature，`cargo check -p rc-os` 在 macOS 上
    依然会编译 `windows-future`。**唯一可靠的做法是把 WinRT 代码独立成
    crate**（`rc-notify` 就是为此存在），模块上的 `#[cfg(windows)]` 无效。

96. **`winres` 静默产出无图标二进制（两个独立的原因）**
    （2026-09-30）。给 exe 嵌图标和版本资源时，连续踩了两层：
    (a) `winres` 默认找**无前缀**的 `windres`/`ar`，而 Rust triple
    （`x86_64-pc-windows-gnu`）**不是** MinGW 前缀（`x86_64-w64-mingw32`）——
    照着 triple 拼出 `x86_64-pc-windows-gnu-windres` 这种不存在的名字。
    (b) 更隐蔽的：`winres` 最后把 `resource.o` 打包成 `libresource.a`，
    而**静态库的成员只有在解决未定义符号时才会被链接器拉入**。
    `resource.o` 不定义任何符号，它只贡献 section——于是链接**成功、
    静默、什么都没进去**。必须用 `cargo:rustc-link-arg` 直接把 `.o`
    传给链接器。

    **两条都没有任何警告。** 唯一可靠的验证是**去看产物**：
    `objdump -h remotecrab.exe | grep rsrc`。顺带一个通则：
    `signtool` 在证书**过期**时也退出 0 但什么都没签，所以
    `sign_one` 里签完必须 `signtool verify` 复查。

97. **「帧认得但没有 dispatch 分支」= 按钮点了什么都不发生**
    （2026-09-30）。`Kind::CommandResult = 0x23` 在 `wire.rs` 里有、
    能识别，但 `rc-net/src/dispatch.rs` 没有对应分支，Mac 发来的命令结果
    被静默丢弃。用户在手机上点「打开应用」，什么都不会发生，且**任何地方
    都没有解释**——看起来像产品坏了，而不是少了个回复。

    **通用形态**：给某个 kind 写了枚举值和 codec，就**不等于**处理了它。
    审计时要查的是「每个 kind 有没有 dispatch 分支」，而不是「枚举里有没有
    这个 kind」。0x22 也一样：`rc-protocol` 里当时**连结构体都没有**，
    所谓「帧认得，直接丢弃」其实是整条链没写。

98. **托盘图标的格子顺序是承重的，而旧测试恰好测不到**
    （2026-09-30）。图标集由 `scripts/generate-windows-menu-icons.py`
    生成，格子号由 Rust 的 `tray_menu::icon_cell` 决定。生成器中间插入一格
    而 Rust 没跟上，结果**从第 4 格起每一行的图标都是错的**（摄像头行画着
    切换图标的图标，退出行画着停止的方块），第 5 格没有任何一行指向。

    **为什么测试没抓到**：原有三条测试只检查「格子号在范围内」，
    而**错位一格的格子号同样在范围内**。缺的是「格子 ↔ 含义」的对应关系。
    修法是新增 `the_generator_and_the_rust_map_agree_cell_for_cell`，
    用 `include_str!` **直接读生成器脚本**逐格比对。已验证：把某个格子改
    错，三条测试同时变红。

    **附带一个盲区**：`MenuState` 没有 `Default`，而「连接详情」子菜单那行
    `Sub` 只在 `details` 非空时才出现——所以所有图标测试用全 false 的状态，
    **从来没走到过 `Sub` 分支**。测试用了比被测代码更窄的输入。

99. **UI 的「文件级」对齐不够，要查「动作级」**（2026-09-30）。
    逐个文件对照 Mac 和 Windows 只能发现「缺一个窗口」，发现不了
    「窗口在但控件是死的」。这次动作级审计抓到两个：

    (a) 向导的动作按钮用 `take()` 把闭包**取走**了，所以**只能点一次**。
    失败场景极其具体：用户取消 UAC 后，**向导自己的文案叫他再点一次**，
    而再点什么都不会发生。**测试套件里没有第二个 UAC 弹窗**，所以任何
    单测都抓不到。修法：读出引用、在锁外调用，并加一条「点三次」的测试
    （已验证恢复 `take` 后变红）。
    (b) 设置窗口的摄像头行**只有文字没有按钮**——分发分支写了
    `with(|a| (a.camera)()).unwrap_or(false);` **读了值就丢掉**，而且
    没有任何控件用那个 ID，当初用 `let _ = ID_CAMERA;` 把警告压下去了。
    一个写着「未注册」却不给任何办法修复的行，正是 AGENTS.md 规则 1
    禁止的「状态行不说怎么办」。

100. **`#[cfg(windows)]` 里的测试等于不存在**（2026-09-30）。这是本项目
    第四次栽在同一处：加了 `#\[cfg(windows)\]` 的持久化往返测试，而
    `%APPDATA%` 在 Mac 上不存在，那个测试**在能跑测试的机器上一个都跑不到**；
    它「通过」是因为读回了默认值——**一个不可能失败的测试比没有测试更糟**。
    同一次审计还发现一个测试**在源码树里真的创建了目录**：
    `crates/rc-app/C:\Users\Default\AppData\Roaming`，因为回退路径是
    真实 Windows 路径。

    **纪律**：逻辑测试必须任何平台可跑，平台特有的部分靠**注入路径**
    而不是靠 `cfg`。`#[cfg(windows)]` 只应该出现在「真的调 Win32 API」
    的那一层。

101. **笼统的 `allow(dead_code)` 会掩盖真正死掉的代码**
    （2026-09-30）。`notify_relay.rs` 一度有 **14 处**
    `#[allow(dead_code)]`——我一直在压警告而不是接线。全部改成
    `#[cfg_attr(not(windows), allow(dead_code))]` 之后，**Windows 目标下
    死代码检查真的在跑，结果是零**——这才是一个有证据的断言，而不是一句
    压制。改的时候要先确认那些函数确实有 Windows 侧的调用者。

102. **「函数已存在」不等于「行为正确」——要查回调是否被消耗**
    （2026-09-30，与 95/100 同源）。一个状态机里
    `run_action()` 用 `action.take()` 取走闭包，编译通过、单测通过、
    函数**看起来**是对的。同类的还有 `Mutex<TokenStore>` 方案：
    持 guard 跨 `await` 会让 future **非 `Send`**，编译期就失败——
    那个失败反而是好的，它指向了正确的形状：**supervisor 必须是唯一写者**，
    设置窗口发 `Session::forget_phone` **命令**。

103. **E2E 连续三次「全红」全是我的环境问题，不是产品**（2026-09-30）。
    (a) 我手动启动了 Mac 接收端 → 脚本的「带环境变量启动」是空操作 →
    断言读空日志，**而 iPhone 正在 happy 地推 600 帧**（日志里能看到
    `sendSessionReply accepted`）。
    (b) 上一次跑剩的**旧接收端进程**才是真正连上的那个 → 日志里的 PID
    和我启动的对不上，这是唯一的线索。
    (c) iOS bundle id 我记错了：`com.ibridge.iBridgeCapture`——iOS 那个
    保留 `ibridge`（AGENTS.md 命名约定里明写），不是 `com.remotecrab.*`，
    也不是别的。

    **通则**：`e2e-device.sh` **假设 Mac 接收端没在跑**。跑之前先
    `pkill -f "RemoteCrab.app/Contents/MacOS/RemoteCrab"`，并且**相信 iPhone
    侧日志比断言更有信息量**——iPhone 说连上了而 Mac 侧计数为 0，说明是
    接收端的问题；反之说明是断言的日志源错了。

104. **协议的两半各自往返，测不出漂移**（2026-09-30）。Swift 测试用
    Swift 往返 `IBNotification`，Rust 测试用 Rust 往返 `Notification`，
    **两边都完美往返，产品却可能已经坏了**——一边改了字段名、忘了
    `#[serde(rename_all = "camelCase"]`、或者 status 拼写不同。

    修法是**把一边的真实字节交给另一边解**：fixture 由
    `cargo run -p rc-protocol --example contract_gen`（真正的 Rust 编码器）
    产出，不是手写。8 条测试覆盖 0x22/0x23，含
    「`windowTitle` 必须是驼峰（写成 `window_title` 会静默解成 nil，
    点通知跳转无声失效）」和「kind 号对着 `wire.rs` 本身断言，
    而不是把常量抄一遍」。

    写的时候踩了一个 Swift 坑：**`#"..."#` 原始字符串遇到第一个 `"#` 就结束**，
    而 JSON 密到足以包含它——`"#42"` 直接把字符串截断，编译器在**三行之后**
    报语法错误。**第一条错误才是要看的那条。**
    另一点：`#filePath` 在**编译后的测试 bundle** 里指向 `.build` 内部，
    往上走永远到不了 checkout，所以跨 crate 找源码要从工作目录往上找。

105. **需要 iPhone 在手的测试，可以用一个假手机进程代替**
    （2026-09-30）。测 Windows 接收端有个无法用工程消除的硬前提：
    **手机得开着、解锁、在推流、还在同一网络**。于是测试套件依赖「有人拿着
    设备」，只在有人记得跑的时候跑，不在 CI 跑的时候跑——一个回归可以躺
    好几个星期。

    `rc-net/tests/session.rs` 里早就有假 iPhone，但它**跑在测试进程内、绑
    随机端口**，所以只能测 `Session`，测不了真正会出事的东西：**那个二进制
    本身**（参数解析、托盘、重连循环）。

    `rc-phone-sim` 就是把它变成进程：
    `rc-phone-sim --port 8765` + `remotecrab.exe --connect 127.0.0.1:8765`。
    （loopback 是**故意保留**的——见 supervisor 里那段注释，就是为了这个。）

    七个场景里最有价值的是 `silent`（连上后什么都不发）和 `drop`（连上就断）：
    这两类故障手测时最难抓，因为**界面看起来一切正常**。

    **它不能替代真机**：真 iOS 编码器、摄像头、真通知、真实 WiFi 发现仍然
    需要设备。意义在于把**不需要设备**的那些检查从设备上解绑出去。

106. **`Frame2::Other(u8)` 让假手机看不见 ping，于是延迟路径无法断言**
    （2026-09-30，与 105 同源）。假手机此前把所有不认识的帧塌成
    `Other(u8)`，所以「ping 发出去了吗、回来了吗、往返多久」在进程外**完全
    不可观测**。加了 `Ping(u64)`（带时间戳，调用方可以自己算 RTT）、
    `Notification`、`CommandResult` 三个变体。

    通则：**一个「其它都归这里」的分支，会在你把它变成进程的那一刻变成盲区**。

107. **崩溃在我改动之前就存在——用 `git stash` 对照确认的**（2026-09-30）。
    `rc-phone-sim` 第一次跑就让接收端打出了 `sessionReply: Accepted`，
    随即 `fatal runtime error: Rust cannot catch foreign exceptions, aborting`。
    因为它出现在我新写的功能之后，第一反应是「我搞坏的」。

    `git stash -u` 回到改动前重新构建，**同样崩**。所以是既有 bug，且**在
    macOS 上也复现**（不是 Windows 特有）。崩溃与视频无关（`silent` 场景
    一样崩），发生在 `Accepted` 之后的本地处理阶段。**根因未定位。**

    教训有两条。第一，**怀疑自己刚写的代码之前，先花五分钟排除它**——
    `git stash` + 重建 + 复现，比读代码快且确定。第二：这条能成立是因为
    测试套件是绿的；**如果当时套件是红的，「我改坏的」和「本来就有」就分不开了**。

## 108 · 一个 panic 说得比它的成因更准（`build.rs` 的护栏）

2026-10-02。`WINDOWS_TODO.md` §2.3 一直把「MSVC 构建」列为上线阻塞，建议换到
MSVC 目标。切过去之后**根本编译不过**：

```
panic: winres reported success but ...\resource.o is missing
       — the .exe would ship without an icon or a version
```

护栏本身是对的。错的是它**只认识一种工具链的产物**：`resource.o` 是 GNU
`windres` 的输出，微软的 `rc.exe` 出的是 `resource.lib`。`winres` 对两者都
返回成功，于是「成功」这个信号从来没有区分过是谁在编译。

**教训**：当一个检查只对**某一个工具链**成立时，它会变成「在正确的工具链上
静默通过、在其余的全部报错」——而报错的那一个往往是你刚换上的那个。写护栏时
按 `target` 分支，而不是按「我手头这个」写。

## 109 · 判据读到 0 条，等于给了绿灯

`scripts/check-windows-deps.sh` 是决定「这个发布能不能发」的那道判据。它在
Windows 上**从来跑不起来**（只认 `x86_64-w64-mingw32-objdump` / `llvm-objdump`），
所以只能在 Mac 上跑——于是它推荐的 MSVC 路径从来没被真正测量过。

给它加上 `dumpbin`（经 `vswhere` 定位）之后，它第一次在 Windows 上运行就报：

```
imports: 0 DLLs
OK — every dependency is either in the box or shipped with the exe.
```

0 个导入被当成了「什么都不缺」。真因是 Git-Bash 把 `/dependents` 改写成了
`C:\Program Files\Git\dependents`，dumpbin 的报错走了 stderr，而脚本把空结果
读成了通过。

**教训**：**一个判据读到 0 条输入时必须失败，不能通过。** 「没读到东西」和
「没有东西」在结果上长得一模一样，而这道判据的输出会变成一个绿色的勾。
`if [ "$total" -lt 5 ]; then exit 1; fi` 是这里唯一重要的一行。

## 110 · 只在一种语言下成立的测试，是坏掉的断言

`stream_stats.rs` 有两个测试用**英文 label** 去 `detail_rows()` 的结果里找行，
而那些 label 来自 `i18n::t`。在这台中文 Windows 上它们失败：

```
assertion `left == right` failed
  left: None
  right: Some("a")
```

代码是对的，断言是错的。修法是让测试**用和代码一样的 `t()`** 去解析 label，
这样两种语言下它问的是同一个问题。

**教训**：`i18n::t(a, b)` 这种「按语言二选一」的写法，会把**语言**变成测试的
隐式输入。断言里任何一处硬编码了某个语言分支的字符串，测试就只在那一半的机器
上有效——而 CI 通常跑在另一半，于是它长期是绿的，从来没被人质疑过。
和 `lessons/windows.md` 第 100 条（`#[cfg(windows)]` 里的测试等于不存在）
是同一类：**测试的适用范围比它看起来窄。**

## 111 · 换工具链不消除外部依赖，它只是换了一个名字

「MSVC 构建不需要 MinGW 运行时」这句话，在 §2.3 里被当成理所当然。实测：

```
26 imports   MISSING VCRUNTIME140.dll
19 imports   OK            （加了 -C target-feature=+crt-static 之后）
```

`vcruntime140.dll` 不是 Windows 自带的，它随 VC++ 重分发包来。所以不开静态
CRT 的 MSVC 构建，在一台没装过任何 MSVC 应用的干净机器上**照样起不来**——
和 GNU 缺 `libstdc++-6.dll` 是同一个形状的问题，只是文件名换了。

**教训**：把「A 构建方式有依赖」换成「B 构建方式没有依赖」之前，先量 B 的导入表。
依赖来自**你链接进去的代码**（这里是 OpenH264 的 C++），不是来自工具链的牌子。
## 112 · 「协议里有这个字段」不等于「有人在读它」

2026-10-02。有人问「镜像投屏实现了，扩展屏是不是还没实现」，我grep 了
`toggleExtendedDisplay`，看到 Mac 侧有实现、Windows 侧只有一句
`not supported`，于是判断「iPhone 端还在无条件显示这个入口」并准备动手。

读完 `ContentView.swift` 才发现那一行早就有门：

```swift
if !engine.connectedIsWindows {
    Button { ... engine.toggleExtendedDisplay() } ...
}
```

`CaptureEngine.swift:95` 的 `connectedIsWindows` 来自 `clientHello.platform`，
而 Windows 一直在发它（`supervisor.rs:655`）。功能**早就完整了**。

同一次排查里还看到：`IBClientHello.capabilities` 这套机制 Mac 声明了
（`ReceiverSession.swift:1290`）、Core 建模了、还配了 19 条测试，但全仓
`.supports(` **零调用**——iOS 从来没读过它。今天没人受害，是因为 `platform`
恰好覆盖了唯一需要的判断（这是不是 Windows）。等真需要按能力而不是按操作系统
区分时，这个「已建模、已测试、无人消费」的状态就是陷阱。

**教训**：grep 到「A 端有实现」不能推出「整条链没接完」。要证明一个功能缺失，
得找到**该功能本该出现的那一行**，而不是找到另一端的实现。我的错误是把
「Windows 说不支持」当成了「iPhone 没做判断」——前者是结论，后者是原因，
而结论恰好是对的，所以我连自己要修的东西都不存在。

和 `WINDOWS_SESSION_CLOSEOUT.md` §6 那六次「做完了说太早」是同一个家族的反面：
那次是**有**却当**无**，这次是**无**却当**有**。两个方向的错误都靠「逐个动作问
它真的做事吗」才能挡住。

## 113 · 诊断工具的判决比 bug 更危险，因为它会被相信

2026-10-04，Windows 机。预览花屏（沿高对比边缘的彩色噪点 + 周期性横向条带）。
上一个 session 留了一个判决工具 `vcam_forensics`，规则是

```
harsh horizontal > 8%  →  像素已坏  →  坏在上游（码率）
```

**这个阈值是在一个平铺的合成测试图上量的。** 同一批改动里新加的
`renderer_fidelity` 把一段**可证明完好**的 1080x1920 流推过同一个解码器和
`window.rs` 那一模一样的 blit，逐级确认无失真——它在**干净流上量到 12.31%**。
真实高对比场景本来就有这么多边缘。旧规则会判它「像素已坏」，然后把责任推给手机，
理由是渲染层有 bug，而那个 bug 不存在。

**更糟的是它会显得可信**：工具用大写打出 `VERDICT:`。一个用错输入量出来的阈值，
经过一个自信的输出格式，就从猜测变成了事实，并且占住了「已测量」的位置——
正是本仓库反复栽的那种「不告诉你真相」。

同一批里还有第二个同形错误，我从别人写的文档里抄了过来：

- 手机 metadata 报 `6220 kbps`，正好等于 `1920×1080×30×0.1`。
- 于是「系数 0.1 太小，改成 0.15」被写成了带数字的结论。
- 但 `H264Encoder` 同时设了 `AverageBitRate` 和 `Quality`，**iOS 上 `Quality`
  直接覆盖前者**：要 6,220 和要 9,331 产出**逐字节相同**。
- 那个 6220 是手机**编造**出来的，从来没有任何东西量过它。
  `scripts/vt-bitrate-probe.swift` 量到真实值：`quality 0.70 → 9,179 kbps`。

我把这个数原样抄进了自己的测试常量，**而我这个 commit 的全部内容就是
「不要相信来路不明的数字」**。

**教训**：

1. **一个测量如果它的输入选错了，它不是证据，是负证据。** 阈值来自平铺合成图，
   数字来自机器自报字段——两者都带着「已测量」的标签进入讨论。
2. **比较要选一个不会被场景改变的东西。** 「边缘能量占像素百分比」随场景剧烈变化；
   「这一帧是不是这条流自己的中位数的三倍」不会。均匀差（码率不够）
   少数帧爆掉（参考帧丢了）是两类故障，绝对阈值分不开，相对阈值能分开。
3. **「读代码排除了」不是「排除了」。** 那个交接文档里，渲染竞争和 stride
   都被标成「只是读代码排除的」，而当天读代码错了两次。
4. **判决工具的阈值和它的输出格式一样，是产品表面。** 输出一个判决的工具，
   必须能用它自己的输入证伪它自己的判决——否则它只是个 opinionated 的
   `println!`。
5. **不要把文档里的数字当事实继承。** 写进新代码之前，先问这个数是谁在什么输入上
   量的。本例的答案是「没人量过」。

## 114 · 「统一」和「没内容」在数据上是同一句话

2026-10-04，同一台 Windows 机，接上真 iPhone 跑通了 `vcam_forensics`
（`Accepted`，`camera_on=true`，180 秒）。判决是：

```
  frames decoded         : 307
  harsh horizontal       : 0.02%
  VERDICT: uniform. 没有一帧突出。
```

看起来是「解码器没问题」。**但 `harsh horizontal 0.02%` 同时说明画面几乎没有细节**
（0.04% pooled，对比 `renderer_fidelity` 里那段可证明完好的 1080x1920 流是 24.6%）。
拍的时候镜头对着的是没有纹理的东西。这种输入**本来就不可能显出花屏**，
所以「没发现异常」和「没问题」在数据上是同一句话，而只有第一种是真的。

更糟的是方向性：**零特征画面最容易通过任何「找异常」的检查。**
一个只找离群帧的工具，会在最没信息的时候给出最肯定的结论。

所以加了 `Pattern::TooLittleDetail`：pooled 边缘能量低于 1% 时**单独报一种判决**，
明说「这不是通过」，并给出校准来源——

- `renderer_fidelity` 的可证明完好流：24.6%
- 真机对着一面暗墙：0.04%

1% 落在这两者之间，不是拍脑袋的数。`renderer_fidelity` 自己如果落到这个分支会
**判失败**而不是 PASS：一个不再测到输入的闸门，必须响亮地失败。

**同一次真机跑还暴露了一个完全不同的问题**，而旧工具会把它藏起来：

| | 实测 | 声称 |
|---|---|---|
| 帧率 | ~4 fps | 30 |
| 码率 | 820 kbps | 6220 |
| 关键帧间隔 | 14.1s | 1s |
| 解码器拒绝的 NAL | 54 | 0 |

**像素正常，但码流本身是坏的。** 「像素都对」和「码流是对的」不是同一句话，
一个只报像素的工具会让后者完全看不见。所以探针现在把「声称 vs 实测」并排打出来。

**教训**：任何「没找到问题」的结论，都必须先回答**「输入里有没有问题可找」**。
找异常的检查在无信息输入上必然通过，所以要先量输入的信息量，再解释输出。

## 115 · 三块拼起来的保险丝，每一块都没接上，45 个测试全绿

2026-10-04，审计触控板「不好用」。用户报的方向反转**不存在**——真机跑
`REMOTECRAB_E2E_TRACKPAD_DIR=1`，86 个采样、68 个有效样本，`in.dx` 与
`cursor_dx` **零反号**。交接文档追了三轮的那个方向问题，到此结案。

但审计过程中读到一段注释，它比周围的代码更完整：

```swift
// Remember what is down so a dropped link can release it. A
// stuck Shift is the kind of bug that makes the whole machine
// feel broken and is invisible in every log.
```

`rc-input/src/windows_impl.rs` 里，这套保险丝由三块组成：

| 部件 | 实际状态 |
|---|---|
| `released_keys` | 有声明(59)、有 drain(128)，**从未被写入** |
| `end_gesture()` | **全仓零调用**——它自己的注释写着「链路断开时调用」 |
| `released` 标志 | 只写不读 |

`ModifierKeys` 分支**只调 `send_vk`**，一个键都没记。所以 `held_modifiers()`
永远返回空 Vec，整条保险丝是三段没接上的电路。`cargo test -p rc-input`
**45 passed**。

**用户会遇到的症状**：按住 Shift 划选时链路一断（手机锁屏、Wi-Fi 抖一下、
Mac 抢走手机），**物理 Shift 一直按在 Windows 上**，之后打字全是大写、
触发快捷键，直到手动按一下再松开。日志里零信息。

### 修的过程，以及我犯的错

第一版测试只测了 `HeldKeys` 这个纯结构。**逆向验证时我把 `press`/`release`
两行调用整个删掉，50 个测试依然全绿。** 因为测试自己 new 了一个 `held` 然后
自己调 `apply` —— 它**复制**了接线，而不是**测试**接线。这比重写之前更糟：
它给一行没人执行的代码签了证。

第二版用 `InputTranslator` 手工喂 `MouseAction`——还是绿的，同样原因。

真正的原因是：`perform_mouse` 里的记账在 `SendInput` 调用**后面**，测试够不到，
因为一够到就会在跑测试的机器上真的按下键。

**最终修法**：把 `send_vk` / `send_mouse` 提成 `WindowsInjector` 上的函数字段，
默认指向真函数，`#[cfg(test)]` 下换成记录用的桩。于是测试可以驱动**真实的**
`inject_touch → translator → perform_mouse` 全链路，并断言「实际会发出哪些按键」。
把 `held_keys.apply` 删掉再跑：**2 个测试 FAILED**，其中一条的断言消息就是
`end_gesture must key the stranded Shift up — this is the whole bug`。

**教训**：

1. **注释描述意图，代码实现事实，两者不一致时信代码**——并且要当成缺陷报出来，
   而不是当成注释过时。写注释的人已经想清楚了防御方案，只是没接上。
2. **一个测试必须在删掉被测代码后失败**，否则它测的是测试自己。这个检查很便宜：
   `git stash` 一下改动、跑测试、看红不红。上面两轮我都是靠它才发现问题的。
3. **不可测的分支不会被测试覆盖**。所以「先记下的键忘了写」和「没人调用清理
   函数」可以共存三年还全绿——因为两者都在一个碰不到的平台调用后面。
   要修 bug，先把接缝造出来。


Lesson 116 · 「已排除」最强的形式是换一个完全不同的解码器

2026-10-04，用户说了一句把整件事翻过来的话：**「mac 的摄像头就很清楚，主要就是
Windows 的」**。

同一台手机、同一个编码器、同一个 WiFi。这句话否掉的东西比它确认的多：如果手机的
码流坏了，Mac 也该花；Mac 不花，**手机就不是变量**。而前面三轮 session 的全部诊断
——码率太低、参考帧丢失、关键帧太密——都在假设手机是变量。

### 关键的一步：用产品自己的文件做对照

`docs/demo/remotecrab-demo.mp4` 是**本产品录的**。同一份字节：

| 解码器 | 结果 |
|---|---|
| ffmpeg | **721 帧，零错误** |
| 我们的管线（OpenH264） | **27 帧，728 个 NAL 里 694 个被拒** |

这一步的价值不在「发现了 openh264 有问题」，而在**它不需要手机**。此前每一次
判断都要连手机，而手机每 20 分钟会因为「Mac 抢走 / 手机离开网络 / 要点批准」
失败一次——这就是为什么这个问题过了三轮没人定案。手上本来就有一个可判定的文件，
没人用它。

### 然后必须分离变量

「OpenH264 解不了这条流」不是一个可执行的结论。同一画面重新编码、每次只改一个
变量：

| refs | B 帧 | 结果 |
|---|---|---|
| 4 | 2 | 27 帧（原文件） |
| 1 | 2 | **33 帧** ← 仍然坏 |
| 2 | 0 | **721 帧全过** |
| 1 | 0 | 721 帧全过 |

**是 B 帧，不是参考帧数。** 参考帧数降到 1 也没用。
`openh264::Decoder::decode()` 调的是 `DecodeFrameNoDelay`——「no delay」就是
**不做重排序**，因此解不了带 B 帧的流；而 Mac 两端都是 VideoToolbox，天然支持。

如果只做到「发现某个解码器解不了」，下一个 session 只能换库碰运气。
分离变量之后才得到一句能写进代码注释、能交接、能验证的话。

**教训**：

1. **「A 平台好好的、B 平台坏」不是线索，是排除**。它一次干掉所有关于 A 的假设。
   听到这句话要做的第一件事是**列出被它否掉的假设**，而不是开始调 B。
2. **判定要选一个不依赖最不可靠环节的输入**。这个 bug 的判定用了仓库里已有的
   mp4，而前三轮都在等一台每 20 分钟掉线一次的手机。
3. **「解码器解不了」必须继续问「哪一部分解不了」**。错误码是 `16`／`18`，
   OpenH264 自己的 trace 一开就说 `PrefetchPic ERROR, iNumRefFrames:4`。
   一个裸数字码不是结论。
4. **一个裸数字码 + 自己的 trace = 答案**。openh264-rs 的
   `DecoderConfig::debug(true)` 就是为这个存在的，成本是一次编译。
   没开 trace 就下结论，等于自愿接受一个没有信息量的错误码。

Lesson 117 · 「声称做了」的第 4 次，这次是我自己写的

交接文档里我写了一句「Windows 侧已经加了协议定义和发送逻辑」，写的时候**我还没加**。

这不是笔误，是同一个 session 里第 4 次「测量/记录自己骗人」：

1. 「码率太低」——手机报的 6220 kbps 是**算出来的**，`Quality` 覆盖了它，
   从来没人量过
2. 旧探针的 8% 阈值——在**平铺合成测试图**上量的，真实场景是 12.31%
3. 我自己的 `detail()` 多除了一个帧数，把 309 帧的有纹理采集判成「镜头对着空白墙」
4. 这一条：交接文档里的完成声明

前三条是**测量工具**骗人，这一条是**我自己**骗人，而且是最坏的一种：它写进了
交接文档，Mac 那边会照着它相信「已经做好了」。

**教训**：写「已实现 / 已完成」之前，回去确认那一行代码真的存在。
**交接文档里的完成声明是最强的断言**，因为它是别人唯一的依据，而且他无法验证。
如果不确定，写「准备做」比写「已做」便宜得多。

Lesson 118 · 反向验证要能抓到「什么都没执行」

修「卡住的修饰键」时我第一版测试是同义反复：它自己 new 了一个 `held_keys`
然后自己调 `apply`——**把接线在测试里重写了一遍**。把生产代码里的
`press`/`release` 调用整个删掉，50 个测试依然全绿。

第二版用 `InputTranslator` 手工喂 `MouseAction`，还是全绿，同样原因。

真正的原因是那个记账在 `SendInput` 调用后面，测试够不到——一够到就会在跑测试
的机器上真的按下键。

修法是把 `send_vk`/`send_mouse` 提成 `WindowsInjector` 上的**函数字段**，
默认指向真函数，`#[cfg(test)]` 下换成记录用的桩，测试走真实的
`inject_touch → translator → perform_mouse` 全链路。

现在把 `held_keys.apply` 删掉会红 2 个测试，其中一条的断言消息就是
`end_gesture must key the stranded Shift up — this is the whole bug`。

**教训**：

1. **反向验证（删掉被测代码，测试必须红）每一条都值得做**，它很便宜：
   `git stash` 一下、跑测试、看红不红。本次靠它抓到两个**同义反复**的测试。
2. **测试里复制一遍接线 = 给没人执行的代码签了证**。看起来有覆盖，实际零覆盖，
   **比没有测试更坏**，因为它让人以为这条被测过了。
3. **不可测的分支不会被测试覆盖**，所以「忘了写」和「没人调用清理」可以共存三年
   还全绿——两者都在一个碰不到的平台调用后面。**要修 bug，先把接缝造出来。**


## 146 · 一个会误报的 preflight 比没有 preflight 更糟

2026-10-06 接 145 的反面。`scripts/e2e-parity.sh` 在开跑前检查
「声明的每个 marker 都存在于接收端源码里」，用来发现「断言写着一个
代码早就不打印的 marker」这种腐烂。第一版要求**整个 marker 是源码字面量**，
而**两端都把握手结果格式化**：Mac 打 `reply.result.rawValue`，
Rust 打枚举的 `{:?}` —— 「accepted」这个词**在两个源文件里都不存在**。
于是它对一条完全正常的 marker 误报。

**教训**：**会误报的守检查比没有更糟，因为它教你忽略它** ——
跑三次红之后你就学会跳过它了，然后它真正该抓的东西也一起被跳过。
修法不是放松断言，是把两个概念分开：

* **LITERAL** —— 稳定、能 grep 进源码、防腐烂，preflight 只查这个；
* **MARKER** —— 拿去在 transcript 里断言，**允许**包含格式化的部分。

顺带两条同源的：`--lib` 不编 bin（lesson 142），
以及 preflight 扫描范围要跟着代码走 —— 握手的 marker 住在 `rc-net` 而不是 `rc-app`。

**同一个脚本里另外四个 bug 全是跑出来的、不是读出来的**：
`report` 定义了**从没被调用**（表是空的，我以为它跑了）；
`ROWS+="$1\n"` 在双引号里 `\n` **不展开**，整张表变成一行；
`while read` 少了个重定向，于是读 stdin 立刻结束；
二进制路径写死 `windows/target/debug/`，而 `~/.cargo/config.toml` 把
**所有项目**指向同一个共享 `target-dir`，所以那个路径不存在 ——
现在用 `cargo metadata` 去问输出到底在哪。

**还有一个反向的例子**：那句 abort（`Rust cannot catch foreign exceptions`）
在 macOS 上是 **minifb 开不了 Cocoa 窗口**，而 Windows session 记录它
「真机 + 托盘下**仍无法复现**」。两个观测合起来才是结论 ——
**它是托管方式的产物，不是 Windows 缺陷**。

## 147 · 共享 index：一个提交可以只装下**别人的**文件，而说明和你毫无关系

2026-10-06。两个 session 在**同一个工作树**里干活（`.worktrees/parity-harness`
被删掉之后，第二个 session 直接在主目录开工）。当天被卷走两次，方向相反：

1. 我 `git add` 了 8 个文件，提交出来**11 个** —— 对方在我 add 和 commit 之间
   跑了一次 `git add -A`，那 3 个文件就进了**同一个 index**，被我的说明吞掉。
2. 修好之后反过来：我的 `git commit -F - -- <paths>` 因为 `-F` 写在 `--` 后面
   被当成 pathspec 而**整条命令失败**，就在那个空档里对方的提交
   `feat(mac): raise a desktop alert…` **只包含了我的 6 个文档**，
   它自己的源码改动根本不在里面。**说明和内容完全无关，而且当时没人发现。**

**根因**不是粗心，是「工作树」不等于「提交」：`git add` 写的是**共享的
`.git/index`**，不是某个 session 私有的暂存区。lesson 134 记的是「对方把你正在写
的代码用它的说明推上去」，这一条是它的另一半 —— **你也会把对方的东西用你的说明
推上去**，方向反了而已。

**能落地的防护**（第 2 条救了我两次）：

* **`git commit -F <msgfile> -- <明确的路径>`**。`-F` 必须在 `--` **之前**；
  写在后面会被解析成 pathspec 然后整条失败。显式列路径的提交**对并发的
  `git add -A` 免疫**，因为它只碰你点名的那些文件。
* **每次提交后 `git show --name-status --format='%h %s' HEAD`**，把内容和说明
  对一遍。这是一行命令，而它抓到过一次「说明讲 A、内容是 B」。
* **发现卷进来时用 `git reset --soft HEAD~1`**，它**一个磁盘文件都不动**，
  只回退 HEAD 和 index。**绝不要用 `git reset --hard`**，那才会丢东西。
* 卷进来的文件用 `git restore --staged <file>` 摘出去（保留磁盘内容）。

**推论**：两个 session 共享一个工作树时，**「提交」不是原子的隔离单位**。
要么各开 worktree（代价是共享 index 消失），要么接受历史里会出现混装提交，
并且**每次都验**。
