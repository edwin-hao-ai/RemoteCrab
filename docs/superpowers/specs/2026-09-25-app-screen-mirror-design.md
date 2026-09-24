# App Screen Mirror — Design Spec

**Date:** 2026-09-25
**Branch:** `feature/screen-mirror` (worktree `.worktrees/screen-mirror`)

## Goal

Add a live, interactive mirror of the Mac's **frontmost application window** to
the iPhone/iPad, reachable from a top-bar "screen" button at the same level as
the camera/microphone toggles. The mirror is a full-screen surface with local
zoom/pan; touches operate the mirrored Mac app directly (absolute pointer +
classic trackpad gestures). The existing relative trackpad surface is unchanged
and remains available.

## Non-Goals

- Whole-display mirroring (window only).
- Audio from the Mac.
- Remote-region capture for zoom (local zoom only, v1).
- iOS-initiated target selection beyond following the Mac's frontmost app.

## Decisions (approved with the human)

1. Placed as a new full-screen surface `.screen` (not a PiP), entered from a new
   top-bar button. The trackpad stays its own surface.
2. The mirror **follows the Mac's frontmost app** and captures its frontmost
   on-screen window ("main/active window"), to stay focused and full-window.
3. **Interactive**, not read-only: single-finger tap = absolute left click;
   single-finger drag = left drag; long-press = right click; two-finger tap =
   right click; two-finger drag = pan-first-then-scroll; pinch = local zoom.
4. **Local zoom** (v1): Mac streams at window resolution (Retina 2x, capped);
   iPhone zooms/pans locally. Default view = fit whole window (letterboxed).
5. **Mac cursor is shown** in the mirror (`showsCursor = true`).
6. **X**: two-finger drag pans the mirror view first; when the view hits its
   pan boundary it falls through to scrolling the Mac content.

## Architecture

Mac (`RemoteCrabReceiver/`)
- `ScreenStreamer.swift` — owns `SCStream` + `VTCompressionSession`; follows the
  frontmost app; sends `screenSPS/PPS/video` + `screenInfo`. Also emits input
  handling hooks (see `ScreenInputInjector`).
- `ScreenTargetResolver.swift` (RemoteCrabCore, pure) — given the frontmost PID
  and a list of window descriptors, returns the window to capture.
- `CGEventInjector` gains an **absolute** input path (`inject(screenInput:)`)
  driven by `IBScreenInput`.

iOS (`RemoteCrabCapture/`)
- `ScreenDecoder.swift` — `VTDecompressionSession` + `AVSampleBufferDisplayLayer`.
- `ScreenShareView.swift` — display layer host + gesture layer (zoom/pan/input).
- `ScreenZoomState.swift` (RemoteCrabCore, pure) — fit rect, clamp, zoom/pan math,
  and the pan-first-then-scroll decision.
- `CaptureEngine` — `screenOn`, inbound `screenVideo/SPS/PPS/Info`, outbound
  `screenControl` / `screenInput`.
- `ContentView` — top-bar button + `.screen` surface.
- `FeatureStore`/`Surface`/`IBFeature` — add `.screen`.

## Wire Protocol (new kinds, 0x1A–0x1F)

| Kind | Value | Dir | Payload |
|---|---|---|---|
| screenVideo | 0x1A | Mac→iOS | one H.264 NAL unit |
| screenSPS   | 0x1B | Mac→iOS | SPS NAL |
| screenPPS   | 0x1C | Mac→iOS | PPS NAL |
| screenControl | 0x1D | iOS→Mac | `IBScreenControl {command: start/stop/select}` |
| screenInput | 0x1E | iOS→Mac | `IBScreenInput {action,u,v,dx,dy,modifiers}` |
| screenInfo  | 0x1F | Mac→iOS | `IBScreenInfo {status,windowId,appId,appName,title,originX,originY,width,height,pixelWidth,pixelHeight,showsCursor}` |

`IBScreenInfo.status ∈ {ok, permissionDenied, noWindow}`.
`IBScreenInput.action ∈ {click, dragStart, dragMove, dragEnd, rightClick, scroll}`.
`u,v` are normalized 0..1 inside the window content; `dx,dy` are normalized
deltas for `scroll`. iOS computes `u,v` from its own zoom/pan state, so the Mac
never learns the phone's gesture state.

## Mac capture pipeline

- Resolve window: `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)`
  is front-to-back; filter to the frontmost app's PID, `layer == 0`, size ≥
  160x120, not our PID; match `kCGWindowNumber` to an `SCWindow`.
- Debounce app activation 300 ms; ignore RemoteCrab; if the new front app has no
  eligible window keep the previous target (no thrash); if none, `status=.noWindow`.
- `SCStream`: window content filter, size = window points × backingScale (even),
  long edge ≤ 2560, `minimumFrameInterval = 1/30`, `queueDepth = 2`,
  `showsCursor = true`, `pixelFormat = 32BGRA`, `capturesAudio = false`.
- Encoder: H.264 `VTCompressionSession`, `RealTime`, ~4 Mbps, keyframe ≤ 120;
  emit SPS/PPS once on create; on `-12903` rebuild + re-emit (throttled 1 s).
- Backpressure: drop frames while an encode callback is outstanding.
- Per-frame attachments (`SCStreamFrameInfo.contentRect`, `scaleFactor`) detect
  window move/resize → resend `screenInfo` and reconfigure if size changed.
- Window close / app quit → re-resolve; no target → `status=.noWindow`.

## iOS display + gestures

- Fit rect for window aspect inside bounds; `scaleEffect(zoom)` + `offset(pan)`.
- Touch → content coords: cancel out pan/zoom to get `u,v`; ignore touches on the
  letterbox.
- Two-finger drag: if content is pannable in the drag direction, pan; else send
  `scroll` with the centroid `u,v` and normalized deltas.
- One-finger: < 10 pt and < 0.3 s = `click`; movement = `dragStart/dragMove/dragEnd`.
- Long-press 0.45 s = `rightClick`. Two-finger tap = `rightClick` at centroid.
- Pinch = local zoom (clamped 1..4), clamped pan.

## Mac absolute injection

- `click`/`rightClick`/`drag*`: global = windowOrigin + (u·w, v·h); post at global;
  update `lastCursor`.
- `scroll`: move cursor to the point (window under cursor), then post scroll with
  gain based on window height.

## Window-picker thumbnails (quality/speed fix)

`WindowCapture` currently captures 480 px JPEG @ 0.6 sequentially. Change to
960 px @ 0.72, captured in parallel (`withTaskGroup`, ≤ 4 concurrent), with the
retry delay lowered. Keep the existing degradation paths.

## Error handling

- `permissionDenied` → iOS card: enable Screen Recording on the Mac; Mac calls
  `CGRequestScreenCaptureAccess()` once.
- `noWindow` → iOS placeholder ("这个应用没有可显示窗口").
- Disconnect → stop streamer; mirror shows "Mac 未连接".
- New target/resolution → decoder resets on new SPS/PPS.
- iOS background → mirror stops (platform), like camera.

## Testing

- Pure unit tests in `RemoteCrabCore/Tests`: wire round-trip for all six kinds,
  `ScreenTargetResolver`, `ScreenZoomState` (fit/clamp/zoom/pan, pan-first-then-
  scroll), coordinate mapping.
- Build both app targets via `./scripts/test.sh`.
- E2E hook `REMOTECRAB_E2E_SCREEN=1` (iOS auto-starts the mirror) + receiver log
  markers; full capture E2E requires a Screen-Recording-granted Mac.
