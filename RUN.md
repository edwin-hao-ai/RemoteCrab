# How to run iBridge V0.1

This document covers everything you need to take iBridge from a freshly
cloned repo to a working "iPhone camera on Mac" demo, plus the
automated test loop.

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

The repo includes a script that compiles both apps and runs all
automated tests against the iBridgeCore package:

```sh
./scripts/test.sh
```

What it runs:

1. **`swift test` on `iBridgeCore`** — 13 unit + integration tests
   covering the wire protocol, Bonjour discovery, and a full
   Bonjour-advertised TCP round-trip (no hardware required).
2. **`xcodebuild` for `iBridgeCapture`** — confirms the iOS app
   builds cleanly for the simulator.
3. **`xcodebuild` for `iBridgeReceiver`** — confirms the Mac app
   builds cleanly.

If everything is green, proceed to step 2. If anything fails, **do
not skip this step** — the rest of the demo depends on the wire
protocol working correctly.

```
✓ iBridgeCore tests
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

- A small icon appear in the **macOS menu bar** (top right of the screen).
- A floating **Control Panel** window opens automatically.
- The status pill says **"OFFLINE — Looking for an iPhone…"** or similar.

Click the menu bar icon → **Open Preview Window** to see the live
video feed when an iPhone connects.

## 3. Run the iOS app

For the iOS app you need a real device — the simulator has no
camera.

```sh
open iBridgeCapture.xcodeproj
```

In Xcode:

1. Plug in your iPhone / iPad via USB.
2. Select it as the run target (top bar, where the device dropdown is).
3. **First time only**: Xcode will need a signing team.
   - Click the **`iBridgeCapture`** project → **`iBridgeCapture`** target → **Signing & Capabilities**.
   - Pick your personal **Team** (free Apple Developer account works).
4. Press **⌘R** (Run).

When the app opens:

1. iOS will pop up the **Camera** permission dialog — tap **Allow**.
2. iOS will pop up the **Microphone** permission dialog — tap **Allow**.
3. iOS will pop up the **Local Network** permission dialog — tap **Allow**.
4. You'll see the live camera viewfinder with a red **STOP** button.
5. Tap the button to **start streaming**.

## 4. Watch the magic

Within a few seconds:

- Mac menu bar icon turns blue.
- Mac control panel updates: latency, FPS, bitrate.
- Mac **Preview Window** shows the live iPhone camera feed.

Open the control panel (click menu bar icon → Open Control Panel) for
detailed connection status, and the preview window (Open Preview
Window) for full-screen video.

## 5. Test the V0.2 features

| Feature | Where to find it |
|---|---|
| **Touchpad** | iPhone app → tap the camera viewfinder top-left tab → "Trackpad" |
| **Keyboard** | iPhone app → "Keyboard" tab |
| **Voice input (ASR)** | Planned for V0.3 |

> ⚠️ **V0.2 features are UI only.** The trackpad and keyboard send
> events over the network, but the Mac-side `CGEventPost` injection
> and accessibility-permission flow are not yet implemented. The
> touchpad and keyboard screens will appear, but they won't move the
> Mac cursor or type yet.

## 6. Camera Extension (Mac virtual webcam)

The `iBridgeCameraExtension/` folder contains the skeleton code for a
real **macOS Camera Extension** — when wired up, Zoom / Teams / Photo
Booth will see "iBridge Camera" as a system webcam input.

To finish it requires:

1. **Apple Developer Program membership** ($99/yr) — system
   extensions require a real team, not the free personal team.
2. **System Extension approval** — first launch triggers a macOS
   prompt; user must approve in **System Settings → Privacy &
   Security**.
3. **Embedding the extension** into `iBridgeReceiver.app/Contents/
   PlugIns/` — Xcode does this automatically when the extension
   target is part of the same project.
4. **Manual signing** of the extension bundle with the same team
   identity.

The skeleton already implements:

- `CameraExtensionProvider` (the system calls this)
- `CameraExtensionDevice` (one camera, "iBridge Camera")
- `CameraExtensionStream` (one H.264 stream, sample-pull delivery)
- Format description + decoder wired up to VTDecompressionSession

What's missing:

- The host (`iBridgeReceiver`) wiring its decoded frames into the
  extension. Currently the extension has its own decoder but doesn't
  receive frames from the host yet. See the `iBridgeFrameSink`
  protocol in `CameraExtensionProvider.swift` — that's the seam.

## Troubleshooting

### Mac says "no devices found"

1. Make sure the iPhone app is actually streaming (red dot button
   pressed, status pill green).
2. Check that both devices are on the same WiFi network — not
   "iPhone hotspot" on the Mac or vice versa.
3. Toggle the iPhone's WiFi off and back on.
4. Restart both apps.

### iPhone says "No camera available"

You're running on the simulator. Camera only works on a real device.

### The test script says "BUILD FAILED"

Run `swift test --package-path iBridgeCore` directly to see the full
error. Common cause: missing Xcode 26+ (you need iOS 26 / macOS 26
SDKs for the Liquid Glass APIs).

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
├── iBridgeCapture/                    # iOS app sources
├── iBridgeReceiver/                   # macOS app sources
├── iBridgeCameraExtension/            # macOS Camera Extension skeleton
│
└── prototypes/                        # 9 HTML design direction prototypes
```

## What works today (V0.1)

- ✅ iPhone (iOS 26+) → Mac (macOS 26+) over WiFi
- ✅ Camera: 1080p @ 30 fps, hardware H.264 encode/decode
- ✅ Microphone: captured on iPhone (not yet routed to Mac virtual mic)
- ✅ Bonjour auto-discovery — no IP addresses to type
- ✅ Custom length-prefixed wire protocol with metadata + NAL frames
- ✅ Apple Native UI with **Liquid Glass** design language
- ✅ Mac menu bar app + floating control panel + preview window
- ✅ 13 automated tests (unit + Bonjour + wire protocol e2e)

## What's next (V0.2 roadmap)

- 🎯 Touchpad / keyboard events from iPhone → Mac via `CGEventPost`
- 🎯 Mac virtual microphone (CoreAudio AudioUnit extension)
- 🎯 Finish wiring the Camera Extension so Zoom sees iBridge Camera
- 🎯 Speech input (SFSpeechRecognizer) for voice typing
- 🎯 Windows support (DirectShow virtual camera)
- 🎯 Android support (Camera2 client over WiFi)