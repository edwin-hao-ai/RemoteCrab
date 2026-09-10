# e2e 测试 iPhone 14 ↔ Mac — 操作手册

> iOS app 已装到 iPhone 14，Mac 端 iBridgeReceiver 已在跑（PID 在菜单栏）。要让两边真正联动起来，按下面步骤走。

## 关键问题

**Bonjour (mDNS) 不能跨网段。** iPhone 14 现在是 USB 接到 Mac 的，Bonjour 在不同子网里走不通。需要 iPhone 14 跟 Mac 在**同一个 WiFi 网络**上。

## Step 1: iPhone 14 连到 Mac 同一个 WiFi

1. **拔掉 iPhone 14 的 USB 线**
2. iPhone: **Settings → Wi-Fi** → 选你 Mac 正在用的网络
   - 你的 Mac 在 `192.168.31.105`，所以 WiFi 网关是 `192.168.31.x` 段
   - 家里 WiFi 一般就是同一个
3. iPhone 上确认获取了 `192.168.31.x` 的 IP
   - Settings → Wi-Fi → 你的网络 → 详细信息能看到

> ⚠️ 这一步关键。**没做的话，Mac 永远找不到 iPhone**。

## Step 2: iPhone 上信任 dev 证书

第一次从 Xcode 装的 app，需要在 iPhone 上手动信任一次。

1. iPhone: **Settings → General → VPN & Device Management**
   - iOS 18 路径：General → VPN & Device Management（有些版本是"Device Management"）
2. 找到你的 Apple ID（`edwinhao@sendpalm.com` 或显示的团队名）
3. 点 **"Trust 'Apple Development: Edwin Hao'"**
4. 弹框 → **Trust**

## Step 3: 启动 iBridgeReceiver on Mac

iBridgeReceiver 已经在跑（PID 在你的菜单栏右上角），但你可以再确保一次：

```bash
# 检查 receiver 是否在跑
pgrep -f iBridgeReceiver

# 如果没跑，启它
open /Users/edwinhao/Library/Developer/Xcode/DerivedData/iBridgeReceiver-*/Build/Products/Debug/iBridgeReceiver.app
```

你看到 macOS 菜单栏右上角有 iBridge 的小图标就 OK 了。

## Step 4: 启动 iPhone 上的 iBridge

iPhone 上找到 **iBridge** app，tap 打开。它会直接进 camera 模式（因为 IBRIDGE_AUTO_START 已经设了）。

## Step 5: 启动 streaming

iPhone 上点**大的红色 START 按钮**。会弹两个系统权限框：
- **Camera** → Allow
- **Microphone** → Allow（可选）
- **Local Network** → **Allow**（这步最关键！Bonjour 靠它）

## Step 6: 验证连接

Mac 上点菜单栏的 iBridge 图标，会看到：
- ✅ `CONNECTED · XXms`（绿色圆点）
- 设备名是 `Edwin Hao的iPhone`
- 信号延迟在 100ms 以下

如果点 **Open Control Panel** 或 **Open Preview Window** 就能看到实时画面。

## 验证脚本

任何时候跑：

```bash
cd /Users/edwinhao/iBridge
./scripts/check-e2e-readiness.sh
```

如果一切正常，会看到：
- Mac WiFi: `192.168.31.105`
- iPhone info: `marketingName: iPhone 14, osVersionNumber: 18.6.2, transportType: localNetwork`
- Bonjour: 列出 `iBridge — iPhone 14` 服务（这是 Mac 找到的 iPhone！）

如果 Bonjour 列里只有 iPhone 17 Pro（simulator），说明 iPhone 14 不在 Mac 同一个 WiFi 段上。

## 故障排查

| 现象 | 可能原因 | 解决 |
|---|---|---|
| Mac 找不到 iPhone 14 | iPhone 不在 Mac 同一个 WiFi 段 | 拔 USB，连同一个 WiFi |
| 点 START 没弹权限框 | 之前拒绝过 Local Network | iOS Settings → Privacy → Local Network → 打开 iBridge |
| 弹框了 Allow 但 Bonjour 还是没出现 | 权限没真的允许 | 杀掉 app 重启重试 |
| iBridge 启动崩溃 | dev cert 没信任 | Step 2 |
| 菜单栏图标没出现 | iBridgeReceiver 没跑 | 跑 `open ...` 启动它 |

## 跑完后

`./scripts/e2e-simulator.sh` 仍然能跑（验证 iOS 端代码路径）。
`./scripts/install-to-iphone.sh --auto-start` 仍然能装到真机。
`./scripts/check-e2e-readiness.sh` 验证 e2e 准备。

如果 e2e 跑通，所有 26 个单元 + 集成测试 + 2 端 build + 真机 e2e 都过了，发布就绪。

## Camera Extension（V0.3）

实际流程（2026-09-11 验证）：

1. 真签构建（team 5XNDF727Y6，xcodegen 后
   `xcodebuild -scheme iBridgeReceiver -configuration Debug -allowProvisioningUpdates clean build`；
   必须 clean —— 增量 build 出过 adhoc 签名产物，sysextd 会拒绝）
2. ~~手动打包修正~~（已废弃）：自 51c5e30 起，新构建直接嵌入命名正确的
   `com.ibridge.iBridgeReceiver.Camera.systemextension`，且
   `CFBundlePackageType` 已是 `SYSX`，无需任何手动修补。
   此前的重命名 + `plutil -replace CFBundlePackageType` + 重签步骤
   只是 51c5e30 之前的临时 workaround。
3. `cp -R` 到 `/Applications/iBridgeReceiver.app`，`open -a` 启动
   （host 必须在 /Applications 里运行）
4. 启动时 `SystemExtensionManager` 自动提交
   `OSSystemExtensionRequest.activationRequest` —— 首次会到
   `[activated waiting for user]` 状态
5. **用户手动（一次性）**：系统设置 → 通用 → 登录项与扩展 → 相机扩展 →
   打开 iBridge 开关
6. 验证：`systemextensionsctl list` 应出现
   `5XNDF727Y6 com.ibridge.iBridgeReceiver.Camera`（cmio 类别，
   批准前 `[activated waiting for user]`，批准后 `[activated enabled]`）；
   `ffmpeg -f avfoundation -list_devices true -i ""` 的 video devices 里
   出现 `iBridge Camera`（批准并加载后才枚举得到）
7. iPhone 启动 iBridgeCapture 并连接
8. Photo Booth / Zoom → 摄像头选 "iBridge Camera" → 应看到实时画面
9. 退出 iBridgeReceiver → "iBridge Camera" 不可用，不崩溃

排查：`log stream --info --predicate 'subsystem == "com.ibridge" OR process == "sysextd"'`
（`log show --last` 在本机损坏：`cannot use --last when archive metadata is missing`；
注意 info 级日志必须加 `--info`）
