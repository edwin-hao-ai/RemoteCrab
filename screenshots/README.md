# iBridge — Visual tour

Screenshots of the V0.1 (basic) and V0.2 (polished) UI.

## V0.1 (functional but bare)

| # | File | What it is |
|---|---|---|
| 1 | `01_ios_v0.1_camera_mode.png` | The original iBridge Capture app running in iOS 26 Simulator, with the iOS 17 camera permission dialog. Shows the original status pill, mode tabs (camera / trackpad / keyboard), and the big red STOP button. |
| 2 | `02_v0.1_status_pills.png` | The three connection-state pills: CONNECTED / RECONNECTING / OFFLINE. |

## V0.2 (designed)

After the "简陋" feedback, every screen was redesigned with proper
information density, real visual hierarchy, and the Apple Native +
Liquid Glass aesthetic. See `RUN.md` for the per-feature story.

| # | File | What it is |
|---|---|---|
| 3 | `03_v0.2_mac_control_panel.png` | The Mac control panel. Top: app identity + CONNECTED · 24ms pill. Hero row: live preview thumbnail + stream stats (Resolution / Frame rate / Bitrate / Codec). Below: a real latency sparkline drawing the last 30 measurements. Device card with iPhone 15 Pro + IP + four feature badges (CAM/MIC/TPAD/KEY) showing which subsystems are active. Bottom: Preview / Stop action row. |
| 4 | `04_v0.2_ios_trackpad.png` | The trackpad surface. Center: glowing blue cursor preview (where the user's finger is) + a faint vertical guide line spanning the screen. Bottom: gesture hints card (Drag / Tap / Two fingers) + the ⌃⌥⌘⇧ modifier bar with ⌘ active. |
| 5 | `05_v0.2_ios_keyboard.png` | The keyboard surface. Top: "ON YOUR MAC" preview card showing the current text being typed + char count. Below: full QWERTY layout with the iOS-style second-row indent, special keys (⇧ ⌫ 123 space ⏎), and the modifier bar at the bottom. |
| 6 | `06_v0.2_ios_topbar.png` | The iOS top bar — the new pill-style "Camera / Trackpad / Keyboard" segmented mode selector. |
| 7 | `07_v0.2_ios_camera.png` | The iOS camera viewfinder with grid lines, status pill + mode selector at the top, big red STOP button with the live pulse ring, and a Mic on/off pill. |
| 8 | `08_v0.2_mac_preview.png` | The Mac Preview window with the minimal "● LIVE · 1080p · 30" status bar and a person-silhouette placeholder showing what a live iPhone feed would look like. |
| 9 | `09_v0.2_mac_menubar.png` | The menu bar dropdown — connected device + 24ms + WiFi 5G status, four feature toggles, and a "Preferences / Quit" footer. |

## How to regenerate

```sh
cd /tmp/ibridge-screenshot && swift run
```

Renders both V0.1 and V0.2 demo screens to `/tmp/v2_*.png` (and
`/tmp/ibridge_demo_*.png` for the older designs). The `v2_*.png` files
are the up-to-date ones.