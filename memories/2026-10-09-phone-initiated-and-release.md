# Memory: 手机主动连接 v2 + 真机打磨 + 发布（2026-10-09）

> 写给下一个 session 的人，不写给简历。完整叙述见 `AGENTS.md` 顶部的
> `_Last updated: 2026-10-09`，代码与文档都已推送 `main`。

## 一句话

把「手机主动连接 v2」从 spec 做到三端（iOS/Mac/Windows），subagent-driven
17 个 task + 每步 review；**上真机后被用户连续抓出 6 个真 bug，全部先取证再改**；
然后**发布了 iOS TestFlight + Mac 1.0.1（公证）**。

## 用户真正要的东西（贯穿全程）

「像蓝牙/WiFi 一样：配对一次后点一下就 ~1s 接管，A/B/…/10 台随点随切，
Mac 与 Windows 一视同仁。现在经常『这台能连那台不能连』，必须根治。」
后来升级为：**「简单、傻瓜，7 岁小孩都会用」**——UX 是唯一标准。
关键取舍授权给我「看竞品、自己定」，别再回来问。

## 六个「上真机才暴露」的 bug（每个都有 lesson）

1. **配对卡在隐藏的 Mac 弹窗**：接收端加了「首次接触需 Mac 确认」，但它只渲染在
   **折叠的菜单栏 popover** 里，通知又是 denied → 手机等 30s 被超时关闭 →「连不上」。
   → **删掉接收端二次确认**；手机点一下 + 手机侧配对卡即同意（Remote Mouse / 电视遥控
   的做法）。错误证明（冒充）仍拒绝。lesson 164。
2. **首次连接赛跑**：接收端首次遇到某手机时不知道它会自己拨，于是它也拨 → 撞上，
   手机被回 `busy`。→ name-only owner（接收端自己拨起的会话）**让位**给主动拨入的手机。
   lesson 162。
3. **掉线不重连**：我第一版重拨循环「一有拨号在飞就 return」→ 只拨一次。→ 改成
   「只在空闲时才拨，循环直到连上」。lesson 165。
4. **触控板光标跳左上角**：joystick 相对光标从 `(0,0)` 起步。→ 会话开始用
   `CGEvent(source:nil)?.location` 播种。lesson 166。
5. **「释放此 iPhone」空操作**：只清了已失效的 `current`。→ 改成 断开 + 清
   current/preferred/off-intent。
6. **`accessibility trusted:false`**：反复开发重装堆了 **18 条陈旧 TCC 记录**，
   App 在列表里但 `AXIsProcessTrusted()` 是 false。→ `tccutil reset Accessibility <bid>`
   + 一次干净授权 + 重启 App；同 Developer ID 的后续替换不再重置。lesson 163。
   另外：**授权后必须重启 App**（macOS 缓存判定）；并把「只在首次启动弹提示」改成
   「没授权就弹」。

还有一个非功能性的：**`main` 的 macOS host-build 门禁本来就红**（`rc-app` 引用
Windows-only crate 未加 `#[cfg(windows)]`），本轮顺手修绿；先在一棵一次性 worktree
里构建 `origin/main` 证明它本来就红（lesson 167）。lesson 162–168。

## Windows（本端已做，真机未验）

四项全部实现并推送（`cff9eb6`/`ac09d40`）：读首帧分流 / `rc-net` 服务端握手
（`clientHello.token=nil` + `answer_challenge`）/ 对 `supportsPhoneInitiated` 停自动重拨 /
accepted socket 的 `IP_UNICAST_IF`。host `cargo test --workspace --lib` 326 +
`x86_64-pc-windows-gnu` clippy 干净。**真机验收步骤在
`docs/HANDOFF-WINDOWS-PHONE-INITIATED.md` §4**，还没在 Windows 上打勾。

## 发布（踩坑在 lesson 168）

- **iOS**：build `2026100901`（**版本仍 1.0**，审核中不动），`altool --upload-app`
  上传 → attach 到 Internal + Public Beta；公共链接
  `testflight.apple.com/join/6VNNHAyx`。**官网 `~/VGOAPP` 本来就有这个按钮**。
- **Mac**：`release-mac.sh 1.0.1 --skip-pkg`（mic 驱动没变，复用旧 pkg）→ 公证
  DMG + Sparkle zip；`make-appcast.sh 1.0.1` → appcast v13；`~/VGOAPP/scripts/deploy.sh`
  with `DMG=` 部署。`/Applications` 已换公证版。
- **网络**：公证要 `timestamp.apple.com`（被常规代理挡成 000，需 mihomo `global`）；
  VPS 部署要 SSH:22（`global` 下被代理吞 banner）→ **分两段**，先 global 做 Apple，
  再切回做 VPS。

## 已知残留（不是遗忘，是有客观阻塞）

- Windows 四项：**真机未验**（需 Windows 机器）。
- 出站/旧机路径仍信任裸 `accepted`（按用户选的「接收端不拦路」）。
- 通知中继需用户在「系统设置→通知」开启（`e2e-device.sh` 里诚实 SKIP）。
- iOS 正式版仍 `WAITING_FOR_REVIEW`；审核通过后再升版本号。
