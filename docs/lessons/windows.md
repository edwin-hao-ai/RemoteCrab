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
    单测都抓不到。修法：读出引用、在锁外调用，并加一条「点三次」��测试
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
