# App Screen Mirror — Implementation Plan

> **For agentic workers:** execute task-by-task. Steps use checkbox syntax.

**Goal:** Live interactive mirror of the Mac's frontmost app window on iPhone/iPad.

**Architecture:** Mac `ScreenCaptureKit` window stream → H.264 hardware encode →
new wire kinds → iOS VideoToolbox decode → `AVSampleBufferDisplayLayer`; touches
map to window-normalized `(u,v)` → Mac absolute `CGEventPost`.

**Tech Stack:** Swift 6.2, ScreenCaptureKit, VideoToolbox, AVSampleBufferDisplayLayer,
Network.framework, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-09-25-app-screen-mirror-design.md`

## Global Constraints

- Swift 6.2, strict concurrency; `@Observable` for new stores; `os_log` subsystem
  `com.remotecrab` (never `print`).
- No new third-party dependencies. No emoji in UI strings. SF Symbols only.
- New iOS files require `xcodegen generate --spec project-ios.yml`; Mac files
  require `--spec project-mac.yml`. `.xcodeproj`/`dist/` are gitignored.
- All shared types live in `RemoteCrabCore` and are `Codable, Sendable, Equatable`.
- `./scripts/test.sh` must pass before any "done" claim.

## File Structure

- Create `RemoteCrabCore/Sources/RemoteCrabCore/Screen/ScreenTargetResolver.swift`
- Create `RemoteCrabCore/Sources/RemoteCrabCore/Screen/ScreenZoomState.swift`
- Modify `RemoteCrabCore/.../Networking/IBEvents.swift` (screen structs, `.screen` surface/feature)
- Modify `RemoteCrabCore/.../Networking/IBWire.swift` (kinds + encode/decode)
- Modify `RemoteCrabCore/.../Networking/IBEventBroadcaster.swift` (send methods)
- Modify `RemoteCrabCore/.../State/FeatureStore.swift` (`screenOn`)
- Create `RemoteCrabReceiver/ScreenStreamer.swift`
- Modify `RemoteCrabReceiver/Input/CGEventInjector.swift` (absolute input)
- Modify `RemoteCrabReceiver/ReceiverSession.swift` (dispatch + send)
- Modify `RemoteCrabReceiver/WindowCapture.swift` (thumbnails)
- Create `RemoteCrabCapture/ScreenDecoder.swift`
- Create `RemoteCrabCapture/ScreenShareView.swift`
- Modify `RemoteCrabCapture/CaptureEngine.swift`, `ContentView.swift`
- Tests under `RemoteCrabCore/Tests/RemoteCrabCoreTests/Screen*Tests.swift`

---

### Task 1: Wire types + kinds + broadcaster (RemoteCrabCore)

Add `ScreenStatus`, `IBScreenControl`, `IBScreenInput`, `IBScreenInfo`; kinds
0x1A–0x1F; encode/decode; broadcaster send methods; `.screen` on `Surface` and
`IBFeature`; `FeatureStore.screenOn`. Tests: round-trip all six kinds.

### Task 2: Pure logic (RemoteCrabCore)

`ScreenTargetResolver.resolve(frontmostPID:windows:)` (window descriptor in/out)
and `ScreenZoomState` (fitRect, `contentPoint(forViewPoint:)`, zoom/pan clamp,
`twoFingerDecision` = pan offset or scroll delta). Tests for each.

### Task 3: Mac pipeline (subagent, `RemoteCrabReceiver`)

`ScreenStreamer` (SCStream + encoder + info/video sends), absolute input in
`CGEventInjector`, dispatch in `ReceiverSession`, thumbnail improvement.

### Task 4: iOS surface (subagent, `RemoteCrabCapture`)

`ScreenDecoder`, `ScreenShareView`, `CaptureEngine` wiring, top-bar button +
`.screen` surface in `ContentView`, placeholder states.

### Task 5: Integrate + verify

`xcodegen` both specs, `./scripts/test.sh` green, manual smoke notes.
