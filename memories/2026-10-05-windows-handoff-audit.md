# Memory: Windows 交接审计 session（2026-10-05）

> 这份记录写给下一个 session 的人，不写给简历。
>
> ## 一句话
>
> 用户让我审计 Windows session 交接给我们四条 bug。**四条真 bug 一条都没做**
> （它们只是被写进了文档），我全部修完并验证；**而第五条「已实现」的断言前提无效，
> 照做就是修一个不存在的病。**

## 交接 ≠ 已实现（lesson 117 的实测）

Windows 10-04 交接的四条，逐条对着代码核：

| 交接项 | 实际 |
|---|---|
| 死掉的 pending 连接锁死手机 | ❌ 代码逐字还是文档里那段 |
| 扬声器习惯静默关麦克风 | ❌ 未修 |
| 4d 包络用累计平均 | ❌ 未修 |
| iOS 接收 `0x25 requestKeyframe` | ❌ 未做 |
| 「加 `NumberOfBFramesBetweenReferenceFrames: 0`」 | 🔴 **前提无效** |

**「已完成」的那些我核了，也基本是真的**：`decode_file` / `renderer_fidelity` /
`vcam_forensics` 三个工具都在（我实跑了 `decode_file`，数字一帧不差）；
`rc-app/src/speaker.rs:484` 真的有 `0x24` 发送路径；Windows 侧确实已改按包测量；
`test.sh` 的 `cargo build --workspace` 门禁补上了。**所以不是交接全都不可信 ——
是不可信的恰好是最关键那条，而它写得最确定。**

## 最有价值的一件事：B 帧问题在一台 Mac 上就答完了

`docs/HANDOFF-MAC-SIDE-2026-10-04.md` 要求「先量当前构建的码流再改 iOS」。
那个文档的证据是解码 `docs/demo/remotecrab-demo.mp4`—— 而那是
`scripts/demo-video.sh:99` 用 `-c:v libx264` 从 **macOS 录屏**生成的
（`1468x1180` 并排合成 vs 产品 `1080x1920`）。

**编码器完全由 key 配置，所以不需要手机**：`scripts/vt-bframe-probe.swift` 拿
`H264Encoder.createSession` 的原样 key 跑真 VideoToolbox，**并带对照组**：

| mode | `AllowFrameReordering` | `has_b_frames` |
|---|---|---|
| shipping | `false` | **0** |
| reorder（对照） | `true` | **2** |

**对照组是重点**：两档都打 0 的话，那就不是「线上没 B 帧」而是「探针看不见
B 帧」—— 输出上完全一样（lesson 76/111）。

诚实边界：macOS 的 VideoToolbox，不是 iOS。能否证，不能证明。

## 我自己犯的错，比我抓到的 bug 更值得记

**① 一件已经做了的事，我写了「没做」。** 我在交接里断言 `0x25`
「没有任何地方发送」，依据是一条 grep。**Windows session 回填：发送端在
`rc-app/src/main.rs:718-738`。我复核——他们对的。** 区别只在于我**在一棵没
拉取的树上 grep**。→ **lesson 148**：交接里的「没做」也是断言，比「做了」更容易
过期，而且**没有任何东西会坏**，只是让下一个人重做一遍。

**② 共享 index 把代码卷走两次。** 一次我 add 8 个提交出 11 个；一次对方的提交
**只装了我的 6 个文档**，源码改动根本不在里面，说明和内容毫无关系。
→ **lesson 147**：修法是 `git commit -F <file> -- <明确路径>`
（`-F` 必须在 `--` **之前**），加每次提交后 `git show --name-status` 对一遍。
发现卷进来用 **`git reset --soft`**（一个磁盘文件都不动），**绝不 `--hard`**。

**③ 我自己的 diff 里有两个真缺陷**：编辑造成的一段注释**重复两遍**
（正是我刚批评 Windows 交接里的那种），和两行被并成一行。都是自查抓到的。
**审自己的 diff 是独立的一道工序，不是提交前的扫一眼。**

## 还开着、且 Mac 侧写代码解决不了的

- **iPhone ↔ Windows 扬声器出声**（协议两端都验过了，就差最后一段）
- `docs/WINDOWS-GAPS-2026-10-03.md` §5.6 的 **10 条**、`PROMPT-WINDOWS-SESSION.md`
  的 **16 条**、`WINDOWS_TODO.md` 的 **37 条** —— 我逐条看过，**全部**是
  「买证书 / 干净 Windows 机器 / 解锁 iPhone 看屏幕」或「明确不做」的决定。
- **Mac 侧**：访达 `PeerIdentity` 修复的真机确认、4 条文案上真机、
  `e2e-parity.sh --input simulator` 真因未知（四个假设都被否，停在「需要新证据」）。

## 给下个 session 的三条操作纪律

1. **交接文档里的每个断言都要 fetch 之后复核，包括「没做」**（lesson 148）。
2. **共享工作树时用显式路径提交，提交后核对内容**（lesson 147）。
3. **自己写的工具，输出判决前先让它能推翻自己** —— 对照组、边界用例、
   或者一条「把旧错误值放回去」的测试。三个反向验证都抓到了东西。