---
title: 4K 可行性实测（2026-10-05）
type: measurement
status: current
last_verified: 2026-10-05
machine: Windows 11，release build
---

# 4K 可行性：Windows 侧实测

起因：有人问「4K 行不行」。之前只有推断（"环是文件映射所以 63MB 没问题"），
**没有实测**。这份把它量出来。

## 结论先说

**4K 在 Windows 预览端做不到 30fps，实测上限约 15fps。瓶颈在 OpenH264 解码本身，
不在我们的代码，也不在码率。**

但 4K **能正确解码**（180 帧全出、0 拒收），共享内存环也**装得下**（63.3 MiB）。
所以这不是"不支持"，是"支持但跑不满"。

## 实测数据

两段合成流，都对齐线上编码配置（`-bf 0` 无 B 帧、`-g 60` 两秒关键帧）：

| | 1080×1920 | 3840×2160 |
|---|---|---|
| 文件大小 | 4.9 MB | 12.3 MB |
| 解出帧数 | 180 / 180 | 180 / 180 |
| **拒收 NAL** | **0** | **0** |
| `feed_nal`（H.264 解码） | 15.44 ms | **53.77 ms** |
| `to_bgra`（色序转换） | 2.59 ms | 10.42 ms |
| 合计 | 18.0 ms | **64.2 ms** |
| **实测帧率** | **54.4 fps** | **15.2 fps** |
| 30fps 预算 33.33 ms | 通过 | **超出 1.9×** |

复现：

```sh
ffmpeg -f lavfi -i testsrc2=size=3840x2160:rate=30:duration=6 \
  -c:v libx264 -profile:v high -bf 0 -g 60 -b:v 16M -pix_fmt yuv420p -f h264 4k.h264
cargo run -p rc-render --release --example bench_decode -- 4k.h264
```

工具：`windows/crates/rc-render/examples/bench_decode.rs`（把帧预算按阶段拆开，
因为这两段的不同归属不同的修法）。

## 顺带修掉一个真 bug：`to_bgra` 逐字节 push

拆阶段时发现 `to_bgra` 是每像素 4 次 `Vec::push`：

```rust
for &p in &self.pixels {
    out.push((p & 0xFF) as u8);        // B
    out.push(((p >> 8) & 0xFF) as u8); // G
    out.push(((p >> 16) & 0xFF) as u8);// R
    out.push(0xFF);                    // A
}
```

每像素 4 次带边界检查的 push，还要处理容量增长。改成 `chunks_exact_mut(4)`
一次分配后按索引写：

| | 改前 | 改后 | 加速 |
|---|---|---|---|
| 1080p | 10.30 ms/帧 | **2.59 ms** | **4.0×** |
| 4K | 41.32 ms/帧 | **10.42 ms** | **4.0×** |

**1080p 下这是白烧 10.3 ms/帧**——占 33.33 ms 预算的 31%。改完 1080p 预览
从 38.7 fps 涨到 54.4 fps。字节序由既有测试
（`to_bgra_writes_bgra_with_opaque_alpha`）守着，没变。

## 共享内存环：4K 装得下

`rc-vcam` 的环有两槽，`required_size = HEADER_SIZE + 2 * stride * height`：

| | 每帧 | 环总大小 |
|---|---|---|
| 1080p | 8.29 MB | 16.6 MB |
| **4K** | **33.18 MB** | **63.3 MB** |

`frame_bytes` 的上限是 256 MiB/帧，4K 远在之下。测试
`a_4k_frame_is_a_legal_ring_geometry`（`rc-vcam/src/shm.rs`）钉住这个几何。

**注意**：我第一次写这个测试时把 33,177,600 字节写成了 31,641,600（混了 MiB
和字节），测试立刻红了。这个数字是**算出来然后被测的**，不是抄进去的。

## 上游还有一个硬限制（不在 Windows 侧）

`VideoEncodingPolicy.bitrate(w,h,fps) = clamp(w*h*fps*0.15, 1M, 16M)`。

4K30 请求 37.3 Mbps，**被 16 Mbps 天花板截断**——只有请求值的 43%。
所以即使 Windows 端够快，链路上也只有 16 Mbps。Mac 侧已有测试
（`testTheCeilingIsReachableButOnlyByGenuinelyLargeFormats`）确认这个天花板
在 4K30 上确实生效。

**两端都不到位**：Windows 解码 15fps，链路上限 16 Mbps。要真上 4K30，得同时
抬天花板（Mac 侧）**和**换解码器或加 GPU 解码（Windows 侧）。

## 待定

- [ ] 真机 4K 实跑：合成流证明管线能吃，但没在真手机上验证过协商与元数据
- [ ] OpenH264 换 GPU 解码的可行性（`ffmpeg -hwaccel` 路线本项目未评估）