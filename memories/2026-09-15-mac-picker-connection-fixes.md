# RemoteCrab 2026-09-15（下半场）：连接修复 → 反馈三连 → 多 Mac 选择器

承接 `2026-09-15-opus-a11y-setup-relaunch.md`。用户外出带走手机前的最后一批工作，全部已提交 main（未 push）。

## Commits

- `8665298` 连接死锁修复（e2e 0/10 暴露）：①已配对 Bonjour 发现可抢占仍 .connecting 的投机直连（stale lastPhoneIP 卡 preparing 75s）;②直连 8s 未 ready 自动放弃（directDialTimeoutTask）。→ AGENTS.md 踩坑 #23
- `ce0a2c1` iOS 反馈批：①后台即关摄像头（进后台 set(.camera,false)+广播 featureState，回前台需手动开）；②等待卡去掉 IP:port 副标题；③触控板长按拖拽（0.45s hold / 12pt 容差 / armed 时禁 tap recognizer;doubleTapWindow 0.28→0.35）;④Forensic.SelfShot(Darwin 通知 com.remotecrab.selfshot → 渲染 key window 存 Documents/selfshot-<ts>.png)
- `fa46d73` **iOS 多 Mac 选择器**：顶栏 overflow → "Choose a Mac"(MacPickerView)。preferred "hold the door" 语义：MacPairingStore 持久化 preferredId+preferredAt(10 分钟 TTL);PairingPolicy.decide 加 preferred 参数——owner 检查之后、token 校验之前，非 chosen Mac 一律 busy(preferred.name)（已配对带 token 也一样）；chosen Mac 自己仍需 token 才 accept，否则 pending。grant() 里 chosen 到达即 clearPreferred。setPreferredMac 对当前已连接的 Mac 是 no-op；选了别的 Mac 就 disconnectCurrentMac，被断的 owner 重连被 busy 挡住退避（Mac 侧 busy → 停 3s 重连 + 手动 Retry + 一次 30s 慢重试，正好是切换需要的回压）。UI 徽标用新的 @Published connectedMacId（名字会撞）。xcstrings 注意："Waiting" 键与已有 "WAITING" 撞 symbol，徽标键用 "Preferred"(zh 已选定）。
- `bcfd4db` AGENTS.md:#22 扩后台关摄像头、#23 stale 直连死锁、#24 长按拖拽、Multi-Mac 节补选择器、测试计数 49/87→94（分文件数重新实测）

## 未验证（全部只有 test.sh/单测级信心，真机回归清单）

1. `./scripts/e2e-device.sh` 全绿（上次 0/10 是 stale IP 死锁，已修未重跑）
2. 长按拖拽手感（0.45s/12pt 可调，只调手势侧别动注入侧）
3. 摄像头后台即关 + 回前台手动开
4. Opus iOS 真机编码器可用性（Apple AudioConverter；失败会回退 PCM）
5. 多 Mac 选择器全流程（需要两台 Mac 或改 paired 列表模拟）
6. 连接守卫在真机 VPN/hotspot 场景的表现

## 环境备忘

- iPhone 14 devicectl UDID `866A1921-B588-59D5-A1B7-B266103B2E49`;libimobiledevice UDID `00008110-00140CA12611401E`;idevicescreenshot 已死 → 用 SelfShot
- Mac 挂 fake-ip VPN:Bonjour 走 WiFi 死；api.appstoreconnect.apple.com TLS 被杀（python monkeypatch getaddrinfo 走 DoH 1.1.1.1 绕过）
- 部署：签名构建 derivedDataPath .build/e2e-derived + `rm -rf /Applications/RemoteCrab.app && ditto`;xcodegen 改完 yml 要重跑（test.sh 不自带 xcodegen)
- xcstrings 编辑姿势：python OrderedDict 追加 + json.dump(ensure_ascii=False, indent=2) + 末尾换行，diff 干净

## 追记（当晚）：模拟器 e2e + 拖拽实测（a75ef34 / e597d18）

- `e2e-simulator.sh` 重写为断言式 e2e（127.0.0.1 直连回退），10/10 绿。两个坑：① headless 启动前必须 simctl privacy 预授权 camera+mic——requestPermissions() 在监听启动前 await 相机弹窗，无人点即死锁（端口不开、零日志，症状和 Bonjour 坏了一样）;② sim 应用启动会把 Simulator 窗口抬到前台抢走键盘焦点——看到 sessionReply: accepted 立即 osascript activate TextEdit。
- **Opus 首次活体验证**:opus encoder ready (48kHz mono 24kbps)，收发两侧 codec=opus。
- **拖拽端到端实测通过**:iPhone dragStart/move/up → Mac leftMouseDown/Dragged/Up → TextEdit 窗口真的被拖动（AX 位置断言）、文字真的被拖选（⌘C → pbpaste 断言）。
- **CGEventInjector 真 bug 修复**:lastCursor 从不 clamp 到屏幕内，漂移出屏后所有后续事件（含拖拽）都投在屏外坐标——这可能就是真机"拖拽不了"的注入端原因之一。clamp 后位置确定性，e2e 用"左上爆发位移 → (0,0) → 定量爆发 → (0.3H,0.3H)"做绝对 staging。
- 编排技巧：iPhone 只发相对位移，所以"舞台向光标移动"（脚本用 AppleScript 把窗口挪到已知光标点下），剪贴板 marker 做相位同步（poll pbpaste）。文本行用 AX text area 实测（窗口头部约 100pt，不是猜的）。
- 仍未验：长按 0.45s/12pt 手势手感（真机）、视频/录制（模拟器无摄像头）。

## 追记 2（当晚真机）:e2e-device.sh 10/10 一次通过

真机（iPhone 14 / iOS 26.6.2）回归全绿：握手、视频帧、音频（**真机 codec=opus**,iOS AudioConverter 编码器可用性闭环）、触控、键盘、文件、剪贴板、App 切换、录制。8665298 的连接死锁修复在真机网络（Mac 挂 fake-ip VPN）下工作正常。至此"未验证清单"只剩：长按拖拽手感、摄像头后台即关体验、多 Mac 选择器全流程（需两台 Mac）——都是手动体验项，无自动化阻塞。
