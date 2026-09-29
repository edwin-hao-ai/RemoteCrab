# Windows receiver — session handoff

> Read this before touching `windows/`. It is the single place that captures
> **status, architecture, the implementation plan for what is left, the
> pitfalls we hit, and how to verify**. It complements
> `docs/WINDOWS_PORT_PLAN.md` (the original port plan); where they disagree,
> this file is newer.

Last updated: 2026-09-29 (on the Windows box — virtual camera brought up end to
end).
**State**: the receiver is feature-complete for the "utility" surface
(discovery/handshake/video/audio/input/mirror/recording/tray/launcher/
clipboard **+ virtual camera**) — `windows` **166 tests** (`cargo test
--workspace` on MSVC) + clippy `-D warnings` clean. **The only remaining
feature work is the virtual microphone** (§5b), plus the Extended Display
limit (§4), and both need the user's Windows 11 box. **Next concrete action
for a new session**: the vcam is wired and E2E-green on this box (§5a); what is
still owed is a *real* visual confirmation by the user — iPhone connected,
`remotecrab --vcam`, then pick **RemoteCrab Camera** in the Windows Camera
app / Zoom / OBS and confirm moving pixels that track the phone. Everything
that can be verified without the phone (unit tests, `vcam_probe` E2E, clippy)
is already green.

> **2026-09-28 audit (on the Windows box)** — four protocol-parity bugs were
> found by diffing every `rc-protocol` field/enum against the Swift sources,
> and fixed. They were all compiler-invisible, so `cargo test`/clippy stayed
> green while the features were silently broken on a real phone. See §3.14.
> New guards: `rc-protocol/tests/wire_keys.rs` (exact JSON keys + every
> Kind/enum raw value), a `rc-input` keymap test over the Mac's full
> `keycode(forCharacter:)` table, and a runnable `rc-os` live smoke check
> (`cargo run -p rc-os --example live_check`). Live-verified on the box:
> `--selftest`, `--preview-selftest`, `--audio-selftest`, `live_check`.

> **2026-09-29 (on the Windows box)** — the virtual camera went from spike to
> shipped: the COM `IMFMediaSource` loads in the Frame Server, delivers real
> samples to any MF consumer, and `vcam_probe` proves it without a phone.
> Six distinct root causes were found on real hardware; all six are written
> down in §3.17–§3.22 and the bring-up recipe is §5a. **No other session may
> "simplify" any of those six fixes without re-proving them on the box.**

---

## 0. TL;DR status

**Done and shipped** (`cargo test --workspace` **166** on Windows/MSVC;
`clippy -D warnings` clean. The `x86_64-pc-windows-gnu` cross-check is the
macOS-side equivalent — run it there via `cargo check --target
x86_64-pc-windows-gnu --workspace`):

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
- **Virtual camera** (Media Foundation): `rc-vcam` (ring + writer +
  `MFCreateVirtualCamera`) and the in-proc `IMFMediaSource` cdylib
  `rc-vcam-source` — see §5a for the recipe and §3.17–§3.22 for the six root
  causes it took. E2E gate: `cargo build --release --example vcam_probe -p
  rc-vcam` must print `RESULT: PASS` (no phone needed).
- **Windows-target compile check**: `brew install mingw-w64` +
  `rustup target add x86_64-pc-windows-gnu`, then
  `cargo check/clippy --target x86_64-pc-windows-gnu --workspace`.
  **This is mandatory** — `#[cfg(windows)]` code is invisible to the macOS
  build (a `TerminateProcess(...).as_bool()` shipped broken for exactly this).

**Not done**:

1. **Virtual microphone** (appear as a system input device) — §5b.
2. **Virtual camera — user-visible confirmation only.** The pipeline is
   E2E-green (`vcam_probe` PASS, 166 tests, clippy clean) but *a person has
   still not looked at it*: no iPhone has been connected with `--vcam` on, and
   no camera app has shown the moving phone feed. That is the last gate, and
   it is a manual one (§6 step 10).
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
    ├── rc-vcam/                # virtual camera, app side:
    │   │                          ring file + FrameWriter + MFCreateVirtualCamera
    │   ├── src/shm.rs          #   ring layout (64-byte header + 2 BGRA buffers)
    │   ├── src/writer.rs       #   FrameWriter: create/publish (NULL DACL section)
    │   ├── src/win.rs          #   HKLM CLSID registration + Start/Stop camera
    │   └── examples/vcam_probe.rs  # E2E: real MF consumer reads our samples
    ├── rc-vcam-source/         # virtual camera, COM side (separate cdylib,
    │   │                          loaded BY THE FRAME SERVER, not by us):
    │   ├── src/source.rs       #   IMFMediaSource (+ hand-written vtable)
    │   ├── src/stream.rs       #   IMFMediaStream: queue + sample clock
    │   ├── src/activator.rs    #   IClassFactory → COM object lifetime
    │   ├── src/exports.rs      #   DllGetClassObject / DllCanUnloadNow
    │   └── src/ring.rs, trace.rs, attrs.rs  # ring reader, RCVCAM_LOG, media types
    ├── rc-testkit/            # fake iPhone for tests / --selftest
    └── rc-app/                # the `remotecrab` binary: CLI + tray + console
        ├── main.rs            # arg parsing, the tokio::select! loop, console commands
        ├── tray.rs            # Shell_NotifyIconW + popup menu (mirrors the Mac popover)
        ├── mirror.rs          # MirrorController: capture/encode thread + input
        ├── vcam.rs            # Vcam: decoded frames → FrameWriter (behind --vcam)
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
14. **serde `rename_all = "camelCase"` silently mangles acronym fields.** The
    Swift structs use verbatim property names, so `iconPNG` / `snapshotJPEG`
    became `iconPng` / `snapshotJpeg` and the iPhone found no key — app icons
    and window thumbnails were silently empty. Fix is an explicit
    `rename = "iconPNG"`. **Never assume camelCase matches the Swift key**;
    any field with a run of capitals needs an explicit `rename` and a test.
15. **A missing enum variant breaks the WHOLE frame, not just that value.**
    The Swift `IBFeature`/`Surface` gained a `screen` case for the mirror, but
    the Rust enums were not updated: `activeSurface: "screen"` made the entire
    `featureState` snapshot fail to decode the moment the user opened the
    mirror. Enums that cross the wire must be diffed against Swift whenever
    the Mac adds a case — `wire_keys.rs` now pins every raw value.
16. **A `Kind` byte with no arm decodes as `Video`** (the parser's fallback).
    That is why 0x1A–0x22 had to be added as explicit kinds: an unknown byte
    hands its JSON payload to the H.264 decoder. Any new wire kind must be
    added to `Kind` + `from_u8_or_video` + a recognise-and-ignore (or handle)
    arm in `rc-net::dispatch_frame`.

### Virtual camera — six root causes (all hit on real hardware, do not "simplify")

Every one of these failed *silently or misleadingly*: builds were green, the
camera enumerated, and only the pixels were wrong or absent. Re-prove them on
the box before touching §5a.

17. **The source DLL must be registered in HKLM, not HKCU.** The Windows
    Frame Server (the service that activates `IMFMediaSource` for Camera.exe /
    Zoom / OBS) runs as `LocalService` and never reads `HKCU`. With a
    per-user CLSID the camera *enumerated fine* and then activated a missing
    object. `rc-vcam::install_source` writes
    `HKLM\Software\Classes\CLSID\{…}\InprocServer32` once, elevated; a
    normal run re-reads HKLM first so it becomes a no-op afterwards.
18. **The frame ring must be a file-backed section with a NULL DACL.** A
    named *private* section lives in one session; the Frame Server is a
    different session/user and `OpenFileMappingW` there fails. The ring lives
    at `%ProgramData%\RemoteCrab\vcam-ring.bin` with a NULL DACL so the
    consumer can open it. Consequence: never truncate that file.
    `CREATE_ALWAYS` returns `ERROR_USER_MAPPED_FILE (0x4C8)` whenever any
    consumer still has it mapped (e.g. the Frame Server keeping the section
    open across an app restart) — observed for real. The writer uses
    `OPEN_ALWAYS` + `grow_to()` (grow-only); the header carries the geometry
    so a stale, larger tail is harmless.
19. **A Rust `&dyn Trait` is not a COM vtable.** `activator.rs` hand-writes
    the raw vtable layout (`QueryInterface`/`AddRef`/`Release` …) and
    `AtomicU32` for the reference count. Boxed trait objects append a data
    pointer that COM callers do not expect — the first real activation reads
    garbage and dies inside the Frame Server, with no log anywhere.
20. **`ReadSample` out-params must be passed as `Some(&mut …)`.** Media
    Foundation writes `E_POINTER (0x80004003)` and returns no sample if they
    are `None`. Also, `Source::Start` must do all three: `SetStreamState(RUNNING)`
    + queue `MESourceStarted` + `MENewStream`, or the consumer waits forever
    for a stream it was never told exists.
21. **Sample timestamps must be on the `MFGetSystemTime()` clock** (100 ns
    units, ~30e9 magnitude). Using the ring's persistent `frame_seq` — or a
    0-based ordinal — makes MF *drop* every sample and the consumer parks on
    `MFSRC_STREAMTICK (0x100)` indefinitely. `StreamCore::next_sample_time()`
    derives timestamps from `MFGetSystemTime()` with a monotonic fallback;
    `SetStreamState(RUNNING)` resets that clock (`reset_sample_clock()`).
22. **`SECURITY_ATTRIBUTES::lpSecurityDescriptor` must outlive the attributes.**
    Returning `(SECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES)` from a function and
    dropping the tuple leaves `sa` pointing at a *moved-from* local. Release
    builds passed by luck (stack residue); the kernel validated garbage and
    returned `ERROR_INVALID_REVISION (0x80070519)` on the debug test build.
    The descriptor now lives in the caller's frame (`everyone_security_descriptor()`
    returns it by value; `create()` builds `sa` in place beside it).

### Virtual camera — how to see what is happening

23. **COM logs are opt-in, and the env var *is* the file path.**
    `rc-vcam-source` appends one line per COM call to the file named by
    `RCVCAM_LOG`; unset, empty, or a relative path means "the log lands in
    whatever the hosting process's CWD happens to be" — use an absolute path.
    `trace.rs` is a `OnceLock<Option<PathBuf>>` so the hot path is one atomic
    load and a branch. Never ship a build with unbounded COM logging: the log
    reached 2.2 MB in a few minutes and the Frame Server holds the file.
    Read it, then delete it — and confirm a clean run does *not* recreate it.
    A good log looks like this (all `S_OK`), which is how you know the *OS*
    loaded the source rather than only our own probe:
    ```
    Set-Item Env:RCVCAM_LOG C:\ProgramData\rc-vcam.log
    ```
    ```
    [pid N] DllGetClassObject rclsid=9D4B0D4D-… -> 0x00000000
    [pid N] CreateInstance riid=7FEE9E9A-…      -> 0x00000000
    [pid N] ActivateObject riid=3C9B2EB9-…      -> hr=0x00000000 ptr_null=false
    [pid N] Source::Shutdown
    ```
24. **`vcam_probe` is the E2E gate, and it needs no phone.** It opens the real
    camera by CLSID (as an MF consumer would), reads 12 samples off the ring
    and asserts the pixels change:
    ```powershell
    cargo build --release -p rc-vcam-source
    cargo build --release --example vcam_probe -p rc-vcam
    .\target\release\examples\vcam_probe.exe   # must print RESULT: PASS, exit 0
    ```
    The `--example` build does **not** relink `rc-vcam-source` — build that
    package separately after touching its sources, or the probe silently runs
    against the old DLL. `--vcam-selftest` (`rc-app`) is the longer 60 s
    variant; it stops on its own after `SECONDS = 60`.

25. **A TUN-mode VPN silently kills every connection to the iPhone.** During
    bring-up on 2026-09-29 the phone was on the same WiFi, VPN off on the
    phone, the app open, `开始推流` pressed — and the PC could not reach it at
    all: no ARP entry, no answer on 8765 anywhere in the /24, mDNS silent for
    20 s. The cause was **Mihomo (Clash Meta) in TUN mode on the PC**: it owns
    the default route, so traffic to a LAN address was pulled into the tunnel
    and dropped. `Find-NetRoute -RemoteIPAddress <phone>` naming `Mihomo`
    instead of `WLAN` is the tell.
    - **Inbound is unaffected** (phone → PC works), which is why this looks
      like a half-dead network and burns an hour.
    - The same symptom has four other causes that look identical: the phone
      on a guest network (Xiaomi guest nets are a separate subnet *and*
      isolated), the iOS **Local Network** permission denied (the app then
      neither advertises nor listens), and the app never started — iOS only
      binds 8765 inside `startStreaming()` (`CaptureEngine.swift:686`), so an
      open app that was never started looks exactly like an offline one.
    - **Fix, in order of preference**: turn TUN off; or add the LAN to the
      proxy's direct rules (`IP-CIDR,192.168.0.0/16,DIRECT,no-resolve` plus
      `tun.route-exclude-address: [192.168.0.0/16]`); or, without touching the
      proxy, a temporary host route (needs an elevated shell, `ActiveStore`
      only, gone on reboot):
      ```powershell
      New-NetRoute -DestinationPrefix <phone>/32 -InterfaceAlias WLAN `
        -NextHop <gateway> -RouteMetric 1 -PolicyStore ActiveStore
      ```
    - `remotecrab doctor` (§5c) detects and names this automatically.
26. **`RCVCAM_LOG` is a file path, not a flag.** `RCVCAM_LOG=1` writes a file
    literally named `1` into the hosting process's working directory — which
    is how a stray `windows/1/` directory appeared during bring-up. Always
    pass an absolute path; see §3.23 for what a healthy log looks like.

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

### 5a. Virtual camera — **shipped; one gate left (user must look at it)**

**Goal**: `RemoteCrab Camera` appears in Zoom/Teams/OBS/Chrome as a webcam
fed by the live iPhone video. **Route chosen: Media Foundation** (Windows 11
22H2+ — DirectShow/`regsvr32`/signing was deliberately not taken).

**Architecture** (the six pitfalls it depends on are §3.17–§3.22):

```
iPhone H.264 ──▶ rc-render (OpenH264 decode, BGRA)
                     │  rc-app --vcam  →  vcam::Vcam::publish
                     ▼
        rc-vcam::FrameWriter  ── writes ─▶  %ProgramData%\RemoteCrab\vcam-ring.bin
        (64-byte header + 2 BGRA buffers, NULL DACL, file-backed)
                     ▲  mapped read-only by CLSID {9D4B0D4D-…-7F6E5D4C3B2A}
                     │
   rc-vcam-source.dll (in-proc COM IMFMediaSource, loaded by the Frame Server)
                     │  MFCreateVirtualCamera("RemoteCrab") by rc-vcam::start_camera
                     ▼
        Windows Frame Server ──▶ Camera.exe / Zoom / OBS / Chrome
```

Two crates, deliberately separate: **`rc-vcam`** is linked into our app (ring +
writer + camera lifetime), **`rc-vcam-source`** is a standalone `cdylib` that
*the Frame Server loads* — it must never pull our app's dependencies in.

**One-time bring-up (elevated).** The CLSID registration is machine-wide:

```powershell
# as Administrator, from windows/
cargo build --release -p rc-vcam-source
cargo run --release -p rc-vcam -- install   # writes HKLM\...\CLSID\{…}\InprocServer32
```

`install_source()` re-reads HKLM first, so afterwards every normal
(non-elevated) run is a no-op; if the key already points at this build's DLL
it writes nothing at all (that is the path taken above — the box is already
registered). Registration now **persists across runs** — `Vcam::drop` stops
the session camera but no longer unregisters, which previously made an
elevated run silently undo itself and forced elevation on the next start.
Undo it with `cargo run --release -p rc-vcam -- uninstall` (elevated).

> Registration is worth **re-proving once** if activation ever fails again:
> `Get-ItemProperty 'HKLM:\Software\Classes\CLSID\{9D4B0D4D-1D2A-4B3E-9C0A-7F6E5D4C3B2A}\InprocServer32'`
> must return the `rc_vcam_source.dll` you expect.

**Everyday use**

```powershell
cargo run -p rc-app -- --vcam            # phone video → virtual camera
cargo run -p rc-app -- --vcam --no-preview
cargo run -p rc-app -- --vcam-selftest   # moving test pattern, no phone; stops after 60 s
```

**Verification ladder** (bottom rungs are automatic; only the top needs a human):

1. `cargo test --workspace` → **166** + `cargo clippy --workspace --all-targets -- -D warnings` clean.
2. `vcam_probe` (E2E, no phone) — opens the camera **by CLSID like a real
   consumer**, reads 12 samples, asserts the pixels change:
   ```powershell
   cargo build --release -p rc-vcam-source
   cargo build --release --example vcam_probe -p rc-vcam   # separate! -p rc-vcam-source
   .\target\release\examples\vcam_probe.exe                # RESULT: PASS, exit 0
   ```
   Last run on this box: `RESULT: PASS — RemoteCrab delivered 11 samples
   with 31680 changing bytes`, exit 0, and **no** `rc-vcam.log` created
   (confirming `RCVCAM_LOG` gating works).
3. `rc-app --vcam-selftest` for a 60 s soak through our own app path.
4. **Manual gate (still owed)** — with a real iPhone: start `rc-app --vcam`,
   open the Windows Camera app / Zoom / OBS, pick **RemoteCrab Camera**, and
   confirm the picture moves and tracks the phone. Until a person has seen
   this, §5a is not closed.

**Known limits**: Windows 11 22H2+ only; the camera exists while the app
runs (session-scoped by `MFCreateVirtualCamera`); geometry follows the
decoded frame (`vcam::publish` re-creates the ring on a size change, which is
why the ring is grown, never truncated).

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

**Plan**: spike the audio driver in a throwaway repo first; only commit a
chosen route here. Until then, the app plays the iPhone mic on the speakers
(`--unmute`). (The MF-virtual-camera spike it used to sit beside is finished
— see §5a.)

### 5c. Polish backlog (small)

- Audio resampler for non-48 kHz devices (pure `resample_linear` + test).
- `--record` audio: muxed single file via MF (currently WAV sidecar).
- Congratulate: mirror double/triple-click on Windows relies on event timing;
  verify word/paragraph select on device.

### 5d. `remotecrab doctor` — why won't it connect?

Run this **first** whenever the iPhone will not connect, before changing any
setting. It gathers the evidence itself and prints ranked causes with fixes.

```powershell
cargo run --release -p rc-app -- --doctor              # browse mDNS only
cargo run --release -p rc-app -- --doctor 192.168.31.5 # probe one address
```

Exit code 0 = nothing wrong, 1 = it found something to fix (usable as a gate
in a support script).

What it checks, and what each result means:

| Check | How | Tells you |
|---|---|---|
| Local addresses | std UDP-connect route probe (`rc_net::route`) | which adapter this PC owns |
| Route to the target | same probe, compared against our own addresses | **VPN/proxy TUN takeover** (§3.25) — the cause that looks like a dead phone |
| mDNS `_remotecrab._tcp` | 6 s browse | whether any phone advertises at all |
| TCP `8765` | connect probe | port bound, or the app was never started |
| Handshake | previous run's outcome | "port open but the handshake stopped" → tap Allow on the phone |

It never claims a problem when the port is open and the handshake succeeded —
a tool that cries wolf gets ignored.

---

## 6. Real-machine test checklist (the user runs this)

1. `cargo run -p rc-app` on Windows, RemoteCrab open + foreground on the iPhone
   on the same Wi-Fi. Expect `sessionReply: accepted`.
   **If it never connects, run `--doctor` (§5d) before touching anything**, and
   on the phone confirm 设置 → 隐私与安全性 → **本地网络** allows RemoteCrab and
   that `开始推流` was pressed (the port only binds inside `startStreaming()`).
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
10. **Virtual camera — the outstanding gate (see §5a).** With a real iPhone:
    `cargo run -p rc-app -- --vcam`, then in the Windows Camera app / Zoom /
    OBS / Chrome pick **RemoteCrab Camera**. Expect (a) it enumerates, (b) a
    *moving* picture that follows the phone, (c) moving on first open without
    a restart, and (d) quitting `rc-app` makes the camera stop delivering.
    Take a screenshot — this is the evidence that closes §5a. If it fails,
    `Set-Item Env:RCVCAM_LOG C:\ProgramData\rc-vcam.log` before starting,
    re-run, and read that file; delete it afterwards.

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
