# Handoff: iOS-side changes the Windows session measured but cannot ship

> Windows receiver session, 2026-10-04. Everything here was **measured on a real
> Windows machine with a real iPhone**. None of it could be shipped from that
> session because it requires an Xcode build. Nothing here is speculative — each
> item names the number that prompted it.
>
> **Verification tooling that already exists** (do not rebuild it):
> `cargo run -p rc-render --example vcam_forensics -- --connect <ip>:8765 --seconds 25`
> — see §4. Run it before and after; it prints a verdict.

---

## 1. The bitrate is too low, and it is arithmetic rather than taste

`RemoteCrabCapture/CaptureEngine.swift:1182`

```swift
private func bitrateFor(width: Int, height: Int, fps: Int) -> Int {
    let raw = Int(Double(width * height * fps) * 0.1)   // ← 0.1 bits per pixel
    return min(max(raw, 1_000_000), 12_000_000)
}
```

For the live configuration this produces **6,220,800 bps**, confirmed on the
wire: the Windows receiver independently reported `streaming: 1080x1920 @
30fps (6220 kbps)`, matching `1920 × 1080 × 30 × 0.1` exactly.

0.1 bit/pixel is below the range where 1080p30 reads as sharp. The usual target
is **0.13–0.25 bpp**; at 30 fps that is 8–12 Mbps for 1080x1920.

**Symptom the user reported**: the preview looked soft, and had a
"光影的感觉" — a shimmering, light-and-shadow quality that moved with the
camera.

**Symptom in the captured frame** (user screenshot, 1080x1920): coloured
speckle concentrated along high-contrast edges, plus periodic horizontal
streaking. That is the signature of P-frames starved of bits.

### What to change

| | now | proposed | why |
|---|---|---|---|
| coefficient | `0.1` | `0.15` | lands 1080p30 at ~9.3 Mbps, mid-range for "sharp" |
| clamp upper | `12_000_000` | `16_000_000` | so the coefficient is not silently capped at high resolutions |

The clamp only becomes load-bearing above ~1500×1500 at 30 fps, so raising it is
safe, but it should be raised deliberately rather than left inconsistent with
the coefficient.

---

## 2. A keyframe every second starves the P-frames at that bitrate

`RemoteCrabCapture/H264Encoder.swift:102`

```swift
kVTCompressionPropertyKey_MaxKeyFrameInterval: fps,   // ← one I-frame per second
```

At 6.2 Mbps an I-frame for 1080x1920 is expensive, and paying for one every
second leaves the remaining 29 P-frames almost nothing. That is what produces
the periodic horizontal banding rather than uniform noise.

**Proposed**: `fps * 2` — one I-frame every two seconds. Live-stream latency is
unaffected because the decoder starts from the previous I-frame and the stream
starts on the first one; the cost of a longer GOP is a slightly longer wait on
*resume* after a stall, which is milliseconds either way.

**Verify the latency claim, do not assume it.** The Windows receiver measures
`Event::Latency` from a ping, which is network RTT and **not** video latency —
do not use it to check this. Instead confirm the picture still appears
immediately when a stream starts.

### What is already correct and must not change

```swift
kVTCompressionPropertyKey_RealTime:             true,
kVTCompressionPropertyKey_AllowFrameReordering: false,
```

These are right for a live path and are why the Windows receiver adds no
measurable latency of its own. Any change that trades them for quality would
show up as lag, which is the other half of what the user complained about.

---

## 3. Acceptance — how to know the change worked

### 3.1 From the phone side

1. Build and install on the iPhone.
2. Start a stream to the Windows receiver.
3. Read the metadata the Windows side prints: the kbps figure must be **≈9,300**
   for 1080x1920@30, not 6,220. This is the cheapest possible check and it needs
   nothing but the receiver's console.

### 3.2 From the Windows side — the forensics probe

```sh
cd windows
cargo run --release -p rc-render --example vcam_forensics -- \
    --connect <iphone-ip>:8765 --seconds 25
```

Healthy output looks like:

```
  featureState: camera_on=true mic_on=false position=Back
  frames analysed   : 182
  saturated pixels  : 0.31%   (healthy desk scene: well under 1%)
  harsh horizontal  : 1.12%   (edges only: under 2%)
  harsh vertical    : 0.94%   (edges only: under 2%)
  flat rows         : 0.00%
  VERDICT           : pixels look healthy — the fault is in the renderer
```

Corrupt output looks like:

```
  harsh horizontal  : 14.2%
  harsh vertical    : 11.8%
  VERDICT           : pixels are corrupt — the fault is upstream of the renderer
```

Note the probe's own handshake is a **manual** one, so the phone will ask for
approval for it the first time. It needs the camera switch on.

### 3.3 The human check that neither of the above replaces

Open the preview window and **look at it**. The probe proves the pixels are
well-formed; only an eye confirms the picture is *watchable*. Specifically:
move the camera slowly across a high-contrast edge (a hand against a desk) —
that is where the artefact was most visible.

---

## 4. What was ruled out, so nobody re-investigates it

Measured on the Windows side, not reasoned about:

- **Not** a renderer race. `FrameSlot` is a `Mutex<Option<RgbaFrame>>` and the
  copy into the draw buffer is atomic.
- **Not** a stride mismatch. `rc-render/src/decoder.rs:89` uses openh264's own
  `write_rgba8`, which handles the converter's strides. There is no hand-rolled
  repack.
- **Not** the virtual-camera path. `vcam_consume` had already confirmed
  Media Foundation receives changing bytes; the artefact is upstream of that.
- **Not** another receiver holding the phone — although that *did* happen twice
  during this session and cost real time. If the probe prints
  `sessionReply: Busy`, stop and fix that first; every measurement taken while
  the phone is held is of nothing.

---

## 5. One more iOS-side item, separate from quality

`docs/WINDOWS-GAPS-2026-10-03.md` §5.6 and the "追加" section of
`docs/PROMPT-WINDOWS-SESSION.md` hold the checklist the Mac session left for a
real Windows machine. It is **not** in this document because none of it is
caused by the Windows receiver — it all needs the new iOS build in the phone and
then a human ticking boxes. See those files; this one is only about what the
Windows session measured.
---

## 6. Speaker mode: two iOS-side defects, measured from the Windows session

Windows 侧把扬声器采集实现完了（`docs/WINDOWS-SPEAKER-2026-10-04.md`），
所以下面两条**现在是可以修的了**，而且第 6.1 条**必须先修**，
否则打开 Windows 的扬声器入口会打开一个陷阱。

### 6.1 🔴 The saved speaker habit silently switches the microphone OFF on Windows

`RemoteCrabCapture/CaptureEngine.swift:1635`, on every accepted session:

```swift
if UserDefaults.standard.bool(forKey: Self.speakerHabitKey), !features.speakerOn {
    features.set(feature: .microphone, enabled: false)
    features.set(feature: .speaker, enabled: true)
}
```

**There is no `connectedIsWindows` check here.** The gate is only on the menu item
(`ContentView.swift:759`). The chain, all of it verified by reading the code rather
than guessing:

1. the user turns the speaker on once with a Mac, so `remotecrab.ios.speakerOn` is
   persisted;
2. they connect to a Windows receiver instead;
3. the block above runs: **microphone off**, speaker on;
4. `AudioModeArbiter.resolve` puts the speaker above the microphone
   (`AudioModeArbiter.swift:62`), so `wantsMicrophone == false` — the microphone
   genuinely stops streaming and the session goes to `.playback`;
5. the top bar shows `speaker.wave.2.fill`, tinted as active
   (`ContentView.swift:790`) — and the menu it opens has **no speaker row**, because
   that row is behind `if speakerAvailable`.

So the state is visible and the action is unreachable, and the microphone the user
believes is streaming is not. That is rule 1 twice over.

**Fix**: a pure function in `RemoteCrabCore` (so it can be tested),
`speaker::shouldRestore(habit:connectedIsWindows:)` plus a test, then one added
condition:

```swift
if UserDefaults.standard.bool(forKey: Self.speakerHabitKey),
   !features.speakerOn,
   !connectedIsWindows {
```

**Why it has to land before `ContentView.swift:759` is deleted.** With the habit
path still unfixed, removing that gate gives a Windows user a speaker toggle they
cannot switch off. Fix the gate, then open the entry.

### 6.2 The 4d shape assertion cannot pass, and the reason is a running average

`SpeakerPlayer.swift:203-214`: the envelope character is derived from
`receivedRms`, which is a **cumulative average over the whole capture**
(`energySum += sum`, `energyCount += count`, reset only in `start()`).

A cumulative mean of "eight notes with gaps" converges to the notes' level, so the
gap can never appear — **the plateau is arithmetic, not "the tap missed the
gaps"**. The per-packet `sum` and `count` are already computed in `enqueue` (for
`peak`), so using `sqrt(sum/count)` for the digit gives the shape directly:
a gap lands on 0, a note near 7.

**The same root cause weakens 4c.** `pcmRms > 500` is the same cumulative average,
so it stays high after the audio stops and cannot detect "the sound stopped". Since
`docs/WINDOWS-SPEAKER-HANDOFF-2026-10-04.md` §6 tells the Windows session to copy
4c and 4d specifically, **copy the fixed versions, not these**.

**Why this session did not patch it**: no Swift toolchain on this machine, so not
even a compile was possible. AGENTS.md's own rule — a change you cannot verify is
worse than a handoff with numbers — wins over the urge to just do it.