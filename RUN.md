# How to run iBridge

This document covers everything you need to take iBridge from a freshly
cloned repo to a working "iPhone camera + touchpad + keyboard + mic on
Mac" demo, plus the automated test loop.

## Prerequisites

- **macOS 26 (Tahoe) or later** host machine (Apple silicon or Intel)
- **Xcode 26.0+**
- **iPhone or iPad running iOS 26** (any device — A13 Bionic or newer)
- Both devices on the same WiFi network (any 2.4 GHz / 5 GHz / 6 GHz)
- ~30 minutes the first time

## 0. Bootstrap (one-time)

```sh
# From the repo root
brew install xcodegen

# Generate both Xcode projects
xcodegen generate --spec project-ios.yml
xcodegen generate --spec project-mac.yml
```

This produces `iBridgeCapture.xcodeproj` and `iBridgeReceiver.xcodeproj`.

## 1. Automated test loop (highly recommended)

```sh
./scripts/test.sh
```

What it runs:

1. **`swift test` on `iBridgeCore`** — 26 unit + integration tests
   covering the wire protocol, Bonjour discovery, event pipeline,
   audio packet round-trip.
2. **`xcodebuild` for `iBridgeCapture`** — confirms the iOS app builds.
3. **`xcodebuild` for `iBridgeReceiver`** — confirms the Mac app builds.

If everything is green, proceed. If anything fails, **do not skip** —
the rest depends on the wire protocol working.

```
── iBridgeCore package tests ──
Test Suite 'All tests' passed.
   Executed 26 tests, with 0 failures
✓ iBridgeCore tests (26 e2e + unit)

✓ iBridgeCapture builds
✓ iBridgeReceiver builds

All checks passed.
```

## 2. Run the Mac app

```sh
open iBridgeReceiver.xcodeproj
```

In Xcode:

1. Select the **`iBridgeReceiver`** scheme (top bar).
2. Make sure "My Mac" is the run destination.
3. Press **⌘R** (Run).

You should see:

- A small icon appear in the **macOS menu bar**.
- A floating **Control Panel** window opens automatically.
- The status pill says **"Looking for an iPhone on your WiFi…"**.

Click the menu bar icon → **Open Preview Window** to see the live video
feed when an iPhone connects.

## 3. Run the iOS app

For the iOS app you need a real device — the simulator has no camera.

```sh
open iBridgeCapture.xcodeproj
```

In Xcode:

1. Plug in your iPhone / iPad via USB.
2. Select it as the run target.
3. **First time only**: Xcode will need a signing team.
   - Click the `iBridgeCapture` project → target → **Signing & Capabilities**.
   - Pick your personal **Team** (free Apple Developer account works).
4. Press **⌘R** (Run).

When the app opens:

1. iOS pops up the **Camera** permission — tap **Allow**.
2. iOS pops up the **Microphone** permission — tap **Allow**.
3. iOS pops up the **Local Network** permission — tap **Allow**.
4. You'll see the live camera viewfinder with the **STOP** button.
5. Tap the button to **start streaming**.

## 4. Watch the magic

Within a few seconds:

- Mac menu bar icon turns blue.
- Mac control panel updates: latency, FPS, bitrate.
- Mac **Preview Window** shows the live iPhone camera feed.

## 5. Try V0.2 features

iOS app has three modes accessible from the icons at the top:

| Mode | Icon | What it does |
|---|---|---|
| Camera | `camera.fill` | Live camera view + streaming toggle |
| Trackpad | `hand.point.up.left.fill` | Whole-screen touch surface — drag = mouse move, tap = left click, two-finger drag = scroll, two-finger tap = right click |
| Keyboard | `keyboard` | Type on the system keyboard; text gets injected into the active Mac window |

Below the stream button: a **Mic on / off** toggle that streams the
iPhone microphone through your Mac speakers.

When the iPhone app is streaming, **all four work simultaneously**:

- Camera → Mac video preview
- Trackpad → Mac cursor + clicks + scroll
- Keyboard → Mac text input
- Mic → Mac speaker playback

## 6. Camera Extension (Mac virtual webcam)

The `iBridgeCameraExtension/` folder contains the **CMIOExtension**
skeleton for a real macOS Camera Extension. When wired into
`iBridgeReceiver.app`, Zoom / Teams / Photo Booth will see "iBridge
Camera" as a system webcam.

The skeleton includes:

- `CameraExtensionProvider` — system calls this
- `CameraExtensionDevice` — one camera, "iBridge Camera"
- `CameraExtensionStream` — one H.264 stream with sample-pull delivery
- Format description + decoder wired to `VTDecompressionSession`
- `CameraExtensionBridge` — host-side adapter that pushes decoded
  NAL frames into the extension

What's left for the developer:

1. **Apple Developer Program** ($99/yr) for system-extension signing.
2. Add `iBridgeCameraExtension` as an `Embed App Extensions` build
   phase on `iBridgeReceiver` in Xcode.
3. First-launch approval in **System Settings → Privacy & Security**.

## Troubleshooting

### Mac says "no devices found"

1. iPhone app must be actively streaming (red dot button pressed,
   status pill green).
2. Both devices on the same WiFi network — not "iPhone hotspot"
   on the Mac.
3. Toggle iPhone WiFi off and back on.
4. Restart both apps.

### iPhone says "No camera available"

You're on the simulator. Camera only works on a real device.

### Touchpad moves but doesn't click

The first generation of `CGEventInjector` posts `mouseMoved` then
`leftMouseDown/Up` as separate events. macOS 14+'s new event system
sometimes drops click events if they're posted < 1 ms apart. We're
working on this — see `CGEventInjector.swift` for the current
implementation.

### Keyboard types gibberish

The `.text` action uses `CGEventCreateKeyboardEvent` with unicode
string. macOS IME and certain apps (e.g. terminal emulators) require
`.down`/`.up` keycode events instead. A custom in-app keyboard that
sends USB HID keycodes is the next step (V0.3).

### Mic plays but with echo / delay

You're hearing yourself through the iPhone → Mac → Mac-speaker loop.
Use headphones on the Mac, or mute the Mac speakers.

### `test.sh` says BUILD FAILED

Run `swift test --package-path iBridgeCore` directly to see the full
error. Common cause: Xcode < 26 (you need iOS 26 / macOS 26 SDKs for
the Liquid Glass APIs).

### Permission dialogs don't appear

On iOS 17+, some permissions only show once. To re-trigger them:
**Settings → [App Name] → reset permissions**, or uninstall and
reinstall the app.

### macOS Gatekeeper blocks the app the first time

Run from Xcode (Cmd+R) once to bypass Gatekeeper, or right-click the
.app in Finder → **Open** → confirm.

## Where the code lives

```
iBridge/
├── README.md                          # project overview + architecture
├── RUN.md                             # this file
├── scripts/test.sh                    # automated test + build loop
│
├── project-ios.yml                    # xcodegen → iBridgeCapture.xcodeproj
├── project-mac.yml                    # xcodegen → iBridgeReceiver.xcodeproj
│
├── iBridgeCore/                       # Swift Package — design system, protocol
│   ├── Tests/                          # 26 unit + e2e tests
│   └── Sources/iBridgeCore/
│       ├── DesignSystem/               # colors / typography / materials / animations
│       ├── Components/                 # IBGlassCard / IBStatusPill / etc.
│       ├── Input/                      # InputInjector protocol + RecordingInputInjector
│       └── Networking/                 # IBProtocol / IBWire / IBEvents / IBEventBroadcaster
│
├── iBridgeCapture/                    # iOS app sources
│   ├── CaptureEngine.swift             # camera + Bonjour publish + broadcaster
│   ├── H264Encoder.swift               # VideoToolbox hardware encode
│   ├── MicrophoneEncoder.swift         # mic → PCM packets
│   ├── TouchpadView.swift              # gesture → TouchEvent
│   ├── KeyboardView.swift              # text field → KeyEvent.text
│   ├── ContentView.swift               # 3-mode tab UI
│   └── ...
│
├── iBridgeReceiver/                   # macOS app sources
│   ├── ReceiverSession.swift           # Bonjour browse + parse + dispatch
│   ├── H264Decoder.swift               # VideoToolbox hardware decode
│   ├── AudioPlayer.swift               # PCM playback via AVAudioEngine
│   ├── BonjourBrowser.swift            # NWBrowser wrapper
│   ├── CameraExtensionBridge.swift     # push decoded frames into system extension
│   ├── Input/CGEventInjector.swift     # real CGEventPost input injection
│   └── ...
│
└── iBridgeCameraExtension/            # CMIOExtension skeleton
```

## What's verified end-to-end (V0.2)

The 26 automated tests in `iBridgeCore/Tests/` cover:

- **Wire protocol** (11 tests) — every frame kind (metadata, video,
  SPS, PPS, touch, key, audio) survives a TCP round-trip with byte-for-byte
  payload equality. Partial frames reassemble correctly. Oversized
  frame-length values are refused (denial-of-service guard).
- **Touch / key / audio event types** (8 tests) — round-trip each
  event kind and verify the modifier bitmask, scroll deltas, base64
  audio encoding, and keycode presence are preserved.
- **Bonjour service discovery + TCP round-trip** (2 tests) — a
  listener advertises the test service, a browser discovers it, a
  real TCP connection is established, and frames flow in both
  directions without corruption.
- **Full input / audio pipeline** (5 tests) — a sequence of touch
  events flows from sender → TCP → IBWire.Parser → InputInjector, and
  the recorded cursor position lands at the expected pixel coordinates.
  Same for keyboard text bursts, audio packets (bit-exact), and mixed
  traffic where video + touch + key frames interleave on the same
  connection.

## What's next (V0.3 roadmap)

- Custom in-app keyboard that sends USB HID keycodes (preserves ⌘C,
  ⇧⌥→, etc.)
- Mac virtual microphone (CoreAudio AU extension)
- Full wiring of the Camera Extension so Zoom sees iBridge Camera
- Real Opus encoding (replace raw PCM) for lower bandwidth