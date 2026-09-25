# Handoff — Windows receiver

> Written on a Windows machine (2026-09-25) so a Mac session can continue.
> Branch: **`feat/windows-receiver`** (pushed). Base: `origin/main`.
> Companion design doc: [`docs/WINDOWS_PORT_PLAN.md`](docs/WINDOWS_PORT_PLAN.md).

---

## TL;DR

A working Windows receiver now lives in **`windows/`** — a standalone Rust
workspace that speaks the exact wire protocol the iOS app already sends.
**No Mac or iOS source is required to build or run it**, and the Windows tree
never modifies the Swift sources.

It has been **verified live against a real iPhone**: video, audio, trackpad
and keyboard all work over WiFi.

---

## What works today

| Area | Status | Crate |
|---|---|---|
| Wire protocol (all 0x00–0x19 frames) | ✅ | `rc-protocol` |
| mDNS discovery + direct-IP + subnet sweep | ✅ | `rc-discovery` |
| TCP session, handshake, pairing, ping watchdog, reconnect | ✅ | `rc-net` |
| H.264 video decode + preview window | ✅ | `rc-render` (OpenH264) |
| Opus audio decode + speaker playback + level | ✅ | `rc-audio` (pure-Rust Opus + cpal) |
| Trackpad / keyboard injection | ✅ | `rc-input` (SendInput) |
| Clipboard (both directions) | ✅ | `rc-os` |
| File transfer → `~/Downloads/RemoteCrab` + reveal | ✅ | `rc-os` |
| System keys (volume/media/open URL) | ✅ | `rc-os` |
| App switcher (`appList` / `activateApp`) | ✅ | `rc-os` |
| Selection rewrite (`textCommand`) | ✅ | `rc-os` |

**Not done yet**: window-list thumbnails (0x17/0x18), virtual camera,
virtual microphone, a real tray UI (currently a console + a preview window).

Run it:

```powershell
cd windows
cargo run -p rc-app --release                 # discover + connect + preview
cargo run -p rc-app -- --selftest             # fake iPhone, no phone needed
cargo run -p rc-app -- --preview-selftest     # real H.264 → window
cargo run -p rc-app -- --audio-selftest       # Opus decode → speaker
cargo run -p rc-app -- --scan                 # diagnose the LAN
cargo run -p rc-app -- --connect <ip>:8765    # bypass discovery
```

Tests: `cargo test` (96) + `cargo clippy --all-targets -- -D warnings` (clean).

---

## The iOS-side changes (already on this branch)

Two product problems were fixed on the **iOS** side so Windows feels
first-class, not like a second-class citizen:

1. **The iPhone now knows the peer's OS.** `IBClientHello` gained an optional
   `platform` field (`"macos"` / `"windows"`), decoded with
   `decodeIfPresent` so an older Mac still parses. `CaptureEngine` exposes
   `connectedPlatform` / `connectedIsWindows`.
   - `IBModifierBar` + `KeyboardScreen` show **Ctrl / Alt / Shift** and
     Windows chords (`Alt+Tab`, `Ctrl+W`, `Esc`…) when the peer is a PC.
   - `TouchpadScreen` passes the same platform flag to the modifier bar.

2. **"Choose a computer" now lists every computer seen**, not only paired
   ones. `MacPairingStore` keeps a `SeenComputer` list populated on **every**
   `clientHello` (before approval), so a brand-new Windows PC is selectable
   even while a Mac holds the session. `CaptureEngine.setPreferredComputer`
   arms the switch for an unpaired machine.

Files touched (all iOS/core):
`RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift`,
`.../State/MacPairingStore.swift`,
`.../Components/IBModifierBar.swift`,
`.../DesignSystem/IBLocale.swift`,
`RemoteCrabCapture/{CaptureEngine,KeyboardScreen,TouchpadScreen,MacPickerView}.swift`,
`RemoteCrabCore/Tests/RemoteCrabCoreTests/PairingTests.swift`.

**⚠️ These iOS changes have NOT been compiled on a Mac.** A Windows machine
has no Swift toolchain, so only the *Windows* side is verified by build/test.
**The Mac session should run `./scripts/test.sh` first**; expect at most
minor Swift compile nits (nothing structural — brace balance and API usage
were reviewed by hand).

---

## Known issues / next steps (in priority order)

1. **Compile + test the iOS changes on a Mac** (`./scripts/test.sh`). This is
   the only real unknown.
2. **Window list (0x17/0x18)**: `rc-net` already decodes `windowList`; the
   Windows side needs `Windows.Graphics.Capture` for thumbnails (or can send
   `canCapture: false` with app-level entries, which the iPhone already
   tolerates).
3. **Timing-sensitive bug seen once**: on a reconnect the iPhone streamed
   video before the Windows decoder was ready and the first frames errored
   harmlessly. Consider buffering SPS/PPS + the first keyframe.
4. **Latency was 10–1400 ms over 2.4 GHz** — the receiver is fine; this is
   the radio. Note in the manual that 5 GHz helps.
5. **Busy/`in use` UX**: when another computer owns the iPhone the receiver
   now shows who holds it and retries every 10 s. If the *other* computer is
   a Mac, the Mac must be disconnected (menu bar → Disconnect) — the iPhone
   itself can also be told to switch via "Choose a computer".

## Gotchas worth remembering

- **`SendInput` absolute vs relative**: `MOUSEEVENTF_MOVE`'s `dx/dy` are
  *relative* unless `MOUSEEVENTF_ABSOLUTE` is set; absolute coords must be
  normalized to `0..65535` across the virtual desktop. Getting this wrong
  makes the cursor race off-screen and vanish (this was a real reported bug,
  now fixed + unit-tested in `rc-input/src/windows_impl.rs`).
- **AP isolation**: if `--scan` finds nothing while the iPhone streams, the
  router is isolating wireless clients. No code can defeat that; document it.
- **`audiopus` needs CMake, `opus` needs a system libopus.** We use
  **`opus-decoder`** (pure Rust) specifically to avoid both. Don't switch
  back without checking the toolchain story.
- **First contact requires a tap on the iPhone** (the pairing prompt). The
  receiver's `clientHello` carries `platform: "windows"` and a stable PC id,
  so after one approval it reconnects silently.

## Architecture map

See [`docs/WINDOWS_PORT_PLAN.md`](docs/WINDOWS_PORT_PLAN.md) §5 for the full
layered diagram. Short version:

```
rc-discovery ─► rc-net ─┬─ video ─► rc-render ─► window
                        ├─ audio ─► rc-audio  ─► speaker
                        ├─ touch/key ─► rc-input ─► SendInput
                        └─ app/file/clipboard ─► rc-os ─► Win32
```
