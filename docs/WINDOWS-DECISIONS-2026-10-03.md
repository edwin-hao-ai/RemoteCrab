---
title: Windows 接收端 — 体积决定、签名后果、以及一个 ACL 问题
type: decision
status: current
last_verified: 2026-10-03
---

# 三个结论：文件体积、不签名的后果、共享内存的 ACL

日期：2026-10-03 · 用户决定 + 本机核查

---

## 1. 文件体积：不拆，这是有意的决定

用户明确决定：**不拆分超长文件**，理由是"没有超出很多，后面注意点就好"。

**记录一下真实数字**，免得以后某个 session 把它当成待办重新翻出来：

| 文件 | 行数 | 相对 800 硬上限 |
|---|---|---|
| `rc-app/src/main.rs` | 1168 | +46% |
| `rc-app/src/tray_menu.rs` | 1102 | +38% |
| `rc-net/src/supervisor.rs` | 1040 | +30% |
| `rc-input/src/injector.rs` | 938 | +17% |
| `rc-protocol/src/events.rs` | 932 | +17% |
| `rc-app/src/tray.rs` | 882 | +10% |
| `rc-app/src/doctor.rs` | 809 | +1% |

**不是"超出一点"，但这是用户的决定，不是疏漏。** 真正的理由（也是我同意的）
是：拆分 `main.rs` 的真正难点不是文件大小，而是 `run()` 本身是一个 **850 行的
函数**，里面塞了启动、select! 循环、以及七八个事件分支。把它拆成模块是搬移，
把它拆成可读的结构是重构 —— 后者会改变行为，而项目规矩是"重构单独一轮、
必须有测试证明等价"。为了凑行数而做的拆分只会把一个难读的函数变成几个
一样难读的函数。

**留下的实际风险**：`main.rs` 里那个 850 行的 `run()`。它的编译期保护是
389 个测试；如果将来要动它，规矩是"先补测试证明你读懂了它在做什么"。

---

## 2. 不签名会发生什么

**先说结论：能装、能用。** 未签名的 exe 跑得起来。SmartScreen 会显示
"Windows 已保护你的电脑"蓝屏，用户点"更多信息" → "仍要运行"，两次点击。

**但真正的风险不是 SmartScreen。**

### 触发 SmartScreen 的是"下载"，不是"未签名"

浏览器下载的 exe 会带 **Mark-of-the-Web**（NTFS 的 `Zone.Identifier` 备用数据流），
是它触发 SmartScreen。所以：

- 从浏览器下载 → 有 MOTW → SmartScreen 提示（未签名也一样）
- `irm … | iex` 内存执行 → **没有 MOTW → 完全不触发**
- 刻录成光盘 / 拷贝到 U 盘 → 没有 MOTW → 不触发

### 真正会被拦的是杀软，而这个产品的行为画像正好是目标

这个程序同时做这些事：

1. `SendInput` **往所有进程**注入键盘和鼠标
2. 写 `HKLM`（COM 组件注册，需要管理员）
3. 在系统上**创建一个虚拟摄像头**
4. 创建一个 **NULL DACL 的共享内存文件**（见 §3）
5. 一个 COM DLL 被 **Frame Server（以 LocalService 运行）加载**

这五条组合起来，正是启发式引擎的典型目标：**"一个往所有进程注入输入、
还往 HKLM 写东西的程序"**。Defender 的行为式检测不靠特征码也能命中；
国内用户常装的 360 / 火绒 / 腾讯管家更敏感。**被直接隔离、
用户连"为什么被拦"都看不到，是真实概率。**

签名买的主要是**杀软信任**，不是 SmartScreen 豁免 —— 微软文档明说 EV 自 2024
起也不再提供即时豁免。**所以"先不签名、靠 irm|iex 发"的路线在技术上是成立的，
真正的风险是杀软误报，而不是 SmartScreen。**

### 其他

- **企业环境可能直接禁未签名**（AppLocker / WDAC 策略），这类环境完全进不去
- **驱动必须 EV 证书** —— 将来如果做虚拟麦克风（sysvad）或扩展屏（IddCx），
  微软要求 EV。这是 EV 唯一还值得付钱的理由
- `irm | iex` 的真实代价：用户看到的是一条吓人的命令、PowerShell 执行策略
  可能拦、无法校验来源

---

## 3. ⚠️ 一个和签名无关、但更该修的安全问题

`vcam-ring.bin` 用的是 **NULL DACL**：

```rust
// windows/crates/rc-vcam/src/writer.rs:59
SetSecurityDescriptorDacl(psd, true, None, false)?;   // ← None = NULL DACL
```

NULL DACL 的含义是**给所有人完全访问权限**。而这个文件在
`%ProgramData%\RemoteCrab\vcam-ring.bin`，也就是：

- **任何进程、任何用户都可以往里写帧** —— 也就是可以往虚拟摄像头里注入任意画面。
  任何用 `RemoteCrab Camera` 的应用（Zoom / Teams / OBS / 浏览器）都会把它
  当成真实摄像头画面显示
- **任何进程都可以读它** —— 也就是能看到正在传输的内容

**当初为什么这么做**：Frame Server 以 `LocalService` 运行在另一个 session，
需要能打开这个 section，而当时没做细粒度 ACL。这是可以理解的，
但"图省事"的后果留在了产品里。

**修法**：文件创建后立刻用 Windows 自带的 `icacls` 收紧到四个主体：

```
icacls vcam-ring.bin /inheritance:r /grant:r \
    "SYSTEM:(F)" "Administrators:(F)" "LOCAL SERVICE:(F)" "INTERACTIVE:(F)"
```

`/inheritance:r` 会剥掉父目录继承来的 ACE，所以不会有别的东西把它放宽回去。

**为什么用 `icacls` 而不是 `SetEntriesInAclW`**：手写四个 SID 的 DACL 意味着
`CreateWellKnownSid` + `SetEntriesInAclW` + 一个自相对描述符缓冲区（还得活过两次
`Create*` 调用）—— 一百行 `unsafe`，失败模式是"在别人机器上摄像头突然不工作"。
`icacls` 是 Windows 为这件事自带的工具，而且它吃**账户名**，没有 SID 编码可写错。
代价是每个会话多一个子进程。

**实测（三个进程，只有一个是我们的）**：

| 进程 | 身份 | 作用 |
|---|---|---|
| `remotecrab --vcam-selftest` | 交互用户 | 写 ring |
| `rc_vcam_source.dll` | **LocalService，session 0** | 读 ring |
| `vcam_consume` | 本 shell | 读相机 |

如果 ACL 收得过紧，断的正是第二个（Frame Server）。所以 **PASS 就是
`LOCAL SERVICE:(F)` 必要且充分的证据**：

```
permissions AFTER:
  NT AUTHORITY\INTERACTIVE:(F)
  NT AUTHORITY\LOCAL SERVICE:(F)
  BUILTIN\Administrators:(F)
  NT AUTHORITY\SYSTEM:(F)

RESULT: PASS — a real MF consumer received 11 samples with 34560 changing bytes
```

**不需要手机。**
