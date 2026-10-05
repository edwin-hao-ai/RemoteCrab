---
title: 交接给 Mac session —— 扬声器模式：解锁 iOS 入口 + 两个必读的真 bug
type: handoff
status: current
last_verified: 2026-10-04
code_baseline: 1176159
---

# 交接：Windows 扬声器采集已完成，iOS 入口等你开

读者：**Mac / iOS session**。写的人：**Windows session**（在 Windows 机器上）。
按项目规矩写在这里而不是聊天里（`docs/HANDOFF-IOS-QUALITY.md` §6 是同一件事的浓缩版）。

---

## 0. 三句话

1. **Windows 侧的扬声器采集已实现并在真机验证出声**（`rms=497 peak=1100`，丢帧 0）。
   iOS 端的隐藏开关**可以删了** —— 但**必须先做第 1 项**，顺序反了会给用户一个关不掉的开关。
2. **`e2e-speaker.sh` 的 4d「形状」断言红着，不是功能坏了**，是那段测量代码数学上
   不可能通过（§3）。如果你先看到它并去查功能，会白查一轮。
3. 本文档给出**可直接贴的 patch**，不需要你自己推导。

---

## 1. 🔴 先修这个：`CaptureEngine.swift:1648` —— 扬声器习惯会静默关掉麦克风

```swift
// CaptureEngine.swift:1648 附近，现有的代码
if UserDefaults.standard.bool(forKey: Self.speakerHabitKey), !features.speakerOn {
    features.set(feature: .microphone, enabled: false)
    features.set(feature: .speaker, enabled: true)
}
```

**这里没有 `connectedIsWindows` 判断。** 那个判断只存在于菜单项
（`ContentView.swift:759`）。完整因果链，每一步都在代码里核过：

1. 用户用 Mac 开过一次扬声器 → `remotecrab.ios.speakerOn` 被持久化；
2. 改连 Windows 接收端 → 上面这段执行：**麦克风关**、扬声器开；
3. `AudioModeArbiter.resolve` 把扬声器排在麦克风**前面**
   （`RemoteCrabCore/Sources/RemoteCrabCore/Audio/AudioModeArbiter.swift:62`）
   → `wantsMicrophone == false` → **麦克风真的不推流了**，音频会话切 `.playback`；
4. 界面显示 `speaker.wave.2.fill` + 高亮（`ContentView.swift:790`），
   **而点开的菜单里没有扬声器那一行**（被 `if speakerAvailable` 挡住）。

**净效果：状态看得见、操作够不着，用户拿到一个哑掉的麦克风，界面不告诉他原因。**
违反 AGENTS.md 规则 1 两次。

### 修法

**第一步**：在 Core 里加一个纯函数（这样能测，符合本项目惯例）。
新建 `RemoteCrabCore/Sources/RemoteCrabCore/Audio/SpeakerRestorePolicy.swift`：

```swift
import Foundation

/// Whether a saved "the phone plays the computer's sound" choice may be
/// resumed on a session that just opened.
///
/// A pure function because the decision is a policy, and because the failure it
/// prevents is invisible: resuming it against a Windows receiver turns the
/// microphone OFF, and the UI that would explain why is itself hidden behind the
/// same platform check.
public enum SpeakerRestorePolicy {
    /// - Parameters:
    ///   - habit: the persisted choice (`remotecrab.ios.speakerOn`).
    ///   - alreadyOn: the snapshot already has it on, so there is nothing to do.
    ///   - connectedIsWindows: whether the peer is the Windows receiver.
    /// - Returns: `true` only when the choice may be applied.
    public static func shouldResume(
        habit: Bool,
        alreadyOn: Bool,
        connectedIsWindows: Bool
    ) -> Bool {
        guard habit, !alreadyOn else { return false }
        // The Windows receiver has no `muteBehavior` equivalent and its capture
        // is the one this app hides behind a menu gate; restoring the habit there
        // would leave the user with a speaker they cannot switch off and a
        // microphone that has gone quiet.
        return !connectedIsWindows
    }
}
```

**第二步**：`CaptureEngine.swift:1648` 改成

```swift
        // The speaker is resumed the way the camera is: it only takes effect
        // once a session exists, so restoring it here cannot capture anything
        // on a computer we are not connected to.
        //
        // NOT on Windows, and that is the whole point of the policy: there the
        // speaker entry is hidden, so resuming the habit would switch the
        // microphone off with no control anywhere to switch it back on
        // (`AudioModeArbiter` puts the speaker above the mic). Fixing the gate
        // is what makes it safe to open the entry in step 2.
        if SpeakerRestorePolicy.shouldResume(
            habit: UserDefaults.standard.bool(forKey: Self.speakerHabitKey),
            alreadyOn: features.speakerOn,
            connectedIsWindows: connectedIsWindows
        ) {
            features.set(feature: .microphone, enabled: false)
            features.set(feature: .speaker, enabled: true)
        }
```

**第三步**：在 `RemoteCrabCore/Tests/RemoteCrabCoreTests/` 加测试（**至少这四条**）：

```swift
import XCTest
@testable import RemoteCrabCore

final class SpeakerRestorePolicyTests: XCTestCase {
    func test_it_resumes_the_choice_on_a_mac() {
        XCTAssertTrue(SpeakerRestorePolicy.shouldResume(
            habit: true, alreadyOn: false, connectedIsWindows: false))
    }

    /// The bug. Restoring against a Windows receiver stands the microphone
    /// down, and the menu row that could switch it back is hidden there too.
    func test_it_never_resumes_on_windows() {
        XCTAssertFalse(SpeakerRestorePolicy.shouldResume(
            habit: true, alreadyOn: false, connectedIsWindows: true))
    }

    func test_no_habit_means_no_restore() {
        XCTAssertFalse(SpeakerRestorePolicy.shouldResume(
            habit: false, alreadyOn: false, connectedIsWindows: false))
    }

    /// Idempotent: the snapshot already carries it.
    func test_already_on_is_not_a_second_restore() {
        XCTAssertFalse(SpeakerRestorePolicy.shouldResume(
            habit: true, alreadyOn: true, connectedIsWindows: false))
        XCTAssertFalse(SpeakerRestorePolicy.shouldResume(
            habit: true, alreadyOn: true, connectedIsWindows: true))
    }
}
```

---

## 2. 然后开 iOS 入口（一行）

**做完第 1 项再做这一步。**

```diff
--- a/RemoteCrabCapture/ContentView.swift
+++ b/RemoteCrabCapture/ContentView.swift
-            let speakerAvailable = !engine.connectedIsWindows
+            let speakerAvailable = true
```

`ContentView.swift:759`。建议顺手把上面那段**重复了两遍**的注释
（745-758 行，`// The Windows receiver does not send kind 0x24 yet` 出现了两遍）
删掉一段 —— 它现在不成立，而且留着会让下一个人以为入口还锁着。

删完之后 `ContentView.swift:780` 的 `if speakerAvailable {` 也可以一并去掉，
变成无条件显示。

**验证**：连 Windows → 手机声音菜单里点扬声器 → 电脑声音从手机出来。

---

## 3. ⚠️ `e2e-speaker.sh` 的 4d 红着，**不是功能坏了**

`SpeakerPlayer.swift:224`：

```swift
let db = 20 * log10(max(receivedRms / 32_768.0, 1e-6))
let digit = max(0, min(9, Int((db + 60) / 6)))
envelope.append(Character(String(digit)))
```

`receivedRms`（`:218`）是**整场累计平均**：

```swift
energySum += sum          // :215
energyCount += count      // :216
receivedRms = energyCount > 0 ? (energySum / Double(energyCount)).squareRoot() : 0   // :218
```

它只在 `start()` 里重置（`:146-149`）。「8 个音符 + 间隙」的**累计均值必然收敛到
音符的电平**，所以**间隙在数学上不可能出现在包络里** —— 长平台是必然结果，
不是「tap 抓不到音符间隙」。

`enqueue` 里每包的 `sum` / `count` **本来就在算**（为了 `peak`），所以修法是一行：

```swift
// 用**这一包**的 rms，不是整场平均。
let packetRms = count > 0 ? (sum / Double(count)).squareRoot() : 0
let db = 20 * log10(max(packetRms / 32_768.0, 1e-6))
```

这样间隙 → 数字 0、音符 → 约 7，`e2e-speaker.sh` 的 4d 会开始有形状。
**建议把它抽成 Core 里的纯函数**（例如 `SpeakerEnvelope.digit(packetRms:)`）+ 单测，
这样「映射对不对」不用真机就能验。

### 3b. 同一个根因让 4c 也变弱

`pcmRms > 500` 用的是同一个累计平均，所以**音频停了它依然很高** ——
检测不出「声音断了」。`docs/WINDOWS-SPEAKER-HANDOFF-2026-10-04.md` §6 点名让
Windows 抄 4c/4d，**Windows 那边已经改成按包测了**；Mac 侧建议一起改，
否则两边同一份断言含义不同。

---

## 4. Windows 侧已经完成的部分（**不要重做**）

| | 状态 |
|---|---|
| 协议 kind `0x24` + `AudioPacket` 复用 | ✅ 两端登记，Windows 侧有「绝不会被当成 H.264 帧」的测试 |
| WASAPI loopback 采集 | ✅ `windows/crates/rc-loopback/`，纯逻辑（环 / 格式转换 / 静音 A/B）**47 个测试** |
| 20 ms / 48 kHz / 立体声 / Int16 / 3840 字节一包 | ✅ 实测 125 包 / 2.5 s = 精确 50 包/秒 |
| `featureState.speakerOn` → 启停 | ✅ `rc-app/src/speaker.rs`，跟随**回显状态**（和 Mac 侧同一条规则） |
| 托盘里的状态行 | ✅ 与 Mac 的 `FeatureStatusRow` 四种状态一一对应（`9091672`） |
| 「静音本机」偏好 | ⚠️ 只有控制台命令 `speaker-mute on`，**还没有 GUI 开关** |

真机数字（`remotecrab --speaker-probe`，Windows 机器，2026-10-04）：

```
  mix format     : F32 48000 Hz, 2 ch
  captured       : 153600 frames (3.20 s)
  packets        : 125 in the 2.5s window (480000 bytes of PCM)
  level          : rms=497 peak=1100
  dropped        : 0 frames
```

细节：`docs/WINDOWS-SPEAKER-2026-10-04.md`。

### 两个和 Mac 语义**故意不同**的地方（别照抄）

1. **Windows 默认不静音本机**，Mac 默认静音。macOS 有 `muteBehavior = .mutedWhenTapped`
   由系统恢复；Windows 只有主音量一个杠杆，进程死了会把用户留在哑的电脑上，
   而且 loopback 采集的是**音量之后**的信号（实测 20,000 振幅进去测到 1,100），
   静音会连采集一起压掉。所以做成运行时 A/B + 崩溃可恢复的 marker 文件。
2. **Windows 的托盘行是状态不是开关**，和 Mac 一致：手机拥有这个决定。

---

## 5. 验收清单

- [ ] `SpeakerRestorePolicy` 四条测试绿，`CaptureEngine` 改用它
- [ ] 连 Windows，手机声音菜单里扬声器项**可见**
- [ ] 手机开扬声器 → **电脑声音从手机出来**（这是唯一还没验过的环节）
- [ ] 手机关扬声器 → 电脑声音回到本机
- [ ] **用 Mac 开过一次扬声器，然后连 Windows** → 麦克风**照常工作**（第 1 项的回归）
- [ ] `./scripts/e2e-speaker.sh` 的 4d 不再是长平台（第 3 项）
- [ ] `0x25 requestKeyframe` 按 `docs/HANDOFF-MAC-SIDE-2026-10-04.md` §6 打勾

---

## 6. 我这边**没做**的（诚实版）

- **第 1、2、3 项全是 Swift**，这台机器**没有 Swift toolchain**，我连编译都做不到。
  按项目自己的规矩（`PROMPT-WINDOWS-SESSION.md`：「别改 Mac / iOS 侧」+ AGENTS.md
  「本端只写文档不改代码」），推一条自己验不了的改动比留一条带数字的交接更糟。
- **iPhone ↔ Windows 端到端**没跑过：需要一台解锁的 iPhone + 这台 Windows 机器。
- **静音偏好的 GUI 开关**被图标表卡住（`generate-windows-menu-icons.py` 需要
  Python + PIL，这台机器没有）。我把它改成了控制台命令，并在
  `ids::SPEAKER_MUTE` 的注释里写清了补齐步骤，另有一条测试钉住「预留但没接线」。