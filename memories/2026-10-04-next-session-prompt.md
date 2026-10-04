---
type: handoff
title: 下一个 session 的开场 prompt —— iOS Windows 兼容 + 触控板方向
created: 2026-10-04T07:50:00+00:00
source: cli
---

# 交给下一个 session（直接粘贴下面这段）

---

## 你的任务：把触控板移动方向这件事查完并修掉

上一轮 session 的 iOS 侧工作已全部提交推送（`main` 与远端同步，491 测试全绿）。
**只剩一件事没做完**，就是下面这一件。

### 🔴 唯一未完成：触控板指针移动方向

**用户报告**：在 Windows 上，手指往左拖，光标往右走。用户已确认
**在屏幕中间、小幅拖动就会反向**（不是只有到边缘才出现，也不是冲过头）。

**已经查清、不要重新推导的结论**：

- 整条链读下来**两端没有任何取负**：
  - iOS：`rawDX = (location.x - last.x) / uniformReference`（手指往右 = 正）
    → `TrackpadMath.accelerate` 是 `dx * gain`（正增益）
    → `emit(dx:)` 直传
  - Mac：`lastCursor.x + dx`
  - Windows：`last_cursor.0 + dx`
- `git log -S` 显示 **Windows 那个 move 计算只有一个提交**
  （`1016b22`，最初的 P1 接收端），**历史上从未取过负**。
- 两端的边界钳制也等价。
- 所以：**代码解释不了这个症状**。上一轮因此拒绝再猜一轮，改成测量。

**上一轮已经就位的两块基础设施**：

1. **方向不变量测试**（`RemoteCrabCore/Tests/RemoteCrabCoreTests/TrackpadMathTests.swift`）
   —— 加速度 / 选择曲线 / 滚动曲线都断言「只缩放、绝不反射」，任何灵敏度/速度/两个轴，
   外加**增益上界**断言（增益失控或 NaN 会让小幅拖动冲过目标，用户很容易说成
   「往另一边去了」）。提交 `c48773b`。
2. **手机端诊断**（`RemoteCrabCapture/Input/TouchSurface.swift`，
   `REMOTECRAB_E2E_TRACKPAD_DIR=1`）—— 每 12 次 move 往 forensic.log 写一行：

   ```
   [dir] n=<序号> fx=<手指x> prev=<上次x> ref=<归一化基准> out.dx=<带符号> out.dy=<带符号> speed=<指针速度> w=<表面宽>
   ```

   正式 build 里完全惰性。**方向定案后请删掉它。**

### 第一步：请用户滑一下手机

诊断 build 上一轮已装到手机并启动过，但**不要假设它还在** —— 版本号
（`2026092404`）和 App Store 版一样，改不了；要看二进制：

```sh
# 确认 build 里有诊断标记（真代码在 .debug.dylib，主二进制只有 92KB）
strings .build/e2e-derived/Build/Products/Debug-iphoneos/RemoteCrabCapture.app/RemoteCrabCapture.debug.dylib \
  | rg -c REMOTECRAB_E2E_TRACKPAD_DIR

# 需要就重装 + 重启（带上诊断开关）
xcodebuild -project RemoteCrabCapture.xcodeproj -scheme RemoteCrabCapture -configuration Debug \
  -destination "id=866A1921-B588-59D5-A1B7-B266103B2E49" \
  -derivedDataPath "$PWD/.build/e2e-derived" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic
xcrun devicectl device install app --device 866A1921-B588-59D5-A1B7-B266103B2E49 \
  .build/e2e-derived/Build/Products/Debug-iphoneos/RemoteCrabCapture.app
xcrun devicectl device process launch --device 866A1921-B588-59D5-A1B7-B266103B2E49 --terminate-existing \
  --environment-variables '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_SURFACE":"trackpad","REMOTECRAB_E2E_TRACKPAD_DIR":"1"}' \
  com.ibridge.iBridgeCapture
```

然后请用户**在触控板上左右各滑几下，每段慢一点、停约一秒**，读日志：

```sh
xcrun devicectl device copy from --device 866A1921-B588-59D5-A1B7-B266103B2E49 \
  --domain-type appDataContainer --domain-identifier com.ibridge.iBridgeCapture \
  --source Documents/forensic.log --destination /tmp/f.log
rg '\[dir\]' /tmp/f.log
```

### 判读表

| 日志显示 | 结论 | 下一步 |
|---|---|---|
| 手指往左的行 `out.dx` 为**负** | **iOS 侧正确** → 问题在 Windows 接收端 | 给 `windows/crates/rc-input/src/injector.rs` 的 `TouchPhase::Move` 分支加一行日志（打印收到的 `event.dx` 和算出的 `Move{x}`），请用户在 Windows 上跑一次，两边一比即定位 |
| 手指往左的行 `out.dx` 为**正** | **是 iOS 的 bug，就在本机** | 直接修，并补一条断言「手指向左时 out.dx 必须为负」 |
| `out.dx` 符号对但幅度异常大/为 0 | 增益或 `uniformReference` 问题 | 看同一行的 `ref=`、`speed=`、`w=` |

⚠️ **只有一行日志不够** —— 一次连续滑动会产生很多行，必须能**成对比较**：
找出「手指明显向左移动」的行和「手指明显向右移动」的行，看 `out.dx` 的符号是否相反。

### 顺带说明：加速度不是「没了」，是变了

用户提到「加速度怎么也没了」。查清：`c2bd246`（2026-09-25「real pointer
acceleration」）把加速度从「按单次事件位移」改成「按**速度**」，`maxBoost` 2.0→2.5。
而**旧代码的加速几乎从未生效**（其注释自陈 "acceleration silently never
engaged"）—— 所以用户习惯的那套一直是「几乎无加速」，现在真的开始加速了。
日志里的 `speed=` 和 `out.dx=` 能直接看出这版对不对。

---

## 已完成、不用重做（上一轮 session）

**iOS 的 Windows 兼容（4 个提交）**

- `33e2183` 修饰键行：`IBShortcutBar`（触控板+投屏共用）没传 `platform`，走缺省 `.mac`，
  所以 Windows 用户在最常用的两个界面看到 ⌘。四处 `platform` 现在**都没有默认值**。
- `7fbbf81` Windows 系统区三个说谎的按钮：「显示桌面」原来发 **keycode 53 = Escape**
  （`keymap.rs:105`）、浏览器图标是 `safari.fill`、语音 hero 渲染两次。Mac 侧零改动。
- `84f30fa` 设备列表一个电脑一行（同名合并 + 30 天过期）。
- `14045b3` 审计轮：手势说明页 5 行按平台分流（原 catalog 里 `pinchZoom` 根本没条目）、
  VoiceOver 标签（Windows `Ctrl+Z` 被念成「Mission Control」）、
  context chip 的英文 `"Computer"`。
- `15cd3e7` 审计又抓到 2 个：`pruneStale` 的 count 早退跳过了悬空偏好清理；
  **「Forget」只清 `paired` 而列表读 `seen`**，所以点了 Forget 那台机器还在。

**切换/断开重构（2 个提交）**

- `08fa2ca` 失败切换会把**所有人**锁死 10 分钟（`decide` 无条件回 `busy`，TTL 10 分钟）。
  改为 **30 秒宽限期**，判据在 store 的 `effectivePreferred()`，policy 里不含时间概念。
- `2ba45ad` **选择列表可能一台电脑都不列** —— 行过滤按**名字**排除待批准那台，
  而这台机器当时有**两台都叫 EDWIN**；拿真实数据代进旧规则 `old rule lists: []`。
  ⚠️ 这个 bug **无法用「改一个值」逆向验证**（修法是删掉一个输入，旧行为无法表达），
  证明方式是拿真实数据跑旧规则。另外切换进行中的状态之前**只在选择面板里渲染**，
  主界面完全没有提示；Mac 端只说「正被占用」并给一个永远不可能成功的 Retry。

**归档**：lessons 118–122 + 130–136、`memories/2026-10-04-ios-windows-parity-audit.md`、
AGENTS.md session 条目、测试数 491。

---

## 已确认、故意没修（留给 Windows session）

**Windows 屏幕镜像滚动没取负**，而 Mac 的取了负：

| 路径 | Mac | Windows |
|---|---|---|
| 触控板双指滚动 | 取负 ✓ | 取负 ✓ |
| **屏幕镜像滚动** | 取负 | **没取负** ✗ |

铁证：`windows/crates/rc-input/src/injector.rs` 里两个测试**互相矛盾** ——
`scroll_is_inverted_and_gained`(第 416 行) 期望 `dy=0.1 → -120`（取负），
`scroll_becomes_wheel_deltas`(第 664 行) 期望 `dy=0.0625 → +75`（不取负）。
两个测试各自都绿，因为测的是两条不同路径，**没有任何测试断言两条路径方向一致**。

**为什么留着**：那是**镜像**的症状，和本 session 查的移动方向是另一个问题。
把符号改动叠在一个还没定性的方向问题上，会让两个都更难查。
**用户已同意由本 session 直接修，但建议你先修完移动方向再动它。**

---

## 已知的环境阻塞

**整个 session 没有一次 e2e 全绿过。** 三次跑 `./scripts/e2e-device.sh` 都是
22 个失败，根因只有一个：**手机被另一台 RemoteCrab 接收端占着**：

```
[receiver] sessionReply: busy owner=EDWIN
```

这是**正确行为**。一锤定音的是读手机持久化的 `seenComputers`（别从日志推断）：
当时两条 `…-98db…` **node 相同、id 不同** = 同一台机器两个身份。
**跑 e2e 前先确认那台机器没连着手机。**

目前状态：这台 Mac（`ECBDD7BA`）已重新拿到手机（`streaming`）。
手机上还有一条 `forensics` id 的记录 —— 并行 session 的探针工具，客户端 id 直接
写了字符串 `forensics`，可以忽略。

---

## 这个仓库的坑（会浪费时间，值得先知道）

1. **共享工作树 + 并行 session 不断推 main。** 推之前必须
   `git fetch` → `git diff --name-only HEAD...origin/main | sort` 求交集确认零重叠 → 合并
   → 重跑全套 → 再推。历史上被拒过三次。
2. **`git add -A` 是双向陷阱。** 我捞进过别人的半成品（把 main 弄编译不过），
   也被别人捞走过正在写的代码（提交说明是对方的，历史说谎）。
   **只 stage 自己明确改过的文件。**
3. **Debug build 的真代码在 `RemoteCrabCapture.debug.dylib`**，主二进制只有 92 KB。
   用 `strings` 验证标记时查错文件会得到假阴性。**而且版本号不变**
   （`2026092404` 和 App Store 版一样），**不能用版本证明装的是新 build**。
4. **Lesson 编号是共享空间** —— 上一轮就撞过 123/124/125 重复。归档前先查重。
5. **反向验证必须有效果。** 「把代码改回旧样子，断言却还绿着」= 你的 revert 没生效
   （这个坑我踩了两次，都是 python patch 静默没匹配）。
6. **断言要在真机上验。** 「ctx chip 显示 Computer」这个 bug 测试全绿，
   是**看真机截图**才发现的（英文界面下它根本不存在）。
7. **`./scripts/e2e-device.sh` 会备份并还原 `/Applications/RemoteCrab.app`**
   （lesson 80 的修复，已反复验证有效，CDHash 前后一致）。
8. `/Applications/RemoteCrab.app` 是用户的 Developer ID build 11，
   CDHash `d9dacda991ffaa8a1a32aff7abacf9b38b945549` —— **别破坏它**。