---
type: memory
title: 并行 session 推 main 导致 push 被拒（三次）——每次 fetch+求交集+合并后重测
created: 2026-10-03T10:46:43.121974+00:00
source: cli
---

# 并行 session 推 main 导致 push 被拒（三次）——每次 fetch+求交集+合并后重测

# 协作踩坑：并行 session 会不断推 main（lesson 92 的持续形态）

这一轮 push 被拒了**三次**，每次都是另一个 session（Windows 侧）先推了东西。

## 事实

- 第 1 次：落后 10 个提交（WiX manifest / MSI / vcam ring 权限）
- 第 2 次：落后 4 个提交（MSI 卸载状态、install-to-use cycle）
- 第 3 次：又是 4 个

## 每次都先核对再动

关键动作是 **`git diff --name-only main...origin/main | sort` 和
`git diff --name-only origin/main...main | sort` 求交集**，确认**文件零重叠**
再合并。三次都是零重叠，合并干净、合并后立刻跑 `./scripts/test.sh` 全绿。

不要因为「文件名看着不一样」就放心——我第一次也这么想的，第二次直接用
`comm -12` 求了交集。**用工具求交集，不要靠眼看。**

## 记录

AGENTS.md lesson 92 记录的是「并行 session 会提交我的工作树」以及 `reset`
变体。这是同一问题的**推送侧形态**：不是我的工作树被改，是我的 push 被拒。
两次的共同教训是——**并行 session 之间唯一的协调手段就是每次动手前
`git fetch` + 求交集 + 合并后重跑测试**。

## 附带：mddock vault

`memories/2026-09-30-windows-windows.md` 这个未跟踪文件是**另一个 session**
（Windows 侧）的记忆笔记。我一直没动它，也没删它——它在仓库根目录、
不属于我的文件。如果它该进 `.gitignore` 或者该提交，那是用户/那个 session
的决定。
