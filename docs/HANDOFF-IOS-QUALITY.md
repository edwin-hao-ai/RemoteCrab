# Handoff: iOS-side changes the Windows session measured but cannot ship

> Windows receiver session, 2026-10-04. Everything here was **measured on a real
> Windows machine with a real iPhone**. None of it could be shipped from that
> session because it requires an Xcode build. Nothing here is speculative — each
> item names the number that prompted it.
>
> **Verification tooling that already exists** (do not rebuild it):
> `cargo run -p rc-render --example vcam_forensics -- --connect <ip>:8765 --seconds 25`
> — see §4. Run it before and after; it prints a verdict.
>
> **Verification tooling that needs no phone at all** (added 2026-10-04):
> `cargo run --release -p rc-render --example renderer_fidelity` — exits nonzero
> and names the stage if the Windows side ever stops being faithful.

---

## 0. ⚠️ §1 and §2 below were overtaken by `dd7022d`. Read this first.

This document's original thesis was "the bitrate coefficient is too low, raise
`0.1 → 0.15`". `dd7022d` measured the real encoder with
`scripts/vt-bitrate-probe.swift` and found the request was **inert**:
`H264Encoder` sets both `AverageBitRate` and `Quality`, and on iOS `Quality`
wins outright. Asking for 6,220 bps and for 9,331 bps produced **byte-identical
output** (3,442,273 bytes).

So the `6220 kbps` this document treated as a confirmed measurement was a number
the phone computed and published about itself, and nobody had ever measured it.
The `0.1 → 0.15` change recommended in §1 would have gone green against the
"must read ~9,300" acceptance criterion while the picture stayed exactly as
soft.

What is actually true now:

| | value | measured |
|---|---|---|
| effective rate | **`quality 0.70 → 9,179 kbps`** (`0.75 → 10,886`) | yes, `vt-bitrate-probe.swift` |
| advertised rate | 6,220 kbps (`0.1` bpp) | **never measured** |
| dial that moves | `VideoEncodingPolicy.quality` | yes |
| keyframe interval | `keyframeIntervalSeconds = 2` (was `fps`, i.e. 1s) | yes |

Two consequences for the corruption hunt in
[`HANDOFF_WINDOWS_MSI.md`](../HANDOFF_WINDOWS_MSI.md):

1. **9.2 Mbps is a normal rate for 1080p30.** "The bitrate is too low" is no
   longer available as an explanation for the speckle.
2. **The keyframe interval is now 2 seconds, not 1.** If corruption turns out to
   be reference-frame loss, the *period* of the banding doubles. Do not use the
   period to identify which build you are looking at.

§3's acceptance criterion "the kbps figure must read ≈9,300" is also void — that
figure comes from the phone's own metadata and is not what the encoder does.

The rest of this document is kept because §4's exclusions still hold and §5's
Mac-side checklist is still unclaimed.

---

## 1. The bitrate is too low, and it is arithmetic rather than taste

> ⚠️ **Superseded by §0.** The arithmetic below is correct and the conclusion is
> inert — `bitsPerPixel` does not decide quality on iOS. Kept for the reasoning
> and because `VideoEncodingPolicy.bitsPerPixel` is still the right target for
> an encoder that does honour it.

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

> ⚠️ The sample outputs below are from the **old** version of this tool, kept so
> you can recognise them if you find them pasted elsewhere. They are **wrong** —
> the absolute cut-offs they quote are not achievable on real video. The current
> tool prints the wire facts first and then a scene-independent pattern. Trust
> the pattern, not a percentage.

Old, superseded output:

```
  featureState: camera_on=true mic_on=false position=Back
  frames analysed   : 182
  saturated pixels  : 0.31%   (healthy desk scene: well under 1%)
  harsh horizontal  : 1.12%   (edges only: under 2%)
  harsh vertical    : 0.94%   (edges only: under 2%)
  flat rows         : 0.00%
  VERDICT           : pixels look healthy — the fault is in the renderer
```

```
  harsh horizontal  : 14.2%
  harsh vertical    : 11.8%
  VERDICT           : pixels are corrupt — the fault is upstream of the renderer
```

A `renderer_fidelity` run on a **flawless** 1080x1920 stream reports
`harsh horizontal: 12.31%`, which the first sample would have called healthy and
the second would have called corrupt. Neither answer means anything.

What the current tool reports instead, in the order that matters:

```
the wire:
  video NALs received    : 731
  of those, keyframes    : 24
  keyframe every         : 1.02s on average
  frames decoded         : 731  (29.2 fps, wall clock)
  ...
the pixels (absolute numbers, scene dependent — read the pattern below):
  ...
VERDICT:
  a few frames are broken and their neighbours are fine.
  outliers (1-based frame index): [57, 89, 118, …]
  worst outlier is 7.3x this stream's own median.
  of those, 0 came from a keyframe and 19 from a predicted frame.
  Not one broken frame came from a keyframe. A keyframe is self-contained,
  so it cannot be mispredicted — that rules out bitrate as the cause and
  leaves a missing reference frame, which points upstream of the decoder.
```

The last block is the one that names a cause. If instead you see

```
VERDICT:
  uniform. Every frame carries about the same amount of edge energy ...
```

then no individual frame is broken and the question is picture *quality*, not
corruption — though check `video NAL(s) produced no picture after the stream had
started` first, because a frame that never decoded cannot be judged.

Note the probe's own handshake is a **manual** one, so the phone will ask for
approval for it the first time. It needs the camera switch on. And if the phone
answers `Connection refused`, that is not the tool: confirm the phone is still
on the same WiFi with the app in the foreground.


### 3.3 The human check that neither of the above replaces

Open the preview window and **look at it**. The probe proves the pixels are
well-formed; only an eye confirms the picture is *watchable*. Specifically:
move the camera slowly across a high-contrast edge (a hand against a desk) —
that is where the artefact was most visible.

---

## 4. What was ruled out, so nobody re-investigates it

Split by how the exclusion was obtained, because the difference has cost real
time twice (AGENTS.md rule 3: "ruled out by reading the code" is not "ruled
out").

### Now measured — the whole Windows render path is faithful

`cargo run --release -p rc-render --example renderer_fidelity` (2026-10-04,
exits 0) pushes a **provably well-formed** 1080x1920 stream through
`PreviewPipeline` and through the exact statements `window.rs` uses, and checks
every stage: SPS parsing, `pixels.len() == w*h`, channel order per third,
the blit including its resize branch, and the decoded picture's own
frame-to-frame consistency. All pass.

- **Not** a renderer race. `FrameSlot` is a `Mutex<Option<RgbaFrame>>` and the
  copy into the draw buffer is atomic — and now measured, not argued.
- **Not** a stride mismatch or a channel swap. `decoder.rs:89` uses openh264's
  own `write_rgba8`; the fidelity gate confirms the resulting RGBA→`0x00RRGGBB`
  repack lands red on the red third, 12 frames out of 12.
- **Not** the virtual-camera path. `vcam_consume` had already confirmed
  Media Foundation receives changing bytes; the artefact is upstream of that.
- **Not** the bitrate. See §0 — the phone is producing ~9.2 Mbps, which is
  normal for 1080p30, and the advertised figure was never a measurement.

### Not ruled out — do not treat these as excluded

- **Not** the pointer lifetime in `run_preview_window`. The handoff flagged
  `update_with_buffer(&buffer, …)` as a latent hazard on a resolution change.
  It is **unexamined**, not excluded: the fidelity gate reproduces the buffer
  bookkeeping but cannot prove what minifb does with the pointer after the
  call. At a fixed 1080x1920 it never triggers.
- **Not** the `Parser::try_parse_next` buffer wipe. A bad length value clears
  the whole buffer, discarding already-received complete frames, and counts
  nothing. That produces a **freeze**, not speckle — but it is unfixed and it
  is silent.
- **Not** another receiver holding the phone — although that *did* happen
  during three separate sessions and cost the most time of anything on this
  list. If the probe prints `sessionReply: Busy`, stop and fix that first;
  every measurement taken while the phone is held is of nothing.


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

> **RESOLVED on the Mac side 2026-10-05** (`6fff9d5`). The policy landed as
> `RemoteCrabCore/Sources/RemoteCrabCore/Audio/SpeakerRestorePolicy.swift` with
> five tests, `CaptureEngine.grant` calls it, **and the iOS entry is now open**
> (`ContentView.swift`, `speakerAvailable = true`) — in that order, as required
> above. The gate is one line if it ever needs reverting.

### 6.2 The 4d shape assertion cannot pass, and the reason is a running average

`SpeakerPlayer.swift:203-214`: the envelope character is derived from
`receivedRms`, which is a **cumulative average over the whole capture**
(`energySum += sum`, `energyCount += count`, reset only in `start()`).

A cumulative mean of "eight notes with gaps" converges to the notes' level, so
the gap can never appear — **the plateau is arithmetic, not "the tap missed the
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

> **RESOLVED on the Mac side 2026-10-05** (`6fff9d5`, and the follow-up in
> `AGENTS.md`'s "本轮未完成" list). Both 6.1 and 6.2 are fixed, and 6.2's fix
> differs from the text above in one deliberate way: **`receivedRms` became a
> peak-hold, not a per-packet value.** The device e2e samples it once at the end
> of a run, where a per-packet number lands on a gap as often as not and makes
> 4c flaky. 4c asks "did any sound arrive" (a maximum); 4d asks "what did it look
> like" (per packet). The envelope digit is now `SpeakerEnvelope.digit(packetRms:)`
> in Core, tested; the instantaneous reading is logged as `pktRms=`.
> **If you copied 4c/4d from this section, copy them from
> `RemoteCrabCapture/SpeakerPlayer.swift` instead** — the two ends must not mean
> different things by the same assertion.

---

## 7. 🔴 Never filed by the session that found it: the iOS listener sometimes never starts

> Recorded 2026-10-05 by the Mac session.
> `HANDOFF_WINDOWS_MSI.md` §"顺带发现，尚未修" item 1 said this *should* be added
> here. It was not, which is how a fifth "claimed done, actually not" went
> unrecorded. Filing it here so it is findable.

**Symptom, as observed from the Windows side**: the phone's IP is correct, it
answers `ping`, it is reachable at layer 2 — and **nothing is listening on 8765**.
No listener, no error on the phone, and (on one run) the app was visibly alive
with UIKit and VideoToolbox logging.

**Status: NOT reproduced, NOT excluded.** This is filed as *unexamined*, not as
ruled out (AGENTS.md rule 3). The same session hit it while a `vcam_forensics`
run was in flight, which is also exactly when the phone is most likely to be
holding a session, changing its address, or being backgrounded — so "the listener
never started" and "the listener started and then stopped" are not yet separated.

**What would settle it, cheaply, from either side:**

1. On the phone, `Forensic.log("[hs] …")` and the listener-start line are the
   ground truth. If `[hs] listener up` never appears, the listener genuinely
   never started; if it appears and then a teardown line follows, it started and
   was stopped. **The iOS side needs to log both**, which today it does not — that
   gap is the reason this is still open.
2. The phone's own log is more decisive than the port: a phone can refuse a
   connection for a dozen reasons that all look like "nothing is listening" from
   the outside.
3. A `v2`/multi-hypothesis reading is required. Do not record this as excluded
   on the strength of a probe that happened to succeed.

**Do not spend a session on this before** the 0x25 send path and the speaker
playback leg (both handed to the Windows session 2026-10-05), which are
mechanical and already scoped.