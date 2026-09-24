# RemoteCrab 会话记录（2026-09-24 深夜）：语音长文丢字根治 + 摄像头按习惯记忆 + iOS 26 SpeechAnalyzer 兼容层

# 一句话
把「按住说话、停顿后丢字/断连」根治了（真机 trace 驱动），加了摄像头习惯记忆，
并加了「iOS 26 有已装模型就用 SpeechAnalyzer，否则回落 SFSpeechRecognizer，永不下载」的兼容层。

## 语音：从「突然断开」到「长文稳定」的完整根因链（全部已 push）
问题表象：说完一句、停顿、说第二句会断/必须重按；后来变成「输入不进去/丢字/上屏慢」。
定位手段：设备端 `Forensic.log`（`Documents/forensic.log`，用
`devicectl device copy from --domain-type appDataContainer --domain-identifier com.ibridge.iBridgeCapture`
拉取）——因为 `idevicesyslog` 看不到设备、`os_log` 也不进 Mac 日志库。**关键**：日志只记计数，
绝不记识别出的文字（隐私）。

根因是**四个叠加问题**：
1. **任何中途 error 都被当致命错误拆会话**。`kAFAssistantErrorDomain` 203(≈1min 上限)/1110(静音)/
   1101/1107/216 其实都可恢复 → `VoiceRecognizer.recoverFromError`：commit 后在**同一 audio engine**
   上静默重启 task；只有「3 秒内连续 5 次快速失败」才 `onInterrupted`。
   另加 **task 身份守卫**（`sessionGeneration`）防止被取消的旧 task 的迟到错误杀掉新 task；
   加 `AVAudioSession.interruptionNotification` 处理来电/Siri。
2. **iOS 18 端侧识别器停顿后会丢弃 `formattedString` 并从 "" 重新开始**，
   而旧逻辑按「字符数」算增量、假设只增不减 → `stable(17) < typed(18)` 时错位，出现「滑滑滑板」这类重复/丢字。
   修法：`result.speechRecognitionMetadata != nil` 标记段结束，把结束段 commit 进 `committedText`，
   让 `onPartial` **只增不减**；`onPartial` 现在带 committed 前缀长度。
3. **投递必须 tail-only**：macOS 按键只落在光标（末尾），`TextDiff.events` 的公共后缀优化会改中间 →
   失效。新增 `TextDiff.tailEvents(from:to:)`（回退变化的尾巴再重打，+5 单测）。
   `CaptureEngine` 实时只打「已定稿前缀 + 稳定一句」（append-only、不停句删），
   每个断句边界做**一次**精确 tail 对齐，松手再对一次。`beginVoiceSession()` 每次按住重置。
4. **长按约 30–40s 后端侧识别开始稀疏丢字、~1min 硬上限**：在句边界且 task >20s 时**主动翻页**
   （先 commit 再换新 task，180ms 让旧 task 释放——立即重建会失败并级联）。

真机验证：58s 长按、2 次主动翻页、所有 reconcile **只向前、零回退**。用户确认「好了」。
浮窗也改成显示**最近一段**（前缀 …），不再把开头截断成「…」。

## 摄像头按习惯记忆（新增）
`FeatureStore.cameraOn` 仍默认关；新增 `CaptureEngine.setCameraEnabled(_:)` 把**用户显式开关**
写入 `remotecrab.ios.cameraOn`，启动时 `restoreStreamHabits()` 恢复。
**自动关（后台/断连/e2e AUTOSTREAM）走 `features.set`，不覆盖记忆。**
只记摄像头、**不记麦克风**（开机自动开麦=隐私/审核风险）。

## iOS 26 SpeechAnalyzer 兼容层（新增，方案 A：零下载、能用就用）
- `RemoteCrabCore/Input/VoiceEngineSelector.swift`（纯函数 +5 测试）：
  `iOS26 && SpeechTranscriber.isAvailable && 目标语言已安装` → `.analyzer`，否则 `.legacy`。**永不触发下载**。
- `VoiceEngine` 协议；`AnalyzerVoiceEngine`（`@available(iOS 26)`）用
  `SpeechAnalyzer` + `SpeechTranscriber(preset: .progressiveTranscription)`：
  final→committed、volatile→尾，映射成本项目已有的 `onPartial(full, committed)` 契约。
  无 60s 上限 → iOS 26 上不需要主动翻页。音频走 `AVAudioConverter` → `AnalyzerInput`。
- `VoiceRecognizer` 对外 API 一行未改（UI/CaptureEngine 不动）：`start()` 先试 analyzer，
  拿不到/失败就无声回落 legacy。
- 已知取舍 v1：analyzer 路径遇到来电/打断会结束本次长按（不自动续），后续可补。
- 模型是**系统按需下载、全系统共享、存在 App 包外**，很多设备（Notes/Apple Intelligence）已装；
  所以只用 `installedLocales` **只读检测**，不弹下载、无审核风险。

## 验证状态
- `./scripts/test.sh`：**161 单测**全绿 + iOS/Mac 两 target 构建通过。
- **真机已确认（iPhone 14 / iOS 26）**：`engine=analyzer`，~45s 真实长句输入、
  reconcile 全部向前（46→48 … 165→166，零回退），用户确认「能正常输入」。
- **踩坑（浪费一个真机 cycle）**：设备已装的模型报 `zh-CN`，而我们申请 `zh-Hans`——
  语义等价但字符串不等，朴素匹配会永远回落 legacy。必须先用
  `SpeechTranscriber.supportedLocale(equivalentTo:)` 把目标 locale 归一，
  再去比 `installedLocales`。设备实测 `installed=["zh-CN","zh-TW"]`、`desired=["zh-CN","en-US"]` → analyzer。

## 产品思考（未落文档，先记着）
- 「让用户不愿用原生键鼠」是错的目标（触屏打字/精确定位永远打不过）。
  真正的 Aha 应是**某几个手机严格更好的场景**（人离开电脑时）。
- **不要做物理小键盘**（Codex Micro 那种）：与「手机就是硬件」的立身之本相反，
  且 Stream Deck 的留存数据说明宏键盘大量进抽屉；其真正价值是**软件层**——
  「不离开窗口就一眼看到 agent 状态 + 一键处理 + 语音下指令」。
- 由此推：RemoteCrab 可能的 Aha = **手机 = 不在电脑前时的「注意力路由器 + 遥控器」**
  （agent 跑完/要批准 → 手机亮/震 → 一键批准/切换/语音下一条）。难点/护城河 = Mac 端接 agent 状态。
- 待用户回答的逼问：**谁**会离开电脑、回来发现 agent 卡在「等你批准」？现在靠什么撑？（决定要不要做）
