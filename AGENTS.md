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
│   ├── Tests/                    # 151 automated tests (see below)
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

145 tests in `RemoteCrabCore/Tests/`, all pass:

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
├── ContextProfilesTests.swift         (24)  17-suite frontmost-app mapping (presentation/agent/finder/notes/browser/mail/messages/calendar/xcode/editor/text/media/chat/meeting/image/notebook/console), even-row-pairing + bundle-id uniqueness invariants, Codable round-trip
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
- 151 automated tests passing
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

### Real-device lessons (2026-09-11, iPhone 14 / iOS 26.6.2)

Hard-won knowledge from the first real-hardware run. All four bugs
below were invisible to the simulator and to `./scripts/test.sh`:

1. **Swift `Data` slices keep the parent's indices.** `data[4..<n]`
   has `startIndex == 4`, so `slice[0]` traps (SIGTRAP) on the very
   first frame. This killed the app at launch. Always subscript
   slices by `slice.startIndex` or index into the parent directly.
2. **TCC permission callbacks fire on a background XPC queue.**
   A `withCheckedContinuation` wrapping `SFSpeechRecognizer.requestAuthorization`
   inside a `@MainActor` type traps in `swift_task_checkIsolated`.
   Mark the wrapper `nonisolated`. (`AVCaptureDevice.requestAccess`
   calls back on main, which is why only speech crashed.)
3. **MenuBarExtra labels: SF Symbols, or a proper template IMAGE asset.**
   A custom `Canvas` label renders as a solid blob; hardcoded `.white`
   art is invisible in light menu bars. SF Symbols get template
   rendering for free. For the app's own logo, ship a **monochrome
   transparent-background image set** with
   `"template-rendering-intent": "template"` (`MenuBarIcon.imageset`,
   mastered from `assets/menu-bar-icon.svg` via `rsvg-convert`) and use
   `Image("MenuBarIcon").renderingMode(.template)` — macOS then tints it
   for light/dark. That's how the menu bar shows the monitor-buddy logo
   instead of a phone glyph.
4. **`./scripts/test.sh` used to clobber signed builds.** Its
   `CODE_SIGNING_ALLOWED=NO` builds wrote into the same DerivedData
   that deploy scripts copy from — deploying right after gating
   shipped an app with zero entitlements (sysex activation then
   fails with "Missing entitlement"). Gate builds now use
   `.build/ci-derived-data`. If you touch signing, verify the deployed
   app: `codesign -d --entitlements :- /Applications/RemoteCrabReceiver.app`.
5. **The mic path needs two non-obvious things on device.** (a) An
   active `AVAudioSession` in a record-capable category before
   `AVAudioEngine.start()`, or the input tap never fires. (b) The
   input node delivers **Float32 non-interleaved**, so
   `buffer.int16ChannelData` is nil — a `guard let int16` silently
   drops every buffer. Convert to Int16 (mix to mono) yourself.
   Both bugs fail 100% silently: no error, no crash, just zero
   packets. Verify with the Mac-side `audio packets received` log.
6. **Backgrounding kills video but not audio — by design of iOS, and
   it does NOT auto-recover.** AVCaptureSession gets interrupted
   (video device unavailable in background); the MicrophoneEncoder's
   separate AVAudioEngine survives. Symptom: after a reconnect, audio
   flows but the Mac shows "No video" forever. CaptureEngine observes
   `.AVCaptureSessionWasInterrupted / InterruptionEnded / RuntimeError`
   and restarts the session, and `handleDidBecomeActive` force-checks
   `captureSession.isRunning`.
7. **Actor-isolated tap closures trap on the audio realtime thread.**
   Any `installTap` block formed inside a `@MainActor` type inherits
   that isolation and SIGTRAPs in `swift_task_checkIsolated` on the
   first buffer. Give the block an explicit `@Sendable` type and box
   non-Sendable captures (`UnsafeSendableBox`). This is what made
   hold-to-talk crash on tap.
8. **`Text(someString)` is verbatim — it never localizes.** SwiftUI only
   runs the String Catalog lookup for `Text("literal")` /
   `Text(LocalizedStringKey(x))`. A string routed through a `String`
   property or a `func row(title: String)` helper displays as-is, so the
   UI silently stays English. Type helper params as `LocalizedStringKey`;
   for non-`Text` uses go through `String(localized:bundle:.module)`.
   Also `.help("…")` / `.accessibilityLabel("…")` literals can resolve
   verbatim — wrap in `Text("…")`. Corollary (2026-09-15): two catalog
   keys that differ ONLY BY CASE ("Switch Camera" vs "Switch camera")
   collide in Xcode's GeneratedStringSymbols and fail the build —
   reuse the existing key instead of adding a case-variant.
9. **The black video scare was a covered camera, not the decoder.**
   `CaptureEngine` streams the `.back` camera; a phone face-down on a
   desk is perfectly black. To tell "lens covered" from "decoder emits
   black", run the receiver with `REMOTECRAB_DEBUG_FRAME_PROBE=1` and read
   the `frame probe: min/max/avg` line (true black → `max≈0`; a real
   scene → `avg≈140`). The probe reads pixels via a `CGContext`: CI's
   PNG writer is blocked by the sandbox and a failed CI render reads
   back as 0, so CI is not trustworthy here.
10. **Accessibility grant survives an in-place redeploy.** Overwriting
    `/Applications/RemoteCrabReceiver.app` with `ditto` (same path, same
    bundle id, same cert) keeps the TCC grant; a path/signature change
    drops it. TCC is cached per process — **restart the app after
    granting**, then confirm `accessibility trusted: true` in the log.
11. **Tooling gotchas that cost an hour.** macOS has **no `timeout`**
    (GNU-only; the failure is silent, which fakes "Bonjour isn't
    advertising"); use `cmd & sleep 5; kill $!`. The iOS **Simulator's
    Bonjour service is not visible to the host Mac's `NWBrowser`**, so
    don't use a simulator to test discovery/pairing. `NWListener(using:
    NWParameters.tcp)` (no explicit port) comes up; `on: .any` didn't.
    For `simctl launch`, pass env vars with a `SIMCTL_CHILD_` prefix.

12. **The iOS top bar is a floating overlay — surfaces must leave room.**
    `ContentView` overlays a compact top bar (status icon + cam/mic
    stream toggles + an overflow `Menu`) plus a centered status alert
    card. `KeyboardScreen` pads its
    top by 56pt so its header (正在 Mac 上输入) isn't covered. The
    bottom `pttRow` (round `keyboard` button + wide PTT capsule) is
    ~76pt tall, so `TouchpadScreen.dockClearance` is **76** (was 148
    when the V0.3 FeatureDock — ~134pt of capsule + button row — still
    existed; at the old 88 the ⌃⌥⌘⇧ modifier bar sat on top of the
    "按住说话" capsule). Keep these numbers in sync when the bottom
    row grows.
    Long status text must never go in a cramped pill (it wrapped one CJK
    glyph per line); it goes in the alert card.
13. **Never surface a raw `NWError`/POSIX error.** `"\(error)"` shows
    `POSIXErrorCode(rawValue: 54): Connection reset by peer` in the
    popover. Log the error, set a human message
    (`IBLocale.Error.iPhoneConnectionLost`). Also: `IBStatusPill`'s
    `.disconnected` renders no secondary text now — showing the reason
    produced the mixed "离线 Connection lost" pill.
14. **`MenuBarExtra(.window)` re-sizes (and visibly animates) whenever
    its content height changes.** A status row whose text wraps (the
    offline hint `Text(session.state.message).fixedSize(vertical:)`)
    changed height on every reconnect-loop state change, so the popover
    kept sliding/re-sizing — read as a "looping sideways animation".
    Keep popover rows a FIXED height and their text `lineLimit(1)`.
15. **Don't run an always-on `TimelineView` for an idle animation.**
    The trackpad's cursor preview ticked at 20 Hz forever, which made
    surface switches (and the camera PiP) feel janky; it's now
    `TimelineView(.animation(minimumInterval: 0.05, paused: trail.isEmpty && !isPressed))`.
16. **`H264Decoder.emit` must not build a `CIContext` per frame.** It
    did — 30 expensive context creations a second showed up as visible
    stutter. One cached `lazy var ciContext` per decoder.
17. **AVFoundation has a state where `captureSession.isRunning` is true
    but the video output silently stops delivering.** Symptom: touch and
    audio keep flowing, `featureState camera=true`, but no video frames
    — Mac preview goes black while the status bar still says 直播中.
    Root cause found (2026-09-14): backgrounding the app makes iOS
    **invalidate the VTCompressionSession** — after returning, every
    `VTCompressionSessionEncodeFrame` returns -12903
    (`kVTInvalidSessionErr`) forever, and the error only went to os_log.
    Fix: `H264Encoder.scheduleSessionRecreation()` invalidates and
    rebuilds the compression session on that error (1s throttle), clears
    cached SPS/PPS so the first new frame re-emits parameter sets.
    CaptureEngine still runs a video-frame watchdog for the separate
    "session running, output dead" mode — but it must respect a warm-up
    window: before the encoder has produced its first frame
    (`hasProducedVideoFrame == false`, i.e. cold start or a
    reconfiguration) the threshold is 12 s, not 2.5 s, and it never
    fires while `captureSession.isRunning == false`. Without this it
    stop/starts the session every 3 s during a perfectly healthy cold
    start. Related cold-start trap: `configureCaptureSession` wires
    `videoOutput.setSampleBufferDelegate(encoder, …)`, so the
    `H264Encoder` must be created BEFORE the session is configured —
    passing a nil encoder silently clears the delegate and no frame is
    ever delivered (looks exactly like the silent-stop bug). Forensics:
    `RemoteCrabCapture/Forensic.swift` writes counters +
    events to stderr AND `Documents/forensic.log` (pull it with
    `devicectl device copy from --domain-type appDataContainer`;
    `devicectl --console` attach is too flaky to rely on).
18. **One `AVCaptureVideoPreviewLayer` per app, attached only AFTER
    `startRunning()` returns.** Measured on iPhone 14 / iOS 26
    (2026-09-14): attaching a SECOND preview layer to the session blocks
    the main thread ~9 s at cold start (the camera daemon serializes
    preview-client registration), and attaching while `startRunning` is
    in flight can wedge the layer black forever — only destroying and
    recreating the view recovers it. Both presented as "launch freezes
    the UI and the preview is black until I switch tabs". The
    full-screen preview and the PiP now reparent ONE shared
    `CameraPreview.PreviewView` (`CaptureEngine.previewView`), created in
    the startRunning completion; SwiftUI gates on `captureSessionReady`
    and shows a "starting camera" placeholder meanwhile. Note
    `AVCaptureSessionDidStartRunningNotification` fires BEFORE
    `startRunning()` returns — attaching from that notification still
    blocks, so the gate must be on the return, not the notification.
    `Forensic.MainStallMonitor` logs main-thread stalls >300 ms to
    forensic.log; a healthy launch shows zero `[main-stall]` lines.
19. **The app sandbox blocks `shm_open` outright — the mic feed must
    use loopback UDP.** The original virtual-mic design shared an SPSC
    ring via POSIX shm (`IBRingOpen`); the sandboxed app always failed
    with `mic ring unavailable (shm_open failed)`, so the device only
    ever output silence. Now the ring lives inside coreaudiod
    (`RemoteCrabMicrophone.c` mallocs + `IBRingInit`), `MicSocketListener.c`
    binds `127.0.0.1:49182` and feeds it (single writer; the IO thread
    stays the single reader — SPSC unchanged), and the app's
    `MicRingWriter` sends raw Int16 datagrams via NWConnection
    (`com.apple.security.network.client` allows loopback). Datagrams
    are host-endian raw PCM — same machine, no byte-order concern.
    Verified bit-exact by a standalone harness (socket → ring → read,
    48000 frames). `IBRingOpen` is kept for non-sandboxed consumers but
    is no longer used by the app.
    **Loading gotchas that cost a day (all silent — no log, no crash
    report, device just never appears):** (a) the HAL plug-in binary
    must be **Developer ID Application** signed (coreaudiod library
    validation refuses Apple Development); (b) `Info.plist` must carry
    `CFBundleExecutable` — without it CFBundle can't locate the binary
    and coreaudiod skips the bundle entirely; (c) the driver struct's
    first field must be the interface **pointer**
    (`AudioServerPlugInDriverInterface *mInterfacePointer`), not the
    interface struct by value — `AudioServerPlugInDriverRef` is a
    pointer-to-pointer, so a by-value first field reads as a NULL
    vtable and the very first host call segfaults. (d) By the same
    token, `QueryInterface` must return the **ref itself**
    (`*outInterface = inDriver`), not `&driver->mInterface` — the host
    derefs the returned ref and would read the struct's reserved NULL
    slot as the vtable. This one crashes the
    `Core-Audio-Driver-Service.helper` host process (report in
    /Library/Logs/DiagnosticReports, stack in
    `init_driver_interface` at `ldr x8,[x8,#0x10]`) and the log only
    shows "Loading server plug-in X…" with no "Done". (e) **Build the
    driver x86_64, not arm64**: macOS hosts each third-party driver in
    an arch-matching `Core-Audio-Driver-Service.helper`; the arm64
    helper is arm64e and calls the vtable with `blraaz` (pointer
    authentication), which faults on a plain arm64 binary's unsigned
    function pointers (SIGILL right after the "Loading" line). Every
    shipping third-party driver (Teams/Lark/TFF/…) is x86_64 — the
    x86_64 helper has no PAC. (f) **`QueryInterface` MUST `AddRef`
    (COM contract)**: the x86_64 host's `get_asp_interface` calls
    `vtable->Release` on the factory reference right after QI — a QI
    that only returns the pointer drops the refcount to 0 and frees
    the driver before first use; the host then calls `AddRef` through
    a dangling/NULL vtable and SIGSEGVs at 0x10 in `load_driver`
    (this crash is in the main `Core-Audio-Driver-Service`, not the
    helper). Disassembly of the service binary
    (`otool -tvV`, trace `get_asp_interface`) shows the exact
    QI-then-Release sequence — the definitive answer when the dlopen
    harness "passes" but the real host still crashes; extend the
    harness to replay the host's exact call sequence
    (factory → QI → Release → use). (g) **The publish path needs
    `kAudioPlugInPropertyDeviceList` (`'dev#'`)**: after `Initialize`
    the host asks the plug-in object for `'dev#'`; an
    unknown-property error there makes it give up silently —
    `CreateDevice` is never called and the device never publishes.
    Also implement `kAudioPlugInPropertyTranslateUIDToDevice` (`'uidd'`,
    UID via qualifier → AudioObjectID) for the on-demand
    `kAudioHardwarePropertyPlugInForBundleID` query. (h) **Enumeration
    then walks base-class properties**: `kAudioObjectPropertyClass`
    (`'clas'`, return `kAudioPlugIn/Device/StreamClassID`) on every
    object and `kAudioDevicePropertyZeroTimeStampPeriod` (`'ring'`) on
    the device; and `HasProperty` must never claim a selector that
    `GetPropertyData` refuses (RelatedDevices / PreferredChannelLayout
    are now implemented; Icon / CustomPropertyInfoList were dropped) —
    one mid-walk error aborts publishing, again silently.
    **Instrumentation**: every lifecycle entry + every property error
    is `os_log`'d under subsystem `com.remotecrab.micdriver` — that's how
    (g) and (h) were found. Debug path when a
    driver "installs but never appears": dlopen harness
    (`scripts/mic-driver-harness.c` — replays the host's exact
    sequence factory → QI → Release → Initialize → dev# → clas → ring
    → uidd → property tree; run it against the pkg payload BEFORE
    installing); compare against a working driver in
    `/Library/Audio/Plug-Ins/HAL` (Teams/Lark/TFF load fine).
    The pkg's postinstall `killall coreaudiod` makes installs take
    effect immediately. **Iterating without user clicks**: the
    pkg-installer GUI is a bottleneck — use a Terminal autoloader
    (user types sudo password once per window) that watches a trigger
    file, `ditto`s the `.driver` into `/Library/Audio/Plug-Ins/HAL`,
    `killall coreaudiod`, and can also run queued root commands
    (e.g. `sample coreaudiod`). Verify publication with a C tool
    querying `kAudioHardwarePropertyDevices` + per-device UID —
    `system_profiler` is cached and unusable.
    **coreaudiod 100% CPU / clients hang on first query**: sample
    showed a `HALC_ShellSimpleProxyList::Reconcile` notification storm
    with 17k+ "Registering remote driver with bundle id
    com.apple.AirPlayXPCHelper" entries — Apple's AirPlay helper in a
    re-registration loop (an Apple bug, aggravated by the Personal-
    Hotspot network; NOT our driver — our plugin registers once and
    stays). `sudo killall AirPlayXPCHelper` breaks the loop and
    coreaudiod drains within a minute; clients then answer again.
    Verified end-to-end 2026-09-14: device publishes
    (`com.remotecrab.RemoteCrabMicrophone.device` in the system list),
    injecting a 440 Hz sine over UDP 127.0.0.1:49182 and capturing
    from the device via AUHAL reads back the exact amplitude
    (peak=12000) — UDP → listener → ring → DoIOOperation → CoreAudio
    all bit-plausible. Same day, real hardware: iPhone mic →
    RemoteCrab app → MicRingWriter → UDP → device captured speech-level
    audio (rms 0.0073) — full chain confirmed.
20. **Personal Hotspot breaks Bonjour — ship a direct-IP fallback.**
    When the Mac's WiFi is the iPhone's hotspot (Mac gets 172.20.10.x,
    phone is always the gateway 172.20.10.1), mDNS multicast does not
    reach hotspot clients: `dns-sd -B _remotecrab._tcp` shows NOTHING even
    though the phone's listener is up and `nc -z 172.20.10.1 8765`
    succeeds. Same story with AP client isolation and some VPNs.
    Symptoms read as "connects slowly / never connects". Diagnosis
    order: check the Mac is NOT on a VPN (`ps aux | grep -i clash/surge/
    wireguard…`, utun interfaces without IPv4 addrs are Apple's idle
    system tunnels, harmless) → `nc` the phone's gateway IP to prove
    TCP works → then it's multicast. Fix (2026-09-14): the receiver
    runs a fallback loop (`ReceiverSession.startFallbackLoop`) — after
    5 s of empty Bonjour in `.searching` it probes the last-connected
    IP (`remotecrab.lastPhoneIP`, persisted from every successful connect's
    `currentPath.remoteEndpoint`) and the hotspot gateway with a 2.5 s
    dial, then connects directly. Direct-link token reuse keys the
    token store by the mapped name (`remotecrab.phoneNameByIP`), so
    pairing survives. Verified live on hotspot: Bonjour found the phone
    anyway in one run (multicast is *flaky*, not deterministically
    dead), so treat this as a fallback, not a replacement.
    Related: the iPhone app dies/suspends within ~a minute when the
    phone locks or the app backgrounds — every "the Mac can't find the
    phone" report should first check the phone's screen is ON with the
    app foregrounded (devicectl `--console` launch ties app lifetime to
    the console session; killing it kills the app).
21. **"iPhone stuck on 连接中" was three stacked bugs (fixed 2026-09-15).**
    The iPhone is the TCP *server* — it can only wait for a Mac to dial
    in, so every connection failure presents as a permanent "connecting"
    card. Root causes: (a) the waiting card said 连接中 with zero
    actionable info; (b) the fallback loop only probed when Bonjour was
    TOTALLY empty — a stale or unpaired discovery record (e.g. a
    simulator that once advertised) suppressed direct-IP dialing
    forever, a deadlock on VPN'd Macs; (c) direct connections keyed
    the pairing token by a placeholder name ("iPhone (direct link)"),
    so `clientHello` went out tokenless (`paired: false`) and the phone
    demanded a fresh approval tap on EVERY reconnect. Fixes: the
    waiting card now says 「等待 Mac 连接」 and shows the phone's own
    `IP:port` + the Mac menu-bar manual-connect path
    (`IBLocale.Error.waitingForMac` / `manualConnectHint`, pill says
    「等待中」); the fallback probes whenever no DISCOVERED-AND-PAIRED
    phone exists; and `ReceiverSession.rekeyDirectConnection` moves the
    token under the real service name (`RemoteCrab — <deviceName>`,
    learned from the metadata frame) and updates `phoneNameByIP`, so
    the next direct dial is `paired: true` and reconnects silently.
22. **The camera is OFF by default (2026-09-15).** Users may only want
    the mic, the trackpad, or voice typing — streaming video on launch
    was the surprising default. `FeatureStore.cameraOn = false`; the
    local preview still runs, nothing is SENT until the camera toggle
    (top-bar `video.fill` button since V1.1; `handleEncodedFrame`
    guards on `features.cameraOn`). The camera
    surface already had a "CAMERA IS OFF / TURN ON" placeholder, so no
    new UI was needed. Headless e2e opts back in explicitly:
    `REMOTECRAB_AUTOSTREAM=1` sets the camera feature on connect.
    **Backgrounding also turns the camera OFF now** — returning from
    the background used to silently resume streaming (a privacy
    surprise: the user covered the lens / walked away and the Mac kept
    watching). On `.background` the engine sets the camera feature off
    and broadcasts `featureState`; back in the foreground the surface
    shows the OFF placeholder + a hint to tap the camera toggle
    (`IBLocale.Error.resumedAfterBackground`). Mic keeps flowing in the
    background by design (`UIBackgroundModes: audio`).
23. **A stale speculative direct-IP dial starved Bonjour (fixed 2026-09-15).**
    Symptom: e2e went 0/10 — the receiver sat in `preparing` for 75 s
    and ignored the phone's perfectly good Bonjour record. The fallback
    loop dials the last-known IP speculatively; when that IP is stale
    (phone changed networks) the TCP connect hangs in `preparing` for
    the full NWConnection timeout, and `handleDiscovered` refused to
    preempt a connection already "in progress". Two guards:
    (a) a Bonjour discovery of a PAIRED phone preempts a still-
    `.connecting` speculative dial; (b) any direct dial that isn't
    `ready` within 8 s (`directDialTimeoutTask`) is abandoned so the
    next discovery/fallback cycle gets a turn. Lesson: a speculative
    connection must always be preemptible by a discovered one, and
    every speculative path needs its own timeout shorter than the
    platform default.
24. **Long-press drag + a wider double-tap window (2026-09-15).**
    "Can't drag windows or select text" — the only drag gesture was
    double-tap-hold (Mac muscle memory) with a 0.28 s second-tap
    window, too tight to hit reliably, so drags decayed into scrolls.
    TouchSurface now also arms drag on **long-press** (0.45 s hold
    without moving, 12 pt tolerance; while armed, the tap recognizer
    is disabled so the release doesn't fire a click) and the
    double-tap window is 0.35 s. **The long-press state machine must
    live in `touchesBegan/Moved/Ended`, NOT in the pan recognizer** —
    a `UIPanGestureRecognizer` only reaches `.began` when the finger
    MOVES, so the first version (keyed off the pan's `.began`) could
    never detect press-and-hold-still, and "long-press to select
    text" was dead on arrival (second device report). Corollary guard:
    a long-press that armed while the finger never moved leaves the
    pan in `.possible`, so no `.ended` ever fires — `touchesEnded`
    must release the drag itself when `singlePan.state == .possible`,
    or the Mac's left button stays DOWN forever. Injection chain
    verified: `dragStart` → `leftMouseDown` → `leftMouseDragged` →
    `leftMouseUp` (`CGEventInjector`). Mac trackpads don't have
    long-press drag, so keep both gestures; if either feels laggy on
    device, tune the 0.45 s / 12 pt constants, not the injection side.
    **Also fixed the same day**: `CGEventInjector.lastCursor` never
    clamped to the screen, so it could drift off-display and post
    every later event (including drags) at meaningless off-screen
    coordinates — the cursor "lost" itself. `moveCursor` now clamps,
    which also makes the position deterministic (enough up-left
    deltas always reach (0,0) — the e2e drag staging relies on this).
    Verified live in the simulator e2e: window title-bar drag moves
    the window; text drag-select → ⌘C puts the selection on the
    clipboard. Four-finger swipes emit `.threeFingerSwipe` (macOS
    maps both to the same Mission Control family); haptics re-`prepare()`
    right before firing (generators go stale) and now also fire on
    3/4-finger swipes + three-finger tap.
25. **An active record session suppresses ALL in-app haptics (2026-09-15).**
    "No vibration anywhere on device" — iOS disables every
    `UIFeedbackGenerator` in the app while an `AVAudioSession` in a
    record-capable category is active (it keeps vibration noise out of
    the recording; documented in community reports, not by Apple). Our
    bug made it permanent: `MicrophoneEncoder.start()` did
    `setCategory(.playAndRecord) + setActive(true)` but `stop()` never
    called `setActive(false)`, so once the mic had run once (and e2e's
    `REMOTECRAB_E2E_MIC=1` forces it on), the session stayed active
    forever and trackpad haptics were dead even with the mic toggled
    off. Fix: `MicrophoneEncoder.stop()` ends with
    `setActive(false, options: .notifyOthersOnDeactivation)`
    (`VoiceRecognizer` already did this correctly — it's the template).
    **Hard platform limit that remains**: haptics are still suppressed
    WHILE the mic is actually streaming — nothing an app can do about
    that; don't file it as a bug.
26. **Drag clutch: lifting mid-drag must not end the drag (2026-09-15).**
    "Can't select a big block of text" — a relative-position drag ends
    the moment the finger runs out of screen, so selections were
    capped at ~one screenful. The clutch (macOS three-finger-drag
    behavior): on a mid-drag finger lift the Mac's left button stays
    DOWN for 0.8 s (`clutchWindow`); one finger back down continues
    the SAME drag (the pan re-begins against the still-armed state,
    no second `dragStart`), and the cursor dot springing back to
    center on lift is exactly what makes finger repositioning
    ergonomic. Three guards that matter: (a) a SECOND finger landing
    during the window ends the drag immediately — the user moved on
    to scroll/pinch; (b) `touchesCancelled` (gesture stolen by the
    system) also releases immediately, no grace period; (c) the view
    leaving the window calls `endDragNow` or the Mac's button is
    stranded down. Feedback: a selection-haptic tick on clutch start
    (a still-held button is invisible on a touchscreen) and a hint
    pill via `onClutchChange`. Companion discoverability: ⇧+click to
    extend a selection worked end-to-end all along (modifier mask →
    mouse event flags) but nobody knew — locking ⇧ on the trackpad's
    modifier bar now shows a "tap start, tap end" hint pill.
27. **Simulator TCC grants for the camera do not survive a sim reboot, and
    a wedged CoreSimulatorService makes every `simctl` call hang
    (2026-09-16).** Three stacked traps hit while capturing ASC
    screenshots headlessly: (a) an adhoc CI build's camera grant is reset
    to denied by tccd's boot-time re-validation (microphone survives —
    camera is the one that flips), and while tccd's in-memory state
    disagrees with TCC.db, even a successful `simctl privacy grant`
    still leaves the app showing the camera prompt, which deadlocks the
    headless launch exactly like lesson 11's trap. (b) When
    `simctl privacy/terminate/launch` ALL hang, CoreSimulatorService is
    wedged — `killall com.apple.CoreSimulator.CoreSimulatorService` (user
    level, no sudo) fixes it, but reboots any booted sims. (c)
    `xcrun simctl bootstatus -b` can block forever on a loaded machine —
    poll `simctl list devices | grep Booted` instead. The reliable
    recovery order: restart CoreSimulatorService → boot → `simctl
    privacy grant camera/microphone` → if the prompt STILL appears, open
    the Simulator.app window for the UDID and tap 允许 once with
    `cliclick` (window pos/size via AppleScript System Events; content
    area = window minus the 28pt title bar, scaled to device pixels) —
    then do NOT reboot the sim again. Also: a full disk makes the
    simulator silently shut down and can wipe installed app containers
    (`get_app_container` → No such file); reinstalling from
    `.build/ci-derived-data` works but wipes TCC again.
28. **Bonjour endpoint description strings escape bytes as `\DDD`
    (2026-09-16).** `"\(result.endpoint)"` for a service endpoint is a
    display string like `RemoteCrab\032-\032iPhone…._remotecrab._tcp.local`
    (`\032` = space, em dash = `\226\128\148`). Never show it raw — use
    `DiscoveredPhone.displayEndpoint` (decimal-escape → UTF-8 decoder in
    `ReceiverSession.swift`). `phone.endpoint` on a Bonjour-discovered
    phone is display-only (dialing goes through `serviceEndpoint`); on a
    direct-link phone it's the IP.

29. **Mac Developer ID signing + notarization goes through a hand-rolled
    re-sign, NOT `xcodebuild -exportArchive` (2026-09-19).** The export
    step dies with `Cloud signing permission error` — our Asc API key
    lacks "cloud-managed distribution certificates" access (an
    Admin/Account-Holder grant, or a different key). What works:
    `archive` (automatic / Apple Development is fine) → copy the `.app`
    out of the archive → re-sign every nested binary by hand with
    `codesign --force --options runtime --timestamp --sign "Developer ID
    Application: Beijing VGO Co;Ltd (5XNDF727Y6)"` (SystemExtensions →
    PlugIns/appex → the app) → delete `Contents/embedded.provisionprofile`
    (a Developer ID app must not carry a development profile) → notarize +
    `stapler staple`. **No Developer ID provisioning profile is needed** —
    the sysex `com.apple.developer.system-extension.install` and app-group
    entitlements are not profile-backed for Developer ID (verified: app +
    DMG both `spctl` → "accepted, Notarized Developer ID"). All of this is
    `scripts/release-mac.sh <version>`. Notary creds live in
    `~/.config/mddock/production.env` (APPLE_ID/APPLE_PASSWORD/APPLE_TEAM_ID).

30. **The embedded virtual-mic pkg is the only thing that fails
    notarization (2026-09-19).** notarytool rejects (a) the HAL driver for
    a missing secure timestamp — fixed by passing
    `OTHER_CODE_SIGN_FLAGS="--timestamp"` to xcodebuild in
    `scripts/build-mic-driver-pkg.sh`, and (b) the pkg itself for being
    unsigned — it must be `productsign --sign "Developer ID Installer:
    Beijing VGO Co;Ltd (5XNDF727Y6)"`. **The first `productsign` pops a GUI
    keychain password prompt** (key `diiformac`); the user clicks "Always
    Allow" once. `codesign` with the Developer ID *Application* key does
    not prompt (that key was already authorized). Sequence: sign driver →
    pkgbuild → productsign → notarize + staple pkg → copy into the app's
    `Contents/Resources/` → re-sign + notarize the app → DMG → sign +
    notarize + staple DMG.

31. **`xcodegen generate` rewrites each app's Info.plist wholesale from
    `project-ios.yml` / `project-mac.yml` (2026-09-19).** Editing only
    `RemoteCrabCapture/Info.plist` (version, `ITSAppUsesNonExemptEncryption`)
    is silently reverted on the next `xcodegen` — the previous release's
    `1.0 / 2026091801` lived only in the plist because no one regenerated.
    Version, `CFBundleVersion` and `ITSAppUsesNonExemptEncryption` must all
    live in the YAML; regenerate before archiving.

32. **App Review notes are mandatory for this app, and the API can write
    them mid-review (2026-09-19).** The iOS app's headline value needs the
    companion Mac app, which is NOT on the Mac App Store, so a reviewer on
    an iPhone just sees "Waiting for your Mac" → likely 2.1 Completeness.
    Fill **App Review Information → Notes** with: how to preview via Demo
    Mode without a Mac, where to get the Mac app, permission rationale, and
    a **demo-video URL**. `appStoreReviewDetails` accepts a PATCH even while
    the version is `WAITING_FOR_REVIEW` (the ASCClient in
    `scripts/ios-app-store-testflight.py` does it). Note the App Store
    **`privacyPolicyUrl` is not exposed by the ASC API** (`appInfos` has no
    such attribute) — it has to be set in the browser.

33. **iOS "where do I get the Mac app" + one URL source (2026-09-19).**
    `RemoteCrabCore.State.RemoteCrabLinks` is the single source for
    productPage / macDownload / privacyPolicy / github, all under
    `vgoapp.com/remotecrab/`. The onboarding pair page and the
    "Waiting for your Mac" card both carry a tappable "Download for Mac"
    button. The domain moved from `remotecrab.app` → `vgoapp.com/remotecrab`
    (ASC marketing/support URLs updated too). Never hard-code a brand URL
    in a view again.

34. **Demo videos: macOS cannot record a physical iPhone's screen from the
    CLI (2026-09-19).** `simctl io recordVideo` only does Simulator, and it
    **stops early for no clear reason** (measured 30 s of a 50 s run, and
    8 s of a 29 s run); QuickTime's device recording is GUI + a TCC prompt
    and hangs scripts. What works (`scripts/demo-video.sh`): lay the
    Simulator window and the Mac receiver's connection self-check window
    side by side on the desktop → one `screencapture -V <secs>` of the
    whole screen → ffmpeg crops each window and `hstack`s them with a title.
    `screencapture` records at 2x (1440×900 pt → 2880×1800 px) so crop
    coords must be doubled. The Simulator has no camera, so the camera tile
    stays empty — say so honestly in the review notes.

35. **How vgoapp.com is deployed (2026-09-19).** The VGO studio site is a
    Vite SPA (`~/VGOAPP`) served by MDDock's Caddy from the VPS
    `/var/www/vgoapp` (`MDDock/crates/mddock-cloud/deploy/Caddyfile`).
    `/remotecrab/` (product page) and `/remotecrab/privacy/` (privacy
    policy) are **multi-entry static pages**
    (`vite.config.ts` → `build.rollupOptions.input`), so no Caddy changes
    are needed. Publish with `VGOAPP/scripts/deploy.sh` (build + rsync
    `dist/`; optional `DMG=` uploads into `downloads/`, which is excluded
    from `--delete`). VPS: `root@158.247.219.230`, key
    `~/MDDock/certs/mddock-vps-root`. **scp/rsync intermittently fail with
    "Connection closed"** (looks like fail2ban); `cat file | ssh … 'cat >
    remote'` is more reliable.

36. **The "background microphone" was never actually enabled
    (2026-09-19 — corrects the old claim in this file).**
    `UIBackgroundModes` exists nowhere in `project-ios.yml`, any
    Info.plist, or git history; so iOS suspends the app on background and
    mic streaming stops. This accidentally removes a 2.5.4 background-mode
    review risk. To enable it, add `UIBackgroundModes: [audio]` to
    `project-ios.yml` and be ready to justify it to Apple.

37. **V1.1 layout: the feature dock is gone (2026-09-22).**
    `FeatureDock.swift` was deleted; camera/mic stream toggles moved to
    the `ContentView` top bar (round `video.fill`/`mic.fill` buttons)
    and the bottom row (`pttRow`: round `keyboard` button + wide PTT
    capsule). The layout constants moved with it:
    `TouchpadScreen.dockClearance` is now **76** (was 148) and
    `ContentView.voiceCardBottomInset` is **132/72** (was 204/146) —
    these are the plan's values and have NOT had a visual pass on
    device/simulator yet; if the shortcut bar crowds the PTT row, tune
    these first. The context sheet (`ContextSheetView` + Core
    `State/ContextProfiles.swift`) keys off the Mac's frontmost app
    (`CaptureEngine.frontmostMacApp` from `IBAppList.isActive`):
    Keynote/PowerPoint → presentation suite, terminals + VSCode/Cursor
    → agent suite, everything else → console (fallback). Sheet actions
    are either KeyEvent replays or `systemCommand` (0x19) frames —
    volume/brightness/media step via system-defined CGEvents,
    `launchApp`/`openURL` via NSWorkspace
    (`RemoteCrabReceiver/SystemCommandHandler.swift`); lock screen is
    deliberately a ⌃⌘Q KeyEvent chord from the iOS side, not a
    systemCommand. AWDL peer-to-peer is enabled at BOTH ends (iOS
    `NWListener.includePeerToPeer = true`; Mac browser + outbound dials
    via `ReceiverSession.tcpParameters()`, Preferences toggle
`remotecrab.mac.peerToPeer` default true). V1.2 shipped the context-sheet
expansion (10 suites, `Codable` profiles, row pairing) and V1.3 the
trackpad scroll-feel pass + connection resilience — the V1.4 backlog
(action-label localization, bidirectional discovery, connection doctor)
is tracked in the Roadmap section — don't duplicate it here.

38. **System-defined (media key) CGEvents: `data1 = (key << 16) | flags`,
    NOT `(key << 16) | (flags << 8)` (2026-09-22, real-device catch).**
    V1.1 shipped the console suite's volume/mute/brightness buttons with
    the flags byte shifted twice (`0xA00 << 8 = 0xA0000`) — WindowServer
    decodes that as "key 10, no state" and drops the event silently, so
    every media button did nothing on device with zero errors anywhere.
    The pure encoder now lives in
    `RemoteCrabCore/Input/SystemKeyEncoder.swift` with regression tests
    (`SystemKeyEncoderTests`); verify empirically with
    `osascript -e 'output volume of (get volume settings)'` before/after
    when touching this path. Same device pass: the app switcher only
    listed on-screen `SCWindow`s, so minimized / hidden / other-Space
    apps vanished entirely (and a stale comment claimed they "still
    appear") — `WindowCapture.buildList` now merges
    `appLevelEntries()` for any regular app with no listed window, so
    the picker always shows every running Dock app. Also: shortcut rows
    lead with ⏎/⌫ (post-dictation "send"/"edit" is the most common
    reach) and context-sheet buttons fire a light haptic on tap.

39. **A Liquid-Glass background does NOT create a hit area — every glass
    button needs an explicit `.contentShape` (2026-09-22, real-device).**
    `IBMaterial.glass/bar` renders `shape.fill(.clear).glassEffect(...)`:
    the `.fill(.clear)` is transparent (no hit test) and the glass layer
    doesn't contribute either, so a button whose only content is a small
    SF Symbol ends up with a ~16 pt tap target — it reads as "the button
    is covered / the tap area is tiny". The top-bar icons always worked
    because `topBarIcon` callers add `.contentShape(Circle())`; the
    bottom ⌨️ toggle, `quickKey`/`shortcutKey`, the context chip,
    `IBModifierBar`, and the context-sheet cards had all been missed.
    **Rule: any Button whose background is `IBMaterial.*` must add
    `.contentShape(<same shape>)`.** Solid `.fill(Color…)` backgrounds
    (e.g. `shortcutKey`'s non-prominent state) are fine.

40. **Only ONE row may anchor itself above the system keyboard
    (2026-09-22).** In keyboard mode both `KeyboardScreen`'s shortcut bar
    (padded by `keyboardHeight`) and `ContentView`'s PTT row (pushed up by
    SwiftUI keyboard avoidance) landed in the same band, so the blue ⌨️
    toggle covered the context chip and ⏎. Fix: `ContentView` does not
    render `pttRow` while `activeSurface == .keyboard` — that surface
    already has a "back to trackpad" button in its header. If a bottom
    control must exist in keyboard mode, it belongs INSIDE KeyboardScreen's
    layout, not as a ContentView overlay.

41. **Multi-file sends MUST be serialized — the wire has no per-file
    stream id (2026-09-22).** `fileOffer → raw fileChunk* → fileComplete`
    carries one transfer at a time; two concurrent sends interleave chunk
    frames and corrupt both. `RemoteCrabCore/Transfer/SerialFileSender.swift`
    (an actor, unit-tested) chains enqueued URLs so the next starts only
    after the previous finishes; `CaptureEngine.sendFiles(at:)` routes
    through it and `sendFile(at:)` is now a one-element enqueue. The Mac
    coalesces the Finder reveal (`scheduleReveal`, 700 ms quiet window) so
    a 10-file send activates Finder once, not ten times. E2E:
    `REMOTECRAB_E2E_SEND_FILE=<N>` sends N generated files (N>1 exercises
    the queue).

42. **"Latest Screenshot" reads the photo library, so it needs a Photos
    permission (2026-09-22).** `NSPhotoLibraryUsageDescription` lives in
    `project-ios.yml` (xcodegen is the source of truth) and the read
    prompt is requested in onboarding (`PermissionFlow.Stage.photos`,
    `.limited` counts as granted) with a lazy fallback on first use.
    Selection logic is pure + tested in
    `RemoteCrabCore/Transfer/ScreenshotPicker.swift`; the Photos plumbing
    is `RemoteCrabCapture/LatestScreenshot.swift`. **Trap:**
    `PHAsset.mediaSubtypes` is plural in Swift, but the
    `PHFetchOptions.predicate` KVC key is singular `mediaSubtype` —
    `NSPredicate(format: "(mediaSubtype & %d) != 0", …)`.

43. **Context profiles are `Codable` + self-describing on purpose
    (2026-09-22).** `ContextProfile` carries `id`/`title`/`bundleIDs`/
    `actions` and round-trips through JSON (`ContextProfilesTests`), so a
    future plugin marketplace can ship developer-authored suites as data;
    nothing remote is loaded yet. `ContextProfiles.all` is the built-in
    registry (first-match-wins on `bundleIDs`), `console` is the fallback.
    **The sheet lays grid actions out two-per-row, so related controls
    must be ADJACENT (first at an even index)** — that pairing is a tested
    invariant (`testConsolePairsRelatedActionsInRows`); reorder profiles
    with that in mind. The voice hero is rendered full-width above the
    grid (a two-column cell would clip the capsule).

44. **The Mac receiver is NOT sandboxed — the sandbox silently broke
    "Quit" (2026-09-22).** `NSRunningApplication.terminate()` /
    `forceTerminate()` return **false** under the App Sandbox (it forbids
    signalling other processes), so the window picker's Quit did nothing
    with zero errors — the wire and dispatch were fine all along. The
    Mac app ships via Developer ID (not the Mac App Store), so the
    sandbox is optional; `RemoteCrabReceiver.entitlements` now keeps only
    `system-extension.install` + the app group. **Consequence:** dropping
    the sandbox moves `UserDefaults` out of the app container to
    `~/Library/Preferences/<bundle-id>.plist`, orphaning the paired-Mac
    tokens and settings — `SandboxDefaultsMigration` copies them across
    on first launch, and `remotecrab.mac.id` must be carried over too
    (a fresh id makes the iPhone treat the Mac as a stranger → `busy`).
    `defaults read <bundle-id>` still resolves to the container while it
    exists — edit `~/Library/Preferences/…plist` directly to inspect it.

45. **The Mac now dials ANY discovered iPhone (2026-09-22).** It used to
    dial only phones it held a token for; after a reinstall / settings
    migration / Mac-id change the token was gone and the Mac silently
    refused to dial (`discovered 1 phone(s); connection==nil: true` and
    nothing after), leaving the user stuck on "waiting". Now it prefers a
    token-matched phone and otherwise dials the first discovered one — the
    iPhone gates access itself (`accepted` / `pending` / `busy`), so an
    unknown Mac shows the iPhone's approval card instead of a dead end.

46. **A silent owner must not hold the session forever (2026-09-22).**
    A half-open socket (Wi-Fi drop, frozen/suspended Mac) stays
    `NWConnection.state == .ready` and never fires `.failed`, so the
    iPhone kept answering every other Mac `busy`. Now the iPhone runs an
    owner watchdog: the Mac pings every 2 s, so **10 s of silence**
    releases the session (verified by `kill -STOP`-ing the receiver — the
    iPhone reset the connection at ~13 s). The Mac mirrors it: **8 s
    without a pong** in the ping loop cancels the link so reconnect
    starts in seconds.

47. **The window picker drops an app the moment it quits (2026-09-22).**
    Quitting from the picker left a stale card. Now `CaptureEngine
    .quitMacApp` removes the app's cards optimistically and the Mac
    republishes the window list after the quit; `didTerminateApplication`
    also refreshes it — but only if the iPhone asked for the list in the
    last 30 s (`lastWindowListRequestAt`), so an app quitting in the
    background doesn't trigger a full ScreenCaptureKit pass.

48. **A half-open dial wedged the Mac forever — add a handshake timeout
    (2026-09-23).** This is the recurring "can't connect". Symptom:
    `discovered 1 phone(s); connection==nil: false` and then silence —
    the Mac holds a connection that reached TCP `.ready` and sent
    `clientHello` but never got a `sessionReply` (phone backgrounded
    mid-handshake). `handleDiscovered` only dials when `connection ==
    nil` or the state is `.connecting`, so a stuck `.handshaking` never
    re-dials. Direct-IP dials had an 8 s timeout; Bonjour dials had none.
    Fix: a 6 s timeout abandons a `.handshaking` connection and
    reconnects — deliberately NOT firing on `.awaitingApproval`, since a
    `pending` reply is a legitimate wait for the user's tap. Verified on
    device: `no sessionReply after 6s — abandoning the handshake` →
    `sessionReply: accepted` on the retry.

49. **The app now stays alive in the background (2026-09-23, supersedes
    lesson 36).** `project-ios.yml` gained `UIBackgroundModes: [audio]`
    and `BackgroundKeepAlive` holds a `.playback` + `.mixWithOthers`
    session playing 1 s of silence while the app is serving
    (`startStreaming` → `stopStreaming`). Without it iOS suspends the
    app the moment it backgrounds or the screen locks, tearing down the
    Bonjour listener so the Mac can never connect — the #1 "can't
    connect" report. `.playback` (not `.playAndRecord`) is deliberate:
    it does NOT suppress the app's haptics (lesson 25) and doesn't
    interrupt the user's music. `MicrophoneEncoder.stop()` /
    `VoiceRecognizer` call `BackgroundKeepAlive.restoreAfterRecording()`
    instead of `setActive(false)` so the mic toggling off doesn't kill
    the keep-alive. Setting: Settings → Input → "Stay connected in the
    background" (default on). **Camera still stops in the background**
    (platform limitation, lesson 22) — only the connection survives.
    App Review note: background audio is justified by the mic stream;
    the setting gives users an off switch.

50. **Declaring `UIBackgroundModes: [audio]` breaks a `.playAndRecord`
    mic — use `.record`, and keep the capture session off the audio
    session (2026-09-23).** Adding the background mode made the mic's
    `AVAudioSession` activation fail with **"Session activation failed"
    (561017449, `'!pri'`)** and e2e lost audio while video/touch looked
    fine. Two causes, both fixed:
    (a) `configureCaptureSession` added an `AVCaptureDeviceInput(audio)`
    that **nothing consumed** (there is no `AVCaptureAudioDataOutput`) —
    it made `AVCaptureSession` manage the app's audio session and fight
    `MicrophoneEncoder`. Removed it and set
    `automaticallyConfiguresApplicationAudioSession = false`.
    (b) The mic activated `.playAndRecord`; with the background mode
    declared iOS rejects that activation. It now uses `.record` (the mic
    only records; `VoiceRecognizer` always used `.record` too).
    Isolation method that settled it: run the e2e with the keep-alive
    forced off, and with `UIBackgroundModes` removed, to separate the
    three variables. With the mode present the app is NOT suspended when
    backgrounded, so the connection survives (verified 90 s: camera goes
    `camera=false` on background while `published 5 apps to iPhone`
    keeps flowing and the TCP stays ESTABLISHED); only the camera still
    stops, by design.
    **Keep-alive vs mic are mutually exclusive**: `applyKeepAlive()`
    only runs when neither `micOn` nor `voiceOn`, and `syncMicrophone`
    fully deactivates the keep-alive session before the mic
    reconfigures (leaving it active in `.playback` makes the switch fail).

51. **`contentShape` belongs INSIDE the button style, not on the Button
    (2026-09-23).** Lesson 39 added `.contentShape(...)` to individual
    buttons; the context-sheet cards still had a dead trailing half
    because a **custom `ButtonStyle` hit-tests the label's content
    shape**, not the outer button bounds — and a glass card's fill is
    transparent, so only the left-aligned icon+text was tappable.
    Fixed once for all: `IBPressButtonStyle` and `GlassPressButtonStyle`
    now apply `.contentShape(Rectangle())` to `configuration.label`, so
    every button using them hit-tests its full bounds. Prefer fixing hit
    areas in the style over per-view `contentShape`.

52. **Context-sheet suites: verify shortcuts against the real menu, and
    keep grid actions even (2026-09-23).** The registry is now 17 suites
    (`presentation, agent, finder, notes, browser, mail, messages,
    calendar, xcode, editor, text, media, chat, meeting, image,
    notebook, console`). Two rules learned:
    (a) **Read the app's actual menu bar with AppleScript** before writing
    a binding — walk `menu bar item` → `menu item`, read
    `AXMenuItemCmdChar` + `AXMenuItemCmdModifiers` (0 = ⌘, 1 = ⇧, 2 = ⌥,
    4 = ⌃, 8 = no-command). That caught three wrong bindings: Mail
    Delete is ⌘⌫, Messages Send is ⌘⏎, and Notes' menu delete is a bare
    ⌫ (ambiguous while editing, replaced with ⇧⌘N New Folder). Electron
    apps (VSCode/Discord/Lark) don't expose menus to AX — use the
    vendor's docs for those.
    (b) **`⌘B` is app-specific**: build in Xcode, bold in TextEdit,
    *toggle sidebar* in VSCode — hence three separate suites (`xcode`,
    `editor`, `text`) rather than one. The sheet's grid is two columns,
    so each suite must have an EVEN grid-action count (tested), and
    related controls must be adjacent (same row).

53. **App Store rejection 1.0 (2026-09-24) — three fixes, all in-app.**
    (a) **2.1(a) crash on the speech permission prompt**: the crash log is
    `_dispatch_assert_queue_fail → swift_task_checkIsolated → TCC
    __TCCAccessRequest_block_invoke`. TCC answers on a *private XPC queue*,
    and `PermissionFlow` is a SwiftUI View (implicitly @MainActor) — resuming
    its `withCheckedContinuation` from there traps (SIGTRAP). Fix: make every
    permission probe `nonisolated static` (camera/mic happen to call back on
    main; Speech's does not). This is the same class as lesson 2.
    (b) **5.1.1 permission UX**: the pre-permission card's button must not say
    "Allow" (use "Continue") and must not offer "Not now" — the user always
    proceeds to the system request.
    (c) **5.2.5 "Mac" trademark**: Apple flagged "Mac" in the name/subtitle.
    It is the *user-visible copy* that matters, so sweep ALL of it — the app
    catalog **values** (not just keys), `project-ios.yml` **Info.plist usage
    descriptions** (shown in the system dialogs — easy to miss),
    `scripts/ios-metadata.json`, the **website** copy, AND the **screenshot
    composer's own title strings** (`compose-asc-screenshots.py` paints them
    INTO the PNGs, so the reviewer sees them). Use "computer"/"电脑".

54. **ASC screenshot uploads fail intermittently with
    `SSL: UNEXPECTED_EOF_WHILE_READING` (2026-09-24).** Apple's API + the
    pre-signed upload host drop the TLS connection under a burst of calls.
    curl and single Python calls are fine, so it looks like rate limiting.
    Fix: retry with backoff and a FRESH `ssl.create_default_context()` on
    every call — in `ios-app-store-metadata.py` BOTH the `request()` helper
    AND the raw chunk `urlopen` to the pre-signed URL (the latter is easy to
    forget; it blocked uploads on its own). Also: `ExportOptions.plist` must
    be `method: app-store-connect`; a leftover `debugging` produces a
    dev-signed IPA that ASC rejects with `90161 Invalid Provisioning Profile`.

55. **The Labs features are two-step and were never device-tested
    (2026-09-24).** Settings → Labs only enables them; the user must ALSO tap
    the lab button that then appears at the bottom of the trackpad
    (`TouchpadScreen` shows it when `remotecrab.ios.labAirMouse` /
    `labWheelScroll` is on) to ARM air-mouse/wheel. Air mouse uses
    `CMMotionManager` (no simulator gyro), wheel uses an angle-around-origin
    recognizer — neither is covered by `e2e-device.sh`, so treat them as
    unverified.

56. **Haptics vs the silent switch vs "System Haptics" (2026-09-24).**
    `UIImpactFeedbackGenerator` plays **only when Settings → Sounds & Haptics
    → System Haptics is ON**, and it is NOT affected by the ringer/silent
    switch. `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` DOES respect
    the silent switch (vibrates only if "Vibrate on Silent" is on). So a
    device with System Haptics OFF feels nothing from generators and only
    feels the fallback when not silenced — which reads as "Normal level does
    nothing but Strong works". Fix: EVERY non-Off level also plays
    `kSystemSoundID_Vibrate` (graded generator + guaranteed buzz); Off = none.
    Also check Accessibility → Touch → Vibration and Low Power Mode.

57. **A control must never toggle the flag that gates its own visibility
    (2026-09-24).** The Labs wheel button was rendered `if labWheelScroll`
    and its tap set `labWheelScroll = false` — so tapping it deleted itself
    from the row ("图标点一下就消失"). Rule: visibility is driven by a
    *config* flag; the control toggles a separate *session* flag
    (`wheelInlineOn`). Same shape as the modifier-key lesson (state that
    outlives the gesture).

58. **Labs are two-step + inline-wheel design (2026-09-24).** Settings → Labs
    only *enables* a feature; air mouse ALSO needs the gyroscope button on
    the trackpad tapped (it must be tap-to-toggle — a `DragGesture` momentary
    hold made it impossible to hold the button AND tilt the phone). Air mouse
    needs `NSMotionUsageDescription` in `project-ios.yml` or CMMotionManager
    silently delivers nothing (iOS 17+). Wheel scrolling is now INLINE: it
    classifies a gesture as a wheel only after ~120° of turn around the
    touch-down point, otherwise the finger moves the cursor as usual (no
    mode, nothing gets swallowed); its trackpad button is a session on/off.
    Air-mouse `tiltGain` is `0.10/π` (was `0.35/π`, ~2900px/s — far too fast).

59. **The Mac picker listed the connected Mac twice (2026-09-24).** The
    sheet renders `preferred` / `session` (current owner) / `paired`
    (allow-list); the connected Mac appeared in the session row AND the
    paired row. Filter the paired list by `id != connectedMacId &&
    name != pendingMacName`.

60. **This session's later device-pass fixes (2026-09-24).** Voice: interim
    typing is APPEND-ONLY of the STABLE prefix (never delete, never
    duplicate); the voice-command path no longer erases the hold. Modifier
    keys: a locked modifier emits a REAL key down (unlock = up), and the
    Mac injector sends modified `.text` as real keycodes + `flagsChanged`
    with device-dependent bits from its own `CGEventSource`. Selection: a
    drag end shows a Copy/Cut/Paste/Select-All bar. Context sheet: system
    keys always pinned below the app keys. All verified with the
    `REMOTECRAB_E2E_VOICE` / `REMOTECRAB_E2E_MODIFIER` hooks + e2e 10/10.

61. **Voice "sudden disconnect" on pauses + long holds (2026-09-24, real-device
    traced).** The old symptom — "说完一句、停顿、说第二句就断/必须重按" — was
    THREE separate bugs, found by writing voice lifecycle markers through
    `Forensic.log` (pull `Documents/forensic.log`) because `idevicesyslog`
    can't see the device and `os_log` doesn't reach the Mac's log store:
    (a) **every mid-hold `kAFAssistantErrorDomain` error tore the session
    down** (203 = the ~1 min cap, 1110 = silence, 1101/1107/216 = transient),
    even though they're routine — `VoiceRecognizer.recoverFromError` now
    commits + quietly restarts the task on the same audio engine, giving up
    (→ `onInterrupted`) only after 5 *rapid* failures; plus a task-identity
    guard (`sessionGeneration`) so a superseded task's late cancellation
    error can't kill the fresh one, and `AVAudioSession.interruptionNotification`
    handling so a call/Siri doesn't end the hold.
    (b) **The on-device recognizer DISCARDS its transcript on a pause (iOS 18)
    and starts the next utterance from ""** — `result.speechRecognitionMetadata != nil`
    marks the closed segment; `VoiceRecognizer` folds each closed segment into
    `committedText` so `onPartial` only ever GROWS (a shrinking string stalled
    CaptureEngine's prefix typing). `onPartial` now carries the committed
    prefix LENGTH.
    (c) **Typing must be tail-only** — macOS keystrokes only land at the
    cursor, so `TextDiff.events(from:to:)`'s common-suffix optimisation is
    invalid (it edits the middle); added `TextDiff.tailEvents` (backspace the
    changed tail, retype it, tested). `CaptureEngine` types the finalized
    prefix + the one-update-stable live prefix live (append-only, no
    mid-sentence deletes) and does ONE exact tail reconcile per segment
    boundary and at release, so a pause never loses or duplicates chars.
    `beginVoiceSession()` resets the trackers each hold so an interrupted
    session can't make the next one backspace the previous text.
    (d) **Long holds degrade**: the on-device recognizer goes sparse/drops
    results after ~30-40 s and hard-caps at ~1 min. `VoiceRecognizer` now
    **proactively rolls the task at a natural segment boundary once it is
    >20 s old** (commit + fresh task, `throttled` 180 ms so the recognizer
    releases the old task — an immediate recreate used to fail and cascade).
    Verified on device: 2 rollovers over a 58 s hold, all reconciles forward
    (zero backspaces) → no loss. The voice card also shows the recent TAIL
    (`…` prefix) instead of truncating the head to "…".
    **Do NOT log recognized speech to forensic.log** — an early instrumented
    build wrote `«the text»` into it; the committed logs carry counts only.

62. **Camera now remembers the user's choice (2026-09-24).** `FeatureStore.cameraOn`
    still defaults OFF on a fresh install, but `CaptureEngine.setCameraEnabled(_:)`
    persists explicit UI toggles to `remotecrab.ios.cameraOn` and restores them
    at startup (`restoreStreamHabits`). Automatic offs — backgrounding,
    disconnect, `REMOTECRAB_AUTOSTREAM` — go through `features.set` directly and
    must NOT overwrite the habit. Deliberately **camera-only**: restoring `micOn`
    would start recording the moment the app launches (privacy / App-Review
    risk). The UI toggles (top-bar cam/mic, the camera-off "turn on" button)
    route through these helpers.

63. **iOS 26 SpeechAnalyzer compatibility layer (2026-09-24).** Voice now has
    two backends behind a `VoiceEngine` protocol, chosen at `start()` and
    **never** requiring a download:
    - `VoiceEngineSelector` (`RemoteCrabCore/Input/`, pure + unit-tested)
      returns `.analyzer` only when `#available(iOS 26)` AND
      `SpeechTranscriber.isAvailable` AND a model for `zh-Hans`/`en-US` is
      **already installed** (`installedLocales`), else `.legacy`.
    - `AnalyzerVoiceEngine` (`@available(iOS 26)`) wraps `SpeechAnalyzer` +
      `SpeechTranscriber(preset: .progressiveTranscription)`. Its result
      model maps 1:1 onto ours: `result.isFinal` → append to committed,
      volatile → the live tail, emitted as `onPartial(full, committed)`.
      It has **no ~1 min cap**, so iOS 26 skips the `proactiveRollover`.
      Audio: mic tap → `AVAudioConverter` → `AnalyzerInput` yielded into an
      `AsyncStream`; finish with `finalizeAndFinishThroughEndOfInput()`.
    - `VoiceRecognizer`'s public API is unchanged (UI/`CaptureEngine`
      untouched): it tries the analyzer engine, and silently falls back to
      the legacy `SFSpeechRecognizer` path if it's unavailable or `start()`
      fails. **Old OS/device = today's behaviour, zero change.**
    **The model is NOT preinstalled with iOS** but is downloaded on demand,
    shared system-wide, and stored outside the app bundle — many devices
    (Notes / Apple Intelligence use it) already have it, which is why we
    only *read* `installedLocales` and never prompt. Do not add a download
    flow without revisiting App Review (undisclosed-download rejection).
    v1 trade-off: the analyzer path ends the hold on an audio interruption
    (the legacy path auto-resumes); revisit if it matters.
    **Locale-equivalence gotcha (cost a device cycle):** the installed
    asset reports as `zh-CN` while we asked for `zh-Hans` — equivalent but
    NOT string-equal, so a naive match silently fell back to legacy forever.
    Always canonicalize the desired locale through
    `SpeechTranscriber.supportedLocale(equivalentTo:)` before matching
    `installedLocales`. Verified on iPhone 14 / iOS 26 (installed
    `["zh-CN","zh-TW"]`) → `engine=analyzer`, ~45 s real dictation typed
    append-only (reconciles 46→48 … 165→166, zero backspaces).
    New files: `RemoteCrabCapture/VoiceEngine.swift`,
    `RemoteCrabCapture/AnalyzerVoiceEngine.swift`,
    `RemoteCrabCore/Sources/RemoteCrabCore/Input/VoiceEngineSelector.swift`.
    **`xcodegen generate --spec project-ios.yml` is required after adding
    files** — a stale `.xcodeproj` fails with "cannot find type in scope".

64. **App screen mirror (branch `feature/screen-mirror`, 2026-09-25).** The
    iPhone can mirror the Mac's **frontmost app window** live and interact
    with it directly. Mac side: `RemoteCrabReceiver/ScreenStreamer.swift` —
    resolves the frontmost app's frontmost eligible window
    (`ScreenTargetResolver`, pure), follows `NSWorkspace` activation changes
    (300 ms debounce), captures with `SCStream` (`desktopIndependentWindow`,
    Retina scale capped at 2560 px, 1/30, `queueDepth 2`, cursor shown),
    H.264 hardware-encodes (reuses the camera encoder's session-invalidation
    fix), and sends `screenSPS/PPS/video` + `screenInfo`. iOS side:
    `ScreenDecoder.swift` (VTDecompressionSession → `AVSampleBufferDisplayLayer`)
    + `ScreenShareView.swift` (UIKit gesture overlay: 1-finger tap=absolute
    click, 1-finger drag=drag, long-press/two-finger tap=right click,
    2-finger drag=pan-first-then-scroll, pinch=local zoom) driven entirely by
    the pure `RemoteCrabCore/Screen/ScreenZoomState.swift`. New top-bar
    `rectangle.on.rectangle` toggle enters the `.screen` surface; touches are
    mapped to normalized window `(u,v)` so the Mac never learns the phone's
    zoom/pan state. Window-picker thumbnails were also improved (960 px JPEG
    @ 0.72, parallel `withTaskGroup` ≤4). **Requires Screen Recording** on the
    Mac (already requested for thumbnails); `screenInfo.status` reports
     `permissionDenied` / `noWindow`. E2E:
    `REMOTECRAB_E2E_SCREEN=1`. 181 tests green + both apps build.

65. **Screen mirror device debugging + polish (2026-09-25).** Three real
    bugs and a batch of UX gaps, all found/fixed on-device:
    (a) **Taps did nothing** — `inject(screenInput:...)` was declared only
    in an `InputInjector` *extension*, so a call on `any InputInjector`
    dispatched **statically to the no-op default** and `CGEventInjector`
    was never invoked. A protocol-extension method is NOT dynamically
    dispatched unless it is a protocol *requirement* — it is now, and
    `RecordingInputInjector` records it (tested).
    (b) **Clicks landed in the wrong place** — `SCStreamFrameInfo.contentRect`
    is in the **window's own coordinate space** (origin `(0,0)` for every
    app observed), and the code overwrote the window's **global** origin
    with it, mapping `(u,v)` near the screen corner. The global origin now
    comes from `CGWindowList` (`refreshTargetFrame`), re-read when the
    content rect changes and every 1 s; `contentRect` is only a change
    trigger. Verified on device: window at `(270,136)`, click at
    `u=v=0.5` → `global 719,360`.
    (c) **Voice dictation got laggy / dropped words with the mirror on** —
    the phone was simultaneously camera-encoding 1080p@30, decoding the
    mirror (~2.6K@30) and running on-device speech recognition (decode was
    already off the main actor, so it was CPU/GPU contention, not a stall).
    Mirror cost cut to 1920 long edge / 24 fps / 3 Mbps and
    `AVSampleBufferDisplayLayer.enqueue` moved off the main actor into the
    decoder queue.
    (d) **Polish batch**: mirror modifier bar (`IBModifierBar`, mask on
    every input + real modifier key down/up), double/triple-click
    (`IBScreenInput.clickCount` → `mouseEventClickState`), fit/fill toggle +
    anchored double-tap zoom (`ScreenZoomState.fillsView` /
    `setZoom(_:anchor:)` / `toggleZoom(at:)`), device-aware pixel cap
    (`IBScreenControl.maxPixel`: iPad 2560 / iPhone 1920), mirror window
    picker + **pin** (`.select`/`.follow`; `ScreenStreamer` stops following
    the frontmost app while pinned), background privacy cover, and a
    first-use coach mark. Keyboard opened from the mirror is a translucent
    overlay that returns to the mirror (not the trackpad).
    **Deferred** (need design/hardware): Apple Pencil passthrough, iPad
    hardware-keyboard passthrough, auto-keyboard on text-field focus,
    multi-display mapping, DRM-black detection, motion-adaptive fps.
    186 tests green + both apps build; base mirror device e2e 16/16.

66. **Pointer acceleration was silently dead + one shared shortcut bar
    (2026-09-25).** Two follow-ups from iPad testing:
    (a) **"No acceleration, several swipes to cross the screen"** — the
    trackpad's `TrackpadMath.accelerate` computed its boost from the
    *per-event* delta (a touch-move carries a few points), so
    `1 + min(delta*6, maxBoost)` was ~1 almost always and acceleration
    never engaged. It now takes a `pointerSpeed` (normalized units/second,
    from `UIPanGestureRecognizer.velocity`) and ramps up to 2.5×; slow
    drags stay precise, fast flicks travel far. `TouchSurface.handleSinglePan`
    passes the velocity. The mirror is **strictly on-demand**: leaving the
    `.screen` surface calls `stopScreenMirror()` (except the keyboard opened
    *from* the mirror), so it costs nothing when unused. The mirror's
    bottom bar was a bespoke two-row, non-scrolling thing — replaced by
    `RemoteCrabCore/Components/IBShortcutBar.swift` (pinned frontmost-app
    context chip + ONE horizontally-scrollable key row + inline modifier
    bar + `,`/`.`), now shared by the trackpad and the mirror so both have
    the same bar and the same context-sheet (情景模式) entry. 186 tests green.
    Network gotcha seen while e2e-ing: the Mac had a **VPN/proxy**
    (`utun4 = 198.18.0.1`) up, and `dns-sd -B _remotecrab._tcp` showed zero
    services — the lesson-20 Bonjour killer. Also, **more than one device
    advertising matters**: the Mac dials the first discovered phone (it
    connected to a leftover iPad Simulator once), so quit the other device's
    app (and shut simulators) before a single-device e2e.

67. **The recording e2e failure was a Mac H264 decoder deadlock, not the
    recorder (2026-09-26).** The last red device-e2e assertion was
    "recording written to ~/Movies/RemoteCrab"; the recorder logs showed
    only `recording armed` + `toggled`, never `saved`/`failed`, i.e.
    `stop()` hit its `writer == nil` early-return. That is a *symptom*:
    `writer` was nil because `appendVideo` never ran — the decoder emitted
    **zero** frames (`first frame decoded OK` was absent from the whole
    log, and `video frames received:` counts *wire* frames, NOT emitted
    images — the key trap that misled the first diagnosis). Three stacked
    causes, all in `H264Decoder`:
    (a) **The iPhone stream's first wire frame is a non-IDR P-slice**
    (the encoder drops capture frame 1, so its first output references a
    frame the Mac never saw). Feeding it makes VideoToolbox return
    `kVTVideoDecoderMalfunctionErr` (`-12909`).
    (b) **`handleMalfunction` called `VTDecompressionSessionInvalidate`
    from inside the VT decode callback — that DEADLOCKS.** The log proves
    it: `decoder malfunction — rebuilding session (1)` was the last
    H264Decoder line; `tryCreateSession()` (which logs on entry) never
    ran. The decoder was dead for the rest of the session. Never tear a
    codec session down from its own callback; hand it to the serial
    `queue` (`markNeedsRebuild` → `rebuildSession`).
    (c) Feeding **SEI/AUD/parameter-set NALs** as samples also trips
    `-12909` (the iOS encoder already drops them; a stray/old peer
    wouldn't). The pure `H264FrameGate` (`RemoteCrabCore/Input/`,
    unit-tested) accepts VCL slices only and drops P-slices until the
    first keyframe, so the stream never triggers (a) at all; `rebuildSession`
    stays as the fallback. `feedSPS`/`feedPPS` now no-op when the parameter
    set is unchanged (the iOS encoder re-sends SPS/PPS with every keyframe,
    which used to invalidate+recreate the session ~once a second).
    **Debug method that cracked it (reusable):** a hardware-free harness
    that extracts SPS/PPS + AVCC NALs from an existing `~/Movies/RemoteCrab/
    *.mov` (`AVAssetReader`, `outputSettings: nil`), strips H264Decoder's
    `import RemoteCrabCore`, compiles it with a `main.swift`, and replays
    controlled sequences (IDR-first, P-before-IDR, SEI-first, corrupt-slice
    then recover). `os_log` from a CLI is only visible via `/usr/bin/log`
    (zsh shadows `log` with a math builtin!). Result: device e2e 16/16,
    recording is real H.264 1080x1920 + AAC. Also this pass hardened
    `StreamRecorder` (`AVAssetWriter` create/canAdd failures are logged;
    "recording saved" only when the writer actually completed).

68. **Windows parity round 2 + a cross-compile check that actually compiles
    the Windows code (2026-09-26).** Two things:
    (a) **The macOS `cargo check`/`clippy` never type-checks the Windows
    receiver.** Every real Win32 module is `#[cfg(windows)]` (`rc-os::apps`,
    `clipboard`, `windows`, and the `#[cfg(windows)]` arms in
    `rc-app/main.rs`), so on the Mac they are simply excluded — a latent
    compile error (`TerminateProcess(...).as_bool()` on a
    `windows::core::Result`, not a `BOOL`) shipped in the activate/quit
    commit and only surfaced when cross-checked. To actually validate:
    `brew install mingw-w64`, `rustup target add x86_64-pc-windows-gnu`, then
    `cargo check`/`clippy --target x86_64-pc-windows-gnu --workspace`
    (the msvc target can't build OpenH264 from macOS; the GNU target can,
    once mingw is present). The **runtime** paths still need a real Windows
    box — the user runs that.
    (b) **Windows data-plane parity**: `activateApp`/`quitApp` were being
    dropped (fixed — see the activate/quit + feature-control commit);
    `windowListRequest` (0x17) was unhandled, so the iPhone's window-based
    `AppSwitcherView` (it renders `engine.macWindows`, NOT `macApps`) was
    always empty. `rc-os::windows::build_window_list` now enumerates
    top-level windows (`PrintWindow` + `PW_RENDERFULLCONTENT` for
    GPU-composited ones) and returns a JPEG thumbnail per window via the
    pure, unit-tested `rc-os::thumbnail::encode_bgra_jpeg` (box-downscale →
    `jpeg-encoder`); window `id` is `"<pid>:<hwnd>"` (the iPhone keeps only
    ids containing `:`) and `app_id` is `"pid:<pid>"` to match the app list.
    `activateApp` now also matches the tapped card's `windowTitle`. The PC
    clipboard can be pushed to the iPhone with the `clipboard` console
    command (`clipboardSet` 0x13 was receive-only before). And the iOS app
    now hides its mirror button while `connectedIsWindows` (that receiver
    has no window-capture path, so the button only ever dead-ended) —
    `CaptureEngine.startScreenMirror()` guards the other entry points too.
    **Recording**: the new pure crate `rc-record` (`--record` / console
    `record`) muxes the iPhone's own H.264 into an MP4 (passthrough, no
    re-encode) + a PCM WAV sidecar (the `mp4` crate only muxes AAC and the
    project refuses an FFI AAC encoder) under
    `%USERPROFILE%\Videos\RemoteCrab`; unit-tested on the host. **AWDL**:
    Windows cannot do Apple Wireless Direct Link (proprietary Apple link
    layer; `includePeerToPeer` is Apple-only; OWL targets Linux) — the
    router-less paths are the iPhone Personal Hotspot / USB tethering, which
    the direct-IP fallback already covers (`HOTSPOT_GATEWAY 172.20.10.1` +
    last-IP + `/24` sweep). **App-window mirror**: `rc-protocol` now has the
    `ScreenControl`/`ScreenInput`/`ScreenInfo` structs + codecs (tested) and
    `rc-net` dispatches `screenControl`/`screenInput`; the new `rc-mirror`
    crate captures the target window (`PrintWindow` + `PW_RENDERFULLCONTENT`),
    H.264-encodes it with OpenH264, and `rc-app` streams
    `screenSps`/`screenPps`/`screenVideo` + `screenInfo` from a dedicated
    thread (input is mapped via `rc-input`'s absolute `screen_actions`).
    Because Windows now supports it, the iOS mirror button is **no longer
    hidden** for `connectedIsWindows`. **Switcher quick destinations**
    (2026-09-26, both receivers): the switcher's top row now has **Desktop**
    — a new `IBSystemCommand.showDesktop` (0x19) kind; the Mac hides every
    other regular app then activates Finder (hiding is what uncovers it;
    activating Finder alone only raises a Finder window), Windows sends
    Win+D — and **Open app…**, a searchable installed-app launcher on a new
    frame pair (`installedAppsRequest` 0x20 / `installedApps` 0x21):
    `InstalledApp.id` carries exactly what `launchApp` wants as its argument
    (bundle id on the Mac — `InstalledAppsCatalog` scans /Applications
    (+Utilities), /System/Applications, CoreServices and ~/Applications,
    deduped by bundle id — Start Menu `.lnk` path on Windows, so
    `ShellExecuteW` handles it). **Tray + real app icons** (2026-09-26,
    both the P2 experience gap and the switcher's fallback icons):
    `rc-app` puts an icon in the notification area (`Shell_NotifyIconW` +
    a message-only window on a dedicated thread; every menu pick routes
    through a channel to the app's `select!` loop — the tray thread owns
    nothing) and its menu mirrors the Mac menu-bar popover's structure and
    wording (`State::pill_label`/`phone_name`/`pill_latency_ms` for the
    status row; the SAME four toggles the Mac shows — camera/mic/trackpad/
    keyboard — then Start/Stop Recording, Send Clipboard to iPhone,
    Reconnect, Disconnect, Quit; `--no-tray` skips it). `build_app_list`
    now renders each process's 48 px icon (`SHGetFileInfoW` → `DrawIconEx`
    into a 32-bit DIB → RGBA → PNG in the pure, tested `rc-os::icon`),
    cached per exe path — the same fill the Mac does on the explicit
    `appListRequest`. **Still open on Windows**: virtual mic (see
    the blueprint below) and the self-drawn tray panel (§5f of
    `docs/WINDOWS_HANDOFF.md`); `cargo test --workspace` 207 +
    host/windows clippy clean, now enforced by CI.

69. **Voice start crashed (SIGABRT), dictation dropped chars in the mirror,
    and "Show Desktop" didn't show the desktop (2026-09-27).** Three
    reported bugs, three distinct root causes:
    (a) **Voice crash.** The 09-24 device crash logs show
    `AVAudioEngineGraph::Initialize` raising an Objective-C exception from
    `AVAudioEngine.prepare()` inside `VoiceRecognizer.startAudioEngine()` —
    **uncatchable in Swift**, so it is a SIGABRT. Two causes: a single
    long-lived `AVAudioEngine` accumulates dirty graph state across
    start/stop cycles, and `.record` was configured with `.mixWithOthers`
    (only valid for playback categories). Fix: a **fresh engine each
    session**, no `prepare()` (`start()` prepares), an input-format guard,
    and `.record` + `options: []` (matching `MicrophoneEncoder`).
    (b) **Dictation drops in mirror mode.** The screen mirror is the phone's
    heaviest CPU/GPU consumer and starved the on-device recognizer.
    Hold-to-talk now **yields the mirror** (same pattern as the mic):
    `syncScreen`'s `want = screenOn && !voiceOn` stops the stream while
    voice is held, keeping the last frame + pin on screen, and restarts on
    release.
    (c) **Desktop in the mirror.** The streamer only captured an app window,
    and hiding apps doesn't change the frontmost app (Finder was already
    active), so a live mirror stayed on the old window. `ScreenStreamer` now
    (1) falls back to **whole-display capture** when no eligible window
    exists, and (2) the `showDesktop` system command explicitly calls
    `captureDesktop()` on a live mirror. The e2e asserts `streaming
    display`.
    **Windows audit** (same session): `tap_win_d` released Win before D
    (`Win↓ D↓ Win↑ D↑`) — fixed to `Win↓ D↓ D↑ Win↑`; the context sheet's
    "Safari" `.launchApp` hardcoded `com.apple.Safari` (a dead button on
    Windows) — now a URL so the default browser opens; `clipboard.rs` now
    retries `OpenClipboard` and always closes (a leaked open wedged the
    session); added `rc-app/i18n.rs` (Chinese when
    `GetUserDefaultUILanguage()` is zh) so the tray menu/status + console
    status lines are bilingual.  Device e2e 19/19; `RemoteCrabCore` 198 +
    both apps; `windows` 123 + host/windows clippy clean.

70. **Extended Display — the phone as a real second monitor (2026-09-27).**
    Duet-style secondary display, built on the mirror pipeline. The core is
    a **macOS virtual display** created with the private CoreGraphics
    classes every third-party second-display app uses —
    `CGVirtualDisplayDescriptor` / `CGVirtualDisplay` /
    `CGVirtualDisplaySettings` / `CGVirtualDisplayMode`, reached with
    `NSClassFromString` + KVC/`perform` (`RemoteCrabReceiver/VirtualDisplay.swift`).
    **No driver, kext, or entitlement.** Spike-verified on the dev Mac: a
    new entry appears in `CGGetActiveDisplayList` and `SCStream` captures
    real frames from it; releasing the object removes the display.
    Flow: `IBScreenControl.Command.extend` (0x1D) → `ReceiverSession` creates
    the `VirtualDisplay`, `ScreenStreamer.extend(displayID:)` streams that
    display and **stops following the frontmost app** (a lock-guarded
    `extendedDisplayID`; `follow`/`select`/`stop`/`showDesktop` release it,
    as does disconnect). `configureDisplayStream` now takes an optional id
    (nil = main display, the desktop fallback). iOS: the mirror's window
    menu gains "Extended Display" (checked when the target id is
    `display:`). Device e2e asserts `virtual display created` +
    `streaming extended display` (21/21).
    **Caveat**: the classes are undocumented — Developer-ID-only (no Mac App
    Store), and a macOS update can break them; the "proper" route is a
    DriverKit dext with an Apple-granted entitlement. **Windows** has no
    equivalent yet, so `.extend` reports "not supported".
    **Landscape UI verification gotcha**: the iOS Simulator's rotation did
    not respond to AppleScript (System Events) menu clicks *or* the ⌘→
    keystroke — the window stayed portrait (395×850) — and the
    `requestGeometryUpdate`/landscape-only-plist hacks only produced a
    "content rotated but not re-laid-out" artifact that is NOT a real
    landscape render. Real landscape review needs a device screenshot.

71. **Private-API object ownership: a leaked `CGVirtualDisplay` makes the
    next one fail (2026-09-27).** The user reported "扩展显示器点了完全没反应".
    Evidence chain: the iPhone forensic showed the toggle DID fire
    (`toggle extended display: on=false screenOn=true`) and the Mac logged
    `extend failed — no virtual display` → then `CGVirtualDisplay init
    failed`. `CGGetActiveDisplayList` showed **two** displays (#1 + a leaked
    #10 1920x1200), and killing the receiver removed the orphan — so the
    object, not the code path, was at fault. Cause: `perform(initWithDescriptor:)`
    took **`takeUnretainedValue()`**, so ARC never owned `alloc`'s +1 and
    releasing `display` left the object (and the display) alive; the private
    API then refuses to create another. Fix: **`takeRetainedValue()`**.
    Lesson: with `NSClassFromString` + `perform` on private classes, the
    `alloc`/`init` pair must be `takeRetainedValue()`, or the object leaks —
    and this class of bug only shows on the SECOND use, so a single-shot
    spike (`scripts`-style) proves nothing about repeated create/destroy.
    Verified: device e2e 23/23 with `CGGetActiveDisplayList` back to one
    display after teardown.

72. **A delayed teardown must never be *skipped* — serialize it instead
    (2026-09-27, "用几次就不能说话了").** The user reported hold-to-talk
    working once or twice, then a press doing nothing. Root cause was a
    **regression I introduced while fixing the previous voice bug**, found by
    reading `git log` on the voice files (`42f8ac5`): `stop()` released the
    recognizer on a 300 ms delay (so the last syllable still reached it),
    guarded by `sessionGeneration` / `stopRequested`. A press that began
    within those 300 ms bumped the guard, so the OLD session's teardown
    returned early — its `SFSpeechRecognitionRequest` / `SpeechAnalyzer`,
    results task and installed mic tap were **never released**. After a few
    holds the resources were exhausted and `start()` just failed, which read
    as "按了没反应". The guard existed because the teardown had once killed
    the *new* session ("用两次就不能用了") — so **skipping** the teardown traded
    a wrong-teardown for a leak. The correct shape, now in both
    `VoiceRecognizer` and `AnalyzerVoiceEngine`: the teardown **always** runs
    (it only releases its own session's objects), and `start()` `await`s the
    in-flight `teardownTask` before a new session exists — full
    serialization, so an old teardown can neither leak nor touch the new
    session. `VoiceEngine` gained `waitForTeardown()` (default no-op) so
    `VoiceRecognizer` can await an engine's release; `AnalyzerVoiceEngine
    .start()` also gained the missing `isStarting` guard. **Generalizable
    rule: a guard that makes a cleanup path `return` early is a leak
    generator — serialize (`await` the task) instead of skipping.** Committed
    `dcb23b0`; confirmed by the user on device ("好像好了一些…应该没啥问题了").
    The same build carries the never-shrink final (the analyzer tracks the
    longest `committed+volatile` seen; the finalizer can no longer truncate
    the tail) and the PTT gesture uses
    `onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity,
    onPressingChange:)` — `DragGesture`/`Button` variants restarted the hold
    on re-render (the 1×/s start storm).

73. **A "keep the previous target" fallback must exempt the desktop
    (2026-09-27).** User report: "投屏模式下用 iOS 切应用，画面不更新，要关掉
    投屏再开" — and then the decisive narrowing: **"好像只有切换 Finder 的时候
    不行，切换其他的应用好像是可以的"**. That one sentence is the whole root
    cause: `ScreenTargetResolver.resolveKeepingPrevious` falls back to
    `previous` when the newly frontmost app has **no eligible window**, and
    Finder sitting on the desktop has none — so it "kept" the old app's
    window, `resolveAndStart`'s `same` check matched, and the function
    returned silently. The Mac-side log with new instrumentation made it
    unambiguous:
    `activated app 访达` → `recheck: front=访达/942` →
    `resolve: target=922:80 same=true reason=frontmost`.
    **Fix**: Finder-with-no-window IS the desktop (a thing worth showing), so
    `resolveKeepingPrevious` gained `desktopIsShowing:` (set from the
    frontmost bundle id) → returns nil → the streamer switches to
    whole-display capture. +3 pure tests. Note `⌘-Tab` never hit this
    because the apps it switched to had windows — a reminder that "it works
    when I do X" is evidence about *which* input path differs, not noise.
    **Kept**: the observer diagnostics (`activation recheck scheduled`,
    `recheck: running/extended/pinned/front`, `resolve: target/same/reason`)
    — one line per activation, and they are what made this findable.
    Same pass, two related fixes: **`showDesktop` now hides EVERY regular app**
    (it filtered `!$0.isActive`, so the app the user was looking at was never
    hidden, and it then `activate()`d Finder, which could raise a Finder
    *window* over the desktop — "点了桌面还是原来那个应用"); and the mirror's
    **window picker was unreadable**: it always drew "app name + bare window
    count + chevron", which reads as a status readout and eats a third of the
    row. Now auto-follow is a single 40 pt icon (same footprint as
    fit/fill/zoom), a pinned window adds a pin icon + short title, and the
    menu states the mode ("Show which window" header + "Auto — follow current
    app", checkmarked) with a coach-mark line. New `IBLocale.Mirror` keys
    (`windowPicker` / `autoFollow` / `pinned` / `windowPickerHint`) + zh-Hans
    catalog entries.

74. **Mac auto-update via Sparkle 2 (2026-09-27).** The Developer-ID Mac app
    now self-updates silently: `RemoteCrabReceiver/UpdaterController.swift`
    owns `SPUStandardUpdaterController` and, in
    `SPUUpdaterDelegate.updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`
    **returns `true`** to stash the UI-less install block; the pure
    `RemoteCrabCore/State/UpdateInstallGate.swift` decides when it's idle
    enough (no owned session, not recording, ≥30 s dwell). `ReceiverSession`
    is now a `static let shared` singleton with `isSessionActive`; the updater
    is created lazily and started from `applicationDidFinishLaunching` (NOT
    `App.init()` — same too-early trap as sysextd). UI: menu-bar "Check for
    Updates…" + a pending-only "Restart to Update" row, and a Preferences
    toggle. Release: `scripts/release-mac.sh` re-signs Sparkle's nested
    binaries (XPCServices → Autoupdate → Updater.app → framework) with
    Developer ID **before notarization**, builds `RemoteCrab-<v>.zip`, and
    `scripts/make-appcast.sh` runs `generate_appcast` (EdDSA) →
    `dist/appcast/appcast.xml` (upload to `vgoapp.com/downloads/`).
    **Gotchas that bit:**
    (a) **Never set `automaticallyChecksForUpdates`/`automaticallyDownloadsUpdates`
    imperatively on launch** — Sparkle persists them in UserDefaults and its
    header warns "Do not always set it on launch unless you want to ignore
    the user's preference"; a Preferences toggle would be silently reverted.
    Put the defaults in Info.plist (`SUEnableAutomaticChecks` +
    `SUAutomaticallyUpdate`) and keep only the get/set property for the UI.
    (b) **xcodegen's package `embed: true` is broken for Sparkle's binary
    XCFramework** (it copies from `$(BUILT_PRODUCTS_DIR)/Sparkle`, no
    `.framework` → "The file Sparkle couldn't be opened"); use `embed: false`
    and let Xcode auto-embed, then verify `Contents/Frameworks/Sparkle.framework`.
    (c) Pin the version with xcodegen `exactVersion:` (NOT `exact:` — 2.46
    rejects it) or a clean checkout resolves a newer 2.x than the tested one.
    (d) `generate_appcast` needs a **one-time keychain "Always Allow"** for the
    EdDSA private key (a SecurityAgent prompt), and the private key lives only
    in the login keychain (`generate_keys`, public key → `SUPublicEDKey`).
    (e) The appcast's `sparkle:version` is `CFBundleVersion`, so it must
    increase every release; the camera-extension / mic-driver versions stay
    **frozen** (v1 auto-updates the app bundle only — replacing the sysex
    resets its approval, lesson 5).
    (f) A **dev-signed** build logs "Skipping atomic rename/swap … because
    Autoupdate is not signed with same identity" — exactly what (the release
    script's) nested re-sign fixes; don't chase it locally.
    (g) The feed URL can be overridden for testing with
    `REMOTECRAB_UPDATE_FEED` (used by a local `http://127.0.0.1` appcast E2E);
    running the app from `/tmp` also exposes the sysex "app moved" repair
    (`/tmp` vs `/private/tmp`) — the deactivation fails harmlessly off
    `/Applications`, but the recorded-path default should be restored after.
    (h) Filter Sparkle's **non-failure** outcomes in the delegate:
    `didFinishUpdateCycleFor:error:` still passes a non-nil error for "no
    update found" (`SUNoUpdateError` 1001) and a cancelled install
    (`SUInstallationCanceledError` 4007) — compare `(error as NSError).domain
    == SUSparkleErrorDomain` and `SUError.*.rawValue`, or the log is noise.
    (i) The EdDSA **private key lives only in the login keychain**
    (`generate_keys`); lose it and no future update can be signed — backed up
    to `~/.config/remotecrab/sparkle-ed-private-key` (0600) and
    `root@158.247.219.230:/root/.config/remotecrab/sparkle-ed-private-key`
    (0600, outside the web root), never in the repo. The public key is
    `6007dgFqcTaRt5gMlxnh263ABbequKpT6wXicnFPZZI=` (in `project-mac.yml` /
    `Info.plist`). Full key ops (backup / restore / rotate) live in
    `docs/SPARKLE_UPDATE_KEY.md`.
    **Verification status — be honest:** the update flow is verified **on a
    real Mac with a dev-signed build + local appcast** (fetch → EdDSA validate
    → silent download → idle install → relaunch, bundle `1 → 2`; 215 tests +
    both apps build). **NOT yet verified:** (1) the idle gate against a **real
    active iPhone session** (must defer while a session owns the link, install
    only after it ends — the local run had no session at all); (2) the
    **notarized Developer-ID release** update path — the dev run *skipped* the
    atomic rename/swap + Gatekeeper scan because `Autoupdate` shares no signing
    identity with the app, so the Task-6 nested re-sign must be confirmed on a
    notarized build; (3) a full `scripts/e2e-device.sh` pass on the merged tree.
    **(2) is now RESOLVED — the notarized Developer-ID update path is verified
    (build 1 → build 2 over the real HTTPS feed, atomic swap); the
    launch-blocker fix + verification are in lesson 75.**

75. **The Developer-ID release does not launch on macOS 26 — the System
    Extension Install entitlement is profile-backed (2026-09-27).** While
    trying to verify the notarized update path, the `release-mac.sh` output
    (including the notarized DMG) was SIGKILLed on launch: crash
    `SIGKILL (Code Signature Invalid) / Taskgated Invalid Signature`, and
    `log show --predicate 'process == "amfid"'` gave the real reason —
    `Requirements for restricted entitlements failed to validate` /
    `AppleMobileFileIntegrityError Code=-413 "No matching profile found"` /
    `Broken signature with Team ID fatal`. Narrowing by re-signing a copy:
    empty entitlements → **launches**; `com.apple.security.application-groups`
    only → **launches**; `com.apple.developer.system-extension.install` only →
    **killed**. So the sysex entitlement **is** profile-backed, and
    `release-mac.sh` deleting `Contents/embedded.provisionprofile` (lesson 29,
    "no Developer ID profile needed") breaks launch. Dev / Apple-Development
    builds work only because automatic signing embeds a profile. **Lesson 29's
    "verified" was `spctl` acceptance, not an actual launch** — an app can be
    `spctl`-accepted and still be killed by amfid. **FIXED (2026-09-27):** a
    `MAC_APP_DIRECT` (Developer ID) provisioning profile carrying the System
    Extension Install capability was created via the ASC API, saved to
    `~/.config/remotecrab/RemoteCrab_DeveloperID.provisionprofile` (0600,
    + VPS backup), and `release-mac.sh` now **embeds it** as
    `Contents/embedded.provisionprofile` before signing (env override
    `REMOTECRAB_DEVID_PROFILE`). Verified: the notarized Developer-ID app now
    **    launches**. Also confirmed the **live 1.0 DMG was broken** (downloaded
    `vgoapp.com/downloads/RemoteCrab.dmg` → same amfid kill). **The notarized
    update (atomic swap) path IS verified** (2026-09-27): a Developer-ID build 1
    updated itself to build 2 over the real HTTPS feed (forced background check
    → `found valid update build 2` → download → idle install → atomic swap →
    running build 2). The earlier "notarized build doesn't download" was a
    **test-harness artifact**: Sparkle throttles launch checks via
    `SULastCheckTime`, so repeated test launches simply stopped checking (the
    app didn't even appear in the proxy's connection table — nothing was
    blocked; it also works through a Clash/mihomo **global-mode TUN proxy**,
    `utun4` 198.18.0.1). To force a real check and bypass the throttle call
    `updater.checkForUpdatesInBackground()`. **Still open:** the idle gate
    against a *real active iPhone session* (defer while streaming, install
    after it ends) — only the no-session case has been exercised.
    **Debug method** (macOS 26 launch kill): `log show --predicate 'process ==
    "amfid"' --info` — taskgated's crash report only says "Invalid Signature".

79. **Mac notification relay + the TCC signature-change trap (2026-09-28).**
    **Feature:** the Mac polls Notification Center banners via AX
    (`AXSubrole == "AXNotificationCenterBanner"`; children `AXStaticText`
    id=title/subtitle/body; app name = banner `AXDescription` minus those),
    filters on a **denylist** (privacy apps; default **off**), and relays
    `IBNotification{app,title,subtitle,body}` over the existing link as kind
    **0x22**; the iPhone shows a `UNUserNotificationCenter` local notification
    + an in-app list. Best-effort: **banners only** (real-time), DND hides
    them, app names are localized (no bundle id). Files:
    `RemoteCrabReceiver/NotificationCapture.swift`,
    `RemoteCrabCore/State/NotificationFilter.swift`,
    `RemoteCrabCapture/{NotificationStore,LocalNotifier,NotificationListView}.swift`.
    **The trap:** swapping `/Applications/RemoteCrab.app` from an **Apple
    Development** build to a **Developer ID** build (`release-mac.sh`)
    **invalidates every TCC grant for the app** — Accessibility AND Screen
    Recording are keyed to the code signature (lesson 10). Symptoms, all at
    once right after the reinstall: trackpad dead (`CGEventPost`), mirror says
    "needs Screen Recording", window list logs `canCapture=false`. Fix:
    re-grant both in System Settings; `tccutil reset <service> <bundleid>`
    clears stale entries. **Future Sparkle updates (same Developer ID identity)
    keep the grants** — only a signing-identity change drops them.
    **UX fix shipped:** the app now opens the Screen Recording pane and shows
    a Preferences status row (it previously only called the request API, so
    users couldn't find where to enable it).
    **Blocked here:** the iOS device/release build — `project-ios.yml` uses
    team `DDG3CJL762` but the available ASC key/env is team `5XNDF727Y6` (Mac),
    so no iOS profile can be minted headlessly; and TCC grants are manual. The
    relay's **iOS half is therefore not shipped yet**, so the feature is inert
    for now (the Mac sends 0x22 frames the old iOS build ignores).
    **Released:** Mac **build 4** (`RemoteCrab-1.0.3.zip`, `sparkle:version 4`)
    uploaded to vgoapp.com (DMG replaced; appcast advertises build 4). Build 3
    shipped transiently before it. The setup assistant now also invites
    **Screen Recording** (skippable), and the Mac opens that Settings pane when
    the mirror hits the missing permission.
    **iOS relay half — verified on the Simulator, not a device:** a fake-Mac TCP
    client sent a `0x22 notification` frame to the sim app; the app received it
    and popped the "RemoteCrab Would Like to Send You Notifications" prompt
    (the lazy permission request firing where it should). The actual banner
    wasn't captured (a foreground app suppresses banners; the prompt needs a
    manual tap). Real-device iOS test remains blocked by the signing-team gap
    above.

80. **`project-ios.yml` had the wrong `DEVELOPMENT_TEAM`, and the
    notification relay shipped a receiver crash (2026-09-28, real-device
    session).** Both found by finally running the real-device e2e.
    (a) **The yml said `DDG3CJL762`; the real team is `5XNDF727Y6`.**
    `DDG3CJL762` is the **CN/UID** of the `Apple Development: Created via
    API` certificate — the team ID is the cert's **OU**
    (`security find-certificate -c "…" -p | openssl x509 -subject`), which is
    `5XNDF727Y6`. Someone copied the wrong field into the yml. Every script
    already passed `DEVELOPMENT_TEAM=5XNDF727Y6` on the command line, so only
    a **bare** `xcodebuild` failed, with `No Account for Team "DDG3CJL762"` /
    `No profiles for 'com.ibridge.iBridgeCapture'`. Fix the yml, don't work
    around it. `project-mac.yml` was right all along.
    (b) **The 4th recurrence of the isolation trap (lessons 2 / 7 / 53):**
    `@MainActor final class NotificationCapture` created a
    `DispatchSourceTimer` on its own background queue and wrote
    `source.setEventHandler { [weak self] in self?.poll() }`. The closure
    literal inherits the enclosing `@MainActor` isolation, the timer fires on
    `com.remotecrab.notifycapture`, so **~0.5 s after a session is accepted
    with the relay on** it trapped in
    `_dispatch_assert_queue_fail → swift_task_checkIsolatedSwift` and killed
    the whole receiver (SIGTRAP, type-309 corpse in DiagnosticReports). It
    survived review because `notifyRelay` **defaults off** — the crash needs
    the toggle AND a live session. **Fix:** type the handler explicitly
    (`let handler: @Sendable () -> Void = { … }`) so it is nonisolated;
    `poll()` is already `nonisolated` and hops back via `Task { @MainActor }`.
    **Why it compiled:** under `-swift-version 5` the literal is *silently*
    isolated-but-legal; the project is `SWIFT_VERSION 6.2`, where the same
    literal traps at runtime. An 18-line standalone harness
    (`@MainActor` class + background timer + nonisolated `tick`, printed
    ticks via an `NSLock` counter) reproduces it exactly: Swift 5 → both
    forms survive, Swift 6 → old form SIGTRAPs, `@Sendable` form ticks.
    Lesson: **for any `@Sendable` callback handed to a background queue,
    write the type explicitly** — the compiler will not save you, and
    `ScreenStreamer`'s identical-looking timer is safe only because that class
    is `@unchecked Sendable` (no isolation to inherit), not because the code
    differs.
    (c) **`scripts/e2e-device.sh` silently destroyed the user's release
    install.** Step `[3/5]` did `rm -rf /Applications/RemoteCrab.app && ditto
    "$DD_MAC" …`, replacing the Developer ID build with an Apple Development
    one — a signing-identity change, so it dropped the Accessibility AND
    Screen Recording grants (lesson 79) and left a dev build installed. It
    now backs the install up first and restores it from an `EXIT` trap.
    Corollary worth remembering: **a dev-signed build simply has no TCC
    grant; the release build's grant was never lost.** Seeing
    `accessibility trusted: false` right after an e2e run looked like a lost
    permission and wasn't — reinstalling the same-identity Developer ID build
    brought it straight back. Same-identity Sparkle upgrades keep grants.
    (d) **Tooling gotcha:** for a **non-sandboxed** app that still has a
    leftover sandbox container, `defaults write <bundle-id>` can land in
    `~/Library/Containers/…/Preferences/` while the app reads
    `~/Library/Preferences/…`. Toggling a `UserDefaults`-backed feature this
    way silently does nothing. Write the key with `PlistBuddy` into
    `~/Library/Preferences/<bundle-id>.plist`, `killall -u $USER cfprefsd`,
    and relaunch.
    **Result:** real-device e2e went 5/23 → **23/23**; build 5
    (`RemoteCrab-1.0.4.zip`, `sparkle:version 5`) is notarized and live.

81. **The notification relay is verified end-to-end on a real iPhone
    (2026-09-28), and the first "no banners on this Mac" conclusion was a
    bad probe, not a bad Mac.** Chain, 3/3, all on device:
    Mac banner → AX scan → denylist → `0x22` → iPhone inbox → system banner.
    Evidence, both halves:
    - Mac: `scan plan=dialogWindows windows=4 dialogs=1 banners=1` then
      `relaying notification from <private>` (`REMOTECRAB_DEBUG_NOTIFY=1`).
    - iPhone (`Documents/forensic.log`, pulled with `devicectl device copy
      from`): `[notify] relayed notification received (… unread=1/2/3)` +
      `[notify] system banner posted` ×3.
    **The wrong conclusion, and why:** an AX probe that dumped only each
    window's *direct children* found no `AXNotificationCenterBanner` and I
    concluded "this Mac never shows banners" — hours of work chasing the
    wrong problem. The real banner sits at **depth 2**
    (window → dialog → banner, `dialogs=1` every tick), so a one-level dump
    can never see it. **Lesson: an AX/AX-like probe must dump at least as
    deep as the code under test walks** (`collectBanners` descends to 8) —
    a probe shallower than the code is evidence about the probe, not the
    system. Note the useful side-effect: the same probe DID prove
    `windows=4` is永不 empty (panel + 3 desktop widgets owned by
    `notificationcenterui`), which is the F1 dead-fallback finding below.
    **New diagnostic surface (keep it):** the Mac's `REMOTECRAB_DEBUG_NOTIFY=1`
    per-tick line (plan/windows/dialogs/banners) and the iOS `[notify]`
    forensic markers. Before these, "no banner on screen" and "the AX read
    returned nothing" were indistinguishable in every log — that ambiguity,
    not the code, is what made this take so long. Both are marker-only; the
    notification's text is never logged (the iOS one logs the app-name
    *length*, the Mac the app name at `.private`).
    **Same pass:** adding that log line to the Mac's `nonisolated poll()`
    made the compiler reject `Self.log` — "main actor-isolated static
    property can not be referenced from a nonisolated context". That is the
    **compile-time** form of lesson 80's runtime trap, and it only appeared
    because `poll()` had never logged before. Mark such statics
    `nonisolated`.
    **Audit follow-up (e77b68a/e3366e6 + build 6, `sparkle:version 6`):**
    the scan decisions moved into the pure, tested
    `RemoteCrabCore/State/NotificationBannerParsing.swift` (243 tests), fixing
    three silent-failure modes: the dead `windows.isEmpty` fallback (a banner
    outside a dialog-marked window was missed forever — `scanPlan` now keys
    off the banner marker), a banner with no `AXIdentifier` being dropped
    (content key is the fallback identity), and an app-name parse that
    produced "" dropping the notification (falls back to the pre-comma text,
    then the whole description — with the filter also matching the raw
    description so a degraded name fails the denylist **closed**). Windows
    `rc-protocol` also learned `0x22`, which had decoded as `Kind::Video`.

82. **Tapping a relayed notification switches the Mac to that app *and
    window* (2026-09-27/28).** The point is the loop the user described: an
    agent finishes → the banner reaches the phone → one tap → you are back in
    that agent's window to give the next instruction. Both paths verified on
    a real iPhone:
    - app still running → iOS `[notify] tap: activating '脚本编辑器'
      window=yes` → Mac `activated app 脚本编辑器 window=打开` +
      `raised window 打开`.
    - app quit → iOS `[notify] tap: '脚本编辑器' not running — ignored`, and
      **nothing happens** (deliberate: activating an app the user quit is a
      surprise). Logged, never silent.
    **The Mac side needed no change** — `activateApp(id:windowTitle:)` already
    did `activate(.activateAllWindows)` + `raiseWindow` (un-minimize, raise,
    set main + focused) and already no-opped for a quit app. The work was
    entirely (a) carrying enough identity and (b) routing the tap.
    **Four things that will bite again:**
    (a) **Install the `UNUserNotificationCenterDelegate` from
    `application(_:didFinishLaunchingWithOptions:)`.** A tap that *launched*
    the app is delivered to the delegate immediately after launch, so
    installing it from a view `.task` (or an engine init that runs later)
    silently drops that first tap — the same too-early/too-late trap as the
    camera extension and Sparkle. The router holds taps until a handler
    exists, so a cold-launch tap still lands.
    (b) **Implement `willPresent`** or iOS suppresses the banner (and the tap)
    whenever RemoteCrab happens to be frontmost — which reads as "the relay
    broke".
    (c) **`windowTitle` needs Screen Recording**: `kCGWindowName` is redacted
    without it, so `NotificationWindowMatch.frontWindowTitle` returns nil and
    a tap just activates the app. Don't treat nil as an error. Verified on
    this Mac that `kCGWindowOwnerName` **is** the app display name (matching
    what the banner reports) and that `CGWindowListCopyWindowInfo` comes back
    front-to-back — which is what makes "the first layer-0 window of that
    owner" the frontmost. Only that first window is considered: returning a
    *later* window's title would raise the wrong window, worse than none.
    (d) **An `osascript display notification` is attributed to Script
    Editor**, not the terminal that ran it — that is where the mysterious
    `app=5 chars` came from (脚本编辑器). It also means a synthetic test hits
    the "not running" path unless Script Editor is running; `open -a "Script
    Editor"` first, and the success path exercises properly. Real app
    notifications behave normally.
    **Scope/limits:** only the sender's *localized display name* travels (the
    AX tree exposes no bundle id), so `NotificationAppResolver` matches
    exact → case-insensitive → contains (which also bridges helper processes:
    a "Google Chrome Helper" banner lands on "Google Chrome"). Window-level
    restore is best-effort by *title*; the per-window state is not restored.
    `IBNotification.windowTitle` is optional so old peers decode nil (tested).
    New pure/tested surface: `NotificationAppResolver`,
    `NotificationWindowMatch` (262 tests). E2E: `REMOTECRAB_E2E_NOTIFY_TAP=1`
    runs the same action the tap runs, so the device e2e can assert it without
    a finger. Build 7 (`RemoteCrab-1.0.6.zip`, `sparkle:version 7`).
    **Not yet shipped to users:** the tap routing is iPhone-side, so this
    needs an iOS build (the Mac half alone only adds the window title).

83. **"It connects sometimes" was a phantom: a persisted loopback address
    (2026-09-28).** The reported symptom was vague — *时灵时不灵*, "sometimes
    it works, sometimes it doesn't" — and it was **my own test debris**.
    The receiver learns the phone's IPv4 from every successful connect
    (`persistLastPhoneEndpoint`) and re-dials it whenever Bonjour comes up
    empty. Screenshot work left two **booted simulators** with the app
    installed, so a listener sat on `127.0.0.1:8765`; the fallback connected
    to it, and that "success" persisted `remotecrab.lastPhoneIP = 127.0.0.1`.
    From then on the fallback dialled loopback forever, attaching to the
    phantom and **re-persisting it on every connect** — a self-reinforcing
    loop that the log hid, because it never printed *which* address it was
    dialling (only `connection failed: … Connection reset by peer`, in a
    believable 12-20 s retry cadence that looked like normal backoff).
    **Diagnosis that cracked it:** `lsof -nP -iTCP:8765` showed the Mac
    connected to `192.168.31.26`, `169.254.228.39` (link-local!) and loopback,
    and `nc -z 127.0.0.1 8765` answered while no phone was around. The
    defaults were the evidence: `defaults read … remotecrab.lastPhoneIP`
    → `127.0.0.1`, and `phoneNameByIP` full of `%en0`-scoped junk.
    **Fix:** `DirectDialAddress.isUsable` (pure, tested) rejects loopback,
    link-local `169.254/16`, `0.0.0.0`/broadcast, non-dotted-quads and the
    `%en0` scope form `currentPath.remoteEndpoint` sometimes prints — used at
    **both** the persistence site and in `fallbackCandidates`, so a poisoned
    default heals rather than being dialled. Build 8 (`RemoteCrab-1.0.7.zip`).
    **Two rules for the next agent:** (1) **shut down simulators when you are
    done capturing** — `xcrun simctl shutdown all` — a booted sim is a live
    listener on loopback and the receiver will happily attach to it; (2) any
    address that gets *persisted and re-dialled later* must be validated as a
    plausible LAN host at write time, not just at read time.
    **Also:** when a reconnect loop looks suspicious, **log the address**; a
    loop that "retries every ~15 s" is indistinguishable from a healthy one
    until you can see *what* it retries.

84. **A string in a SwiftUI `Text` is looked up in the WRONG bundle, so a
    label renders English even though the translation exists (2026-09-28).**
    The context-sheet actions rendered `Text(LocalizedStringKey(label))`,
    where `label` is a dynamic `String` read from `ContextProfiles`. The
    Chinese catalog lives in the **Core package** (`RemoteCrabCore/.../
    Localizable.xcstrings`), but `Text(_:)` with a `LocalizedStringKey`
    resolves against **`Bundle.main`** — the *app* bundle. Result: every one
    of the 79 action labels showed **English in the Chinese UI** while the
    exact translation was sitting in the catalog the whole time. (SwiftUI
    only runs the catalog lookup for a `Text("literal")`; a `String` routed
    through a property or a `row(title:)` helper is a different path — this
    is lesson 8's cousin, one layer deeper: the string WAS a
    `LocalizedStringKey`, it just resolved in the wrong bundle.)
    **Fix:** `IBLocale.string(_:)` (explicit
    `String(localized:bundle:.module)`) used at all 4 render sites. The
    lesson: **a label sourced from Core and rendered by the app crosses a
    bundle boundary** — when in doubt, look it up explicitly against the
    bundle that owns the catalog. Caught only by *screenshotting* the
    Chinese UI, not by any test. Fixed in the iOS build **2026092404**
    (already the build under review), so no re-submit.

85. **Three of my own e2e-harness bugs, and the discipline they teach
    (2026-09-28).** The device e2e caught these, and each is a class of
    mistake worth avoiding in any test harness: (a) **A fixed sleep is not a
    state wait** — the extended-display hook slept 2 s then sent `mirror`,
    but the virtual display takes ~3 s to exist, so the mirror request
    arrived while `isExtendedDisplayOn` was still false and took the
    "close viewer" branch. Fix: poll the state, then send. (b) **Two hooks
    can race** — the `showDesktop` hook (10 s) fired *after* the app-switch
    hook, hiding the app that `showDesktop` needs, and by design (lesson 73)
    the capture then falls back to whole-display, so the follow assertion
    could never hold. Fix: sequence the hooks, and assert the *intent*
    ("mirror resumes following the frontmost app") rather than one internal
    `reason=` label. (c) **`grep`/BRE eats `[` `]`** — `check "[notify] tap:"`
    is a *bracket-expression class* (matches any of n-o-t-i-f-y), not a
    literal, so the assertion **failed on a run where the tap actually
    happened**. Fix: escape (`\[notify\]`) — and the general rule: **when an
    e2e assertion fails, first suspect the assertion.** A green assertion
    and a red assertion are both only as trustworthy as the pattern.

86. **A tapped notification aborted the whole app — an `async`
    `UNUserNotificationCenterDelegate` is a landmine (2026-09-29).**
    User report: 收到推送没事,**点一下整个 app 崩**。Three crashes, all with
    the same signature: `EXC_CRASH / SIGABRT`, an ObjC
    `NSInternalInconsistencyException` ("`_userInfoForFileAndLine`" +
    `objc_exception_throw`, i.e. an `NSAssert` — uncatchable in Swift), on a
    thread whose queue is **`com.apple.root.user-initiated-qos.cooperative`**,
    not `com.apple.main-thread`.
    **Two independent traps, both required:**
    1. **`UNUserNotificationCenter` delivers its delegate callbacks off the
       main thread** — measured directly (`willPresent` logged
       `pthread_main_np() == 0`), and the `UNNotification*` object graph is
       main-thread-only.
    2. **Declaring the method `async` adds a second failure the first one
       doesn't explain.** The Swift runtime bridges an async ObjC delegate
       through `_runTaskForBridgedAsyncMethod` (visible in the crash stack
       as `completeTaskWithClosure` → `thunk for @escaping @isolated(any)
       @async`), which runs the body on a cooperative thread **and finishes
       the bridge on that same cooperative thread**. Hoisting the body read
       into `MainActor.run` fixed the body (`run-body main=true`) and the app
       **still aborted** — because the abort was in the trailing bridge
       step. **Only per-line instrumentation showed this**: every log line of
       the body printed, then `Terminating app`. Without it I would have
       "fixed" the read and declared victory.
    **Fix:** both methods use the **completion-handler (non-`async`) form**,
    with a `Task { @MainActor }` hop that reads the objects, delivers, and
    calls the handler. `UncheckedBox` (`@unchecked Sendable`) carries
    `UNNotificationResponse` and the completion handler across the hop —
    Swift 6 otherwise rejects both. Corollary: `@MainActor` on the method is
    *not* a fix by itself; Swift 6 refuses it
    (`non-Sendable parameter … cannot be sent into main actor-isolated
    implementation`).
    **Why it only ever showed on a tap:** `willPresent` never dereferences
    its argument, so receiving + showing a banner was always safe. Any
    `UN` delegate method that *touches* its parameter is a landmine, and the
    crash is on the delivery path a reviewer never exercises.
    **Two process lessons:**
    - **`devicectl device process launch --console` is the reliable way to
      get the exception text.** `idevicesyslog` (even `-n`) died after
      seconds on this device and missed every crash, and the `.ips` alone
      never carries the assertion reason. `--console` also shows the app's
      own `Forensic.log` lines, so instrumentation and the crash arrive in
      one stream.
    - **Lesson 82's e2e was green while the app was aborting.** It asserted
      the iOS `[notify] tap:` line and the Mac's `activated app` — both
      printed, *then* the process died. **An e2e must also assert the
      process is still alive**, and must assert that the *delegate* path ran
      at all: `REMOTECRAB_E2E_NOTIFY_TAP` drives `activateRelayedApp`
      directly, i.e. the **in-app inbox** path, so it emits the same `tap:`
      line and **structurally cannot cover this bug no matter what you
      assert**. The delegate path has no headless trigger at all — it needs
      a real system banner and a finger. What protects it instead: a
      permanent `[notify] banner tapped (delegate path)` marker, the warning
      on both delegate methods, and a manual device tap. Do not let a green
      suite imply that path is covered.
    The user's follow-up "点了之后打开 app 是黑屏" was **a symptom of the
    abort**, not a second bug — it disappeared once the crash was fixed.
    **This is in iOS build 2026092404, the build under App Review**, so it is
    a release-blocker decision, not just a patch.

87. **"切换应用切不过去" was a stale green checkmark, not latency — the
    iOS state machine lied about a dropped link (2026-09-30).** User report:
    switching apps on the phone sometimes did nothing at all; their guess was
    a momentary network drop. **Their guess was half right — the trigger
    really is a network stall, but the symptom is a state bug, and no amount
    of "high latency" UI would have touched it.**
    `checkOwnerLiveness()` released the session when the Mac went silent for
    10 s, but `clearOwner()` nil'd `connection`/`broadcaster` **without ever
    assigning `connectionState`** — and the `.cancelled` callback that
    followed was swallowed by `handleOwnerState`'s `guard connection === conn`
    (the connection was already nil). So the top bar kept a green
    `checkmark.circle.fill` over a dead link, and `activateMacApp`'s
    `broadcaster?.send(...)` — an optional-chained no-op — dropped every tap
    with **no log, no hint, nothing**. Two call sites did this: the owner
    watchdog and the explicit Disconnect / Mac-switch.
    **How it was proven** (three independent signals, not one):
    `kill -STOP` the receiver (lesson 46's method) → the user confirms the
    icon is still green AND the Mac never switches; and the Mac's
    `activated app` log count stays at **0**, which localises the loss to the
    iPhone rather than the Mac. The iOS side then had no marker at all, so
    `Forensic.log("[link] …")` was added — the state was previously only
    observable by looking at the screen, which is how it survived so long.
    **Fix:** `clearOwner(reason:)` is now the *only* thing that changes
    `connectionState` (`.lost → .failed`, `.disconnected → .idle`,
    `.replaced → untouched because `grant()` sets it a line later), and the
    four call sites no longer assign the state themselves. A mandatory
    parameter is the point: a new call site cannot forget.
    `activateMacApp` / `quitMacApp` / `launchInstalledApp` now check
    `IBEventBroadcaster.isReady` (added for this — `send` drops anything not
    `.ready`, right for the data plane, useless for a command a user is
    watching) and raise the shared `transientHint` instead. `hintBanner` used
    to be hard-wired to one caller and is now the engine's general channel.
    **Two traps worth keeping:**
    - **An e2e hook that *causes* a reconnect and lives in `grant()` will
      re-arm itself forever.** `REMOTECRAB_E2E_LINK_LOSS` dropped the link,
      the reconnect ran `grant()`, which re-armed the hook — a measured 6 s +
      3 s offline↔reconnect loop. It looked exactly like a product regression
      and was reported as one. The other hooks only replay a frame, so
      re-arming them is harmless — but the one that perturbs the link needs
      its own once-per-launch flag.
    - **A fixed green status can hide a link that is genuinely flapping.** A
      clean restart showed zero resets for 45 s, so at least some of the
      instability was the hook's; but the lesson stands — a UI that cannot
      show a failure will also hide a real one, and "I never saw this before"
      is not evidence the bug is new.
    Verified on device: `owner silent` → `state=failed` → a switch tap
    shows 「当前未连接到电脑。」; 270 tests + both apps. **Note:** these changes
    are recorded in AGENTS.md but were committed inside a *Windows* commit
    (`0b89c23`) by a parallel session that swept the working tree — the code
    is correct, the attribution is not.
    **Still open:** the mirror's own "switch app → the video stays frozen /
    goes black" is a *separate* bug on the `ScreenStreamer` →
    `ScreenDecoder` → `ScreenZoomState` path, still unrooted. Ruled out so
    far: the Mac's target resolution (its `resolve: target=… same=false` +
    `streaming window` + rising `screen frames sent` are all healthy) and
    the viewport math (a `[mirror] degenerate layout` marker reported
    nothing). The user's screenshot shows a *correct but tiny* window image
    in the corner, which points at the display-layer geometry rather than at
    decode. The one capture that showed it had no iOS-side log at all — the
    marker landed afterwards — so it has not been reproduced since.

### In flight (2026-09-30): latency + failure-reason work, and one hard deployment constraint

**Shipped but NOT yet verified on hardware** (`2df2d9a`): the phone finally
measures its own round trip (`IBLatencyTracker` + `IBPingProbe`, 26 new
tests), and `FailureReason` separates "the camera would not start" from
"the local network is not reachable" from "the link dropped" — three cases
that all used to render the same misleading sentence.

> **⚠️ DEPLOYMENT ORDER IS A HARD CONSTRAINT.** The phone now *initiates*
> latency probes. An **old receiver** treats the phone's timestamp as its own
> echo, subtracts, and paints the **clock offset between the two machines**
> in its menu bar — which can be hours. So **the Mac build must ship first, or
> in the same release.** Never ship the iOS build alone. Both ends discriminate
> with `IBPingProbe.isOwnEcho` (byte-identical to the last stamp we sent), and
> a regression test runs 20 probes against a clock three hours out to prove no
> false echo.

**Also shipped (`b3a8c02`) — command results.** Every control the user taps
was fire-and-forget, so a missing Accessibility grant, an app that quit in
the meantime and a window that closed all looked identical from the phone:
nothing, with no explanation. New kind **`commandResult = 0x23`**,
`IBCommandResult { requestId, status, detail? }`, `status ∈ ok /
appNotRunning / noPermission / noWindow / failed`. The three request structs
gain an **optional** `requestId` in both directions (rule 2: an old phone's
request still decodes and is still honoured — it just gets no answer).
- **No retry, deliberately, and tested as such.** A retry is useless against
  all three failure causes; the genuinely transient case is already covered by
  `reportNoLink()`, and `clearOwner` drops the ledger so a dropped link cannot
  emit a burst of "too old" hints contradicting the "not connected" one.
- **Silence ≠ failure.** A receiver predating 0x23 never answers and the
  phone cannot distinguish that from a lost frame, so it says "your Mac app
  may be out of date" — a capability gap, not an accusation. 1.5 s window,
  then it stops.
- Two receiver return values that were being **discarded** now carry the
  status: `NSRunningApplication.activate()` returns false on exactly the case
  that matters (no Accessibility grant), and `raiseWindow` reported success
  even when AX could not list windows at all.
- Windows needed `0x23 => Kind::CommandResult` for the reason in lesson 68,
  and a parallel session independently wrote `rc-net/src/ping.rs`
  (`PingProbe`) — the Rust twin of `IBPingProbe`, same single-value
  rationale. The two ends agree by construction, but they are two
  implementations of one rule: if either is ever changed, change both.
- 317 Core tests, both app targets, Windows suite, clippy clean including the
  `x86_64-pc-windows-gnu` cross-check.

**Not yet verified on hardware.** Both B1 and B2 are compile- and
unit-verified only; the end-to-end pass needs a **Mac build 9** (B1's ordering
constraint) and, for B2, a phone build against it.

Also considered and rejected: re-probing the local-network permission at
launch. `PermissionFlow.probeLocalNetwork` already answers granted/denied, but
a second probe after the prompt has been answered has a 2.5 s `inconclusive`
window and no guarantee, so the honest symptom (`networkUnavailable`) is
driven off the listener failing instead.

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

_Last updated: 2026-09-29, later (**a real crash in the build currently under App Review — tapping a relayed notification killed the app** — user report 收到推送没事,**点一下整个 app 崩**). Root-caused on a real iPhone 14 / iOS 26.6.2 across **four** reproductions with the same signature: `EXC_CRASH / SIGABRT` from an ObjC `NSInternalInconsistencyException` ("`_userInfoForFileAndLine`") on a **cooperative-pool** queue, not the main thread. Two traps stacked: `UNUserNotificationCenter` delivers delegate callbacks **off the main thread** (measured — `willPresent` runs with `pthread_main_np() == 0`), *and* an `async` delegate method is bridged by the Swift runtime through `_runTaskForBridgedAsyncMethod`, which also **finishes the bridge on that cooperative thread**. The first "fix" (hopping the read into `MainActor.run`) made the body run on the main thread and **still aborted** — only per-line instrumentation revealed the abort came *after* the last line of the body. Fix: both delegate methods use the **completion-handler (non-`async`) form** with a `Task { @MainActor }` hop (lesson 86). The follow-up "点了之后打开 app 是黑屏" was a **symptom of the abort**, not a second bug. Verified on device: `[notify] banner tapped (delegate path)` → `tap: activating` → no abort, plus 270 tests and both app targets. **This bug is in iOS build 2026092404, the build sitting in `WAITING_FOR_REVIEW`**, so shipping it means either withdrawing the submission (a **manual browser** step — the ASC API has no `DELETE` on `reviewSubmissions`) or waiting for a rejection. Two process lessons came out of it: `idevicesyslog` is useless on this device (dies in seconds, never saw a crash) while `devicectl device process launch --console` carries both the exception text and the app's own `Forensic.log` in one stream; and lesson 82's tap e2e was **green while the app was aborting** — it asserted the log line and the Mac-side `activated app`, both printed, *then* the process died, so an e2e must also assert the process is alive (and that the delegate path ran at all, since the in-app inbox emits the same `tap:` line — hence the new marker). Previous entry below._

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
