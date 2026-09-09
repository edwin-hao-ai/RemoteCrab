# iBridge — Visual tour

Six screenshots showing what the V0.2 product actually looks like,
both as the running apps and as rendered SwiftUI components.

## 1. `01_ios_real_app_running.png`

The iBridge Capture app running in iOS 26 Simulator (iPhone 17 Pro).
You can see:

- **Status pill** (top-left): "RECONNECTING" with the amber pulsing dot —
  this is `IBStatusPill` rendered with Liquid Glass (the `.bar(in:)`
  modifier using the iOS 26 `.glassEffect()` API).
- **Mode tabs** (top-right): camera (active, filled blue), trackpad (outline),
  keyboard (outline) — circular buttons with the same glass background.
- **Settings antenna** icon (far right): also a Liquid Glass capsule.
- **Big red STOP button** at the bottom-center: `IBPrimaryButton(style: .stream)`.
  Notice the live "RECORDING" pulse ring around it.
- **Camera permission dialog** with our exact `NSCameraUsageDescription`
  string from Info.plist:
  > "iBridge turns your iPhone into a WiFi camera for your Mac."

This is the actual SwiftUI hierarchy from `ContentView.swift`, no fakes.

## 2. `02_design_status_pills.png`

Three `IBStatusPill` states rendered on the Apple Native + Liquid Glass
gradient. From top to bottom:

- **CONNECTED · 24ms** — green pulsing dot + connection latency in SF Mono.
- **RECONNECTING** — amber dot, label only.
- **OFFLINE · No Mac** — red dot, label + reason.

All three use the same capsule shape, but the dot's color, the pulse
animation, and the auxiliary text differ per `IBStatusPill.Status` case.

## 3. `03_ios_stream_button.png`

The streaming control surface — a simulated iPhone camera viewfinder
with the live "LIVE · 1080p · 30" status label in red, the white-with-red-dot
STOP button centered, and the "STOP STREAM" caption beneath. This is what
you see while streaming.

## 4. `04_ios_modes_selector.png`

The iPhone app's mode selector on first launch. Three circular Liquid
Glass buttons in a row: **Camera** (selected, filled blue), **Trackpad**,
**Keyboard**. Each shows a symbol, name, and one-line caption explaining
what the mode does.

## 5. `05_ios_modifier_keys.png`

The trackpad-mode ⌃⌥⌘⇧ modifier bar. Active modifiers fill blue with a
glow; inactive ones sit as outlined glass capsules. This bar is what
toggles ⌘C / ⌥Tab etc. when you're driving the Mac from your iPhone.

## 6. `06_mac_control_panel.png`

The Mac receiver's floating control panel. It's the `IBGlassCard` with
our connection metadata, rendered with the Apple Native + Liquid Glass
design language. Shows:

- **Device**: iPhone 15 Pro
- **Resolution**: 1080p
- **FPS**: 30
- **Bitrate**: 4 Mbps
- **Codec**: H.264
- **Streaming · 192.168.1.42** with the green status dot

The card uses `IBMaterial.glass(in:tint:interactive:)` which on macOS 26+
maps to `View.glassEffect(.regular.interactive(...))`. On macOS 14+ (which
the renderer uses), it falls back to a translucent material that still
demonstrates the design.

## How to regenerate

```sh
# macOS only — uses ImageRenderer + the iBridgeCore design system.
cd /tmp/ibridge-screenshot && swift run
```

This produces all six screenshots in `/tmp/ibridge_demo_*.png` which you
then copy into this folder.