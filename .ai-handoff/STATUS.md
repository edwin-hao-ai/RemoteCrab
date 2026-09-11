# AI Session Status

> Shared across all active AI sessions. Update your entry when you start, make progress, or finish.

## Session: Kimi (camera extension done; now e2e on real iPhone)
- Branch: `main`
- Status: **真机 e2e 链路已验证**（2026-09-11 11:31）
  - iPhone 14 真机：listener ready (port 49598)，Bonjour 广播正常（走 USB en11/en13 接口，WiFi mDNS 不可见——iPhone WiFi 疑似无 IP，但 USB 路径可用）
  - Mac receiver：browse → discover → connect → **connection ready** → 持续入站数据 ~12KB/s 数分钟无掉线
  - 关键修复已 commit `be3e7d8`：receiver 启动即浏览（原来只在 ControlPanelView.onAppear）、Bonjour serviceEndpoint 直连（旧字符串解析 port 永远=0）
- 注意：**/Applications/iBridgeReceiver.app 必须是包含 be3e7d8 的 build**——11:25 装过一次旧 build 导致零连接零日志。重装机前确认 `strings .../iBridgeReceiver | grep serviceEndpoint` 有输出
- iOS e2e 用法：`devicectl device process launch --terminate-existing --environment-variables '{"IBRIDGE_AUTO_START":"1","IBRIDGE_AUTOSTREAM":"1"}' com.ibridge.iBridgeCapture`；`--console` 可抓 stderr 的 `[e2e]` 标记（ terminate 子命令参数不对会让 --console 报 EINVAL）
- 注意：devicectl console 会话被杀会连带杀掉 app（iPhone app 会消失）
- Will touch（连接自检窗口 goal）: **新增** `iBridgeReceiver/TestWindowView.swift`；**增量** `iBridgeReceiver/ReceiverSession.swift`（@Published 事件镜像）、`iBridgeReceiver/AudioPlayer.swift`（RMS 回调）、`iBridgeReceiver/iBridgeReceiverApp.swift`（注册 test 窗口）、`iBridgeReceiver/MenuBarMenu.swift`（ActionRow 接 openWindow）、`iBridgeReceiver/ControlPanelView.swift`（openWindow stub + 真 sparkline 数据）。Spec: `docs/superpowers/specs/2026-09-11-mac-connection-test-window-design.md`
- **连接自检窗口已完成**（2026-09-11，未 commit）：上述文件全部改完，`./scripts/test.sh` 全绿（49 测试 + 双端 build）。注意：改过 project 后要 `xcodegen generate --spec project-mac.yml` 才会把新文件编入 target。真机验证路径：连上 iPhone 后菜单栏 → Connection Test，打字/滑动/说话看四象限。
