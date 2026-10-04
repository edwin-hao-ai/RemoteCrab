---
title: Windows 扬声器模式 —— 采集已实现并在真机验证（2026-10-04）
type: handoff
status: current
last_verified: 2026-10-04
code_baseline: 本文件所在提交
---

# Windows 侧「用 iPhone 当音箱」：已完成采集 + 真机验证

回应 [`WINDOWS-SPEAKER-HANDOFF-2026-10-04.md`](WINDOWS-SPEAKER-HANDOFF-2026-10-04.md)。
那份交接里的第 1–4 节全部做完了，第 5 节的「Windows 没有等价物」也做成了**可自愈**的，
第 6 节的验收清单变成了一条命令。

---

## 0. 一句话

`WASAPI loopback` 采集已实现，在**这台 Windows 机器上实测出声**（`rms=497 peak=1100`），
协议两端登记完毕，**iOS 端的隐藏开关可以删掉了**。

---

## 1. 真机数字（这台机器，2026-10-04）

用新加的探测命令，播放一个 6 秒的 440 Hz / 48 kHz 立体声 WAV：

```
remotecrab --speaker-probe

  mix format     : F32 48000 Hz, 2 ch
  endpoint       : {0.0.0.00000000}.{64c98063-2154-46ce-8519-8420311959e7}
  captured       : 153600 frames (3.20 s)
  packets        : 125 in the 2.5s window (480000 bytes of PCM)
  level          : rms=497 peak=1100
  dropped        : 0 frames

  ✅ 正常 —— 这台电脑可以把系统声音发给手机。
```

几个值得记下来的数：

| 观察 | 数字 | 说明 |
|---|---|---|
| 包长 | 125 × 3840 = **480000** 字节 | 与 `960 frames × 2ch × 2 bytes` 精确相符 |
| 包率 | 125 / 2.5 s = **50 包/秒** | 正好 20 ms 一包，没有漂移 |
| 丢帧 | **0** | 环形缓冲 + pump 在稳态下不丢 |
| 混音格式 | `F32 48000 Hz 2ch` | 和 Mac 侧 tap 的格式一致，无需重采样 |
| 电平 | rms 497 / peak 1100 | WAV 振幅是 20000；见下面「一条被测出来的限制」 |

### 一条被测出来的限制（交接里问的是「未知」）

WAV 振幅 20000，测到 peak 1100 —— **约 17%**。这台机器的系统音量本身就不高，
所以比例对得上。结论：**Windows 的 loopback 采集的是「音量之后」的信号**。

这条很重要，因为交接第 5 节问「压主音量会不会把采集一起压掉」：**会**。
所以 `MuteBehaviour::MuteLocal` 不是可以赌的东西，`rc_loopback::MuteWatch`
在运行时做 A/B：静音前有声音、静音后连续 1.5 秒（75 包）为**数字静音**，
就自动把音量恢复并在托盘说明。没测到静音前有声音的情况**不做任何动作**
（`MuteVerdict::Inconclusive`），因为在安静的机器上「猜着恢复」只会突然放出声音。

**音量恢复做了三层**，因为「进程死了电脑变哑」是这个功能最坏的失败方式：
1. `stop()` / `Drop` / pump 退出 —— 三个出口都恢复；
2. **动音量之前**先写 `%APPDATA%\RemoteCrab\speaker-muted-marker`，
   `main()` 的**第一行**（`--version` 之前）检查它并恢复，所以崩溃也可恢复；
3. 只在音量**确实是 0** 时才动 —— 用户自己调高过就说明那是故意的。

默认是 `MuteBehaviour::KeepLocal`（本机继续播放），和 Mac 侧默认静音**不一样**，
原因就是这个不对称：macOS 的 `muteBehavior = .mutedWhenTapped` 由系统恢复，
Windows 只有主音量一个杠杆。要静音用控制台命令 `speaker-mute on`。

---

## 2. 落地的东西

| 文件 | 内容 |
|---|---|
| `windows/crates/rc-loopback/`（新 crate，**47 个测试**） | WASAPI 采集 + 环形缓冲 + 格式/采样率转换 + 静音 A/B |
| `windows/crates/rc-app/src/speaker.rs`（新，**21 个测试**） | 策略、pump、偏好、崩溃恢复、探测命令 |
| `rc-protocol/src/events.rs` | `FeatureStateSnapshot.speaker_on`（`#[serde(default)]`，+3 测试） |
| `rc-app/src/main.rs` | `featureState.speakerOn` → 启停；启动时恢复音量 |
| `rc-app/src/console.rs` | `speaker-mute on\|off` |
| `rc-app/src/args.rs` | `--speaker-probe` |

**纯逻辑都放在能跑测试的地方**：环形缓冲、格式转换、静音 A/B、启停策略、
偏好文件往返 —— 全都不需要音频设备，也不需要 Windows。COM 那层是薄薄一层。

### 和 Mac 侧刻意保持一致的部分

`docs/WINDOWS-SPEAKER-HANDOFF` 第 2 节的对比表全部照做：20 ms / 48 kHz / 立体声 /
Int16、3840 字节一包、kind `0x24`、复用 `AudioPacket` 一个字段不加、500 ms 环形、
**每个索引只有一个写者**、跟随手机回显的状态而不是请求、每 tick 最多 20 包、
状态文案必须带「该做什么」。

---

## 3. 途中被测试抓到的四个真 bug（都不是我先想到的）

**① 环形缓冲的丢帧计数是二次增长的。**
第一版把「该丢多少帧」存成**增量**计数，每次 push 都把整个积压再加一遍，
于是总量按平方增长，消费者应用了一个比写入量还大的丢弃数，`read` 越过 `write`，
`wrapping_sub` 报出一个巨大的 available。
**只有双线程测试能抓到** —— 单线程下两个游标永远不会错开，所以单线程测试对一个
用 relaxed store 发布样本的实现也一样通过。改成发布**绝对位置**。

**② 降采样路径从来没读过上一缓冲区的帧。**
`let i = pos.floor() as isize;` 之后立刻 `i as usize`，于是 `if i < 0` 永远是假的，
`prev` 那个字段根本是死的。只有**源采样率高于 48 kHz** 时才会走到这个分支 ——
96 kHz → 48 kHz 的测试立刻抓到（960 帧进去应该出 480 帧，实际出了 1919 帧）。

**③ 采样率换算的比例写反了。**
`step` 应该是 src/dst，我写成了 dst/src。44100 → 48000 恰好是放大，所以
「44.1 kHz」那条测试的数字看着还行（405 vs 480，容差宽），96 kHz 那条直接抓到。

**④ `E_INVALIDARG` —— `WAVEFORMATEXTENSIBLE` 被截成了 18 字节。**
真机上 `IAudioClient::Initialize` 返回 **0x80070057**。原因是 loopback 的混音格式
在现代 Windows 上是 `WAVEFORMATEXTENSIBLE`（IEEE float 的 subformat 就在那里面），
而我只拷贝了 18 字节的 `WAVEFORMATEX` 头就交给 `Initialize`，
它拿到的是 40 字节描述符的前 18 字节。**每台这样的机器都会失败。**

这个只有 `--speaker-probe` 能抓到 —— 它打印 HRESULT。没有那个数字的话，
「初始化失败、0 帧」和「这台机器没有音频输出」看起来一模一样。

**教训（值得进 lessons）**：这不是「WASAPI 难」，是**探针必须打印错误码**。
人话文案给用户行动，`HRESULT` 给开发者定位，两个都要有。

---

## 4. 打开 iOS 端的入口（一行）

`RemoteCrabCapture/ContentView.swift:759`：

```swift
// 现在可以删掉了 —— Windows 侧采集已在真机验证出声（rms=497）：
let speakerAvailable = !engine.connectedIsWindows
```

**⚠️ 但 Mac session 那边还有一个必须一起改的 bug**，否则删这行会打开一个陷阱 ——
见第 6 节。

---

## 5. 剩下的

| 项 | 谁做 | 说明 |
|---|---|---|
| **iOS 隐藏开关（第 4 节）** | Mac session | 一行，但它和第 6 节必须一起改 |
| **扬声器习惯 gate（第 6 节）** | Mac session | **真 bug**，会让 Windows 上麦克风被静默关掉 |
| **托盘里的静音开关** | 本机 | 需要 `generate-windows-menu-icons.py`（Python + PIL），这台机器上没有。**预留的 `ids::SPEAKER_MUTE` 和完成步骤都写在注释里**，并且有一条测试钉住「预留但没接线」这个状态 |
| **真机 + iPhone 端到端** | 需要一台有 iPhone 的机器 | 采集侧已验证；`0x24` 的线路还没在 Windows↔iPhone 之间跑过 |
| **启动瞬间的丢帧** | 待观察 | 探测命令在自己预热阶段不 drain 时会丢 ~9000 帧（它自己造的积压）；加上预热 drain 后是 0。真机上如果持续丢，`ring` 的 500 ms 可能要加大 |

---

## 6. 🔴 交给 Mac session 的两个 iOS 侧问题（我这里验不了，按规矩只写不改）

### ① 扬声器习惯会在 Windows 上静默关掉麦克风

`RemoteCrabCapture/CaptureEngine.swift:1635`，每次连接都会恢复
`remotecrab.ios.speakerOn`：

```swift
if UserDefaults.standard.bool(forKey: Self.speakerHabitKey), !features.speakerOn {
    features.set(feature: .microphone, enabled: false)
    features.set(feature: .speaker, enabled: true)
}
```

**这里没有 `connectedIsWindows` 判断。** 那个 gate 只加在菜单项上
（`ContentView.swift:759`）。后果链条：

1. 用户先用 Mac 开过扬声器 → 习惯被持久化；
2. 改连 Windows → 上面这段把**麦克风关掉**、扬声器打开；
3. `AudioModeArbiter.resolve` 里扬声器优先级高于麦克风
   （`AudioModeArbiter.swift:62`）→ `wantsMicrophone == false` → 麦克风真的不推流了；
4. 界面显示 `speaker.wave.2.fill` + 高亮（`ContentView.swift:790`），
   **点开的菜单里没有扬声器那一行**。

也就是说：**状态看得见，操作够不着**，而且用户拿到的麦克风是哑的，
界面不会告诉他原因。违反 AGENTS.md 规则 1。

**修法**：在 Core 里加一个纯函数（例如
`speaker::shouldRestore(habit:connectedIsWindows:)`）+ 单测，然后

```swift
if UserDefaults.standard.bool(forKey: Self.speakerHabitKey),
   !features.speakerOn,
   !connectedIsWindows {
```

**为什么必须和第 4 节一起改**：在 Mac session 修好这一条之前删掉那个 gate，
Windows 用户就会得到一个**点不掉的扬声器开关**。先修这个，再开入口。

### ② e2e 4d「形状」断言红着的真正原因，是累计平均

`SpeakerPlayer.swift:203-214`，包络那个字符是用 `receivedRms` 算的，
而 `receivedRms` 是**整场累计平均**（`energySum += sum` / `energyCount += count`，
只在 `start()` 重置）。

「8 个音符 + 间隙」的累计均值必然收敛到音符的电平，**数学上不可能显示间隙** ——
所以包络是长平台是必然结果，不是「tap 抓不到音符间隙」。
`enqueue` 里每包的 `sum` / `count` 本来就在算（为了 `peak`），
把数字改成用每包的 `sqrt(sum/count)` 就能出形状（间隙 → 0，音符 → 7）。

**同一个根因也让 4c 变弱**：`pcmRms > 500` 也是累计平均，音频停了它依然很高，
检测不出「声音断了」。而 `docs/WINDOWS-SPEAKER-HANDOFF` 第 6 节点名让 Windows 抄
4c/4d —— **要抄就抄修好的版本**。

**为什么我没改**：改的是 Swift，而这台机器上没有 Swift toolchain，
我连编译都做不到。按项目自己的规矩（`PROMPT-WINDOWS-SESSION.md`：
「别改 Mac / iOS 侧，除非任务明确要求」+ AGENTS.md 的「本端只写文档不改代码」），
推一条自己验不了的改动比留一条带数字的交接更糟。

---

## 7. 本机验证记录

```
cargo test --workspace            493 passed / 0 failed   （改动前 422）
cargo clippy --workspace --all-targets -- -D warnings    exit 0
cargo build --release -p rc-app --target x86_64-pc-windows-msvc   OK
scripts/check-windows-deps.sh …/remotecrab.exe               OK（19 个 DLL）
remotecrab --speaker-probe           rms=497 peak=1100 dropped=0
```

`clippy -D warnings` **在本轮之前是红的**（exit 101）：当时工作树里有另一个 session
未提交的 `rc-render/src/pixels.rs` + `examples/renderer_fidelity.rs`，后者引用了
两个已不存在的方法、根本编译不过。那个 session 后来把它们删掉了，门禁恢复全绿 ——
所以**这条命令此前并没有被真正跑过**，文档里「两平台 clippy 全 0」是不成立的。