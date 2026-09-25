# RemoteCrab for Windows

A Windows receiver for RemoteCrab. It speaks the **same wire protocol** the
existing iOS app already sends, so **the iPhone and Mac code are untouched** —
this tree is standalone and adapts to them.

Status: **P2 — video preview, audio, trackpad, keyboard, clipboard, file
transfer, system keys, the app switcher (list + activate/quit) and live
feature control all work.** Not yet implemented: window-list thumbnails,
virtual camera/microphone, tray UI, recording (see
`docs/WINDOWS_PORT_PLAN.md`).

Video is decoded in Rust with bundled **OpenH264**; audio with a pure-Rust
**Opus** decoder + **cpal/WASAPI** — no system FFmpeg, no CMake, no FFI.

---

## Try it right now (no phone needed)

```powershell
cd E:\RemoteCrab\windows
cargo run -p rc-app -- --selftest
```

Expected:

```
Self-test: starting a fake iPhone on 127.0.0.1 …
  PASS  streaming from iPhone (127.0.0.1)
  PASS  metadata: 1920x1080 @ 30fps
SELF-TEST PASSED — the receive pipeline works.
```

This spins up a fake iPhone locally and drives the whole
discovery → handshake → stream path. If this passes, the receiver works.

To also verify **video decode + the preview window**, run:

```powershell
cargo run -p rc-app -- --preview-selftest
```

Expected:

```
Preview self-test: fake iPhone will stream real H.264 …
  decoded 10 frames (320x180)
  PASS  10 frames decoded (320x180) — window is showing the video
PREVIEW SELF-TEST PASSED — video decodes and renders.
```

A window opens and shows a moving test pattern — that is the same decode
path your iPhone's stream uses.

And for audio:

```powershell
cargo run -p rc-app -- --audio-selftest
```

Expected:

```
decoded 28800 samples (peak 4151, mean |x| 2576)
queued 30 packets, 22080 samples buffered, level 0.088
AUDIO SELF-TEST PASSED — Opus decodes and the player is fed.
```

## Try it with your iPhone

1. On the iPhone, open **RemoteCrab** and start streaming (same WiFi as the PC).
2. On the PC:

   ```powershell
   cd E:\RemoteCrab\windows
   cargo run -p rc-app --release
   ```

3. Watch the console: `[LOOKING]` → `[CONNECTING]` → `[LIVE]`.
   On first contact the iPhone shows an approval card — tap **Allow**.
4. A **preview window** opens and shows the live iPhone camera once
   `[LIVE]`. The iPhone trackpad drives the PC cursor and the iPhone
   keyboard types into whatever window has focus. (Try Notepad.)

   Turn the camera on with the iPhone's top-bar camera button — it's off by
   default.

### When discovery finds nothing

mDNS is blocked on some networks. Try, in order:

1. **Just wait / restart the app.** The receiver automatically falls back to
   (a) the last address that worked, (b) the iPhone-hotspot gateway, then
   (c) **a sweep of your own /24 for anything on port 8765** — no manual IP
   needed in most blocked-mDNS cases.
2. **Diagnose the network:**

   ```powershell
   cargo run -p rc-app -- --scan
   ```

   If this finds nothing *and* the iPhone app is open + streaming, the router
   has **AP isolation** on (clients can't see each other) — turn off
   "AP isolation / wireless isolation" in its settings. Nothing in code can
   defeat AP isolation.
3. **Last resort — connect by IP** (the iPhone shows its address on its
   Connection screen):

   ```powershell
   cargo run -p rc-app --release -- --connect 192.168.1.5:8765
   ```

Other flags:

| Flag | Meaning |
|---|---|
| `--connect IP[:PORT]` | Skip discovery, dial this address (mDNS blocked) |
| `--no-input` | Observe only — do **not** drive the PC cursor/keyboard |
| `--no-preview` | Console status only (no video window) |
| `--list` | Print discovered iPhones and keep running |
| `--unmute` | Play the iPhone mic on this PC's speakers (muted by default) |
| `--selftest` | Fake iPhone on localhost; verify the pipeline |
| `--preview-selftest` | Fake **H.264** stream; verify decode + the window |
| `--audio-selftest` | Decode the embedded Opus tone; verify audio |
| `--scan` | Sweep this PC's /24 for an iPhone on port 8765 |
| `--help` | Usage |

> On first run Windows may show the usual "Unknown publisher" prompt (the
> binary isn't code-signed yet); this is expected in development.

### Live feature control (console commands)

While the receiver is running, type a command and press Enter — the same
toggles the Mac exposes in its menu bar:

| Command | Effect |
|---|---|
| `camera` / `camera on` / `camera off` | Toggle / set the iPhone camera stream |
| `mic [on\|off]` | Toggle / set the iPhone microphone |
| `voice [on\|off]` | Toggle / set the iPhone hold-to-talk voice |
| `trackpad [on\|off]` | Toggle / set the trackpad surface |
| `keyboard [on\|off]` | Toggle / set the keyboard surface |
| `switch-camera` | Flip between the front and back iPhone camera |
| `help` | List the commands |
| `quit` | Shut down (same as Ctrl-C) |

The iPhone's **app switcher** also works in both directions: the list shows
this PC's running apps, and tapping one brings it to the front (holding /
using the quit action terminates it). `--no-input` suppresses both, like it
does for cursor and keyboard injection.

---

## Layout

```
windows/
├── crates/
│   ├── rc-protocol/   wire protocol (frames, events, handshake) — pure logic
│   ├── rc-discovery/  mDNS browse (_remotecrab._tcp) + direct-IP fallback
│   ├── rc-net/        TCP session: handshake, ping watchdog, reconnect, tokens
│   ├── rc-input/      SendInput injection + CGKeyCode→VK mapping
│   ├── rc-render/     H.264 decode (OpenH264) + the preview window
│   ├── rc-audio/      Opus decode (pure Rust) + cpal/WASAPI playback
│   ├── rc-os/         clipboard, file receive, system keys, app list, selection
│   ├── rc-testkit/    a fake iPhone for end-to-end tests
│   └── rc-app/        the `remotecrab` binary (CLI + status + preview + audio)
└── README.md
```

## Test

```powershell
cd E:\RemoteCrab\windows
cargo test                                  # 96 tests
cargo clippy --all-targets -- -D warnings   # clean
```

`rc-net/tests/session.rs` runs a real receiver against the fake iPhone over a
real socket and asserts: accepted handshake, pending→approval, busy→error,
metadata/featureState delivery, ping RTT, feature control, handshake timeout
recovery, and disconnect.

## What maps to what (security note)

The iOS app is the **capture + recognition** side; Windows only **displays and
injects**. Video arrives as H.264 NAL units (decoded here with OpenH264),
audio as Opus, voice as already recognised text. Trackpad gestures arrive as relative deltas (`dx/dy` scaled by
screen height) — the same "joystick" model the Mac receiver uses.

Two Windows-specific caveats:

- **UIPI**: a normal-privilege process cannot inject input into a window running
  as administrator. The cursor will simply not move there. (The Mac has the
  same class of limitation with secure input fields.)
- **Modifiers**: the iOS `command` (⌘) and `control` (⌃) bits both map to
  Windows **Ctrl**, so a Mac muscle-memory `⌘C` becomes `Ctrl+C`.

## Roadmap

| Phase | Contents |
|---|---|
| **P1 (this)** | discovery, handshake/pairing, video frames, trackpad, keyboard, status |
| **P2 (done)** | audio, clipboard (both directions), file transfer → `~/Downloads/RemoteCrab`, app switcher (list + activate/quit), system keys, selection rewrite, live feature control |
| P3 | window-list thumbnails, virtual camera (DirectShow / MF), virtual microphone, tray UI, installer + code signing |

Full plan: [`../docs/WINDOWS_PORT_PLAN.md`](../docs/WINDOWS_PORT_PLAN.md).
