# RemoteCrab 图标重设计 — Liquid Glass 显示器小伙伴

日期：2026-09-10
状态：已获用户批准（视觉稿确认）

## 背景

旧图标（象牙白 iPhone 剪影 + 紫红渐变底）执行质量差：机身是白矩形、
波纹光晕错位、整体廉价。用户要求重设计，方向经历了：
几何「连接器」概念（信号桥 / 双环相扣 / 一笔连桥）→ 全部否决；
吉祥物概念（机器人 / 章鱼 / 显示器）→ 选中 **M3 显示器小伙伴**，
并要求叠加 iOS 26 **Liquid Glass** 质感。

## 最终设计

**角色**：一台带笑脸的小显示器（代表 iPhone 画面抵达 Mac 一侧），
头顶信号天线，天线球即「连接状态」的视觉锚点。

**材质**：Liquid Glass —
- 磨砂玻璃机身：背景青色/紫色光斑透过机身被模糊折射
- 顶部锐利镜面高光 + 左侧柔光 + 底部青色轮廓光
- 对角 sheen、玻璃底座、落地阴影
- 屏幕为深色玻璃，顶部边框藏一颗摄像头小点（呼应产品功能）
- 青色发光双眼 + 微笑，粉色柔光腮红

**主文件**：`assets/concepts/m3-liquid.svg`（手工 SVG 矢量，
rsvg-convert 2048px 渲染 → Lanczos 缩至 1024px 作为源图）。
全部元素为原创绘制，无第三方素材。

## 产出物

1. `assets/source-1024-ios.png` — 替换为新设计
2. `RemoteCrabCapture/Assets.xcassets/AppIcon.appiconset/` — 全套尺寸
   （由 `scripts/generate-ios-app-icons.py` 从 1024 源图生成）
3. `screenshots/app-store-marketing-icon.png` — 同步更新
4. `RemoteCrabReceiver/MenuBarIcon.swift` — 菜单栏图标改为同一角色的
   单色线条版（显示器轮廓 + 双眼 + 微笑 + 天线），天线球兼作
   连接状态灯（绿=streaming / 橙=connecting / 红=error）
5. `AGENTS.md` — 更新图标相关描述

## 验证

- 120px / 60px 小尺寸可读性已在设计阶段验证
- `./scripts/test.sh` 全绿后交付
