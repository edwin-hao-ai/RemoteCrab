# RemoteCrab — AGENTS.md

> Project context for any AI agent (or human) picking up RemoteCrab.
> Read this first. It captures the **why**, the **what**, the **where**,
> and the **state of the world** at V0.2.

---

## Naming: codename `iBridge`, product `RemoteCrab` (2026-09-14)

**`iBridge` is the permanent codename; `RemoteCrab` is the product name.**
"iBridge" can never ship (Apple trademark conflict), so everything the
user or App Store review can see is **RemoteCrab**: app display names,
"RemoteCrab Camera" / "RemoteCrab Microphone" devices, App Store metadata,
the GitHub repo (`edwin-hao-ai/RemoteCrab`).

Deliberately kept as `iBridge`/`ibridge` (codename, invisible to users):

- The **local working directory** `/Users/edwinhao/iBridge` — session
  history, mddock vault, and agent memory are path-keyed; don't rename it
  casually. The GitHub remote no longer matches the folder name; that's fine.
- **iOS bundle id `com.ibridge.iBridgeCapture`** — App Store Connect app
  `6811599153` is bound to it and bundle ids are immutable once an app
  exists. All other bundle ids are `com.remotecrab.*`.
- **Swift symbol prefixes `IB*`/`IB` (IBWire, IBEvents, IBLocale…)** —
  internal identifiers, renamed only if a file is being touched anyway.
- **`~/.config/ibridge/`** legacy credential path (a parallel
  `~/.config/remotecrab/ios-release.env` symlink exists and is what the
  scripts read).

Everything else was renamed: directories/targets/schemes
(`RemoteCrabCapture`, `RemoteCrabReceiver`, `RemoteCrabCore`,
`RemoteCrabMicDriver`, `RemoteCrabCameraExtension`,
`RemoteCrabAudioExtension`), the Bonjour service `_remotecrab._tcp`
(both ends — change them together or discovery breaks), os_log
subsystems `com.remotecrab*`, UserDefaults keys `remotecrab.*`, E2E env
vars `REMOTECRAB_*`, and all scripts/docs.

---

## Rules for every change (learned the hard way — read first)

1. **用户体验是唯一的仲裁标准 —— 而且三端都要稳固。** This is a commercial
   product, not a demo. A feature that works on the Mac and is broken on
   Windows (or vice versa) is *worse* than not shipping it, because the user
   has no way to tell which half they got. Two things follow, both learned the
   hard way on 2026-09-29 while making the Windows receiver connect reliably:
   - **Never ship a debug affordance as the product's escape hatch.** No "enter
     the IP manually", no raw error codes, no `advanced` panel. When the user
     can't connect, the answer is *a status that explains itself plus one
     obvious action* — never an input only a developer would use. (A proposed
     「手动连接…」tray row was rejected for exactly this reason.)
   - **The line that states what is happening must also state what to do.** A
     status line is a UI surface, not a log line. Whenever the state is not
     "working", it owes the user a *reason* and a *next step*. (The Windows
     tray's status row was the only non-clickable row in the menu, and an entire
     multi-session debugging saga existed because of it.)
   - Corollary: prefer making the failure **impossible or self-healing** over
     adding a control. Fix the cause; don't add a button for the symptom.
2. **A new persisted field must be additive and defaulted, or it silently
   destroys user data.** Both loaders swallow decode errors —
   `MacPairingStore.loadSeen` returns `[]` (`MacPairingStore.swift:242-249`) and
   `TokenStore::load` falls back to `default()` (`token.rs:37-42`) — so a single
   missing `#[serde(default)]` wipes every existing user's paired tokens / seen
   history with **no error anywhere**. Same class: a `Codable` struct in
   `UserDefaults` or a JSON file is a shipped data format. Always add a test
   that loads the **previous** format and asserts nothing was lost, and never
   rename or retype an existing field. Wire frames get the same treatment: a new
   field is `#[serde(default, skip_serializing_if = "Option::is_none")]` so older
   peers keep working.
3. **Find the root cause before changing any code.** No speculative edits, no
   "try this and see". Reproduce it, gather evidence (device `forensic.log`,
   `/usr/bin/log stream --predicate 'subsystem == "com.remotecrab"'`, crash
   reports), state the cause in one sentence, *then* fix that cause. A fix
   without a cause is a guess; a guess that works is a coincidence.
4. **Before editing, write down the impact surface.** Every touched function
   has callers and shared state — list them and say how the change affects
   each. (Recent example: adding viewport insets to `ScreenZoomState` for the
   landscape "content hides under the top bar" bug silently changed the
   two-finger gesture split, because a taller-than-band content now pans
   instead of scrolls — the scroll regression was the *same edit*, not a new
   bug. The fix must handle both.) If a change has a plausible side effect,
   either prove it can't happen or fix the side effect in the same commit.
5. **Bugfixes must be verified on the thing that reported them.** A device UI
   bug needs a device check (or a documented, exact reproduction that can't be
   run headlessly). "Builds + unit tests pass" is not evidence a UI bug is
   fixed.
6. **Don't stack a fix on a fix.** If a second attempt to fix the same issue
   fails, stop and re-do step 1 with the new evidence instead of adding more
   code (three failed attempts means the model is wrong).
7. **Never trust a stale artifact.** Verify the build actually on the device
   (a log line that only the new build emits is the cheapest proof), and
   re-pull logs/crash reports rather than reusing an older run's file.
8. **A test suite that only exercises one connection cannot catch a
   cross-connection bug.** The Windows suite (`rc-net/tests/session.rs`) had 9
   good end-to-end tests and still shipped a receiver that asked the iPhone for
   approval on *every* reconnect, because the token was never persisted — every
   test made exactly one connection, and `token_path: None` meant persistence
   was never touched. When a bug only appears on the second connect, across a
   restart, or after a state migration, the test must span that boundary or it
   proves nothing.

---

## What RemoteCrab is

A two-part macOS + iOS utility that turns an iPhone / iPad into a
**WiFi-attached camera, microphone, trackpad and keyboard** for a Mac.

```
┌─────────────────────────────────────┐
│ iPhone / iPad (RemoteCrab Capture)      │
│                                     │
│  • Camera (AVCaptureSession)        │
│  • Mic (AVAudioEngine → PCM)         │
│  • Touchpad (gestures → TouchEvent)   │
│  • Keyboard (text → KeyEvent)        │
│                                     │
│  All packaged into:                  │
│  ┌──────────────────────────────┐   │
│  │  H.264 + PCM + Events        │   │
│  │  (length-prefixed TCP)        │   │
│  └──────────────────────────────┘   │
└─────────────────────────────────────┘
                    │
                    │ WiFi (Bonjour-discovered TCP)
                    │
┌─────────────────────────────────────┐
│ Mac (RemoteCrab Receiver)               │
│                                     │
│  • H.264 decoder (VideoToolbox)     │
│  • AudioPlayer (PCM)                 │
│  • CGEventPost (touch / keys)        │
│  • CMIOExtension skeleton (v2)       │
│  • Menu bar popover                  │
└─────────────────────────────────────┘
```

**Why:** the user owns the iPhone, doesn't own a webcam / trackpad
/ mic, and wants a polished native experience. **Differentiation:**
no subscription, no cloud, no account, no analytics. Pure local.

---

## Repository layout

```
RemoteCrab/
├── README.md                     # project overview + architecture diagram
├── RUN.md                        # how to build + run on real hardware
├── AGENTS.md                     # ← you are here
├── PRIVACY.md                    # privacy policy (App Store required)
├── project-ios.yml               # xcodegen config for iOS app
├── project-mac.yml               # xcodegen config for Mac app
├── RemoteCrabCore/                  # Swift Package — shared code
│   ├── Package.swift             # iOS 26 / macOS 26
│   ├── Tests/                    # 481 automated tests (see below)
│   └── Sources/RemoteCrabCore/
│       ├── DesignSystem/         # Liquid Glass tokens + animations
│       ├── Components/           # Reusable SwiftUI views (incl. IBModifierBar)
│       ├── Input/                # InputInjector + RecordingInputInjector + TrackpadMath + TextDiff
│       ├── State/                # FeatureStore (@Observable, single source of truth) + ContextProfiles (context-sheet suites)
│       └── Networking/           # IBProtocol, IBWire, IBEvents, IBEventBroadcaster
├── RemoteCrabCapture/               # iOS app
│   ├── Info.plist                # permissions + Bonjour service declaration
│   ├── RemoteCrabCaptureApp.swift   # @main
│   ├── RootView.swift            # Onboarding → Permissions → ContentView
│   ├── OnboardingFlow.swift      # 3-page paged TabView with hero/perm/pair pages
│   ├── PermissionFlow.swift      # per-permission request cards (camera/mic/speech/local-network)
│   ├── ContentView.swift         # surfaces + PiP + voice card; top-bar cam/mic toggles + bottom ⌨️/PTT row (V1.1, dock removed)
│   ├── ContextSheetView.swift    # frontmost-app context sheet: header + 2-col action grid + voice hero (V1.1)
│   ├── CameraPreview.swift       # AVCaptureVideoPreviewLayer wrapper
│   ├── CaptureEngine.swift       # AVCaptureSession + Bonjour publish + broadcaster + Mac→iOS control
│   ├── VoiceRecognizer.swift     # hold-to-talk: SFSpeechRecognizer on-device → KeyEvent(.text)
│   ├── H264Encoder.swift         # VideoToolbox H.264 hardware encode
│   ├── MicrophoneEncoder.swift   # mic → 20 ms PCM packets
│   ├── Input/TouchSurface.swift  # unified UIKit gesture engine (shared by trackpad + keyboard mini-pad)
│   ├── TouchpadScreen.swift      # full-screen TouchSurface + coach marks + labs buttons
│   ├── KeyboardScreen.swift      # system IME (hidden UITextField) + shortcut bar + mini trackpad
│   └── Assets.xcassets/AppIcon.appiconset/   # generated by scripts/generate-ios-app-icons.py
├── RemoteCrabReceiver/              # Mac app
│   ├── RemoteCrabReceiverApp.swift  # @main, owns all scenes; menu bar icon = SF Symbol (Canvas labels render as blobs — don't)
│   ├── SetupAssistantView.swift  # first-run setup wizard (welcome → accessibility → virtual camera → virtual mic → done), 1s live status polling
│   ├── SetupStatus.swift         # shared setup detection: AX trust, CMIO device visibility, HAL mic driver + deep links
│   ├── MenuBarMenu.swift         # MenuBarExtra(.window) popover
│   ├── ReceiverSession.swift     # Bonjour browse + parse + dispatch
│   ├── H264Decoder.swift         # VideoToolbox H.264 hardware decode
│   ├── AudioPlayer.swift         # PCM playback via AVAudioSourceNode
│   ├── BonjourBrowser.swift      # NWBrowser wrapper
│   ├── ControlPanelView.swift    # floating control panel
│   ├── PreviewWindow.swift       # live preview window
│   ├── TestWindowView.swift      # connection self-check: 4 quadrants (camera/keyboard/trackpad/mic)
│   ├── CameraExtensionBridge.swift  # host→extension XPC bridge
│   ├── SystemExtensionManager.swift # OSSystemExtensionRequest activation for the CMIO sysex
│   ├── SystemCommandHandler.swift  # IBSystemCommand (0x19) executor: media-key/volume/brightness CGEvents + NSWorkspace launch
│   ├── Input/CGEventInjector.swift   # real CGEventPost injector
│   ├── Input/InputInjector.swift    # protocol + RecordingInputInjector
│   ├── RemoteCrabReceiver.entitlements
│   └── Assets.xcassets/
├── RemoteCrabCameraExtension/       # CMIOExtension skeleton (V0.2)
│   ├── Package.swift
│   ├── Sources/RemoteCrabCameraExtension/
│   │   ├── CameraExtensionProvider.swift
│   │   ├── CameraExtensionDevice.swift
│   │   └── CameraExtensionStream.swift
│   └── CameraExtension.entitlements
├── prototypes/                   # 9 HTML design direction prototypes
├── screenshots/                  # 18 PNGs of every UI surface
│   ├── 01_ios_v0.1_camera_mode.png
│   ├── 02_v0.1_status_pills.png
│   ├── 03-17_v0.2_*.png         # 15 polished V0.2 mockups
│   ├── 18_v0.2_app_icon.png      # App Store marketing icon
│   └── README.md                 # screenshot index
├── docs/
│   └── WINDOWS_HANDOFF.md        # Windows receiver: status + plan + pitfalls (read first)
├── scripts/
│   ├── test.sh                    # ./scripts/test.sh — CI loop
│   ├── render_ui_screenshots.swift # ImageRenderer tool for mockups
│   ├── generate-ios-app-icons.py  # rsvg-convert + PIL: SVG master → all iOS sizes
│   ├── ios-metadata.json          # App Store Connect content
│   ├── ios-app-store-metadata.py  # generic ASC API client
│   └── release-ios.sh             # ./scripts/release-ios.sh 0.2.0 --all
└── .gitignore
```

---

## Design language: Apple Native + Liquid Glass

Picked during the V0.2 visual exploration. The design is **deliberately
Apple-flavored**, not Linear/Arc-flavored:

- **Material**: `.regularMaterial` (NSVisualEffectView equivalent)
  wherever there's a popup, control panel, or floating surface
- **Glass effect**: iOS 26 `View.glassEffect()` (with a legacy
  `.legacyGlass()` fallback for iOS 14–25)
- **Typography**: SF Pro Display (titles), SF Pro Text (body),
  **SF Mono** (every technical readout: latency, FPS, bitrate, file sizes)
- **Accent color**: System Blue (`Color.accentColor`) — never a custom
  brand color except in the App Icon
- **Status colors**: red / orange / green / red are the only places
  that aren't gray-on-glass
- **SF Symbols** are hierarchical; custom icons live only in the
  menu bar and the App Icon
- **No emoji in UI strings** — only SF Symbols

If you want to break from this, talk to the human first. RemoteCrab is
**not** a startup with a brand identity, it's a native utility that
should feel like it ships from Apple.

---

## Wire protocol

One TCP connection per (iPhone, Mac) pair, length-prefixed binary
frames defined in `RemoteCrabCore/Networking/IBWire.swift`:

```
┌────────────────────────────────────────────────────────┐
│  [4 bytes BE length, includes 1-byte kind]              │
│  [1 byte kind][payload]                                 │
└────────────────────────────────────────────────────────┘
```

| Kind | Code | Sender | Payload |
|---|---|---|---|
| metadata | `0x00` | iOS | UTF-8 JSON `IBStreamMetadata` (first frame on connect) |
| video | `0x01` | iOS | One H.264 NAL unit (length-prefixed AVCC) |
| sps | `0x02` | iOS | H.264 SPS NAL unit |
| pps | `0x03` | iOS | H.264 PPS NAL unit |
| touch | `0x04` | iOS | UTF-8 JSON `TouchEvent` |
| key | `0x05` | iOS | UTF-8 JSON `KeyEvent` |
| audio | `0x06` | iOS | UTF-8 JSON `AudioPacket` (opus data base64-encoded) |
| featureControl | `0x07` | **Mac** | UTF-8 JSON `IBFeatureControl` (remote feature toggles) |
| featureState | `0x08` | iOS | UTF-8 JSON `FeatureStateSnapshot` (on connect + on change) |
| ping | `0x09` | **Mac** | 8-byte timestamp; iPhone echoes verbatim → real RTT |
| clientHello | `0x0A` | **Mac** | UTF-8 JSON `IBClientHello` `{name,id,token?,appVersion}` — first frame on connect |
| sessionReply | `0x0B` | iOS | UTF-8 JSON `IBSessionReply` `{result,ownerName?,token?}`; `result ∈ accepted/pending/busy/denied` |
| appList | `0x0C` | **Mac** | UTF-8 JSON `IBAppList` `{apps:[{id,name,pid,isActive}]}` (app switcher) |
| appListRequest | `0x0D` | iOS | UTF-8 JSON `IBAppListRequest` (empty) — ask for a fresh list |
| activateApp | `0x0E` | iOS | UTF-8 JSON `IBActivateApp` `{id}` — bring a Mac app to the front |
| fileOffer | `0x0F` | iOS | UTF-8 JSON `IBFileOffer` `{id,name,size}` — begin a file transfer |
| fileChunk | `0x10` | iOS | raw bytes (≤128 KiB) — next slice of the file |
| fileComplete | `0x11` | iOS | UTF-8 JSON `IBFileComplete` `{id}` |
| fileAck | `0x12` | **Mac** | UTF-8 JSON `IBFileAck` `{id,status,receivedBytes,path?}` |
| clipboardSet | `0x13` | **both** | UTF-8 JSON `IBClipboard` `{text}` — replace the peer's clipboard |
| textCommand | `0x14` | iOS | UTF-8 JSON `IBTextCommandMessage` `{command}` — rewrite the Mac's selection |
| systemCommand | `0x19` | iOS | UTF-8 JSON `IBSystemCommand` `{command, argument?}` — Mac 系统控制（音量/亮度/媒体键/启动 app）; `0x15`–`0x18` are cameraCommand / quitApp / windowListRequest / windowList |
| screenVideo | `0x1A` | **Mac** | One H.264 NAL unit of the mirrored app window |
| screenSPS | `0x1B` | **Mac** | H.264 SPS |
| screenPPS | `0x1C` | **Mac** | H.264 PPS |
| screenControl | `0x1D` | iOS | UTF-8 JSON `IBScreenControl` `{command: start/stop/select, windowId?}` |
| screenInput | `0x1E` | iOS | UTF-8 JSON `IBScreenInput` `{action, u, v, dx, dy, modifiers}` — `u,v` normalized in the window |
| screenInfo | `0x1F` | **Mac** | UTF-8 JSON `IBScreenInfo` `{status, windowId?, originX/Y, width/height, pixelWidth/Height, showsCursor}` |

The protocol is bidirectional since V0.3: Mac can toggle iPhone
features and measure latency.

### File transfer + recording (V0.4, 2026-09-13)

- **Send to Mac** (AirDrop-like): iPhone top-bar paste icon → Photos/Files
  picker → offer/chunks/complete over the wire → Mac writes to
  `~/Downloads/RemoteCrab/` and **reveals it in Finder**
  (`NSWorkspace.activateFileViewerSelecting`). Menu bar also has a
  "Show in Finder" row for the last received file.
- **Record**: Mac menu bar → Record (⌘R) writes the live stream to
  `~/Movies/RemoteCrab/recording-<stamp>.mov` (H.264, decoded frames via
  `AVAssetWriter`) + `recording-<stamp>.wav` (16-bit PCM). Stops and
  reveals in Finder. (`StreamRecorder.swift`.)
- **Sandbox gotcha**: a sandboxed app's `FileManager` redirects
  `~/Downloads`/`~/Movies` into `~/Library/Containers/…`. Fixed by the
  `com.apple.security.files.downloads.read-write` +
  `com.apple.security.assets.movies.read-write` entitlements **and**
  resolving the real home via `getpwuid` (`MacPaths` in
  `StreamRecorder.swift`).
- E2E flags: `REMOTECRAB_E2E_SEND_FILE=1` (iPhone) and
  `REMOTECRAB_E2E_RECORD=1` (Mac receiver).
- **Clipboard**: iPhone app-switcher toolbar → send iPhone clipboard to
  the Mac; Mac menu bar → send Mac clipboard to the iPhone
  (`clipboardSet` 0x13, either direction).
- **Voice commands**: saying “open X” / “切换到 X” (or “switch to X”)
  activates a running Mac app instead of typing the text
  (`CaptureEngine.handleVoiceCommand`).
- **Selection rewrite** (local, offline): “改写为全部大写” / “make this a
  bullet list” transforms the Mac's current selection via
  `TextTransform` (`IBTextCommand`: uppercase / lowercase / capitalize /
  trimWhitespace / stripNewlines / bulletList). The Mac reads the
  selection with synthetic **⌘C** and writes back with **⌘V**
  (`ReceiverSession.copyFrontmostSelection` / `pasteToFrontmost`),
  saving and restoring the user's clipboard.
  **Why not the Accessibility API:** a *sandboxed* app can post key
  events but cannot read another app's AX tree — `kAXSelectedTextAttribute`
  silently returns nothing, which is why this uses the clipboard.

### App switcher (V0.4, 2026-09-12)

Born from WhisPrompt's window wheel and the Codex Micro macropad's
"jump to the app that needs me" keys — on the iPhone, no extra hardware:

- **Mac** publishes its running regular apps (bundle id / name / pid /
  active) via `appList`, refreshed on launch/terminate/activate and on
  `appListRequest` (`ReceiverSession.publishMacApps()`).
- **iPhone** shows them in the top-bar app-switcher sheet
  (`AppSwitcherView`); tapping sends `activateApp` → Mac
  `NSRunningApplication.activate()`. Pinned apps sort first
  (`remotecrab.ios.pinnedApps`).
- **Keyboard** also gains app-switching chords in the shortcut bar:
  `⌘⇥`, `⌘\``, `⌃↑`, `⌃↓`, `⌘H`, `⌘Q`.
- No screen-recording permission needed (names only, no thumbnails). `TouchEvent` also carries extended
phases (`dragStart`, `pinch`, `threeFingerSwipe`, `threeFingerTap`,
`forceClick`) and a modifier bitmask (shift=1, control=2, option=4,
command=8) that `CGEventInjector` applies end-to-end.

`IBWire.Parser` is an incremental parser that holds onto the trailing
partial frame across calls, so callers don't have to manage
buffering. The parser refuses frames larger than 64 MiB
(denial-of-service guard against corrupt length values).

---

## iOS features (V0.2 + V0.3, all done, all tested)

| Feature | File | Notes |
|---|---|---|
| Camera capture + H.264 encode | `CaptureEngine.swift`, `H264Encoder.swift` | 1080p @ 30 fps, hardware encode via VideoToolbox |
| Bonjour publish | `CaptureEngine.swift` | `_remotecrab._tcp` service on `local.` |
| Microphone capture | `MicrophoneEncoder.swift` | AVAudioEngine → 20 ms Opus packets (`IBOpusEncoder`, 48 kHz mono 24 kbps; PCM fallback if the codec is unavailable). **Real-hardware gotcha**: the input node delivers Float32 non-interleaved, so `int16ChannelData` is nil on device — buffers must be converted to mono Int16; also requires an active `AVAudioSession` (`.playAndRecord`) before `engine.start()` or the tap never fires |
| **Feature home (V1.1 layout)** | `ContentView.swift` | FeatureDock removed (V0.3 dock retired): camera/mic stream toggles are round `video.fill`/`mic.fill` buttons in the top bar; trackpad/keyboard are surfaces; a bottom row holds a round `keyboard` button + the PTT capsule; draggable PiP preview. Camera surface has an ✕ close button, keyboard surface a back button |
| **Context sheet (V1.1)** | `ContextSheetView.swift`, `RemoteCrabCore/State/ContextProfiles.swift` | A context chip pinned at the left of the trackpad/keyboard shortcut rows (outside the ScrollView) opens a full sheet keyed to the Mac's frontmost app (`CaptureEngine.frontmostMacApp`): presentation / agent / console suites (console is the fallback); actions are KeyEvent replays or `systemCommand` (0x19); voice hero triggers PTT |
| **Feature state store (V0.3)** | `RemoteCrabCore/State/FeatureStore.swift` | `@Observable`, single source of truth, synced to Mac via `featureState` |
| **Trackpad gesture engine (V0.3)** | `Input/TouchSurface.swift` | Drag (double-tap-hold), momentum scroll, pinch, accel curve, haptics, force right-click, 3-finger gestures. **Joystick-style relative positioning**: the Mac cursor never teleports — hover applies deltas, discrete events fire at the hover position; the on-screen dot springs back to center on lift and leaves a fading motion trail |
| **K3 keyboard (V0.3)** | `KeyboardScreen.swift` | System IME (Chinese/dictation work), shortcut bar, lockable modifiers, 96pt mini trackpad |
| **Hold-to-talk voice (V0.3)** | `VoiceRecognizer.swift`, `ContentView.swift` | On-device SFSpeechRecognizer (zh-Hans/en-US) → `KeyEvent(.text)`; mic stream yields while active. Wide PTT capsule sits in the bottom row (it's a momentary action, not a mode toggle) |
| **Background mic (V0.3)** | `Info.plist` (`UIBackgroundModes: audio`) | Mic keeps streaming with the app backgrounded (screen shows the system mic indicator). Camera still hard-stops in background — platform restriction; capture-session interruption observers restart video on return |
| **Labs (V0.3, default off)** | `IOSSettingsView.swift`, `Input/TouchSurface.swift` | Air mouse (gyro tilt) + wheel scrolling (draw circles) |
| Onboarding | `OnboardingFlow.swift` | 3-page paged: Hero / Permissions / Pair Mac |
| Permission flow | `PermissionFlow.swift` | Sequential camera / mic / speech / local-network requests |
| iOS Liquid Glass UI | All iOS files | Uses `.glassEffect()` on iOS 26+ |

## Mac V0.2 features

| Feature | File | Notes |
|---|---|---|
| Bonjour browse + connect | `ReceiverSession.swift`, `BonjourBrowser.swift` | Browsing starts at launch (in `ReceiverSession.init`); connects via the raw Bonjour service endpoint (`NWConnection(to:)`), auto-connects to first iPhone found |
| H.264 decode | `H264Decoder.swift` | Hardware decode via VideoToolbox |
| Audio playback | `AudioPlayer.swift` | AVAudioSourceNode pulls PCM |
| Touchpad / keyboard injection | `Input/CGEventInjector.swift` | `CGEventPost` for both |
| Input injection abstraction | `Input/InputInjector.swift` | `InputInjector` protocol + `RecordingInputInjector` (for tests) |
| First-run setup assistant | `SetupAssistantView.swift`, `SetupStatus.swift` | Step wizard: welcome → Accessibility (required) → virtual camera (skippable) → virtual mic (skippable) → done; 1s live polling auto-advances each step; "Finish Setup…" menu row while incomplete |
| Menu bar popover | `MenuBarMenu.swift`, `RemoteCrabReceiverApp.swift` | `MenuBarExtra(.window)` with `.regularMaterial`; feature toggles are real (send `featureControl` to iPhone) |
| Menu bar icon | `RemoteCrabReceiverApp.swift` | SF Symbol `iphone.gen3.radiowaves.left.and.right` (system template; status lives in the popover) |
| Control panel window | `ControlPanelView.swift` | Live preview + stats + feature badges; latency sparkline uses real ping RTT history |
| Preview window | `PreviewWindow.swift` | Minimalist live video display |
| Connection test window | `TestWindowView.swift` | 4-quadrant live self-check (camera / keyboard echo / trackpad pad / mic RMS); data from `ReceiverSession` event mirrors (`typedText`/`lastKey`/`touchVisual`/`micLevel`/`latencyHistory`) written in `handleInbound` before injection |
| Camera Extension skeleton | `RemoteCrabCameraExtension/` | system extension (CMIO), wired via XPC; activation via OSSystemExtensionManager, requires /Applications + user toggle |
| **System commands (V1.1)** | `SystemCommandHandler.swift` | Executes `systemCommand` (0x19): volume/brightness/media keys via system-defined CGEvents (step-based — no readback channel), `launchApp`/`openURL` via NSWorkspace |
| **Settings (V1.1)** | `PreferencesView.swift`, `ReceiverSession.swift`, `BonjourBrowser.swift` | launchAtLogin wired to `SMAppService.mainApp` (was a dead toggle); autoReconnect gate now actually gates the reconnect loop (`remotecrab.autoReconnect`); AWDL peer-to-peer toggle `remotecrab.mac.peerToPeer` (default true) feeds `includePeerToPeer` on both the browser and outbound dials (`tcpParameters()`) |
| **Auto-update (V1.6)** | `UpdaterController.swift`, `RemoteCrabCore/State/UpdateInstallGate.swift`, `scripts/make-appcast.sh` | Sparkle 2, silent + idle-gated (no owned session/recording, 30 s dwell); menu-bar "Check for Updates…"/pending-only "Restart to Update" + Preferences toggle; Info.plist `SUFeedURL`/`SUPublicEDKey` (+ `SUEnableAutomaticChecks`/`SUAutomaticallyUpdate`); `REMOTECRAB_UPDATE_FEED` overrides the feed for tests. See lesson 74 |

### Multi-Mac pairing (V0.4, 2026-09-12)

One iPhone used to accept whichever Mac connected last (the old `accept`
dropped the previous connection), so multiple Macs on one LAN fought over
it. Now ownership is explicit:

- **Wire**: the Mac's first frame is `clientHello` (0x0A); the iPhone
  answers `sessionReply` (0x0B) before sending any stream data.
- **Policy** (`RemoteCrabCore/State/MacPairingStore.swift`, pure + tested):
  already-paired id **with matching token** → `accepted`; unknown Mac →
  `pending`; a different Mac while someone owns the session → `busy`.
- **Pairing**: first approval on the iPhone mints a `token`, persisted in
  a UserDefaults allow-list (`MacPairingStore`) and echoed by the Mac in
  every later `clientHello` (TOFU + token). iPhone UI: approval card +
  Settings → Paired Macs (forget / disconnect).
- **Mac behavior**: `handshaking` → `awaitingApproval` / `streaming`;
  on `busy`/`denied` it stops the 3 s reconnect loop, shows why, and
  offers manual Retry (+ one 30 s slow retry).
- **Legacy fallback**: no `clientHello` within 3 s → admit first-come, so
  an old Mac isn't bricked during the upgrade window.
- **iOS Mac picker (2026-09-15)**: top-bar overflow menu → "Choose a Mac"
  (`MacPickerView`) lists the live session + the paired allow-list.
  Tapping a Mac arms a **preference** (`MacPairingStore.setPreferred`,
  10-minute TTL): the current owner is dropped, and while the preference
  is outstanding `PairingPolicy.decide` answers every OTHER Mac —
  paired-with-token or stranger — `busy(preferred.name)` ("holding the
  door"), so the chosen Mac takes over on its next connect (its own
  auto-retry, or menu-bar Retry). `grant()` clears the preference when
  the chosen Mac arrives; picking the already-connected Mac is a no-op;
  `forget`/`removeAll` clear a dangling preference. The Mac that got
  dropped backs off to manual Retry on `busy`, which is exactly the
  backpressure the switch needs.
- **Test flag**: `REMOTECRAB_E2E_AUTOPAIR=1` auto-approves pending Macs for
  headless runs (mirrors `REMOTECRAB_E2E_MIC` / `REMOTECRAB_E2E_INPUT`).

---

## Tests

481 tests in `RemoteCrabCore/Tests/`, all pass:

```
RemoteCrabCore/Tests/RemoteCrabCoreTests/
├── IBWireTests.swift                  (14)  wire protocol round-trip, partial frames, oversized guard
├── IBEventsTests.swift                (13)  TouchEvent / KeyEvent / AudioPacket / feature frames round-trip
├── FeatureStoreTests.swift             (6)  feature state set/apply/snapshot
├── TrackpadMathTests.swift            (15)  accel curve, velocity-scaled momentum, scroll accel/tick spacing
├── TextDiffTests.swift                 (6)  IME text diffing → KeyEvent sequences
├── PairingTests.swift                 (19)  clientHello/sessionReply round-trip, ownership policy, preferred-Mac, allow-list store
├── PairingHandshakeE2ETests.swift      (1)  clientHello → TCP → policy → sessionReply round-trip
├── AppSwitcherWireTests.swift          (8)  appList / appListRequest / activateApp + windowList / cameraCommand / quitApp round-trips
├── ContextProfilesTests.swift         (41)  19-suite frontmost-app mapping (Mac, unchanged) + platform-aware matching, precedence, per-platform system actions. **The original 25 Mac assertions are byte-for-byte untouched** — the `platform:`/`in:` parameters default, which is what keeps Mac regression risk at zero
├── MetaModifierTests.swift           (4)  the META=16 wire bit: value, round-trip, no overlap with 1/2/4/8, coexists with every other bit
├── MetaKeyRowTests.swift            (10)  ⌃⌥⌘⇧ unchanged on Mac; ⊞ **replaces** ⌘ on Windows; Windows labels distinct (they were "Ctrl" twice); **+ the chord row as data** — each keycap paired with the label VoiceOver says, every Windows chord carries a bit the receiver honours, no two collapse
├── ContextProfileFormatTests.swift   (7)  the **previous** on-disk format loads with nothing lost (rule 2), round-trip keeps every new field, `.systemArg` keeps a label and its argument together
├── ContextProfileStoreTests.swift    (11)  a newer `schemaVersion` is refused naming both versions; one bad file costs only itself; merge replaces by id and still matches
├── ContextWindowsSuiteTests.swift    (15)  **the load-bearing ones**: no two Windows actions collapse to the same keystroke (the ⌃C/⌘C bug), a matched suite renders ITS OWN actions, `testPowerPointIsNotYetMapped` asserts a deliberate absence
├── SystemCommandWireTests.swift        (3)  IBSystemCommand (0x19) wire round-trip
├── SystemKeyEncoderTests.swift         (3)  media-key CGEvent data1 encoding (regression: double-shifted flags)
├── FileTransferWireTests.swift         (3)  fileOffer / raw fileChunk / fileComplete + fileAck
├── ScreenshotPickerTests.swift         (4)  newest-screenshot selection (ignores newer ordinary photos)
├── SerialFileSenderTests.swift         (3)  multi-file sends run in order, never overlap
├── ScrollCoalescerTests.swift          (5)  120 Hz scroll deltas coalesce to one event per frame
├── PinchSmootherTests.swift            (4)  pinch dead-zone + EMA damping
├── ClipboardWireTests.swift            (1)  clipboardSet text round-trip
├── TextTransformTests.swift            (5)  selection transforms + textCommand wire round-trip
├── IBOpusCodecTests.swift              (6)  Opus encode/decode round-trip, garbage packets, rate guard
├── BonjourEndToEndTests.swift          (2)  Bonjour discover + TCP round-trip with bit-exact payload
├── EventPipelineEndToEndTests.swift    (6)  sender → TCP → parser → InputInjector
```

`./scripts/test.sh` runs the package tests + `xcodebuild` for both
app targets. Runs in < 30 seconds. **Always run before committing.**

`./scripts/e2e-device.sh` is the **real-hardware** end-to-end test: it
builds + deploys both apps, launches the iPhone headlessly with every
`REMOTECRAB_E2E_*` flag, and asserts the receiver-log markers (handshake,
video, audio, touch, key, file transfer, clipboard, app switch,
recording). Needs an unlocked, connected iPhone with the screen kept
on (a locked phone suspends the app mid-run and everything fails).
10/10 green as of 2026-09-14.

`./scripts/e2e-simulator.sh` is the **no-device** subset (rewritten
2026-09-15, 10/10 green): the simulator's Bonjour is invisible to the
host, but its TCP listener IS reachable at `127.0.0.1:8765`, so the
script seeds `remotecrab.lastPhoneIP=127.0.0.1` (restored afterwards)
and lets the receiver's direct-IP fallback connect — exercising
handshake + AUTOPAIR + token rekey, **Opus encode/decode live**, touch,
key, file transfer, clipboard, app switch, plus **real drag
verification**: the iPhone stages the cursor at an absolute point
(`e2eStageCursor` — works because the injector clamps to screen
bounds), signals via a clipboard marker, and the script moves a
TextEdit window UNDER the cursor (window-drag assert via AX position;
text-select assert via drag → ⌘C → pbpaste). Video + recording are
skipped (no camera in the simulator). **Headless-launch trap:**
`requestPermissions()` awaits the CAMERA prompt before the listener
starts — grant camera AND microphone via `simctl privacy` first, or an
untapped prompt deadlocks the launch (port 8765 never opens, zero
logs, looks exactly like "Bonjour broken"). Focus trap #2: launching
the sim app raises the Simulator window — re-activate TextEdit as
soon as `sessionReply: accepted` appears, or the scripted keystrokes
land in the wrong window.

---

## Build & run

```sh
brew install xcodegen

cd /Users/edwinhao/RemoteCrab
./scripts/test.sh                    # 151 tests + both apps build

# iOS
xcodegen generate --spec project-ios.yml
open RemoteCrabCapture.xcodeproj
# In Xcode: select your Apple Developer team, plug in an iPhone, ⌘R

# Mac
xcodegen generate --spec project-mac.yml
open RemoteCrabReceiver.xcodeproj
# In Xcode: ⌘R (LSUIElement=YES, so it lives in the menu bar)
```

`RUN.md` is the step-by-step version with screenshots.

---

## How to write a new feature (the pattern)

All iOS work goes through `CaptureEngine` → `broadcaster` → `NWConnection`.
The capture engine owns the connection; UI components call:

```swift
engine.sendTouch(TouchEvent(...))    // trackpad gesture
engine.sendKey(KeyEvent(...))         // keyboard event
engine.setMicrophoneEnabled(true)     // audio toggle
```

For new event types:
1. Define the struct in `RemoteCrabCore/Networking/IBEvents.swift`
2. Add a `Kind` case in `IBWire.swift`
3. Add an `encode` method in `IBWire.swift`
4. Add a `decode*` method in `IBWire.swift`
5. Add a `send(_:)` method in `IBEventBroadcaster.swift`
6. In `CaptureEngine.swift`, expose a public send method
7. In `ReceiverSession.swift`, dispatch the new kind via `IBWire.decode*`
8. Add a test in `IBEventsTests.swift` (round-trip)
9. Add a test in `EventPipelineEndToEndTests.swift` (TCP round-trip)

---

## State of the world (V0.3 — Sept 2026)

### 💰 Monetization decided, crowdfunding paused (2026-09-29)
- **The free tier stays free. Pro is the paid layer, and it is additive** — a
  one-time purchase, never a subscription, because "no subscription" is the
  entire brand. Split is by **scale, not by feature**: one phone + one Mac is
  free forever; Pro sells multi-device, 4K, Extended Display, the recording
  studio and the Windows receiver. The reasoning and the free/Pro boundary are
  in **`docs/campaign/MONETIZATION_PLAN.md`** — read it before changing either.
- **Sell on two channels**: App Store non-consumable IAP for iOS (15% under the
  Small Business Program, which we qualify for but must still *apply* for), and
  Lemon Squeezy for the Mac build (5% + $0.50, handles global VAT and license
  keys). Do **not** plan around Apple's 2026-08-14 link-out proposal — it is a
  filing in the Epic litigation, not a rule.
- **A Kickstarter draft exists and is deliberately parked**
  (`kickstarter.com/projects/1755279085/1224057860`, unpublished). Full
  narrative, Risks, FAQ, 5 tiers and 6 items are written; the campaign copy is
  `docs/campaign/KICKSTARTER_REMOTE_CRAB.md` and the hand-off checklist is
  `docs/campaign/KS_TODO.md`. **Do not launch it for the Pro release** —
  Kickstarter's terms say backers fund "something new, not ordering something
  that already exists", the product is free and publicly downloadable, and
  $25k/$59 needs ~5–8k pre-launch signups we don't have. Revisit only to fund
  something genuinely unbuilt (the Android client, or the agent-routing half of
  the notification relay), after Pro has run long enough to build a list.
- Campaign art exists and is reproducible: `scripts/kickstarter-graphics.py`
  (5 narrative plates + two hero variants from real `build/asc-raw/` device
  captures — **never the `screenshots/` V0.2 mockups**, they are renders in the
  old iBridge brand) and `scripts/kickstarter-discovery-video.sh` (9:16).

### 🚀 V1.0 release — submitted for review 2026-09-19 (current)
- iOS 1.0 build **2026091802** uploaded to ASC app 6811599153, attached to
  version 1.0 and to the TestFlight **Internal** group (`IN_BETA_TESTING`);
  `scripts/ios-app-store-testflight.py` manages groups/builds/attach.
- Mac 1.0 (Developer ID, notarized + stapled): `dist/RemoteCrab-1.0.dmg`,
  produced by `scripts/release-mac.sh 1.0`; live at
  `vgoapp.com/downloads/RemoteCrab.dmg`.
- Domain switched `remotecrab.app` → **`vgoapp.com/remotecrab/`** (product
  page + `/remotecrab/privacy/`), deployed via `VGOAPP/scripts/deploy.sh`.
- The iOS app now links users to the Mac download: onboarding pair page, the
  "Waiting for your Mac" card, and Settings (all via `RemoteCrabLinks`).
- App Review notes written (Demo Mode path, Mac app download, permissions,
  privacy) + demo video `vgoapp.com/downloads/RemoteCrab-demo.mp4`
  (recorded by `scripts/demo-video.sh`).
- **Left for the human**: set the App Store privacy-policy URL in the ASC
  browser (`privacyPolicyUrl` is not exposed by the API). The version is
  `WAITING_FOR_REVIEW`. If review asks for a real-camera demo, record the
  iPhone screen and re-stitch with `scripts/demo-video.sh`.

### ✅ Done
- Camera / Mic / Touchpad / Keyboard end-to-end
- **V0.3: bidirectional protocol** — Mac toggles iPhone features (`featureControl`), state sync (`featureState`), real RTT (`ping`)
- **V0.3: iOS feature-dock home** — streams (camera/mic/voice) independent from surfaces (trackpad/keyboard), draggable PiP
- **V0.3: full trackpad** — drag, momentum scroll, pinch, accel curve, haptics, force right-click, 3-finger gestures; modifiers work end-to-end
- **V0.3: K3 keyboard** — system IME (Chinese OK), shortcut bar, mini trackpad
- **V0.3: hold-to-talk voice** — on-device speech recognition types into the Mac
- **V0.3: labs** — air mouse + wheel scrolling (settings → Labs, default off)
- 481 automated tests passing
- 9 HTML design prototypes + 18 PNG mockups
- Liquid Glass design system with 7 reusable components
- iOS Onboarding (3 pages + permission flow incl. speech)
- Mac setup assistant (welcome → Accessibility → virtual camera → virtual mic)
- Custom App Icon — Liquid Glass "monitor buddy" mascot (master: `assets/app-icon-liquid.svg`)
- App Store Connect release scripts (`scripts/ios-*.py`, `scripts/release-ios.sh`)
- Privacy policy (`PRIVACY.md`)
- Camera Extension packaged as CMIO **system extension** + XPC wired + activation flow (status: waiting for user toggle in System Settings)
- **UI audit + polish pass (2026-09-11)** — full iOS+Mac sweep, 4 commits:
  - Mac blockers fixed: real `CGEventInjector` wired (was a recording mock —
    trackpad/keyboard never moved the cursor), menu-bar rows actually open
    windows (⌘P / ⌘⇧P / ⌘T + `NSApp.activate`), disconnect clears
    metadata/frame/latency, sysex activates once (not every launch) with a
    Preferences status section, FirstLaunch re-checks on window focus
  - iOS: `IBStatusPill` gains `.idle`/`.searching`/`.connecting` (no more
    fake RECONNECTING / 0ms), all touch targets ≥ 44pt, trackpad defers
    system edge gestures, coach marks localized (en + zh-Hans)
  - Consistency: `IBGradient.canvasDark` + `IBGradient.brand` tokens replace
    8 hand-written gradients; one status pill everywhere; technical readouts
    in SF Mono; `IBLocale` grew Connection/Voice/Labs/Coach sections

### ❌ Still needed for V1.0 release (real production)
| Item | Why | Estimate |
|---|---|---|
| **Virtual microphone (CoreAudio HAL plugin)** | Driver implemented (`RemoteCrabMicDriver/`): HAL `AudioServerPlugIn` reads an in-process SPSC ring fed over **loopback UDP 127.0.0.1:49182** (the sandbox blocks `shm_open`, so the original POSIX-shm design was silence-only; `MicSocketListener.c` runs the recv thread inside coreaudiod, app side is `MicRingWriter` → NWConnection). pkg is embedded in the app (`dist/RemoteCrabMicrophone.pkg` → `Contents/Resources`) — one-click install from the setup assistant / Preferences, one admin GUI auth. Remaining: user runs the installer once + verify in Zoom/QuickTime/Dictation. (The `RemoteCrabAudioExtension` AUv3 skeleton is a DAW-host plugin and will NOT show up as a system input — don't build on it for this.) | 30 min |
| **App Store review submission** | Metadata + 32 narrative screenshots uploaded to ASC app 6811599153 (en-US + zh-Hans × iPhone 6.9" + iPad 13", all COMPLETE 2026-09-16 — simulator-UI composites via `scripts/capture-asc-raw.sh` + `compose-asc-screenshots.py`; swap for real-device ones if review complains). Subtitle + description + keywords + promo text pushed and read back. Upload build via `release-ios.sh --all`, manual submit in browser | 1 hour |
| **Crash reporting** | OSLog + 3rd-party (Sentry / Bugsnag) | 1 day |
| **VoiceOver / Dynamic Type — device pass** | Core batch done (2026-09-15, commit 0849338: IBFont → Text Styles on iOS, `IBLocale.A11y` 42 keys bilingual, PiP/ToggleRow/menubar-icon/sidebar/status-card blockers fixed, decorative icons hidden). Remaining: real-device VoiceOver walkthrough (verify #9 Announcement timing, #4 PiP double-tap), pill dynamicTypeSize cap evaluation (#19), keyboard preview lineLimit (#20), onboarding scroll-ification at AX sizes (#21) | 1 day |
| **iOS-initiated Mac selection** | Today the Mac dials and the iPhone approves; letting the iPhone browse/pick a Mac is an architecture change (iOS-side browser + persisted targets) | 2-3 days |

Done 2026-09-15: real-device e2e (see Tests), camera extension activation (user approved, device publishes), Opus encoding (ed49e8a), localization pass, ASC metadata + screenshots, trackpad pass (two-finger right-click / orientation mapping / drag-select feel), camera off by default, connection-stability fixes.

### 🛣 Roadmap
- ~~**V0.3** — bidirectional protocol, feature dock, trackpad engine, K3 keyboard, voice, labs, camera sysex~~ ✅
- **V0.4** — Virtual microphone, real-device validation sprint
- **V0.5** — ~~Real Opus encoding~~ ✅ (2026-09-15, Apple AudioConverter, zero deps), localization
- **V1.0** — Public App Store release
- ~~**V1.1** — UI restructure: dock removed (top-bar toggles + PTT row), context sheet (presentation/agent/console suites), `systemCommand` 0x19, Mac settings wired (launchAtLogin/autoReconnect/AWDL)~~ ✅ (2026-09-22)
- ~~**V1.2** — context sheet expanded to 10 suites (presentation/agent/finder/notes/browser/mail/messages/calendar/editor/console), profiles made `Codable` + self-describing (`bundleIDs`) ahead of a future plugin marketplace, 2-column row pairing, full-width voice hero; multi-select file/photo send with a serial queue; "Latest Screenshot" one-tap send (+ Photos permission in onboarding); connection-sheet "Choose a Mac" entry; glass-button hit-area + keyboard-mode PTT overlap fixes~~ ✅ (2026-09-22)
- ~~**V1.3** — trackpad scroll-feel pass (velocity-scaled momentum, scroll sensitivity + natural direction, per-frame event coalescing, adaptive/glide-off haptics, pinch de-jitter, "tap during a glide brakes instead of clicking"); Mac sandbox removed (Quit works) + defaults migration; window picker drops a quit app; connection resilience (dial-any-discovered, owner watchdog, ping timeout)~~ ✅ (2026-09-23)
- **V1.4** — context-sheet action-label localization batch (the 10 suites ship English labels; sheet chrome is already bilingual); **bidirectional discovery** (Mac advertises + iPhone browses/dials, so a one-way Bonjour failure can't deadlock; needs a Mac listener + a role-inverted handshake); connection doctor (Bonjour state, last error, one-tap retry); ~~iOS 26 `SpeechAnalyzer` backend (opportunistic — use it when the model is already installed, never download; see lesson 63)~~ ✅ (2026-09-24, device-confirmed `engine=analyzer` on iPhone 14 / iOS 26); ~~hold-to-talk lifecycle hardened — serialized teardown so many consecutive holds all work (lesson 72) + never-shrink final~~ ✅ (2026-09-27, user-verified)
- **V1.5** — Windows support: app-window **mirror** ✅, window list + JPEG thumbnails ✅, recording (`rc-record`) ✅, app icons ✅, tray + bilingual UI ✅, start-at-login ✅, **virtual camera** ✅ (2026-09-29: `MFCreateVirtualCamera` + a registered COM `IMFMediaSource` in `rc-vcam-source`, fed by a file-backed ring; `vcam_probe` E2E green, `cargo test --workspace` 207, clippy clean and CI-enforced — **still owed**: a human seeing the live phone feed in the Camera app / Zoom, `docs/WINDOWS_HANDOFF.md` §6 step 10); **still open** — **virtual microphone** (a sysvad-class **signed driver**, WDK-only — cannot be built from macOS) and the self-drawn tray panel (§5f). See `docs/WINDOWS_HANDOFF.md` §5a/§5b.
- ~~**Windows 情景模式对齐 + ⊞ 键行 + 套件格式**~~ ✅ (2026-10-03, `082828d`, 真机 e2e 25/25, Lessons 115-117) — 每平台独立动作集（Windows **绝不回退**到 Mac 动作）、⊞ **顶替** ⌘（`windowsLabel` 本来就把 ⌃/⌘ 都渲染成 `"Ctrl"`）、新增 `meta = 16`（否则 ⊞E/⊞R/⊞D/⊞L 一个都发不出去）、修掉 4 个坏按钮（亮度死按钮 / 锁屏塌缩成 `Ctrl+Q` 会退出 app / Safari 打开 Bing / footer 写 "your Mac"）。只上了 3 个**有据可依**的 Windows 套件（agent / editor / browser），其余 13 个**故意不映射**——匹配不上落到系统区是诚实且能用的行为。插件机制只做「格式 + 本地装载」零网络（`schemaVersion` + `source` + `userFile > remote > builtin`）。**🔒 待验**：9 条 Windows 真机项在 `docs/WINDOWS-GAPS-2026-10-03.md` §5.6
- ~~**V1.6 (Mac auto-update)** — Sparkle 2 silent, idle-gated auto-update: `UpdaterController` (`willInstallUpdateOnQuit` → true, stash the UI-less block) + pure `UpdateInstallGate` (30 s dwell, no owned session, not recording), menu-bar "Check for Updates…"/"Restart to Update" + Preferences toggle, Info.plist `SUFeedURL`/`SUPublicEDKey`/`SUEnableAutomaticChecks`/`SUAutomaticallyUpdate`, `release-mac.sh` re-signs Sparkle's nested binaries before notarization + `make-appcast.sh` (EdDSA)~~ ✅ (2026-09-27, merged to `main`); **open verification** — idle gate vs a **real iPhone session**, and the **notarized release** atomic-swap/Gatekeeper path (dev runs skip it). Lesson 74.
- **V2.0** — Android capture client (Camera2 over WiFi); K2 agent chips + voice commands backlog (the possible "phone = attention-router for background agents" Aha — see the 2026-09-24 memory note)

---

## Things the next agent should know

### What `iB` is
An even older pre-launch codename (pre-`iBridge`). Sometimes appears in
ancient code comments. It just means "RemoteCrab" — rename to
`RemoteCrab` if you find it in new code. See "Naming: codename
`iBridge`, product `RemoteCrab`" at the top for the full convention.

### Why we chose Bonjour over mDNS / SSDP
Bonjour is built into every Apple device, free, zero-config, and
robust on flaky home WiFi. We tried SSDP / UPnP first and threw it
out.

### Why we don't use SwiftUI `ImageRenderer` for real PNGs in shipping code
`ImageRenderer` is used **only** in the `scripts/` folder to generate
mockup screenshots for design review. The actual App Store marketing
icon is generated by `scripts/generate-ios-app-icons.py`, which
rasterizes the hand-drawn SVG master `assets/app-icon-liquid.svg`
via rsvg-convert and downscales with PIL, because we want
pixel-perfect control over the output and `ImageRenderer`
doesn't render Liquid Glass correctly in headless mode.

### How the Camera Extension works (CMIO sink architecture, 2026-09-14)
A real `CMIOExtension` is **the** hardest part of this project. It is
now **working end-to-end** — `RemoteCrab Camera` appears in every app's
camera list and delivers real pixels (verified with a camera-permissioned
probe app reading `avg=111` off a live iPhone feed).

**Architecture** — the host feeds the extension over a CMIO **sink
stream**, NOT XPC:
1. Extension (`RemoteCrabCameraExtension/`): one `CMIOExtensionDevice` with
   two streams — `.source` (device → apps) and `.sink` (host → device).
   `CameraSinkStream.consumeSampleBuffer` pulls each frame the host
   enqueues and forwards it out the source via `stream.send`.
2. Host (`RemoteCrabReceiver/CameraSinkFeeder.swift`): CoreMediaIO **C API**
   client — allows screen-capture devices, finds the device by UID
   (`IBCameraDevice.uid`), picks the sink stream, `CMIOStreamCopyBufferQueue`
   + `CMIODeviceStartStream`, then draws each decoded `CGImage` into a
   BGRA 1080p pool buffer and enqueues `CMSampleBuffer`s.
3. `ReceiverSession.decoder.onDecoded` feeds the feeder; flow control is
   one-in-one-out (`readyToEnqueue`, initially **true** or it deadlocks).

**Why not XPC**: systemextensionsd's generated launchd job only vends
`CMIOExtensionMachServiceName`; a custom `NSXPCListener` mach service
can't be looked up by the app (`No such process`). Apple confirms app→
CMIO-extension XPC is unsupported (forum 706184). The old XPC files were
deleted (`IBCameraXPC.swift`, `CameraExtensionBridge.swift`,
`XPCFrameListener.swift`).

**The five gotchas that cost the day** (all fixed, all invisible to
`./scripts/test.sh`):
1. **`main.swift` must call `CFRunLoopRun()` after
   `CMIOExtensionProvider.startService`** — `startService` returns; the
   process exits right after registering and the device never appears.
2. **Advertise `.deviceTransportType`** and return
   `kIOAudioDeviceTransportTypeVirtual` in `deviceProperties`, or CMIO
   won't publish the device. `legacyDeviceID: nil`.
3. **The DAL reports an extension's `.sink` stream as direction 0** (and
   `.source` as 1) — the opposite of the header's wording. OBS also feeds
   `streamIds[1]`. Hardcoded as `CameraSinkFeeder.sinkDirection = 0`; do
   not "fix" it without re-testing.
4. **The system records the host app's origin path at activation.**
   Renaming/moving the app leaves an orphaned record that reads
   `[activated enabled]` but never launches. Re-register via the
   version-bump replacement path (bump the extension's
   `CFBundleVersion`) — deactivation requests fail with an auth error
   once ownership is broken.
5. **Replacing a system extension resets the user's approval.** Never
   re-register automatically because a binary fingerprint changed —
   that silently dropped the approval on every redeploy and the camera
   vanished. `ensureRegistered()` now only auto-repairs when the host
   app *moved*; binary updates need an explicit Preferences →
   Re-register.

**Deploy rules**: host-only changes → `ditto` over
`/Applications/RemoteCrab.app`, approval survives. Extension changes →
bump `CFBundleVersion` in `project-mac.yml` (currently 6) + re-approve.
`systemextensionsctl uninstall/gc` hang waiting for a GUI auth prompt —
don't script them.

**Verifying the picture**: a CLI process has no camera TCC
(`notDetermined`), so AVFoundation probes silently return zero frames
even for the FaceTime camera — build a tiny ad-hoc-signed `.app` with
`NSCameraUsageDescription` and `open` it, grant once, then read pixels
(and save a PNG; numbers lie less than eyes but PNGs settle arguments).
Full detail: `docs/CMIO_SESSION_HANDOFF_2026-09-14.md`.

### Lessons — the archive now lives in `docs/lessons/`

117 entries, each a bug that shipped or a trap that cost a day. **They are not
prose to read front to back** — that is what turned this file into 212 KB.
Find the row, open that one file, read that one lesson.

Several lessons explain *each other* ("an `async`
`UNUserNotificationCenterDelegate` method aborts the app" is the same root
cause as "the TCC callback fires on a background queue"), so follow the
cross-references rather than the file order.

| # | 一句话 | 文件 |
|---|---|---|
| 1 | Swift `Data` slices keep the parent's indices.** `data[4..<n | [`protocol`](docs/lessons/protocol.md) |
| 2 | TCC permission callbacks fire on a background XPC queue.** | [`ios-device`](docs/lessons/ios-device.md) |
| 3 | MenuBarExtra labels: SF Symbols, or a proper template IMAGE  | [`protocol`](docs/lessons/protocol.md) |
| 4 | `./scripts/test.sh` used to clobber signed builds.** Its | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 5 | The mic path needs two non-obvious things on device.** (a) A | [`protocol`](docs/lessons/protocol.md) |
| 6 | Backgrounding kills video but not audio | [`protocol`](docs/lessons/protocol.md) |
| 7 | Actor-isolated tap closures trap on the audio realtime threa | [`ios-device`](docs/lessons/ios-device.md) |
| 8 | `Text(someString)` is verbatim | [`ios-device`](docs/lessons/ios-device.md) |
| 9 | The black video scare was a covered camera, not the decoder. | [`protocol`](docs/lessons/protocol.md) |
| 10 | Accessibility grant survives an in-place redeploy.** Overwri | [`protocol`](docs/lessons/protocol.md) |
| 11 | Tooling gotchas that cost an hour.** macOS has **no `timeout | [`ios-device`](docs/lessons/ios-device.md) |
| 12 | The iOS top bar is a floating overlay | [`ios-device`](docs/lessons/ios-device.md) |
| 13 | Never surface a raw `NWError`/POSIX error.** `"\(error)"` sh | [`ios-device`](docs/lessons/ios-device.md) |
| 14 | `MenuBarExtra(.window)` re-sizes (and visibly animates) when | [`ios-device`](docs/lessons/ios-device.md) |
| 15 | Don't run an always-on `TimelineView` for an idle animation. | [`ios-device`](docs/lessons/ios-device.md) |
| 16 | `H264Decoder.emit` must not build a `CIContext` per frame.** | [`protocol`](docs/lessons/protocol.md) |
| 17 | AVFoundation has a state where `captureSession.isRunning` is | [`ios-device`](docs/lessons/ios-device.md) |
| 18 | One `AVCaptureVideoPreviewLayer` per app, attached only AFTE | [`protocol`](docs/lessons/protocol.md) |
| 19 | The app sandbox blocks `shm_open` outright | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 20 | Personal Hotspot breaks Bonjour | [`connection`](docs/lessons/connection.md) |
| 21 | "iPhone stuck on 连接中" was three stacked bugs (fixed 2026-09- | [`connection`](docs/lessons/connection.md) |
| 22 | The camera is OFF by default (2026-09-15).** Users may only  | [`ios-device`](docs/lessons/ios-device.md) |
| 23 | A stale speculative direct-IP dial starved Bonjour (fixed 20 | [`connection`](docs/lessons/connection.md) |
| 24 | Long-press drag + a wider double-tap window (2026-09-15).** | [`ios-device`](docs/lessons/ios-device.md) |
| 25 | An active record session suppresses ALL in-app haptics (2026 | [`ios-device`](docs/lessons/ios-device.md) |
| 26 | Drag clutch: lifting mid-drag must not end the drag (2026-09 | [`ios-device`](docs/lessons/ios-device.md) |
| 27 | Simulator TCC grants for the camera do not survive a sim reb | [`ios-device`](docs/lessons/ios-device.md) |
| 28 | Bonjour endpoint description strings escape bytes as `\DDD` | [`connection`](docs/lessons/connection.md) |
| 29 | Mac Developer ID signing + notarization goes through a hand- | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 30 | The embedded virtual-mic pkg is the only thing that fails | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 31 | `xcodegen generate` rewrites each app's Info.plist wholesale | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 32 | App Review notes are mandatory for this app, and the API can | [`release-web`](docs/lessons/release-web.md) |
| 33 | iOS "where do I get the Mac app" + one URL source (2026-09-1 | [`release-web`](docs/lessons/release-web.md) |
| 34 | Demo videos: macOS cannot record a physical iPhone's screen  | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 35 | How vgoapp.com is deployed (2026-09-19).** The VGO studio si | [`release-web`](docs/lessons/release-web.md) |
| 36 | The "background microphone" was never actually enabled | [`ios-device`](docs/lessons/ios-device.md) |
| 37 | V1.1 layout: the feature dock is gone (2026-09-22).** | [`connection`](docs/lessons/connection.md) |
| 38 | System-defined (media key) CGEvents: `data1 = (key << 16) |  | [`release-web`](docs/lessons/release-web.md) |
| 39 | A Liquid-Glass background does NOT create a hit area | [`release-web`](docs/lessons/release-web.md) |
| 40 | Only ONE row may anchor itself above the system keyboard | [`connection`](docs/lessons/connection.md) |
| 41 | Multi-file sends MUST be serialized | [`release-web`](docs/lessons/release-web.md) |
| 42 | "Latest Screenshot" reads the photo library, so it needs a P | [`release-web`](docs/lessons/release-web.md) |
| 43 | Context profiles are `Codable` + self-describing on purpose | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 44 | The Mac receiver is NOT sandboxed | [`connection`](docs/lessons/connection.md) |
| 45 | The Mac now dials ANY discovered iPhone (2026-09-22).** It u | [`connection`](docs/lessons/connection.md) |
| 46 | A silent owner must not hold the session forever (2026-09-22 | [`connection`](docs/lessons/connection.md) |
| 47 | The window picker drops an app the moment it quits (2026-09- | [`connection`](docs/lessons/connection.md) |
| 48 | A half-open dial wedged the Mac forever | [`connection`](docs/lessons/connection.md) |
| 49 | The app now stays alive in the background (2026-09-23, super | [`ios-device`](docs/lessons/ios-device.md) |
| 50 | Declaring `UIBackgroundModes: [audio]` breaks a `.playAndRec | [`ios-device`](docs/lessons/ios-device.md) |
| 51 | `contentShape` belongs INSIDE the button style, not on the B | [`release-web`](docs/lessons/release-web.md) |
| 52 | Context-sheet suites: verify shortcuts against the real menu | [`connection`](docs/lessons/connection.md) |
| 53 | App Store rejection 1.0 (2026-09-24) | [`connection`](docs/lessons/connection.md) |
| 54 | ASC screenshot uploads fail intermittently with | [`release-web`](docs/lessons/release-web.md) |
| 55 | The Labs features are two-step and were never device-tested | [`ios-device`](docs/lessons/ios-device.md) |
| 56 | Haptics vs the silent switch vs "System Haptics" (2026-09-24 | [`ios-device`](docs/lessons/ios-device.md) |
| 57 | A control must never toggle the flag that gates its own visi | [`ios-device`](docs/lessons/ios-device.md) |
| 58 | Labs are two-step + inline-wheel design (2026-09-24).** Sett | [`ios-device`](docs/lessons/ios-device.md) |
| 59 | The Mac picker listed the connected Mac twice (2026-09-24).* | [`connection`](docs/lessons/connection.md) |
| 60 | This session's later device-pass fixes (2026-09-24).** Voice | [`ios-device`](docs/lessons/ios-device.md) |
| 61 | Voice "sudden disconnect" on pauses + long holds (2026-09-24 | [`ios-device`](docs/lessons/ios-device.md) |
| 62 | Camera now remembers the user's choice (2026-09-24).** `Feat | [`ios-device`](docs/lessons/ios-device.md) |
| 63 | iOS 26 SpeechAnalyzer compatibility layer (2026-09-24).** Vo | [`ios-device`](docs/lessons/ios-device.md) |
| 64 | App screen mirror (branch `feature/screen-mirror`, 2026-09-2 | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 65 | Screen mirror device debugging + polish (2026-09-25).** Thre | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 66 | Pointer acceleration was silently dead + one shared shortcut | [`connection`](docs/lessons/connection.md) |
| 67 | The recording e2e failure was a Mac H264 decoder deadlock, n | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 68 | Windows parity round 2 + a cross-compile check that actually | [`windows`](docs/lessons/windows.md) |
| 69 | Voice start crashed (SIGABRT), dictation dropped chars in th | [`ios-device`](docs/lessons/ios-device.md) |
| 70 | Extended Display | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 71 | Private-API object ownership: a leaked `CGVirtualDisplay` ma | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 72 | A delayed teardown must never be *skipped* | [`ios-device`](docs/lessons/ios-device.md) |
| 73 | A "keep the previous target" fallback must exempt the deskto | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 74 | Mac auto-update via Sparkle 2 (2026-09-27).** The Developer- | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 75 | The Developer-ID release does not launch on macOS 26 | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 76 | A readiness check that only tests "is it dark" cannot see a  | [`screenshots-web`](docs/lessons/screenshots-web.md) |
| 77 | A simulator TCC row you wrote is inert until `tccd` re-reads | [`screenshots-web`](docs/lessons/screenshots-web.md) |
| 78 | The product UI is localised, so screenshots are per-locale | [`screenshots-web`](docs/lessons/screenshots-web.md) |
| 79 | Mac notification relay + the TCC signature-change trap (2026 | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 80 | `project-ios.yml` had the wrong `DEVELOPMENT_TEAM`, and the | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 81 | The notification relay is verified end-to-end on a real iPho | [`protocol`](docs/lessons/protocol.md) |
| 82 | Tapping a relayed notification switches the Mac to that app  | [`protocol`](docs/lessons/protocol.md) |
| 83 | "It connects sometimes" was a phantom: a persisted loopback  | [`connection`](docs/lessons/connection.md) |
| 84 | A string in a SwiftUI `Text` is looked up in the WRONG bundl | [`protocol`](docs/lessons/protocol.md) |
| 85 | Three of my own e2e-harness bugs, and the discipline they te | [`protocol`](docs/lessons/protocol.md) |
| 86 | A tapped notification aborted the whole app | [`protocol`](docs/lessons/protocol.md) |
| 87 | "切换应用切不过去" was a stale green checkmark, not latency | [`connection`](docs/lessons/connection.md) |
| 88 | Three bugs in a row, all the same shape: the protocol was te | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 89 | `CFBundleVersion` is three numbers wearing one name, and two | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 90 | Re-cutting a release over the same build number reaches nobo | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 91 | A stalled build is usually the network, and my diagnostics w | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 92 | Parallel sessions will commit my working tree — plus the `reset` variant where untracked new files are the only survivors | [`mac-receiver`](docs/lessons/mac-receiver.md) |
| 93 | Splitting a 212 KB AGENTS.md nearly destroyed 26 lessons | [`protocol`](docs/lessons/protocol.md) |
| 94 | A timer cannot decide whether a remote list is empty — plus the 14.6 MB icon frame behind it, and why JPEG was wrong (no alpha) | [`connection`](docs/lessons/connection.md) |
| 108 | An unanchored pinch is a measurable defect — and the correct overload already existed and was tested | [`ios-device`](docs/lessons/ios-device.md) |
| 109 | A drag threshold in view points is wrong the moment the view is zoomed | [`ios-device`](docs/lessons/ios-device.md) |
| 110 | A three-finger gesture is a trackpad gesture — the hand covers the content on a touchscreen | [`ios-device`](docs/lessons/ios-device.md) |
| 111 | Five ways the device e2e produced a wrong verdict — and the rule that a vacuously-passing assertion is worse than none | [`protocol`](docs/lessons/protocol.md) |
| 112 | Two geometry hypotheses died cheaply: measure `SCWindow.frame` vs the mapping box before editing | [`protocol`](docs/lessons/protocol.md) |
| 113 | A complete reference must be filed where the reader will look for it — render it, don't just diff it | [`ios-device`](docs/lessons/ios-device.md) |
| 114 | A hint and a reference are different jobs — and `defaultScrollAnchor` beats a magic sleep | [`ios-device`](docs/lessons/ios-device.md) |
| 115 | A second platform makes the shortcut set per-platform — and it must never fall back to the other platform's | [`protocol`](docs/lessons/protocol.md) |
| 116 | A format that will carry untrusted input needs `schemaVersion` + `source`, and merging must replace by id | [`protocol`](docs/lessons/protocol.md) |
| 117 | An assertion describing the fix instead of the invariant — and only the component under test knows why | [`protocol`](docs/lessons/protocol.md) |


Headless e2e launch envs for the iOS app (via
`devicectl device process launch --environment-variables`):
- `REMOTECRAB_E2E_SURFACE=trackpad|keyboard|camera` — preset the visible
  surface so simulator screenshots can review each screen
- `REMOTECRAB_AUTO_START=1` — skip onboarding, start streaming
- `REMOTECRAB_AUTOSTREAM=1` — keep screen on + e2e frame counters
- `REMOTECRAB_E2E_INPUT=1` — 3 s after connect, send a scripted
  touch-move burst + the text `RemoteCrab-e2e-OK` (goes to whatever
  has Mac keyboard focus — point TextEdit at a scratch file first)
- `REMOTECRAB_E2E_DRAG=1` — 6 s after connect, two scripted drags
  (window move + text selection) with absolute cursor staging and
  clipboard markers for the Mac-side orchestrator
  (`scripts/e2e-simulator.sh` drives them)
- `REMOTECRAB_E2E_MIC=1` — force the mic feature on without tapping
  the phone screen
- `REMOTECRAB_E2E_AUTOPAIR=1` — auto-approve an unpaired Mac (skips the
  iPhone pairing prompt) for headless multi-Mac runs
- `REMOTECRAB_E2E_SWITCH=<bundleid>` — request the Mac app list + activate
  that app, so the switcher path is verifiable from the receiver log
- `REMOTECRAB_E2E_SEND_FILE=<N>` — generate N 1.5 MB files and send them
  (verifies receive + Finder reveal; N>1 exercises the serial queue)
- `REMOTECRAB_E2E_QUIT=<bundleid>` — quit that Mac app (verifies the
  window-picker Quit path from the receiver log: `quitApp … accepted=true`)
- `REMOTECRAB_E2E_RECORD=1` — Mac receiver records 6 s of the live stream
- `REMOTECRAB_E2E_CLIPBOARD=1` — push a known string to the Mac's clipboard
  (verifies the clipboard path from the receiver log)
- `REMOTECRAB_E2E_TEXT_COMMAND=<command>` — Mac applies a text transform to
  the current selection 10 s after the session is accepted (select text
  in TextEdit first)
- `REMOTECRAB_E2E_SCREEN=1` — enter the app-window mirror ~3 s after the
  session is accepted (verifies the Mac capture path from the receiver log;
  needs Screen Recording granted on the Mac)
- `REMOTECRAB_E2E_INSTALLED_APPS=1` — request the installed-app list at 8 s
  (Mac log: `published N installed apps`)
- `REMOTECRAB_E2E_DESKTOP=1` — send `showDesktop` at 20 s (Mac log:
  `showDesktop requested`, and a live mirror switches to `streaming display`)
- `REMOTECRAB_E2E_SHEET=switcher|launcher` — present that sheet at launch
  (screenshot runs)
- `REMOTECRAB_E2E_TAP=desktop` — with the switcher open, tap the Desktop card
  from code (exercises the exact button action, including `dismiss()`)
- `REMOTECRAB_E2E_NOTIFY_RELAY=1` — force the Mac relay ON, post a unique
  timestamped banner via Script Editor, wait for `relayed on attempt N`
  (retries up to 3×), and assert the iPhone's forensic log received it.
  Input-aware: if the Mac's `REMOTECRAB_DEBUG_NOTIFY=1` scan never reports
  `banners>=1` (no banner on screen), it SKIPs with a reason instead of
  reporting a false failure (lesson 85).
- `REMOTECRAB_E2E_NOTIFY_TAP=1` — after the relay, run the exact tap the
  notification tap performs: activating the front window of the notified app
  (Mac log `activated app … window=…`; iOS forensic `[notify] tap: …`).

Runbook for real-device testing:
- `./scripts/install-to-iphone.sh` builds + installs + launches
  (its `devicectl privacy grant` step is broken on current toolchains
  — grant permissions on the phone instead)
- Crash reports: `idevicecrashreport -e -k /tmp/dir` (libimobiledevice),
  then parse the `.ips` JSON (`faultingThread` + `usedImages`)
- During tests: iPhone 设置 → 自动锁定 → 永不, keep the app
  foreground — **iOS suspends the Bonjour listener on lock/background,
  which is the #1 suspect for "Connection reset by peer" every ~1-2 min**
- Mac side live logs: `log stream --predicate 'subsystem == "com.remotecrab"' --info`
  (pipe through `grep --line-buffered` or you'll see nothing)

### Why we kept raw PCM instead of Opus in V0.2
Adding Opus meant adding a 3rd-party dependency (libopus) and 4-6
hours of CMake / Swift Package plumbing — so V0.2 shipped raw PCM.
Opus finally landed (2026-09-15) without any dependency at all, via
Apple's own `AudioConverter` Opus codec (`IBOpusCodec.swift`), which
is why the "no libopus" trade-off below is now history: wire
bandwidth dropped from ~1 Mbps of base64 PCM to ~35 kbps.
**The one converter behavior that will bite you**: returning
`noErr` + zero packets from the input proc finalizes the Opus
converter PERMANENTLY (all later fills come back empty). The input
proc must return a real error code when the current fill is out of
data — see `kIBOpusInputDrained` in `IBOpusCodec.swift`.

### Why we use `@unchecked Sendable` liberally
Swift 6 strict concurrency. We're a solo developer, the threads are
controlled, and the alternative is a sea of `@MainActor` annotations
that add no real safety. If you're adding code that crosses actor
boundaries, think about it before reaching for `@unchecked Sendable`.

### What NOT to do
- **Don't** add a CloudKit / Firebase / analytics dependency. The
  product's whole pitch is "no cloud". Adding one would betray the
  user.
- **Don't** use `ObservableObject` in new code — use `@Observable`
  (Swift 5.9+) where possible, fall back to `ObservableObject` only
  for compatibility.
- **Don't** add emoji to UI strings. SF Symbols only.
- **Don't** write a `print()` and call it a day — use `os_log` with
  subsystem `com.remotecrab`.
- **Don't** commit `.env` files, signing keys, or App Store Connect
  API keys. Use `~/.config/remotecrab/`.
- **Don't add a feature just because it is easy to build.** Every feature
  grows the binary and can cost performance and review surface. A feature no
  shipping user needs belongs in `#if DEBUG` or in a `scripts/` tool, not in
  the app. (2026-09-27: the ReplayKit recorder was built for our own demo
  footage and moved to DEBUG-only; its ReplayKit-linked code and its
  "records your screen" row in Settings are both gone from release builds.)
- **Don't quote a price before checking what the category already charges**
  (2026-09-29). I proposed "Pro perpetual $99, campaign price $39" for the
  crowdfunding plan **without ever looking at a competitor's price page**.
  Camo (Reincubate, Apple Design Award finalist, 10M users) charges
  $8.99/mo · $49.99/yr · **$99.99 lifetime** — the $99 anchor I picked sat
  exactly on their lifetime price, so any backer who searched would have found
  a decade-old company with an award next to us. I had copied the *structure*
  from Seedtime ($199 = 33% off a stated $295) without checking the *band* it
  landed in. **A pricing anchor is a claim about the category, so it requires
  category research; the structure and the number are separate questions.**
  The plan, and the correction, are in `docs/campaign/MONETIZATION_PLAN.md`.

---

## Lessons 76-78 (2026-09-27: website screenshots + promo video)

76. **A readiness check that only tests "is it dark" cannot see a system
    alert.** `_shot_ok.py` accepted a frame if mean luminance < 100 and
    stddev > 5. An iOS permission alert is a *light grey card floating on the
    same near-black ground*, so it passes both tests. A whole batch of ten
    captures came back "ok" while every one was the local-network prompt. The
    fix measures the share of desaturated mid-grey and rejects > 6%: the bad
    batch reads 0.227, real UI 0.0035. **Generalisable: an automated "is this
    screenshot usable" check must test for the thing that actually makes it
    unusable, and you must look at the output yourself once** — the check
    passing was not evidence the images were good.

77. **A simulator TCC row you wrote is inert until `tccd` re-reads it
    (2026-09-27).** Three separate layers stack here:
    - `simctl privacy` cannot grant `kTCCServiceLocalNetwork` at all (it
      errors), so the seed must go straight into `TCC.db`.
    - `kTCCServiceCamera` and `kTCCServiceSpeechRecognition` are **dropped on
      every simulator reboot** (extends lesson 27), so `simctl privacy grant`
      is a silent no-op and the prompt covers the surface being captured.
    - Even with the rows present and `auth_value=2`, nothing happens:
      `tccd` caches every decision in memory, the simulator has no
      `killall` to bounce it, and `launchctl kickstart` wants
      `user/com.apple.tccd` but errors on that target from `simctl spawn`.
      **Only a boot-cycle makes `tccd` reload the file.** So
      `scripts/capture-feature-shots.sh` seeds five services and then
      shutdowns/boots the device before capturing. Without that step every
      capture is an alert, and lesson 76's check rejects all of them.

78. **The product UI is localised, so screenshots are per-locale — one set
    cannot serve both pages or both video cuts (2026-09-27).** An English
    landing page showing a Chinese screenshot reads as a different product,
    and the same applies to an English-narrated promo with Chinese screens
    inside it. `scripts/capture-feature-shots.sh <sim> <dd> <out> -en`
    takes the locale as a 4th arg and suffixes every filename; the site's
    feature pages pick `<slug>-en.jpg` on the English path and `<slug>.jpg`
    on the Chinese one, falling back across locales before the typographic
    panel. Corollary: the site had **no page at all** for the context-mode
    registry (`ContextProfiles.swift` — 18 suites, 49 bundle IDs), which is
    one of the stronger differentiators; it is now `/remotecrab/suites/`,
    with the suite titles taken from the app's own `IBLocale` strings so the
    site and the product say the same thing.

## Off-repo tooling notes (2026-09-27)

Two workflows that live outside this repo but are easy to lose:

- **Promo video: `~/Videos/RemoteCrab/promote-75s/`** (HyperFrames, 0.8.78).
  1920×1080, narration-only (no music bed: local generation has no music
  provider, and a synthetic pad cheapened a piece whose register is a
  utility that quietly works). TTS is the offline Kokoro voice
  `am_michael` and **needs `kokoro-onnx` + `soundfile`** in a venv, pointed
  at by `HYPERFRAMES_PYTHON`. Two traps that cost real time: the skill
  directory is a **symlink** (`~/.config/opencode/skills` →
  `~/.claude/skills`), so `resolve(argv)` and `import.meta.url` never match
  and `captions.mjs` **silently does nothing** (exit 0, no output, no file) —
  always invoke those scripts by their real path. And the stock caption
  grouping splits on every clause-length pause, which this narration has by
  design, so it produced 2-word flashes; `captions-tuned.mjs` (a project-local
  copy, so the shared skill stays clean) raises `SILENCE_GAP` to 0.85 s and
  the word cap to 6-8, giving 42 readable cues.
- **YouTube via browser: the Kimi WebBridge daemon** on
  `http://127.0.0.1:10086` drives the logged-in Studio session (no OAuth
  credential needed, and none should be handled here). **The title and
  description fields live in a shadow root** — `evaluate` cannot see them at
  all (walking the whole light DOM finds zero `contenteditable`), `fill` with
  a CSS selector reports "not a native input", and
  `execCommand('insertText')` returns `false` because the field wants
  trusted input. **The only working route is `fill` with an `@e` ref from
  `snapshot`**, and those refs only appear once the upload has finished and
  the dialog has settled — snapshotting earlier returns zero of them. Always
  check the `fill` return value before doing the next step: that unchecked
  failure is how a whole 1.4 KB description ended up inside a title field.

### Browser automation against a hostile form (2026-09-29)

Filling Kickstarter's project builder cost ~40 tool calls. The rules that would
have saved most of them:

- **A rich-text editor is not a form field. `fill` and `execCommand` mutate the
  DOM without touching the editor's model, so the change vanishes on reload.**
  Kickstarter's story is CKEditor; the only thing that persisted was
  `inst.getData()` → string edit → `inst.setData(fixed)` (the instance hangs off
  `window.ckeditorInstance`, or `el.ckeditorInstance`). `Input.insertText` via
  CDP *does* work for bulk text entry (it is trusted input), and
  `Input.dispatchKeyEvent` is needed for Backspace. But after the model and the
  DOM have diverged once, no amount of synthetic editing recovers — I left a
  `TEST LINE` in the published Story and had to fix it with `setData`.
- **`upload` sets a file on an `<input type=file>`; it does not click the
  button.** For a plain upload (an image field) that is enough. For anything
  that then runs an XHR with a progress bar, it is not: the file lands, the
  request never goes out. Kickstarter's video slots took `cdp
  DOM.setFileInputFiles` (which *did* fire the upload) and still showed
  "upload failed" with **zero upload requests in the network log** — the tell
  that the failure is upstream of the file, not the file. Two videos therefore
  have to be dragged in by hand.
- **Kickstarter reward tiers silently refuse to save.** The `Digital reward
  (no shipping)` radio is mandatory and the Save button looks perfectly enabled
  without it. Filling title/description/amount/limit and clicking Save produced
  no error and no row on reload. Native `Input.dispatchMouseEvent` at the
  button's coordinates did not help either. Budgeted as manual.
- **Cloudflare rate-limits a scripted session hard.** Several long
  navigations returned a `正在进行安全验证` interstitial; a bare
  `cdp Page.enable` cleared a stuck `beforeunload` dialog, and waiting 40–90 s
  cleared the challenge. If a run of commands starts failing at once, check for
  the challenge before assuming the tool is broken.
- **Always re-read state after a save, from a fresh page load.** Twice a
  change appeared to work in the DOM and was gone after reload — that is how
  the "TEST LINE" survived two rounds of "fixes".

---

## Reference reading (for any agent picking this up)

1. **`README.md`** — the pitch and the high-level architecture diagram
2. **`RUN.md`** — step-by-step build + run on real hardware
3. **`RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBWire.swift`** —
   the wire protocol is the most important file in the project;
   read this first
4. **`RemoteCrabCore/Tests/RemoteCrabCoreTests/EventPipelineEndToEndTests.swift`** — shows
   how every feature is verified end-to-end
5. **`scripts/release-ios.sh`** — how a release gets built and uploaded
6. **`screenshots/`** — what every screen actually looks like

If you're new, also read:
- **`RemoteCrabReceiver/MenuBarMenu.swift`** — the most polished piece of UI
- **`RemoteCrabCapture/OnboardingFlow.swift`** — how the user gets into the app

---

_Last updated: 2026-10-04 (**iOS 侧的 Windows 兼容审计 —— ⌘ 只到了键盘界面，同一句话还有三份独立实现；顺带查出手机上还连着另一台电脑，所以 22 条 e2e 全红**). 用户报「连接 Windows 后还是显示 Command」。**根因不是一处漏改，是同一个概念在这个产品里有四份独立代码**。① **修饰键行有两个来源**：`KeyboardScreen` 自己画（对的），而**触控板 + 投屏**共用 `IBShortcutBar`，它调 `IBModifierBar` **没传 `platform`** → 走缺省 `.mac`。所以同一个 app 里**换个界面键就变了**，而且两个错的正好是最常用的两个。**文档点名了 `KeyboardScreen.swift:345`，实施者就只改了那一处 —— 点名一个文件等于替其他调用点背书**（lessons 118/119）。修法不是「记得传」而是**去掉默认值**：四处 `platform` 全部必填，编译器强制表态。② **手势说明页**写死「Lock ⌃⌥⌘⇧」「Mission Control」「the Mac」，而它是**会话中被阅读**的 —— 一份描述了错误机器的说明比短说明更糟，读者无法判断哪几行可信；顺带发现 `Coach.pinchZoom` **在 catalog 里根本没有条目**，中文界面显示英文原文。③ **VoiceOver 朗读标签**：Windows 和弦键复用了 Mac 的 label，于是 `Ctrl+Z` 被念作「Mission Control」、`Ctrl+A` 被念作「App Exposé」——**键帽是对的，所以没有任何检查能发现**，只有读屏用户听得到；抽成 `ShortcutChords` **数据**（键帽+朗读配成一对）后视图再没有「拿错标签」可言，顺带发现 `extra` 是**完整掩码**不是增量。④ **context chip 写死英文 `"Computer"`**，中文手机上和「按住说话」并排，catalog 里早就有 `Computer`→电脑，是调用点用字面量所以查表从没发生 —— **只能靠看截图发现**（lesson 76）。**情景模式三个按钮在说谎**：`windowsSystemActions` 是**独立数组**，`ContextWindowsSuiteTests` 里所有 `for profile in ContextProfiles.all` 循环**静默跳过了它**，它一个断言都没有而 `systemActions(for:)` 无条件渲染 —— 「显示桌面」发的是 **⊞⌥Escape**（keycode 53 是 Escape，`keymap.rs:105`→`vk::ESCAPE`）、「浏览器」图标是 `safari.fill`（=用户说的「Windows 没有 Safari」）、`.voiceHero` 待在宫格里让「Talk to Computer」渲染**两次**。**去掉宫格 hero 会让 13 个套件失去语音键**（console 没有 `windowsActions`），所以 `voiceHero(for:)` 必须**回退到 console 的 hero**，两条一起改才对 —— 这是最容易漏的一半。**Mac 侧零影响的证明不是测试绿而是渲染对比**：真组件塞进 `NSWindow` 截图，Mac 那张与修改前逐格相同；⚠️ `ImageRenderer` **不给 `ScrollView` 布局**会静默不画内容，必须 `NSHostingView`+`cacheDisplay`。**每个断言都反向验过**，而这一步抓到我自己两处问题：两条 pruning 测试**按最旧→最新排 fixture**，恰好和「最后写入胜出」这个 bug 一致 → **空过**（真实 `seen` 是最新在前，`noteSeen` 插 index 0，那个顺序下 bug 保留最旧的）；`daysAgo: 0` **每项各调一次 `Date()`** 所以「并列」差了几微秒，并列必须用**共享时间戳**构造。**用户随后报「设备列表出现多个 Windows 设备」，和 e2e 失败是同一件事**：`seen` 只按 `id` 去重，所以「按 id 删」永远删不掉换过身份的机器（Windows 接收端过去每装一次换一个 `pc_id`），`seenLimit = 20` 是唯一上限。`84f30fa` 加**同名合并 + 30 天过期**（纯函数 `pruned`），真机验证 **5 行 → 3 行、同名归零**，但**根因在接收端**：`c9c0463`（`MachineGuid`）已进 main 而**用户 Windows 机器上跑的还是旧版**。**e2e 22 条全红的真因是手机正被另一台电脑占着**（`busy owner=EDWIN`，**正确行为**），一锤定音的是读手机持久化的 `seenComputers`（`…98db…` 两条 **node 相同、id 不同** = 同一台机器两个身份）而不是继续从日志推断；且偏好锁 armed 的 10 分钟 TTL **按 id 判断**，我第一次重跑早了 46 秒（`14:51:52` 起跑 / TTL 到 `14:52:38`），结果一模一样 —— **时序断言要先算好时间**（lessons 120-122）。6 个提交全部推上 `main`，453 测试 + 两 target + Windows 套件全绿；`/Applications/RemoteCrab.app` 仍是 Developer ID build 11，CDHash `d9dacda991ffaa8a1a32aff7abacf9b38b945549` 未变；`stash@{0}` 是 Windows session 的**没碰**；合并前求交集确认与远端 3 个 Windows 提交**零文件重叠**。**🔒 待验**：`docs/PROMPT-WINDOWS-SESSION.md` 末尾的清单（修饰键三界面不串 / ⊞ 单独按 / 系统区四按钮 / 语音只一次 / 同名一行 / **重装后不需重新配对**）。Lessons 118-122._
. 用户要求「把这些东西做了，特别是 Mac 端的，不要影响 Mac 本身，同时对齐 Windows 又保留 Windows 自身特色」。11 个提交，`082828d`，真机 e2e **25/25**（iPhone 14 / iOS 26.6.2），427 Core + 369 Windows 测试全绿，两个 app target + 交叉编译 + 双目标 clippy 全绿。**Mac 侧零影响——原有 25 个 `ContextProfilesTests` 一字未改。** 起点不是交接文档说的「面板是空的」：`ContextSheetView.swift:42` 的系统区**无条件渲染**，所以每个 Windows 用户当时就能看到 8 个按钮，其中**4 个是坏的**——亮度直接 `return false`（死按钮）、**锁屏 ⌘Q 塌缩成 `Ctrl+Q` 会退出用户正在用的软件**、「Safari」打开 **Bing**（标签在数据里、参数在 view 里）。修法是移除亮度、锁屏改 **⊞L**、标签与参数绑成 `.systemArg`。根因是 `keymap.rs:147` 的 `COMMAND|CONTROL` 塌缩，它还让 agent 套件的「中断 ⌃C」和「复制 ⌘C」变成同一个按键——而 Windows Terminal 里 Ctrl+C 是中断。**又纠正了交接文档**：⊞「不用动协议」只对单独点 ⊞ 成立，掩码只有 1/2/4/8 而 COMMAND 塌缩成 Ctrl，所以 ⊞E/⊞R/⊞D/⊞L **一个都发不出去** → 新增 `meta = 16`。⊞ 键行**顶替** ⌘ 而非并存，因为 `windowsLabel` 把 ⌃ 和 ⌘ 都渲染成 `"Ctrl"`（本来就有两个同名按钮）。**关键设计**：每平台独立动作集且 Windows **绝不回退**到 Mac 动作（`windowsActions ?? []`，不是 `?? actions`）——回退产生的是*错*按钮而不是*没有*按钮；`testNoTwoWindowsActionsCollapseToTheSameKeystroke` 让这类塌缩不可能再进。**主动砍掉三处**并写了断言让省略读起来像决定：agent 的复制/粘贴（组合键无法确认）、**PowerPoint**（F5 需扩展功能键，`testPowerPointIsNotYetMapped` 明确断言它*没有*映射）、`AppInfo.appRef`（`windowsProcessNames` 按进程名解决同一问题，不用改协议）。其余 13 个套件没有可靠依据，**匹配不上落到系统区是诚实且能用的行为**。插件机制只做「格式 + 本地装载」零网络：`schemaVersion` + `source` + 优先级 `userFile > remote > builtin`（同 id 覆盖——旧的先匹配先赢让「装了插件等于没装」），手写 `init(from:)` + 旧格式迁移测试（否则合成 Codable 遇到非可选 Int 直接抛错，而本项目的 loader 吞掉解码错误 = 静默清空用户数据，规则 2）。**这一轮最有价值的经验在测试里**：那条断言在**正确**的 run 上变红，它描述的是**修复**而不是不变量，我从日志几何推断原因**错了两次**（BSD `sed` 没有 `\?` 会静默匹配不到任何东西、看起来像「没回归」；「和点击同一目标」≠「光标已在目标内」因为前一次滚动可能把光标留在**另一块屏**上）——最终让 `CGEventInjector` 自己说出原因。断言单独成 `scripts/e2e-cursor-guard.sh` 就是为了能对着已知日志跑**两个方向**（真实形状通过 + 注入一次偷走仍然 FAIL）；而且**要求正面证据（「看到一次没动光标」）是不可满足的**——滚动脚本和目标切换脚本赛跑，那种情况可能根本不发生，防空过要靠要求**前置条件**而非结果。**注释与代码分叉时注释是对的**：那段注释早就写对了意图（"rather than a global count"），代码做的是全局计数。**push 被拒三次**，全是 Windows session 先推，每次都先 `git diff --name-only A...B | sort` 求交集确认零重叠再合、合完立刻重跑全套。**🔒 剩下**：§5.6 那 9 条只能在 Windows 真机验；**分屏仍卡在用户**（需要具体场景）；Windows 亮度需 WMI 且只对内置笔记本屏有效。现场已还原：`/Applications/RemoteCrab.app` = Developer ID 发布版（9月30日时间戳、签名有效、无残留备份）。Lessons 115-117._
_Last updated: 2026-10-02 (**投屏的两个手势 bug 全部定位并修复 —— 全部先量后改；六个根因里有两个是我自己假设出来的，三个被实测推翻**). 用户报「点不准」+「双指上下滚动失灵，被感应成拖动镜像」。**先测量，两个假设当场死掉**：`SCWindow.frame` vs `CGWindowList` bounds 在本机 `cgOriginDelta=0.00`（**没有标题栏偏移**，抓图像素盒和映射盒是同一个盒子），而我更倾向的 ZStack 居中偏移也被一个无头 SwiftUI host 推翻（overlay 帧恒为 `0,0 393×852`，不随 zoom 漂移）。剩下的全在手势变换本身。**根因**：① pinch 调的是无锚点重载 —— `setZoom(_:anchor:)` 就写在旁边、有文档、有单测（`testAnchoredZoomKeepsTheTouchedPointFixed`），**但调用点从来没传 anchor**；实测把内容 u=0.153/v=0.117 处捏到 2×，那个点位移 **168 pt**、跑到 x=−76 屏幕外 —— 这就是「放大后点不准」。② `zoom > 1.05` 后双指被永久 latch 成 `.pan`，远端永远无法滚动（**被单测当设计意图断言过**，所以不是回归而是当初的选择）。③ pinch 与双指 pan 同时运行，且首次 pinch 时 latch 的还是 `.scroll`，所以**放大时顺手滚了远端**。④ 单指拖拽阈值是固定 10 **视图**点，4× 下只剩 2.5 内容点，一偏就变拖拽（→ `dragSlop`，1× 保持 10 不变）。⑤ 任何 `screenInfo` 都 `reset:true` 清掉 zoom/pan —— 而 Mac 每秒因窗口移动重发一次（→ `viewportKey`）。⑥ Mac 每次滚动前把光标瞬移到手指处，这正是「光标偏离距离」且距离随机的来源。**修法**：`ScreenDragAxis.decide()` 走 libinput/Chrome 的轴锁（累计 12 pt 起判、主轴需 ≥1.4×、**近对角一律判纵向**），锁定轴滚远端、另一轴平移；pinch 锚定两指中点并让位给 pinch（**让位时也必须消费 translation**，否则 pinch 的质心漂移会在结束时一次性灌进轴锁 —— 这是我自己引入又自查抓到的 bug）；滚动不再抢光标（只在会话首滚或光标已在窗口外时放一次，并加了跨会话 `resetMirrorCursor`，否则重连后首次滚动会落到别的 app —— 有单测跨会话边界，lesson 8）。**Mac 侧真机日志逐帧证实**：scroll→PLACED、click、scroll→left alone（★修复）、scroll→PLACED（目标已切到虚拟屏，换窗口本就该重放）。**但 e2e 一轮里制造了五种错误判决**（lesson 111）：锁屏的 launch 错误被吞成 24 个假失败；追加写的 `forensic.log` 让三小时前的旧 marker 报成**假通过**；staged 二进制早于修复（`strings` 探针也错 —— Debug 的真代码在 `.debug.dylib`，主二进制仅 92 KB）；测「首次放置」的那一帧被跨 actor 时序差静默丢弃，于是断言**空过**；以及跨目标切换计数，凭空造出一个「回归」。**最重要的一条**：断言在自己要测的分支没执行时还能通过，比没有断言更糟 —— 要**逆向验证**（我用手工构造的旧行为日志确认它 FAIL）。**gesture 设计上我错了**：三指平移用户评价「姿势别扭，手挡住画面」—— **三指是触控板手势**（手不在内容上才舒服），搬到触摸屏掌根正好压住要看的区域，无解；而且纵向平移在常用 2× 下**可平移量是 0**，本来就被已有的「双指双击在那个点缩放」覆盖（lesson 110，方案已分析待用户定夺）。369 Core + 25/25 真机 e2e（iPhone 14 / iOS 26.6.2）+ Windows 套件全绿。**随后补完教学（`9445b0f`）**：手势参考从「触控板指南」升级为一份按界面分区的完整滚动页 —— 投屏分区新增 8 条，两个界面「三指」语义不同的问题随分区消失；投屏一次性提示回归本职（3 条 + 「查看全部手势」按钮），因为它同时是那 5 条手势**唯一**的文案，「只弹一次」等于「之后永远读不到」；投屏用**自己的**分区标题，因为把「双指左右滑移动画面」放在「滚动与缩放」下会**让按标题找平移的人永远找不到它**，而投屏没有四指手势却借用了「三指与四指」（lesson 113）。顺手改掉两处**不实**文案：触控板 pinch 实际发的是 **⌘+滚动**（`CGEventInjector.swift:47`），原「捏合缩放」会让用户期待 iPad 式放大；投屏的双击/三击点击代码里真实存在却从未记录。`proxy.scrollTo` + 魔法睡眠换成了 `defaultScrollAnchor`（lesson 114）。**现场已复原**：`/Applications/RemoteCrab.app` 换回 Developer ID 发布版（build 11，签名有效，`accessibility trusted: true` / `extension registration is up to date`）。Lessons 108-114._
_Last updated: 2026-10-01 (**the app launcher: a 500 ms timer was deciding whether the computer's app list was empty — and behind it a 14.25 MB frame**. User report: 第一次打开「打开 App」会先闪「暂时没有应用」，应该显示 loading；打开一个 App 之后也不会马上出现在切换列表里。Three real defects, and the first one was hiding the other two. (1) `InstalledAppsView` waited 500 ms on a `Task.sleep` and then called the list empty — but the round trip belongs to the *other machine*, and the Mac needs seconds, so it said "no apps" and then popped the grid in underneath. Only the `installedApps` (0x21) frame may end a wait; `IBListRequestGate` is four phases because the timeout was merging *still working* / *genuinely zero apps* / *nobody answered*, and 0x21 is only ever sent in reply to 0x20, so silence is a dead link or an older receiver, not an empty list. (2) The real cost was `InstalledAppsCatalog`: `NSImage.lockFocus` into a "96 pt" box, which the backing scale turned into **192×192**, and a 192×192 *lossless* PNG of a macOS icon is ~94 KB — a real `/Applications` (113 apps) is one **14.25 MB** frame. JPEG is 12× smaller and **was implemented, shipped to the phone and reverted**: JPEG has no alpha, a macOS icon is a squircle with transparent corners, so the encoder fills them with opaque white and the phone drew a white square behind every tile. Won on the pixel axis instead — explicit 128 px rep, 2.40 MB, pixel-exact for a 64 pt tile at 2×. (3) The switcher rendered `macWindows` while the Mac only republished the window list when an app *quit*, so a launch — which sends `appList`, a frame the picker never renders — could not add a card. Launch plus the activation that follows is one change, so `IBChangeCoalescer` collapses them into one rebuild once the burst goes quiet; the "picker is probably open" gate was 30 s, shorter than browsing the launcher takes. Windows had the same gap and gets a condition-polled refresh off the select loop. **Two of these were only findable on the device**: the sheet is reachable *before* the Mac answers, and `.task` fires once, so it sat on "not connected" for the whole 8 s handshake (fixed by re-requesting on `connectionState → .connected`); and the correct white-square regression came from looking at the phone, not from reasoning. Measured on iPhone 14 / iOS 26 with Mac build 11: `answered: 113 apps, 2458KB, after 1246ms`, `installedApps frame: 2458KB in 618ms`, and the window list going 6 → 7 with an app launched while the picker was open. **Install the receiver properly** — `/tmp` is not a shortcut: `ensureRegistered()` reads "the host app moved" from any other path and submits a **deactivation request for the user's approved virtual camera**, the Screen Recording grant is keyed to the signing identity so the scratch build reports "not granted" while the installed one is still authorised, and two receivers fight over the phone (the binary is `RemoteCrab`, so `pgrep -f RemoteCrabReceiver` finds nothing). `release-mac.sh` already encodes the fix: archive automatically, swap in the Developer ID profile that carries the System Extension Install entitlement, re-sign the nested sysex + Sparkle + its XPC services, then the app — and then `accessibility trusted: true` / `extension registration is up to date` / `canCapture=true` all hold. **And a parallel Windows session ran `git stash` + `git reset`, emptying the tree mid-task** (lesson 92, new variant): tracked edits survived only because of that stash, while my **untracked new files were the sole survivors — and a commit landed that referenced them by name, so HEAD did not compile for anyone cloning it.** Recovery: tag the stash before anything else, restore file by file with `git checkout stash@{0} -- <path>` (never `pop` — that stash was mixed with their work), and verify HEAD with `git clone --no-local . /tmp/x && swift build`, because a green working tree says nothing about the commit. Finally: **binary hashes cannot tell you whether an installed build is current** — two Release builds of identical source differ (`30391a15…` vs `6bec6b93…`) because Swift embeds a fresh UUID; compare the *string literals* a change introduced instead. 9533be5, 359 tests, both app targets, Windows suite. Lessons 92 and 94.)_

_Previous: 2026-09-29, later (**a real crash in the build currently under App Review — tapping a relayed notification killed the app** — user report 收到推送没事,**点一下整个 app 崩**). Root-caused on a real iPhone 14 / iOS 26.6.2 across **four** reproductions with the same signature: `EXC_CRASH / SIGABRT` from an ObjC `NSInternalInconsistencyException` ("`_userInfoForFileAndLine`") on a **cooperative-pool** queue, not the main thread. Two traps stacked: `UNUserNotificationCenter` delivers delegate callbacks **off the main thread** (measured — `willPresent` runs with `pthread_main_np() == 0`), *and* an `async` delegate method is bridged by the Swift runtime through `_runTaskForBridgedAsyncMethod`, which also **finishes the bridge on that cooperative thread**. The first "fix" (hopping the read into `MainActor.run`) made the body run on the main thread and **still aborted** — only per-line instrumentation revealed the abort came *after* the last line of the body. Fix: both delegate methods use the **completion-handler (non-`async`) form** with a `Task { @MainActor }` hop (lesson 86). The follow-up "点了之后打开 app 是黑屏" was a **symptom of the abort**, not a second bug. Verified on device: `[notify] banner tapped (delegate path)` → `tap: activating` → no abort, plus 270 tests and both app targets. **This bug is in iOS build 2026092404, the build sitting in `WAITING_FOR_REVIEW`**, so shipping it means either withdrawing the submission (a **manual browser** step — the ASC API has no `DELETE` on `reviewSubmissions`) or waiting for a rejection. Two process lessons came out of it: `idevicesyslog` is useless on this device (dies in seconds, never saw a crash) while `devicectl device process launch --console` carries both the exception text and the app's own `Forensic.log` in one stream; and lesson 82's tap e2e was **green while the app was aborting** — it asserted the log line and the Mac-side `activated app`, both printed, *then* the process died, so an e2e must also assert the process is alive (and that the delegate path ran at all, since the in-app inbox emits the same `tap:` line — hence the new marker). Previous entry below._

_Previous: 2026-09-29 (**iOS 1.0 submitted for review with build 2026092404 + tap-to-activate + the phantom-loopback fix shipped as Mac build 8 + 32 fresh store screenshots** — the session's through-line was *finishing verification and shipping*, and it found three real App bugs. (1) **The context-mode action labels never localized** — `Text(LocalizedStringKey(label))` resolves against `Bundle.main` while the catalog lives in the **Core package**, so all 79 labels rendered English in the Chinese UI with the translations sitting right there; fixed with `IBLocale.string(_:)` at all 4 render sites (lesson 84). It is the only iOS-side change and it is **inside the build now under review** (fix committed 17:34, package archived 19:21), so **no re-submission is needed**. (2) **A phantom loopback connection** — my own screenshot debris left two booted simulators listening on `127.0.0.1:8765`; the receiver's direct-IP fallback attached to one, persisted `remotecrab.lastPhoneIP = 127.0.0.1`, and then re-persisted it on every connect, so the user's "时灵时不灵" was a self-reinforcing ghost dial. `DirectDialAddress.isUsable` now rejects loopback / link-local / `%en0` / non-dotted-quads at **both** the write and read sites (lesson 83). (3) The relay crash from the previous session (lesson 80). Two new e2e hooks (`REMOTECRAB_E2E_NOTIFY_RELAY` / `_NOTIFY_TAP`) make the relay chain and the tap assertion part of the device suite, and the suite's three flakiness sources — a fixed sleep, two racing hooks, and an unescaped BRE bracket class — were root-caused and fixed (lesson 85): the suite is **24 deterministic assertions green**, and the relay+tap pair is green whenever macOS actually presents a banner and honestly SKIPs when it doesn't. **Mac build 8** (`RemoteCrab-1.0.7.zip`, `sparkle:version 8`) is notarized, uploaded and running. **iOS 1.0 is `WAITING_FOR_REVIEW` on build 2026092404** with 32 new screenshots (8 story beats × 2 device classes × 2 locales), a full metadata rewrite, and a complete removal of the word "Mac" from every review-facing field (5.2.5). Note the release asymmetry this session exploited: **Mac needs no review** (Developer ID + Sparkle, 5 builds in a day), **iOS does** (one review cycle) — so Mac-side fixes should be preferred, and a swap on an already-submitted version costs a **manual browser withdrawal** because the ASC API has no `DELETE` on `reviewSubmissions`. Still open: real-device screenshots for the mirror/extended-display surfaces (no Mac in the simulator), the denylist filter on real hardware, and the Sparkle idle gate under a live session. 270 tests + both apps. Lessons 83-85.)_

_Previous: 2026-09-28 (**notification relay verified end-to-end on a real
iPhone + iOS device builds fixed + Mac build 6** — the relay chain Mac banner →
AX scan → denylist → `0x22` → iPhone inbox → system banner is **verified 3/3 on
real hardware** (Mac `REMOTECRAB_DEBUG_NOTIFY=1` scan lines + `relaying
notification`; iPhone `[notify] relayed notification received` + `system banner
posted`). Three device-day bugfixes made that possible: the relay **crashed the
whole receiver** ~0.5 s after a session was accepted (a `@MainActor` class's
`DispatchSourceTimer` closure inherited actor isolation — 4th recurrence of the
lessons 2/7/53 trap, lesson 80), the iOS device build was blocked by a wrong
`DEVELOPMENT_TEAM` copied from a certificate's CN instead of its OU (lesson 80),
and `scripts/e2e-device.sh` was silently replacing the user's Developer ID
install with a dev-signed build (dropping every TCC grant — lesson 80).
Real-device e2e went 5/23 → **23/23**. The relay's scan decisions were then
moved into a pure, tested layer (`NotificationBannerParsing`, 243 tests) fixing
three silent-failure modes, and both halves gained marker-only diagnostics
(`REMOTECRAB_DEBUG_NOTIFY=1` on the Mac; `[notify]` in the iOS forensic log) so
the feature can never again fail invisibly. Mac **build 6**
(`RemoteCrab-1.0.5.zip`, `sparkle:version 6`) is notarized, uploaded and
installed. TCC grants survive same-identity Sparkle upgrades; only a
signing-identity change (or the e2e clobber, now fixed) drops them. 243 tests +
both apps. Lessons 79-81.)_

_Previous: 2026-09-27 (**website screenshots + promo video** — ten per-feature
landing pages under `/remotecrab/features/`, a new `/remotecrab/suites/` page for the
18-suite / 49-app context-mode registry, and real captured screenshots in both locales.
`scripts/capture-feature-shots.sh` drives the simulator through the E2E hooks; lessons
76-78 are the three things that made the first runs produce nothing usable. A 75s and a
57s promo cut were rendered with HyperFrames and published to YouTube (three videos, all
public). Lessons 74-75 stand: the notarized Sparkle update path is still unverified.)

_Previous: 2026-09-27 (later session — **mirror follow + desktop semantics + picker UX**. Three device bugs, each root-caused first: (a) switching to **Finder** froze the mirror because `resolveKeepingPrevious` kept the old window when the frontmost app had none — Finder-on-the-desktop has none; the user's narrowing ("只有切 Finder 不行") *was* the root cause, and `desktopIsShowing` (→ whole-display capture) fixes it (lesson 73); (b) `showDesktop` skipped the active app (`!$0.isActive`) and raised a Finder window — now it hides **every** regular app (Win+D semantics); (c) the mirror's window picker was an unreadable "app name + count + chevron" — now a 40 pt mode icon (auto/pinned) + a menu that states the mode, with a coach-mark line and zh-Hans. Also this session: **hold-to-talk is stable across many uses** — the 300 ms delayed teardown was *skipped* when a press came within the delay, leaking the recognizer + mic tap until `start()` failed; the fix is serialization (`await teardownTask`, lesson 72). Tests 206 + both apps.)_

_Previous: 2026-09-27 (**immersive landscape mirror**: in a landscape mirror the chrome collapses by default (top bar, PTT row, the mirror's own handle/shortcut bar, and the content insets drop to zero) so the stream owns the screen, with a top-centre grip to summon it; **root-caused a run of device bugs** — the extended-display toggle "did nothing" because `perform(initWithDescriptor:)` took `takeUnretainedValue()` and leaked the `CGVirtualDisplay` (a second `init` then fails; see lesson 71); hold-to-talk "flashed / died on the second use" was a start/fail retry loop plus an un-generation-guarded delayed stop; two-finger scroll "turned into moving the screen" was the new viewport insets making the fitted content pannable, fixed by latching scroll-vs-pan per gesture; and an unsupported `sessionPreset` could raise an uncatchable exception (now guarded). **Windows parity audit** fixed pinch (was a bare wheel, now Ctrl+wheel), multi-click (clickCount was ignored), three/finger swipes (were a no-op; now Task View / virtual desktops), the audio 48 kHz preference, and added tray Show/Hide Preview + a real tray icon; the full receiver handoff + virtual camera/mic plan lives in `docs/WINDOWS_HANDOFF.md`. Device e2e 23/23; `RemoteCrabCore` 203 + both apps; `windows` 127 + host/windows-gnu clippy clean.)_

_Previous: 2026-09-27 (**Extended Display** — the iPhone as a real second monitor: a macOS virtual display via the private `CGVirtualDisplay` classes (no driver/entitlement; spike + device e2e verified — `virtual display created` + `streaming extended display`, 21/21) streamed through the existing mirror pipeline; voice no longer drops the last 1-2 chars (both engines keep feeding ~300 ms after release + a never-shrink final); the mirror stays on screen while hold-to-talk yields it; Windows audit fixes + bilingual tray/console + start-at-login. Lessons 69-70.)_

_Previous: 2026-09-27 (UI/design pass + three device-reported bugs. The switcher's Desktop entry is now a pinned compact row card and "Open App…" a bottom accent action, the launcher is a Launchpad/Dock-style grid of real 96 px icons (new `IBInstalledApp.iconPNG` on both sides), and the mirror's secondary chrome collapses behind a handle; 19 catalog keys got zh-Hans. Then: **voice start crashed** (SIGABRT from `AVAudioEngine.prepare()` → `AVAudioEngineGraph::Initialize`, uncatchable — fixed with a fresh engine per session, no `prepare()`, and `.record` + `[]` instead of `.mixWithOthers`); **dictation dropped chars in the mirror** (hold-to-talk now yields the screen stream, keeping the last frame); and **"Show Desktop" didn't show the desktop** (the streamer now falls back to whole-display capture, and `showDesktop` calls `captureDesktop()`). Windows audit fixed `tap_win_d`'s release order, the dead `com.apple.Safari` launch action, and clipboard contention; the tray/console are now bilingual (`rc-app/i18n.rs`). Device e2e 19/19; `RemoteCrabCore` 198 + both apps; `windows` 123 + host/windows clippy clean. Lessons 67-69.)_

_Previous: 2026-09-26 (recording e2e fixed — the last red assertion was a Mac `H264Decoder` deadlock, not the recorder: the iPhone stream's first wire frame is a non-IDR P-slice, VideoToolbox answered -12909, and `handleMalfunction` called `VTDecompressionSessionInvalidate` **from inside the decode callback**, which deadlocks — so the session was never rebuilt and the decoder emitted zero frames, leaving `StreamRecorder`'s writer nil. Fixed with the pure, tested `H264FrameGate` (VCL-only + drop P-slices until the first keyframe), a queue-dispatched rebuild that never runs in the callback, SPS/PPS change-detection, and recorder logging that only reports "recording saved" on a completed writer. Also this session: **Windows parity round 2** — the iPhone's window-based app switcher now works against Windows (`windowList` enumerate + JPEG thumbnails + activate/quit by window title), PC→iPhone clipboard, recording (`rc-record`: H.264 passthrough MP4 + PCM WAV), the **app-window mirror** (`rc-protocol` screen structs + `rc-net` dispatch + `rc-mirror` capture/encode + `rc-input` absolute input; the iOS mirror button is un-hidden for Windows), and the iOS mirror button hidden for Windows. Introduced the `x86_64-pc-windows-gnu` cross-compile check that actually type-checks `#[cfg(windows)]` code. **Switcher quick destinations** (both receivers): a **Desktop** button (`IBSystemCommand.showDesktop` 0x19 — Mac hides every other regular app then activates Finder, Windows sends Win+D) and **Open app…**, a searchable installed-app launcher over a new frame pair (`installedAppsRequest` 0x20 / `installedApps` 0x21; `InstalledApp.id` is exactly `launchApp`'s argument — bundle id on the Mac via `InstalledAppsCatalog`, Start Menu `.lnk` path on Windows). **Tray + real app icons**: `rc-app`'s tray mirrors the Mac menu-bar popover's structure/wording via a dedicated thread whose menu routes through a channel into the app's `select!` loop (`--no-tray` skips it), and `build_app_list` now     fills `icon_png` with a cached 48 px `SHGetFileInfoW`→`DrawIconEx`→PNG render (pure `rc-os::icon`). **UI/design pass** (2026-09-26): the switcher's Desktop entry is a pinned compact row card (brand-gradient mini-desktop thumbnail) and "Open App…" is a pinned bottom accent action; the launcher is a Launchpad/Dock-style sheet (adaptive grid of 64 px `iconPNG` icons, native `.searchable`, pinned-first); the mirror's secondary chrome (window chip + fit/fill + zoom) collapses behind a handle so the stream gets the whole screen; 19 new catalog keys got zh-Hans (they were in no catalog and rendered English in Chinese), and the `"Open App"/"Open App…"` GeneratedStringSymbols collision was resolved by naming the launcher title "Applications". AppIconTile + GlassPressButtonStyle lifted to `RemoteCrabCapture/SharedUI.swift`. `RemoteCrabCore` 198 tests + both apps build; `windows` 122 tests + host/windows clippy clean; device e2e 16/16 (replay pending — the iPhone left the Mac mid-session). Lessons 67-68.)_

_Previous: 2026-09-25 (Windows port merged to `main`: `origin/feat/windows-receiver` brought a standalone Rust workspace `windows/` — rc-protocol / rc-discovery / rc-net / rc-render (OpenH264) / rc-audio (pure-Rust Opus) / rc-input (SendInput) / rc-os — plus iOS platform awareness (`IBClientHello.platform`, `SeenComputer`, Ctrl/Alt modifier labels, "Choose a computer"). Merge was hand-resolved (CaptureEngine kept both sides; TouchpadScreen kept the shared `IBShortcutBar`). Fixed over the branch: `connectedPlatform` now comes from the live `clientHello.platform` (not a seen-list lookup that silently fell back to macOS); Windows keyboard chords rewritten to respect the receiver's modifier policy (both ⌘ and ⌃ bits collapse to Ctrl — Alt+Tab / Ctrl+W / Ctrl+Z / Ctrl+A / Alt+F4 / Ctrl+Tab); `MacPairingStore.paired` restored. Phone-screen-mirror compatibility: `rc-protocol` now recognises kinds 0x1A–0x1F and `rc-net` drops them (the unknown-byte fallback was `Kind::Video`, so a mirror NAL could corrupt the camera preview). Verified: `./scripts/test.sh` 193 tests + both apps build; `windows` `cargo test` 94 + `cargo clippy -D warnings` clean. Pushed `origin/main`. **Not done**: device e2e on the merged build, and the Windows-side real-machine self-test. Lessons 64-66.)_

_Previous: 2026-09-24 (later session — iOS 26 `SpeechAnalyzer` compatibility layer: a `VoiceEngine` protocol with `AnalyzerVoiceEngine` (used only when the model is already installed, never downloaded) and the legacy `SFSpeechRecognizer` path as the fallback; pure `VoiceEngineSelector` + tests; `VoiceRecognizer` public API unchanged. Locale `zh-Hans`→`zh-CN` canonicalization was the device gotcha. 161 tests + both apps build; **device-confirmed** `engine=analyzer` on iPhone 14 / iOS 26 with ~45 s real dictation typed append-only. Lessons 61-63.)_

_Previous: 2026-09-24 (voice long-dictation debugging session — pauses and long holds no longer drop chars or disconnect: recoverable-error restart loop + task-identity guard + interruption handling, on-device pause-reset accumulation, tail-only typing (`TextDiff.tailEvents`) with one reconcile per segment boundary, and a >20 s proactive segment-boundary task rollover. Camera now remembers the user's on/off choice (`remotecrab.ios.cameraOn`, explicit toggles only). 156 tests + both apps build; verified on a real iPhone (2 rollovers / 58 s hold, zero backspaces). Lessons 61-62.)_

_Previous: 2026-09-24 (later session — 1.0 re-submitted as build **2026092402**: Mac-picker duplicate fixed; haptics every ON level now vibrates (System Haptics vs silent-switch explained); Labs: air-mouse `NSMotionUsageDescription` + tap-to-toggle gyro button + gain /3.5, wheel is now inline (classify ≥120° turn, no mode); voice no longer deletes or duplicates (stable-prefix typing); modifier keys (locked = real key down + keycode text path + device bits); selection copy/paste bar; context sheet system keys pinned. Lessons 56-60. Build 2026092402 uploaded to ASC; user attaches it to version 1.0 and submits.)

_Previous: 2026-09-23 (V1.3 SHIPPED + context sheet grew to 17 suites

_Previous: 2026-09-22 (V1.2 SHIPPED: context sheet expanded to 10 suites — presentation/agent/finder/notes/browser/mail/messages/calendar/editor/console — with `Codable` + self-describing profiles (marketplace-forward), 2-column row pairing (volume/brightness pairs share a row), full-width voice hero; multi-select file/photo send via a serial `SerialFileSender`; "Latest Screenshot" one-tap send + Photos permission in onboarding; connection-sheet "Choose a Mac" entry. Bug fixes: glass backgrounds are not hit-testable → every glass button now has `.contentShape` (the ⌨️ toggle's tap target was ~16 pt), and keyboard mode no longer renders the PTT row over KeyboardScreen's shortcut bar — lessons 39-43; 130 tests green + both app targets build + real-device e2e 10/10.)_

_Previous: 2026-09-22 (V1.2 SHIPPED: context sheet expanded to 10 suites — presentation/agent/finder/notes/browser/mail/messages/calendar/editor/console — with `Codable` + self-describing profiles (marketplace-forward), 2-column row pairing (volume/brightness pairs share a row), full-width voice hero; multi-select file/photo send via a serial `SerialFileSender`; "Latest Screenshot" one-tap send + Photos permission in onboarding; connection-sheet "Choose a Mac" entry. Bug fixes: glass backgrounds are not hit-testable → every glass button now has `.contentShape` (the ⌨️ toggle's tap target was ~16 pt), and keyboard mode no longer renders the PTT row over KeyboardScreen's shortcut bar — lessons 39-43; 130 tests green + both app targets build + real-device e2e 10/10.)_

_Previous: 2026-09-22 (V1.2 SHIPPED: context sheet expanded to 10 suites — presentation/agent/finder/notes/browser/mail/messages/calendar/editor/console — with `Codable` + self-describing profiles (marketplace-forward), 2-column row pairing (volume/brightness pairs share a row), full-width voice hero; multi-select file/photo send via a serial `SerialFileSender`; "Latest Screenshot" one-tap send + Photos permission in onboarding; connection-sheet "Choose a Mac" entry. Bug fixes: glass backgrounds are not hit-testable → every glass button now has `.contentShape` (the ⌨️ toggle's tap target was ~16 pt), and keyboard mode no longer renders the PTT row over KeyboardScreen's shortcut bar — lessons 39-43; 130 tests green + both app targets build + real-device e2e 10/10.)_

_Previous: 2026-09-22 (V1.1 UI RESTRUCTURE COMPLETE + REAL-DEVICE PASS: FeatureDock removed — top-bar cam/mic toggles + bottom ⌨️/PTT row; ContextSheetView with presentation/agent/console suites + `systemCommand` 0x19; Mac launchAtLogin (SMAppService) / autoReconnect gate / AWDL peer-to-peer wired. Device pass fixed: media-key data1 double-shift (volume/mute dead on device), switcher missing minimized/hidden apps, shortcut rows now lead with ⏎/⌫, sheet buttons haptic — lessons 37-38.)_

_Previous: 2026-09-19 (V1.0 SUBMITTED: iOS build 2026091802 → version 1.0 + TestFlight Internal; Mac 1.0 Developer ID notarized DMG via `scripts/release-mac.sh`; domain → `vgoapp.com/remotecrab/`; iOS download links + App Review notes + demo video; lessons 29-36 added. Remaining human step: ASC privacy-policy URL in the browser.)_
