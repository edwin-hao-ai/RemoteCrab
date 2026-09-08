# iBridge — UI Prototypes

6 个独立 HTML prototype，6 种完全不同的设计方向。直接用浏览器打开 `.html` 文件即可预览。

## 文件列表

| 文件 | 方向 | 模式 | 风格关键词 |
|---|---|---|---|
| `01-pro-camera.html` | Pro Camera | Dark | 纯黑 + System Blue + SF Mono + 信息密集 |
| `01-pro-camera-light.html` | Pro Camera | Light | 米白 + 同样技术感 |
| `02-apple-native.html` | Apple Native | Dark | 材质磨砂 + 渐变蓝 + Final Cut 精致感 |
| `02-apple-native-light.html` | Apple Native | Light | 磨砂白 + Apple 蓝渐变 |
| `03-editorial.html` | Editorial | Dark | 暖灰 + 大留白 + Linear/Arc + 橘色 |
| `03-editorial-light.html` | Editorial | Light | 暖奶油 + SF Pro Display + 杂志感 |
| `04-skeuomorphic-cinema.html` | Cinema Skeuo | Dark | 金属渐变 + 物理拨盘 + 橙色 LED |
| `05-minimal-mono.html` | Pure Mono | Light | 纯 B/W + 无强调色 + Apple Original |
| `06-cyberpunk.html` | Cyberpunk | Dark | 霓虹 + 终端字体 + 扫描线 + 青/品红 |

## 每个 prototype 内含

- **iPhone** — Camera / Trackpad / Keyboard 三个模式可切换
- **iPad** — 横屏采集预览
- **macOS** — 菜单栏下拉 / 悬浮控制面板

点击设备上方的 tab 可切换不同屏幕。

## 6 个方向的差异化定位

### 01 — Pro Camera（专业工具感）
适合人群：开发者、视频创作者、直播主播  
灵感来源：Filmic Pro、Halide、OBS Studio  
关键信号：SF Mono 技术读出、信息密度  
风险：偏冷峻，普通用户可能觉得硬核

### 02 — Apple Native（苹果原生精致感）
适合人群：苹果生态用户、设计师、商务人士  
灵感来源：Final Cut Pro、Logic Pro、Motion、macOS Sonoma  
关键信号：材质磨砂、渐变蓝、Apple 标准控件层级  
风险：信息密度低，差异化弱

### 03 — Editorial（编辑式杂志感）
适合人群：设计师、独立开发者、追求品牌感的用户  
灵感来源：Linear、Arc、Vercel、Notion、Things 3  
关键信号：暖灰 + 大字号 + SF Pro Display + 橘色强调  
风险：不太"原生"，更像是独立产品

### 04 — Skeuomorphic Cinema（电影院级摄影机）
适合人群：电影摄影师、视频专业人士、Filmic Pro 用户  
灵感来源：Blackmagic Camera、ARRI、Things 3 黄金时代  
关键信号：金属渐变、立体阴影、物理拨盘、橙色 LED  
风险：争议大，有人觉得精致有人觉得过时；实现成本高

### 05 — Minimal Mono（纯黑白 Apple Original）
适合人群：设计纯粹主义者、极简主义者  
灵感来源：watchOS 表盘、早期 iOS、Apple Notes、Things 3 主屏  
关键信号：零强调色、SF Pro Display 大字号、纯 B/W  
风险：太通用难差异化；靠字体自信度撑质感

### 06 — Cyberpunk（赛博朋克终端风）
适合人群：开发者、游戏玩家、终端重度用户  
灵感来源：Cyberpunk 2077、Mr. Robot、Watch Dogs、复古 CRT  
关键信号：霓虹青+品红、扫描线、JetBrains Mono、方角控件  
风险：受众极两极化；完全不适合大众消费者

## 我的混合建议（如果你选不出来）

如果你觉得每个都有想保留的元素，最稳的混合方案：

| 来自 | 元素 |
|---|---|
| 02 Apple Native | 主色调用 + 磨砂材质 + 控件样式 |
| 01 Pro Camera | SF Mono 技术读出（延迟、FPS、码率）|
| 03 Editorial | 大字号标题、温暖的整体感 |
| 04 Cinema | 关键按钮的物理感（按下去的"沉"感）|
| 05 Mono | 颜色克制，不滥用 |
| 06 Cyberpunk | 不要用，太两极化 |

最终效果：**苹果生态里最精致的技术感工具**——这是 macOS Pro App 应该有的样子。

## 在 Xcode 里如何落地

```
iBridgeCore/
├── DesignSystem/
│   ├── Colors.swift           # 选定方向的颜色 token（自动 light/dark 切换）
│   ├── Typography.swift       # SF Pro Display / Text / Mono
│   ├── Spacing.swift          # 4 / 8 / 12 / 16 / 24 / 32 / 48
│   ├── Radius.swift           # 圆角系统
│   ├── Shadows.swift          # 阴影系统
│   ├── Materials.swift        # .regularMaterial / .ultraThinMaterial
│   └── Animations.swift       # spring 配置
├── Components/
│   ├── StatusPill.swift       # 连接状态胶囊
│   ├── MicMeter.swift         # 麦克风电平
│   ├── ModifierBar.swift      # ⌘⇧⌥⌃ 修饰键
│   ├── ToggleRow.swift        # 设置开关
│   ├── PrimaryButton.swift    # 主操作按钮
│   └── KeyboardKey.swift      # 键盘按键（含按下动画）
└── Theme/
    └── ThemeManager.swift     # 跟随系统 light/dark 自动切换
```

所有 UI 都从 token 引用，**不可能写出不一致的 UI**。配合 `@Environment(\.colorScheme)` 自动适配 light/dark 模式。

## App Store 审核 checklist（V0.1 上架前必做）

iOS Info.plist 必填字段：
- [ ] `NSCameraUsageDescription`
- [ ] `NSMicrophoneUsageDescription`
- [ ] `NSLocalNetworkUsageDescription`
- [ ] `UIBackgroundModes` — `audio`

Mac 端：
- [ ] Apple 公证（Notarization）
- [ ] DAL plugin entitlement
- [ ] 沙盒策略

通用：
- [ ] 隐私政策 URL
- [ ] App 内标注"需配合 Mac 端使用"
- [ ] 不使用任何私有 API
- [ ] 描述文案真实，不夸大

---

**更多方向**：如果你想要"Soft Pastel"、"Glassmorphism"、"Colorful/Playful"、"Brutalist"、"Soft Material"等其他风格，告诉我我再加。