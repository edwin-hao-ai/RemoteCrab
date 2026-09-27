# Windows receiver — session handoff

> Read this before touching `windows/`. It is the single place that captures
> **status, architecture, the implementation plan for what is left, the
> pitfalls we hit, and how to verify**. It complements
> `docs/WINDOWS_PORT_PLAN.md` (the original port plan); where they disagree,
> this file is newer.

Last updated: 2026-09-27 (device/mac side is iOS+Mac; this file is the
Windows receiver only). **State**: the receiver is feature-complete for the
"utility" surface (discovery/handshake/video/audio/input/mirror/recording/tray
/launcher/clipboard) — `windows` 127 tests + host/`x86_64-pc-windows-gnu`
clippy clean. **The only remaining feature work is virtual camera + virtual
microphone** (§5a/§5b), and both need the user's Windows 11 box. **Next
concrete action for a new session**: have the user run the already-written
vcam spike on Windows (`cargo run -p rc-vcam -- RemoteCrab 20`, §5a) and
report its 3 lines, then implement the COM `IMFMediaSource` that feeds it.

---

## 0. TL;DR status

**Done and shipped** (host + `x86_64-pc-windows-gnu` `cargo test` 127,
`clippy -D warnings` clean on both targets; runtime needs the user's box):

- Discovery (mDNS `mdns-sd` + hotspot/last-IP/`/24` fallback), handshake
  (`clientHello`/`sessionReply`, token pairing, 6 s handshake timeout), 2 s
  ping + 8 s pong timeout, state machine (`searching/connecting/awaiting
  approval/busy/denied/streaming`).
- Video: OpenH264 decode → `minifb` preview window (toggleable at runtime).
- Audio: Opus decode (`opus-decoder`) → `cpal` playback (48 kHz preferred),
  RMS metering, mute/unmute.
- Input: touch→mouse (absolute `SendInput`, drag, right/middle click,
  accel-free trackpad deltas), keyboard (`keymap`, modifier policy: ⌘/⌃ → Ctrl),
  Unicode text, three/four-finger swipe → Task View / virtual desktops,
  pinch → Ctrl+wheel zoom, mirror absolute input with modifiers.
- P2 features: window list + JPEG thumbnails + activate/quit by title,
  app list + 48 px icons, installed-app launcher (`Start Menu *.lnk`),
  file receive → `%USERPROFILE%\Downloads\RemoteCrab` + reveal, clipboard
  both ways, selection rewrite (Ctrl+C/V, clipboard save+restore off the
  UI thread), system keys (volume/media/brightness-unsupported/launchApp/
  openURL/showDesktop=Win+D), app-window mirror (PrintWindow +
  `PW_RENDERFULLCONTENT` + OpenH264 encode + absolute input), recording
  (H.264 passthrough MP4 + PCM WAV), start-at-login (HKCU Run), tray icon
  (embedded product PNG → HICON), bilingual tray/console (`GetUserDefaultUILanguage`).
- **Windows-target compile check**: `brew install mingw-w64` +
  `rustup target add x86_64-pc-windows-gnu`, then
  `cargo check/clippy --target x86_64-pc-windows-gnu --workspace`.
  **This is mandatory** — `#[cfg(windows)]` code is invisible to the macOS
  build (a `TerminateProcess(...).as_bool()` shipped broken for exactly this).

**Not done** (the only remaining feature work):

1. **Virtual camera** (appear in Zoom/Teams/OBS as “RemoteCrab Camera”).
2. **Virtual microphone** (appear as a system input device).
3. **App-window mirror** exists, but **Extended Display** (virtual second
   monitor) reports "not supported" on Windows (macOS has it via
   `CGVirtualDisplay`; Windows has no equivalent public API).

Everything else in the old P2/P3 list is either done or intentionally out of
scope (see §4).

---

## 1. Layout (bi-sync with the repo)

```
windows/
├── Cargo.toml                 # workspace + [workspace.dependencies]
├── assets/tray-icon.png       # generated from assets/menu-bar-icon.svg (32px)
└── crates/
    ├── rc-protocol/           # THE wire contract — mirror of the Swift IB* structs
    │   └── src/{protocol.rs,wire.rs,events.rs}
    ├── rc-discovery/          # mdns-sd browse (+ advertisement schema)
    ├── rc-net/                # Session: connect/handshake/ping/dispatch (tokio)
    ├── rc-render/             # OpenH264 decode + minifb preview window
    ├── rc-audio/              # Opus decode + cpal playback + RMS
    ├── rc-input/              # pure TouchEvent/KeyEvent → MouseAction + Win32 SendInput
    ├── rc-os/                 # Win32 integration: clipboard, files, apps, windows,
    │                          #   system_keys, selection, autostart, icon, thumbnail
    ├── rc-record/             # H.264 passthrough MP4 + WAV sidecar
    ├── rc-mirror/             # app-window mirror: capture + encode + geometry
    ├── rc-testkit/            # fake iPhone for tests / --selftest
    └── rc-app/                # the `remotecrab` binary: CLI + tray + console
        ├── main.rs            # arg parsing, the tokio::select! loop, console commands
        ├── tray.rs            # Shell_NotifyIconW + popup menu (mirrors the Mac popover)
        ├── mirror.rs          # MirrorController: capture/encode thread + input
        └── i18n.rs            # zh/en picker (GetUserDefaultUILanguage)
```

**Data flow**: `rc-discovery` finds a phone → `rc-net::Session` dials, does the
`clientHello`/`sessionReply` handshake, then `dispatch_frame` turns each wire
frame into an `Event` on a broadcast channel → `rc-app`'s `select!` loop feeds
`rc-render` (video), `rc-audio` (audio), `rc-input` (touch/key), `rc-record`,
`rc-mirror`. Outbound frames go through `Session::send_frame`.

**Rule**: any wire change goes in `rc-protocol` first (with a round-trip test),
then the app. Keep names/raw values identical to
`RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBWire.swift`.

---

## 2. Build & verify

```sh
# host (macOS) — fast, catches everything except #[cfg(windows)]
cd windows
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings

# Windows code REALLY must be checked with the GNU target
brew install mingw-w64                 # once
rustup target add x86_64-pc-windows-gnu
cargo check  --target x86_64-pc-windows-gnu --workspace
cargo clippy --target x86_64-pc-windows-gnu --workspace --all-targets -- -D warnings
```

The `x86_64-pc-windows-msvc` target cannot build OpenH264 from macOS (C++),
so use the GNU target. `cargo test` for `rc-os`/`rc-input` only *links* on
Windows (they call Win32), so their logic lives in pure modules that ARE
tested on the host.

On the Windows box:

```powershell
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo run -p rc-app                 # discover + connect + preview
cargo run -p rc-app -- --no-preview # console only
```

---

## 3. Pitfalls / lessons (all of these bit us)

1. **`cfg(windows)` is invisible on macOS.** Always run the GNU-target check.
   A `windows::core::Result` used with `.as_bool()` (it has none) shipped
   because the host build never compiles that code.
2. **`SendInput` coordinates are absolute-only when flagged.** `MOUSEEVENTF_MOVE`
   without `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK` treats `dx/dy` as
   relative and the cursor races off-screen. `send_mouse` normalizes absolute
   virtual-desktop pixels to `0..65535`; multi-monitor can start negative.
3. **A press-release chord must keep the modifier down until the key is up**:
   `Win↓ D↓ D↑ Win↑`, never `Win↓ D↓ Win↑ D↑` (the latter leaves a bare key).
4. **The clipboard is contended and must always be closed.** `OpenClipboard`
   fails transiently (our own Ctrl+C → read makes it worse) → retry ~10×20 ms;
   every early return must `CloseClipboard` or the whole session wedges.
5. **Setting an unsupported `AVCaptureSession`-style preset/format raises an
   uncatchable exception** — mirror the iOS lesson: check `canSet*` first.
   (Windows equivalent: don't add an input/format the pipeline can't take.)
6. **cpal does not resample.** The Opus decoder emits 48 kHz; a 44.1 kHz
   default device pitch-shifts the voice. Prefer a 48 kHz config; a real
   resampler is still a TODO.
7. **`GetUserDefaultUILanguage() & 0x3FF == 0x04`** is Chinese; the app is
   zh/en like the Apple side.
8. **The tray menu must mirror the Mac menu-bar popover** (structure + wording)
   — it is the Windows UI. Keep rows a fixed height and don't let text wrap.
9. **A `Liquid-Glass`-style transparent fill is not a hit area** (iOS lesson,
   same spirit): tray/menu items need real bounds.
10. **Don't leak GDI objects**: DIBs/bitmaps from `CreateDIBSection` /
    `CreateBitmap` must be `DeleteObject`'d after building the HICON; the
    HICON belongs to the tray until `Shell_NotifyIconW(NIM_DELETE)`.
11. **PrintWindow + `PW_RENDERFULLCONTENT`** is the pragmatic window capture;
    UWP/DRM windows can still come back blank → fall back to the app icon.
12. **Recording**: the `mp4` crate only muxes AAC and the project refuses an
    FFI AAC encoder, so video is H.264 **passthrough** MP4 + a PCM **WAV
    sidecar**. A single muxed file needs Media Foundation (Windows-only) —
    fine, but do it on the box.
13. **The mono accent** for `mutool` `icon` etc. — non-issue; keep files small.

---

## 4. What is explicitly out of scope

- **AWDL / peer-to-peer Wi-Fi**: Apple-proprietary link layer; impossible on
  Windows. Router-less paths are the iPhone Personal Hotspot / USB tethering
  (the direct-IP fallback already covers them).
- **Extended Display (virtual second monitor)**: needs a virtual display
  driver. macOS has the private `CGVirtualDisplay`; Windows has no equivalent
  without a signed display driver (WDDM/IDD). Report "not supported".

---

## 5. Remaining work — implementation plan

### 5a. Virtual camera (~2–4 days, needs the Windows box)

**Goal**: `RemoteCrab Camera` appears in Zoom/Teams/OBS/Chrome as a webcam
fed by the live iPhone H.264.

**Two routes — pick after a spike (recommended: route 1):**

- **Route 1 — Media Foundation virtual camera (Windows 11 22H2+).**
  `MFCreateVirtualCamera` (+ `MFVirtualCameraLifetime_Session`,
  `MFVirtualCameraAccess_CurrentUser`) creates a *session-scoped* virtual
  camera for the calling app's user; you supply frames through an
  `IMFMediaSource` you implement (`IMFMediaStream` → `MEMediaSample`).
  *Pros*: in-box API, no driver, no signing. *Cons*: Windows 11+ only, and
  the camera exists only while the app runs (that's fine for us).
  Steps: create the camera → implement a minimal MF media source that pulls
  decoded frames (reuse `rc-render`'s OpenH264 decode, feed NV12/BGRA) →
  `MFCreateVirtualCamera` → publish → verify in the Windows Camera app.
- **Route 2 — DirectShow source filter (any Windows).**
  A COM in-proc server (`.ax`) registered with `regsvr32`; implements
  `IBaseFilter`/`IPin` producing BGRA frames from our ring buffer.
  *Pros*: works on Win10, all apps. *Cons*: registration + admin, signing
  for distribution, and a lot of COM.
  Start from the `windows` crate’s `Win32_Media_DirectShow` bindings; keep the
  frame source pluggable so the same code feeds either route.

**Shared pieces already in the repo**: H.264 decode (`rc-render`), BGRA/YUV
conversion ability (`OpenH264`’s `YUVSource`), the `FrameSlot` fan-out
(`rc-render::window::FrameSlot`) to a second consumer.

**Spike that already exists** (`windows/crates/rc-vcam`): checks
`MFIsVirtualCameraTypeSupported`, calls `MFCreateVirtualCamera`, `Start`s it
with a no-op callback and keeps it alive so the device enumerates. Run on the
Windows box:

```powershell
cargo run -p rc-vcam -- RemoteCrab 20   # then open the Camera app / OBS
```

It reports the support flag, any `MFCreateVirtualCamera` error, and the
`Start()` error (expected until the media-source DLL is registered). That one
run tells us whether the OS/permission path works before writing the COM
media source.

**Verification** (after the media source lands): the Windows Camera app / OBS
selects “RemoteCrab Camera” and shows live pixels; assert a non-black average.

### 5b. Virtual microphone (~3–6 days, needs the Windows box + signing)

**Goal**: `RemoteCrab Microphone` appears as a recording device; the iPhone
mic plays into it.

**Recommended route — a User-Mode Audio Driver (UMDF/ “APO” or a virtual
audio device)**: this is genuinely hard and needs a **test/EV-signed driver**
(WDK + `MakeAuth`). Practical alternatives if a driver is out of scope:
- **VB-Cable style**: document “install VB-Audio Cable, set RemoteCrab to
  play into it” — no code, poor UX.
- **Windows 10+ “Application Loopback”/ `VIRTUAL_AUDIO_DEVICE`**:
  `ActivateAudioInterfaceAsync` with
  `VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK` can *capture an app’s* audio — the
  reverse of what we need; not a general virtual mic.

**Plan**: spike Route A (MF virtual camera) and the audio driver in a
throwaway repo first; only commit a chosen route here. Until then, the app
plays the iPhone mic on the speakers (`--unmute`).

### 5c. Polish backlog (small)

- Audio resampler for non-48 kHz devices (pure `resample_linear` + test).
- `--record` audio: muxed single file via MF (currently WAV sidecar).
- Congratulate: mirror double/triple-click on Windows relies on event timing;
  verify word/paragraph select on device.

---

## 6. Real-machine test checklist (the user runs this)

1. `cargo run -p rc-app` on Windows, RemoteCrab open + foreground on the iPhone
   on the same Wi-Fi. Expect `sessionReply: accepted`.
2. Preview window shows video; tray → **Hide/Show Preview Window** works;
   closing the window yourself flips the label back.
3. Trackpad: move, click, drag (double-tap-hold **and** long-press), scroll
   (momentum), two-finger right-click, three-finger tap (middle), swipe up
   (Task View), swipe horizontally (desktop switch), pinch (**zooms**).
4. Keyboard: typing + Chinese IME; ⌘/⌃ chords (Ctrl) — Alt+Tab, Ctrl+W/Z/A,
   Ctrl+Tab, Alt+F4.
5. Tray: camera/mic/trackpad/keyboard toggles reach the iPhone; Record writes
   an MP4+WAV in `Videos\RemoteCrab` and reveals it; Send Clipboard; Show Last
   Received File (greyed until a file arrives); **Start at login** persists
   across a re-login; language follows the Windows UI language.
6. App switcher: window cards with thumbnails; tap activates by title; quit
   works; **Open App…** lists Start-Menu apps and launches one; **Desktop**
   sends Win+D.
7. Mirror: open on the iPhone → a Windows window appears; tap/drag/right-click/
   scroll/2× tap select work; extended display reports "not supported".
8. Recording, clipboard both ways, file send from the iPhone → file lands in
   `Downloads\RemoteCrab` and Explorer reveals it.
9. Audio: `--unmute` plays the iPhone mic (watch for pitch if the device is
   44.1 kHz — the log warns).

---

## 7. Conventions that keep this maintainable

- Pure logic in testable modules (`injector.rs`, `thumbnail.rs`,
  `system_keys` encoders, `rc-protocol`); the `*_impl.rs` / `rc-os` files stay
  a thin Win32 syscall layer.
- Every new wire frame: round-trip test in `rc-protocol/tests/events.rs` that
  also asserts the JSON field names (the Swift side uses verbatim keys).
- Bilingual strings: `crate::i18n::t(...)`; never hard-code English in the
  tray/console.
- Before any change: **root cause first, write down the impact surface,
  verify on the reporting device, don't stack fixes** (see the top of
  `AGENTS.md`).
