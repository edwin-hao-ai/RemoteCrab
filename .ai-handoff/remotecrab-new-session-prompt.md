# 新会话 Prompt — RemoteCrab 改名 + Logo + 触控板优化

> 把下面分割线之间的内容整段复制给新会话。

---

你是 Kimi Code，工作目录 `/Users/edwinhao/RemoteCrab`。这是一个"把 iPhone 变成 Mac 的摄像头/麦克风/触控板/键盘"的双端项目（iOS Capture + macOS Receiver + CMIO 相机扩展 + CoreAudio HAL 麦克风驱动）。开始前先读：

1. `AGENTS.md`（项目圣经，含全部踩坑记录，尤其"Real-device lessons"和 CMIO/麦克风驱动两节）
2. `docs/CMIO_AND_RELEASE_HANDOFF.md`
3. 运行 `mddock recall "虚拟麦克风"` 和 `mddock recall "改名"` 读取最新记忆

当前代码状态：main 全绿（`./scripts/test.sh` 通过，15+ commits 已提交），虚拟麦克风全链路真机验证通过，Mac App 显示名已是 RemoteCrab（半改名状态）。

## 任务一：产品改名 RemoteCrab/RemoteCrab → RemoteCrab（最高优先级）

原因："RemoteCrab" 会被苹果禁掉（商标冲突）。最终产品名 **RemoteCrab**。

现状：代码库仍是 RemoteCrab 命名，仅 Mac App 显示名改成了 RemoteCrab。用 `grep -rli "remotecrab\|remotecrab" --exclude-dir=.git` 全量扫描，改名范围包括：

- 目录：`RemoteCrabCapture/`、`RemoteCrabReceiver/`、`RemoteCrabCore/`、`RemoteCrabMicDriver/`、`RemoteCrabCameraExtension/`、`RemoteCrabAudioExtension/`
- 两个 `.xcodeproj`、`project-ios.yml` / `project-mac.yml`（xcodegen 生成，改完重跑 xcodegen）
- target / scheme / Swift Package 名、bundle id（`com.remotecrab.*`）、os_log subsystem `com.remotecrab`
- Bonjour 服务名 `_remotecrab._tcp`（**两端必须同步改，否则互相发现不了**）
- UserDefaults 键 `remotecrab.*`、E2E 环境变量 `REMOTECRAB_*`（脚本同步改）
- 显示名：RemoteCrab → RemoteCrab，含 "RemoteCrab Microphone" / "RemoteCrab Camera" 设备名、pkg 文件名
- 全部脚本（scripts/）、文档、README
- **GitHub**：`gh repo rename RemoteCrab`，更新本地 remote URL，替换文档里的仓库链接

硬性注意事项（每条都来自真机踩坑，勿绕过）：

- bundle id 变更 → TCC 授权（辅助功能/麦克风/相机）全部失效，真机回归时要重新授权并**重启 App**（TCC 按进程缓存）
- CMIO 系统扩展改名/重签名 → 用户批准被重置，必须 bump 扩展 `CFBundleVersion` 走替换路径 + 用户重新批准；**绝不自动重注册**（AGENTS.md CMIO 节）
- 麦克风 HAL 驱动 bundle id 变更 → 需要重新打包安装驱动（`REMOTECRAB_MIC_VERSION=x.y.z ./scripts/build-mic-driver-pkg.sh`），设备 UID 同步改
- App Store Connect appId 6811599153 的元数据（名称/截图/文案）同步更新
- wire protocol 的 frame kind 字节**不变**（协议兼容），只改服务名/bundle id/显示名，两端同步
- 改完必须 `./scripts/test.sh` 全绿 + `./scripts/e2e-device.sh` 真机回归（前置：iPhone 解锁亮屏、同局域网、关 VPN——fake-ip 198.18.x.x 段会打断 Bonjour）

## 任务二：新 Logo——赛博风螃蟹 × 苹果 Liquid Glass

沿用现有 master `assets/app-icon-liquid.svg` 的玻璃质感（圆角玻璃底板、系统蓝渐变、高光折射），主体换成**赛博风螃蟹**（机械关节、霓虹描边、但收敛到苹果原生感，不要游戏风）。

产出链路（照现有流程，勿换工具）：

1. 新 master SVG 替换 `assets/app-icon-liquid.svg`
2. `scripts/generate-ios-app-icons.py`（rsvg-convert + PIL）重新生成 iOS 全套 icon
3. 菜单栏：`assets/menu-bar-icon.svg` → `MenuBarIcon.imageset`，必须**单色透明底 + `"template-rendering-intent": "template"`**，用 `Image("MenuBarIcon").renderingMode(.template)`——否则菜单栏显示成一团色块（已有踩坑记录）
4. App Store 营销大图同步更新
5. 不用 SwiftUI ImageRenderer 出正式 PNG（headless 渲染 Liquid Glass 不正确，只用脚本链路）

## 任务三：触控板体验优化

现状：统一手势引擎在 `RemoteCrabCapture/Input/TouchSurface.swift`（摇杆式相对定位，光标不瞬移），数学模型在 `RemoteCrabCore/.../TrackpadMath.swift`，单测 `RemoteCrabCore/Tests/RemoteCrabCoreTests/TrackpadMathTests.swift`。真机手感迭代，单测同步更新。

1. **鼠标右键**：目前是重按触发（force right-click）。评估改为**双指点按**为主（Mac 触控板肌肉记忆）或两者共存；确認 `CGEventInjector` 端 rightMouseDown/Up 事件正确落位
2. **横竖屏手感**：iPhone 竖屏握持映射到 Mac 横屏，方向感不一致（用户实测反馈"横竖屏都要支持"）。评估坐标映射、分轴灵敏度（竖屏 X 轴行程短）、以及 iPhone 横屏握持时的布局与映射适配（相机流的横竖屏旋转支持之前做过，可复用思路）
3. **选取字符手感**：在 iPhone 上拖选 Mac 文字（dragStart 双 tap-hold）目前触发迟滞、容易误触滚动。调触发阈值、按住判定时间、选取场景下的加速曲线（选取需要精细低速，不需要动量），考虑选取激活时的触觉/视觉反馈

## 任务四：剩余 P2（按优先级）

1. e2e 真机回归（改名后必跑）：`./scripts/e2e-device.sh` 全绿
2. App Store 截图 + 元数据：appId 6811599153，`scripts/release-ios.sh --all`，截图要真机采集（不能用 mockup）
3. 调试代码收敛：`Forensic.swift`、各 `REMOTECRAB_E2E_*` 钩子评估保留/裁剪
4. Opus 编码（现在是 raw PCM ~96kbps，wire format 已预留 `opusData`）
5. 无障碍审计（VoiceOver/Dynamic Type）、本地化统一（.xcstrings，coach marks 中文/其余英文混杂）
6. iOS 端主动选择连接哪台 Mac（现在是 Mac 发起 + iPhone 批准；反向需要 iOS 端浏览/持久化目标，属架构改动，放最后）

## 项目规则（来自 AGENTS.md，必须遵守）

- 提交前必跑 `./scripts/test.sh`（<30 秒）
- 不引入任何云依赖/分析 SDK（产品卖点是纯本地）
- UI 字符串不用 emoji，只用 SF Symbols
- 新代码用 `@Observable`，不用 `ObservableObject`
- 日志用 `os_log`，subsystem 随改名改
- 真机调试记住：锁屏会断连（iOS 挂起 Bonjour 监听）；macOS 无 `timeout` 命令；Simulator 的 Bonjour 对主机不可见，发现/配对必须真机
