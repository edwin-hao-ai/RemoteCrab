# Windows 验证清单（2026-09-30）

配合本轮改动在 Windows 上验证。**每一条都对应一个已修的根因**，
请按顺序做——前面的失败会让后面的结论不可信。

构建：

```powershell
cd <仓库>\windows
cargo build --release
```

---

## 1. 托盘菜单是否真的能点（R11，最高优先级）

之前托盘能弹出但**任何一项点击都无反应**。现在必须每一项都有反应。

1. 启动 `target\release\remotecrab.exe`
2. 右键托盘图标 → 菜单应该正常弹出
3. 逐项点击并确认有反应：
   - 摄像头 / 麦克风 / 触控板 / 键盘 → iPhone 端对应开关应变化
   - 重新连接 → 状态行应变化
   - 断开连接 → 状态应变为「等待 iPhone」
   - 「为什么连不上…」→ **应弹出一个对话框**，里面写明原因和该做什么
   - 开机自启动 → 勾选状态应切换
   - 退出 RemoteCrab → 程序应退出

> 如果某一项点了没反应，**在 Debug 构建下会直接 panic**（`debug_assert!`），
> 报错信息里会写「no click handler」。这比静默失败好，请把那条信息发我。

## 2. 免重复批准（R1，最影响体验）

1. 首次连接：iPhone 应弹出「允许这台电脑吗」→ 点允许
2. 断开：`托盘 → 断开连接`
3. `托盘 → 重新连接`
4. **iPhone 不应再弹批准卡片**，应直接连上

再验证一次跨重启：

5. 完全退出程序（托盘 → 退出），重新启动
6. **仍不应弹批准卡片**

> 如果第 4 步或第 6 步又弹了卡片，说明 token 没存住。
> 把 `%APPDATA%\RemoteCrab\tokens.json` 贴给我（token 值可以打码，但保留字段名）。

## 3. 掉线后自己恢复（R10）

1. 连上之后，在路由器上把 iPhone 断开 10 秒，或直接锁 iPhone 屏
2. **不碰电脑**，等约 30 秒
3. iPhone 应该自己恢复连接（iPhone 需要保持前台、屏幕常亮）

> 之前这里会永久断掉，只能重启程序。

## 4. 「为什么连不上」面板（R7 / A）

故意制造一个失败：

1. 关掉 iPhone 上的 RemoteCrab，或让它退出
2. 打开托盘 → 菜单里那一行应该直接显示原因，例如
   `为什么连不上: 没找到 iPhone`，而不是只有「LOOKING」
3. 点它 → 弹出的面板应该写明
   - 当前状态
   - 原因（是没找到 / 被占用 / 等批准 / 被 VPN 接管）
   - **该做什么**（具体到点哪里）
4. 确认面板**没有**任何让你手输 IP 的输入框（这是有意的）

**VPN 场景（如果你开着 Clash / Mihomo 的 TUN 模式）**：

5. 保持 TUN 开着，iPhone 正常开着 RemoteCrab
6. 打开那个面板，应该**第一条**就是
   「到手机的连接被 VPN/代理的虚拟网卡接管」+ 源地址 + 可直接粘贴的 Clash 配置行

## 5. 多电脑切换（Mac ⇄ Windows）

需要 Mac 和 Windows 都在同一 WiFi 上、iPhone 在中间。

5a. Windows → Mac：

1. 先让 Windows 连上
2. iPhone → 顶栏「选择电脑」→ 点 Mac
3. Windows 应当在大约 15 秒内**自己让出**，Mac 接上
4. **Windows 那边不应该需要你点任何东西**（之前必须去 Mac 上点 Retry）

5b. Mac → Windows：

1. iPhone →「选择电脑」→ 点 Windows 电脑
2. Mac 应当被断开
3. Windows 在约 10 秒内接上
4. iPhone 的列表里，Windows 那一行应当显示
   「已找到这台 iPhone，但 Mac 正在使用」之类的一句话

5c. 首次接触一台新电脑：

1. iPhone 的「选择电脑」列表里**看不到**还没连过的电脑（这是有意的）
2. 让那台电脑先连一次 → iPhone 弹批准卡片 → 点允许
3. 之后它才会出现在列表里，可以被选中切换

## 6. 扫描兜底（R2 / R3 / R8）

6a. mDNS 正常时：

```powershell
.\target\release\remotecrab.exe --list
```

应该能列出 iPhone。

6b. mDNS 被拦截时（模拟「只有直连能通」）：

```powershell
.\target\release\remotecrab.exe --connect <iPhone的IP>
```

应该能连上，并且**之后普通启动也能自动连上**（兜底会记住地址）。

6c. TUN 开着时，观察控制台日志里这一行：

- 看到 `[net] mDNS browse could not start` 或 mDNS 长时间无结果 → 正常，会走兜底
- 兜底扫描日志里如果出现 `198.18.x.x` 这样的地址 → **说明还在扫隧道的假 IP 段**，
  把日志给我

## 7. 界面文案

跑一次看整体观感：

```powershell
.\target\release\remotecrab.exe --help
```

7a. `--help` 现在分三段：正常用法 / 排障 / 自检。请确认读起来像一个产品，
而不是一堆调试开关。

7b. 触发「被占用」状态（在 iPhone 上先连 Mac，再让 Windows 连），确认提示文案：

- 应该是 `[IN USE]` 开头
- 应该同时给出 **Mac 菜单栏**和 **Windows 托盘**两个断开路径
  （之前只写了「menu bar」，Windows 上根本没有 menu bar）
- 不应该出现「Choose a **Mac**」这种字样（Windows 用户没有 Mac）

7c. 触发「等批准」状态，确认文案说的是
**「请在 iPhone 上允许「XXX」」**——是 iPhone，不是那台电脑。

---

## 如果只想先验最要紧的三条

时间有限的话，按这个顺序：

1. **第 1 节**（托盘能点了吗）——之前是全坏的
2. **第 2 节第 3-4 步 + 第 6 步**（不用反复点允许）
3. **第 5a 步**（切到 Mac 不用跑过去点按钮）

## 有问题怎么反馈

最有用的三样东西，按优先级：

1. **控制台输出**（启动 `remotecrab.exe` 的那个窗口，里面有 `[net]` 开头的行）
2. `%APPDATA%\RemoteCrab\tokens.json`（字段名保留，token 值可打码）
3. 具体现象 + 你当时点了什么

日志里这几行是特意加的诊断点：

- `[net] mDNS browse could not start (...)` —— 发现功能起不来
- `[net] mDNS still unavailable: ...` —— 重试中
- `[net] mDNS browse running again` —— 恢复了
- `[net] mDNS browse channel closed` —— 浏览通道断了（已自动重启）
