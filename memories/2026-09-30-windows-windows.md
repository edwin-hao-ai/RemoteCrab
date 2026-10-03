---
type: project
title: Windows 接收端交接：功能对齐完成，明天上 Windows 机器
created: 2026-09-30T14:38:12.008835+00:00
tags:
  - windows
  - handoff
  - release
  - remote crab
---

# Windows 接收端交接：功能对齐完成，明天上 Windows 机器

# Windows 接收端：交接状态（2026-09-30 晚）

## 一句话

功能对齐完成并已推送；**剩下的全部需要那台 Windows 电脑或一份代码签名证书**。
明天交接。

## 主清单在哪

**`docs/WINDOWS_TODO.md`** —— 按「能做什么 / 为什么 / 怎么验证 / 怎么算做完」组织，
是当前唯一的主清单。

`docs/WINDOWS_HANDOFF_2026-09-30.md` 是背景与进度记录。
`docs/lessons/windows.md` 第 95–104 条是本次的 10 条经验。

## 代码状态

```
Windows 测试  362        Core 测试 367（359 + 8 跨实现契约）
macOS build   0 error / 0 warning
win-gnu check 0 error / 0 warning
clippy -D warnings  两平台均 0
Windows 目标下死代码   0
Mac↔iPhone 真机 E2E   26/26 绿（iPhone 14 / iOS 26.6.2）
```

## 已完成（本次会话）

补齐了 Mac 有而 Windows 完全没有的界面：`SetupAssistantView`（→ 5 页向导窗口）、
`PreferencesView`（→ 设置窗口，含通知拒绝列表编辑器）、`TestWindowView`（→ 四象限自检）、
`CameraExtensionCard`（→ 托盘安装行 + 设置里的按钮）。

其它：通知中继 0x22（**整条链此前是空的**，`rc-protocol` 连结构体都没有）、
`0x23` commandResult 的 dispatch（此前能识别但丢弃 → 手机按钮点了没反应）、
自动更新空闲门控、配对手机 forget、PE version resource + 20 格图标、
自提权安装摄像头、完整卸载、开机自启过期绿勾修复、`--version`、
`--record` 不再自动开录、`check-windows-deps.sh`、`release-windows.sh` + WiX 清单。

## 明天第一件事

**启动代码签名证书采购。** 周期最长，且后面所有发布工作都压在它后面。
注意 CA/Browser Forum 2023 的 HSM 规则：便宜的 OV 证书已无，要确认含 Code Signing EKU。

## 三个最容易让明天的接手者浪费时间的坑

1. **`pkill` 掉手动开的 Mac 接收端再跑 E2E。** 否则脚本带环境变量的启动是
   空操作，断言读空日志，**而 iPhone 在正常推流**——表现成「23 条全红」。
2. **`windows` 依赖必须 target 化，而且挪到 target 段不够**，WinRT 代码必须
   独立成 crate（`rc-notify`）。否则整个 macOS 测试套件编译失败。
3. **别用笼统的 `allow(dead_code)`。** 本次有 14 处，全部改成
   `cfg_attr(not(windows), ...)` 后 Windows 目标下才真正开始审计死代码。

## 关于我自己

这次会话里我**反复把「我做完了」说得太早**，被用户四次指出。真实情况是：
我比的是**文件级**对齐，而缺的是**动作级**——窗口在，但控件是死的
（读了值就丢弃、没有控件用那个 ID、回调被 `take` 走只能点一次）。

**教训：声明完成之前，必须逐个控件/逐个分支验证「它真的做事」**，
而不是「它存在且能编译」。用户的原话：「你确定所有的 UI 的东西和对齐的
东西都完成了对吗？没有留下一些尾巴是不是还是假装完成」——这个质疑是对的，
而且立刻又抓出两个真 bug。
