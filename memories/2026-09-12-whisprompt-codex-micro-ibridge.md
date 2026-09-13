---
type: memory
title: 借鉴 WhisPrompt / Codex Micro：iBridge 可做的能力清单
created: 2026-09-12T18:17:43.812912+00:00
source: cli
---

# 借鉴 WhisPrompt / Codex Micro：iBridge 可做的能力清单

# 参考产品与可借鉴点

## 参考对象
- **WhisPrompt**（实体 AI Workflow Controller）：语音+触摸，转轮切窗口，动作键，"返回编码 agent"，agent 状态/审批，本地+云语音，Whismart 对光标前文本原地改写。
- **Codex Micro**（Work Louder Creator Micro 2 贴牌）+ 开源生态 `freemicro`/`openmicrokbd`/`open-codex-micro`/`suregoodru/codex-macropad`/`kbd.ctrl`：13 键+旋钮+摇杆；键灯显示 agent 状态；按亮键跳到对应项目/终端；每键可重映射。
- 录写类：Whispur / OpenWhisp / MetaWhisp / VoxPrompt：全局热键 hold-to-talk、多 STT 引擎、LLM 清理、自定义词表、粘贴回退链、按 app 语气、流式预览、选区原地改写、本地历史、MCP 供 agent 语音提问。
- 窗口切换器：StageBar / CircularAltTab / Wheel-Window-Switcher：实时缩略图、径向布局、悬停选择、中键关闭、滚轮循环、多环。

## 已落地（2026-09-13）
- **App switcher**：Mac `appList`(0x0C) → iPhone 切换表（可 pin）→ `activateApp`(0x0E) → `NSRunningApplication.activate()`。
- **键盘 chords**：`⌘⇥` `⌘`` `⌃↑` `⌃↓` `⌘H` `⌘Q`。已有：三指滑动 = Mission Control / Exposé / 切 Space。

## 还未做（按性价比）
1. **语音触发切换**："切换到 Chrome/打开 Xcode" → 意图 → 激活 App（语音 + appList 组合，很便宜）。
2. **剪贴板互通**：iPhone ↔ Mac 复制粘贴（走现有 TCP，便宜且高频有用）。
3. **选区原地改写**（OpenWhisp Refine）：读 Mac 选区（AX `selectedText`，先 ⌘C 兜底），语音说"改正式/翻译"，原地替换。正合 Accessibility 注入。
4. **语音输入增强**：自定义词表（技术术语/代码）、LLM 清理/语气、按 App 切换语气、流式预览、翻译。
5. **agent「需要我」状态**：Mac 检测某终端/agent 完成或等待 → 同步 iPhone → dock 角标 + 通知 + 点按跳回（结合 #1）；可上 iOS Live Activity/灵动岛。
6. **粘贴回退链**：CGEvent 打字在某些 App 会被拒，补 AppleScript/剪贴板兜底（VoxPrompt/OpenWhisp 都这么做）。
7. **窗口缩略图**：给切换表加 ScreenCaptureKit 缩略图（需屏幕录制权限 + 隐私成本，故暂缓）。
8. **Mac 端本地 MCP/bridge**：让 Codex/Claude 能通过 iBridge 语音向用户提问（OpenWhisp 的 MCP server 思路）。
9. **审批**：Mac agent 请求确认时 iPhone 弹允许/拒绝（复用配对授权卡片）。
10. **动态岛/锁屏**：把 Mac 工作状态做成 Live Activity。

## 注意
- 缩略图/窗口标题需要"屏幕录制"权限；纯应用名+图标（`NSWorkspace.runningApplications`）不需要，先做无权限版。
