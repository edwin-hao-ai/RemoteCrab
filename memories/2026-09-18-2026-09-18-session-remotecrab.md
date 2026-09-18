---
type: memory
title: 2026-09-18 Session 收尾:RemoteCrab 全量状态交接
created: 2026-09-18T06:50:10.855413+00:00
source: cli
---

# 2026-09-18 Session 收尾:RemoteCrab 全量状态交接

## 一句话状态
改名 RemoteCrab 完成、Opus 上线、真机 e2e 10/10、触控板四件套(离合器/长按拖选/三四指/震动修复)完成、本地化与无障碍 A/B/D 三类全部收敛。main 领先 origin 130+ commits,**从未 push,push 由用户决定**。

## 本 session 全部 commit(倒序)
- f477e95 D 类 Dynamic Type(onboarding 滚动/键盘预览卡/两行状态行)
- 8dd2b12 B 类 54 处字面量收编 IBLocale
- 448578a A 类 19 条漏翻 + IBStatusPill VoiceOver
- b215ce6 触控板离合器 + ⇧ 选区提示
- e6fb7ff 长按拖选 touchesBegan 修复 + 四指 + 录音会话压震动修复
- e597d18 拖拽 e2e 验证 + moveCursor 屏幕钳制
- 之前:改名、Logo、Opus、CMIO、麦克风驱动等(见更早 memory)

## 踩坑索引(权威记录在 AGENTS.md)
- #8 corollary:xcstrings key 仅大小写不同撞 GeneratedStringSymbols
- #24 长按拖选状态机必须在 touchesBegan/Moved/Ended;moveCursor 钳制
- #25 录音会话 active 压制全 App haptics;MicrophoneEncoder.stop 必须 setActive(false);麦克风流媒体期间震动被压是平台限制
- #26 拖拽离合器三守卫:第二指立即结束/touchesCancelled 立即结束/view 离窗 endDragNow
- 模拟器:simctl 残留进程(bootstatus -b)卡死后续所有操作,ps 找 simctl 杀;headless 截图白屏,open -a Simulator 挂上窗口即恢复;孤儿 TCC alert 会阻塞 SpringBoard,需重启模拟器
- git:index.lock 残留(崩溃的 git 进程)需手动 rm

## 部署状态
真机(iPhone 14, UDID 866A1921-...)已装 f477e95 全量版;安装时手机锁屏未能 launch,用户解锁打开一次即可。iOS bundle id 仍是 com.ibridge.iBridgeCapture(绑 ASC appId 6811599153,不可改)。

## 待用户确认(下个 session 先问)
1. 手感三件套:离合器续拖、⇧ 锁定点按选区、麦克风关闭后的震动
2. 设置 → Replay Onboarding 扫一眼三页(D 类改动后)

## ASC 上架素材(2026-09-16 已由并行 session 完成,更正此前"下阶段主线"的说法)
32 张叙事截图(en-US+zh-Hans × iPhone 6.7 + iPad 12.9 各 8)+ 双语元数据已推送到 ASC,appId 6811599153 version 1.0 处于 PREPARE_FOR_SUBMISSION,**submit for review 由用户手动操作**。详情见 memory "2026-09-16 ASC 上架素材完成" 与 "2026-09-16 Bonjour \032 转义 bug"。素材 pipeline 脚本(capture-asc-raw.sh / compose-asc-screenshots.py / ios-app-store-subtitle.py 等)和 ios-screenshots/ 产物在工作区未提交,属 ASC session 的工作,勿动;原始素材在 build/asc-raw/(git 不跟踪,删了要重采)。

## 更远的 P2
iOS 端主动选 Mac(架构改动);TestWindow 相位标签英文(低);sysex 错误显示系统英文(留作诊断);iPhone 6.5" 截图槽(交给 ASC 自动缩放)。
