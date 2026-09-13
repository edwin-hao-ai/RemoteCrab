---
type: memory
title: iBridge 图标重设计：Liquid Glass 显示器小伙伴（2026-09-10）
created: 2026-09-10T15:34:51.696327+00:00
source: cli
---

# iBridge 图标重设计：Liquid Glass 显示器小伙伴（2026-09-10）

# iBridge 图标重设计决策与经验

## 最终决策
- 图标 = 「显示器小伙伴」吉祥物（带笑脸的玻璃小显示器 + 信号天线），Liquid Glass 质感
- 矢量主文件：`assets/app-icon-liquid.svg`（手工 SVG，原创）
- 管线：`rsvg-convert -w 2048` 渲染 → PIL Lanczos 降到 1024 → `scripts/generate-ios-app-icons.py` 生成全套 14 尺寸
- 菜单栏图标 = 同一角色的 Canvas 单色线条版，天线球兼作连接状态灯（绿/橙/红）
- 提交：58bbb59

## 被否决的方向（不要再提）
- 旧版：象牙白 iPhone 剪影 + 紫红渐变（用户评价"真的很丑"）
- 几何抽象概念：信号桥 / 双环相扣 / 一笔连桥（霓虹弧线类，全部被否）
- 用户偏好：**简单、有记忆点的吉祥物**，胜过抽象几何；深色 Pro 工具风 + Liquid Glass

## 技术经验（坑）
- PIL 画粗折线（`draw.line` joint="curve"）缩小后有横纹 banding；解决：沿路径每隔几点盖圆点（stamp discs）
- PIL 做吉祥物太吃力；**手绘 SVG + rsvg-convert（/opt/local/bin/rsvg-convert 已装）** 质量好得多，改细节就是改数字
- SVG 模拟 Liquid Glass = clipPath + `<use>` 背景光斑 + feGaussianBlur（代替 backdrop-filter）+ 边缘镜面高光 + 半透明霜层
- 链条相扣的 weave 效果：在直边上打孔，圆角半径要小，否则缺口落在角落弧线上会像缺陷
- 菜单栏 template 图标里用彩色状态点（天线球）是可行的，系统不会强制单色
- 评审流程：superpowers brainstorming + visual companion（浏览器预览卡片投票）效果好；`.superpowers/` 已加入 .gitignore

## 环境
- 本机有 rsvg-convert (/opt/local/bin)、ImageMagick (magick)、numpy、PIL
- 火山引擎 arkcli 登录当时已过期（用户选择不用生图模型，改手绘）
