# 虚拟麦克风（CoreAudio HAL 插件）设计

_2026-09-13 · F2 · 目标：iPhone 麦克风在 Mac 上成为一个**系统输入设备**_

## 1. 问题

现在 Mac 端只是把收到的 PCM `AVAudioPlayer` 播放到扬声器（已默认静音防啸叫）。
Zoom / QuickTime / 系统「听写」里**看不到** iBridge，所以"麦克风"卖点不成立。

macOS 上没有公开 API 能让普通 App 变成系统音频输入设备 —— 必须写一个
**CoreAudio HAL AudioServerPlugin**（俗称 HAL 驱动），装到
`/Library/Audio/Plug-Ins/HAL/`，由 `coreaudiod` 加载。

## 2. 行业做法（调研）

| 方案 | 代表 | 优点 | 缺点 |
|---|---|---|---|
| **自研 HAL 插件 + 签名 pkg** | BlackHole、Loopback、Krisp、SoundSource | 设备名干净、一键装、可卸载 | 要写驱动 + 签名/公证 + 处理 `coreaudiod` |
| 依赖 BlackHole（第三方） | 很多免费小工具 | 零驱动开发 | 让用户再装一个开源 App，体验差、依赖外部 |
| 只做监听（现状） | — | 零成本 | 不是系统设备，卖点不成立 |
| Kernel extension | 已废弃 | — | 不可用 |
| DriverKit | **没有虚拟音频类别** | — | 不适用 |

**结论：走 BlackHole/Loopback 同款路线 —— 自研 `AudioServerPlugin`，用一个签名
`.pkg` 安装（双击 → 一次管理员授权 → 装驱动 + 重启 `coreaudiod`）。**

## 3. 用户体验（重点：普通用户要好装）

- Mac 设置页新增「麦克风驱动」区块：
  - 未安装 → 一个 **「安装麦克风驱动…」** 按钮。
  - 已安装 → 绿点「iBridge Microphone 已就绪」+「卸载」。
- 点击安装：触发随 App 打包的 **签名 `.pkg`**（`NSWorkspace.open`），系统弹一次
  管理员授权；安装脚本把 `.driver` 拷进 HAL 目录并 `killall coreaudiod`。
- 不安装也能用其它功能；安装是**可选、可撤销**的，文案写清楚。
- 设备固定命名 **「iBridge Microphone」**，稳定出现在所有 App 的输入列表里。

## 4. 架构

```
iPhone ──PCM(48k mono Int16)──► Mac Receiver
                                   │  写入共享内存环形缓冲
                                   ▼
                        /tmp/ibridge-mic-<uid>.shm
                                   ▲  读取（render 回调）
                                   │
                       iBridgeMicrophone.driver（coreaudiod 内）
```

- **共享内存**：SPSC 无锁环形缓冲，头 = `{ writeFrame, readFrame: Int64, sampleRate, channels }`，
  后面是 Int16 采样环（容量 ~2 s）。writer 覆盖写并推进 `writeFrame`；reader 按帧读，
  underrun 补零、overrun 丢弃。
- 跨进程用 **C 的 `stdatomic`**（避免 Swift 无标准原子类型的问题），
  头文件被插件 target 和 Mac App 同时包含。
- 插件端：实现 `AudioServerPlugInDriverInterface`（C vtable），注册**一个只有输入端**的
  设备 + 一条输入流（48 kHz / 1ch / Float32），`DoIOOperation` 从环形缓冲取 Int16 → 转 Float32。

## 5. 构建与分发

- 新增 target `iBridgeMicrophone`（`com.apple.audio.AudioServerPlugIn`），产物
  `iBridgeMicrophone.driver`，随 Mac App 打包进 `Contents/Library/Audio/`。
- 安装脚本 `scripts/install-mic-driver.sh`：`pkgbuild`/`productbuild` 生成 `.pkg`，
  postinstall `cp -R` + `killall coreaudiod`；开发用 `sudo` 脚本直装。
- 正式分发需 Developer ID 签名 + 公证（`productsign` / `notarytool`）。
- 卸载脚本 `scripts/uninstall-mic-driver.sh`。

## 6. 风险与取舍

- **签名/公证**：HAL 驱动必须签名；开发期 ad-hoc 本地可用，正式要公证。
- **`coreaudiod` 重启**：安装/卸载瞬间会中断所有 App 的音频（BlackHole 等也如此）；
  文案要提示"安装时音频会短暂中断"。
- **稳定性**：驱动跑在 `coreaudiod` 里，崩溃会拖垮系统音频 → 代码要极简、
  绝不在 render 回调里分配/加锁；缓冲区预分配。
- **App Store**：Mac 端本就不走 MAS，无影响。
- 不做：输出（播放）设备、音量控制、多声道 —— 只要一个输入设备。

## 7. 验收

- 系统设置 → 声音 → 输入 里出现「iBridge Microphone」，有音量条。
- QuickTime / Zoom / 语音备忘录里选它，能录到 iPhone 的声音。
- 卸载后设备消失、系统音频正常。
