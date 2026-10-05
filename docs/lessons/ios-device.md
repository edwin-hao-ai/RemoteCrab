# iOS 真机与 AVFoundation

> AVCapture、麦克风链、权限隔离、语音识别

Part of [`AGENTS.md`](../../AGENTS.md). Entries keep their original numbers
so a cross-reference from another lesson still resolves.

2. **TCC permission callbacks fire on a background XPC queue.**
   A `withCheckedContinuation` wrapping `SFSpeechRecognizer.requestAuthorization`
   inside a `@MainActor` type traps in `swift_task_checkIsolated`.
   Mark the wrapper `nonisolated`. (`AVCaptureDevice.requestAccess`

7. **Actor-isolated tap closures trap on the audio realtime thread.**
   Any `installTap` block formed inside a `@MainActor` type inherits
   that isolation and SIGTRAPs in `swift_task_checkIsolated` on the
   first buffer. Give the block an explicit `@Sendable` type and box
   non-Sendable captures (`UnsafeSendableBox`). This is what made

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

13. **Never surface a raw `NWError`/POSIX error.** `"\(error)"` shows
    `POSIXErrorCode(rawValue: 54): Connection reset by peer` in the
    popover. Log the error, set a human message
    (`IBLocale.Error.iPhoneConnectionLost`). Also: `IBStatusPill`'s
    `.disconnected` renders no secondary text now — showing the reason

14. **`MenuBarExtra(.window)` re-sizes (and visibly animates) whenever
    its content height changes.** A status row whose text wraps (the
    offline hint `Text(session.state.message).fixedSize(vertical:)`)
    changed height on every reconnect-loop state change, so the popover
    kept sliding/re-sizing — read as a "looping sideways animation".

15. **Don't run an always-on `TimelineView` for an idle animation.**
    The trackpad's cursor preview ticked at 20 Hz forever, which made
    surface switches (and the camera PiP) feel janky; it's now

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

36. **The "background microphone" was never actually enabled
    (2026-09-19 — corrects the old claim in this file).**
    `UIBackgroundModes` exists nowhere in `project-ios.yml`, any
    Info.plist, or git history; so iOS suspends the app on background and
    mic streaming stops. This accidentally removes a 2.5.4 background-mode
    review risk. To enable it, add `UIBackgroundModes: [audio]` to
    `project-ios.yml` and be ready to justify it to Apple.

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
    (b) The mic activated `.playAndRecord`; ~~with the background mode
    declared iOS rejects that activation~~ **this half was WRONG — see
    lesson 123.** It now uses `.record` (the mic only records;
    `VoiceRecognizer` always used `.record` too).
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

108. **An unanchored pinch is a measurable defect, and the correct overload
    already existed (2026-10-02).** The mirror's pinch called
    `ScreenZoomState.setZoom(_ z)`, the centre-anchored branch, while
    `setZoom(_ z, anchor:)` sat right beside it — written, documented and
    unit-tested by `testAnchoredZoomKeepsTheTouchedPointFixed`. A zoom that
    ignores the gesture's own centroid moves whatever you were pinching:
    measured on a 393×852 phone with a 1224×800 window, pinching a point at
    content u=0.153/v=0.117 to 2× displaced that same point **168 pt**, to
    x=−76 — off the left edge of the screen. The user had already reported
    it as "放大后点不准". **Generalizable: a tested-and-correct model function
    can exist while its call site silently uses the neighbouring overload, so
    "the model is covered" is not evidence the feature is.** Anchor every
    zoom at `gestureRecognizer.location(in:)`.

109. **A drag threshold in view points is wrong the moment the view is
    zoomed.** The single-finger drag-to-Mac-drag threshold was a fixed
    `moved > 10` in *view* points. What the Mac sees is *content* points, so
    at 4× a 10-point slip is a 2.5-point Mac drag — real enough to turn a
    near-miss tap on a button into a drag-select ("点了没点中"). Now
    `ScreenZoomState.dragSlop = min(28, max(10, 4 * zoom))`, unchanged at 1×
    so nothing regresses. **Generalizable: any touch threshold must be
    expressed in the space the far side acts in, not the space you measure
    in.**

110. **A three-finger gesture is a trackpad gesture.** The conflict was
    "two fingers must mean both scroll and pan", so three fingers were added
    for the pan. It worked and the user called it "姿势别扭，手挡住画面":
    three fingers is comfortable on a trackpad *because the hand is not on
    the content*, and on a touchscreen the palm covers the very region being
    examined. No amount of tuning fixes that. **Generalizable: before porting
    a gesture between input surfaces, ask whether the reason it is comfortable
    survives the port.** The replacement already existed and was anchored —
    two-finger double-tap zooms at the tap point (`toggleZoom(at:)`) — and at
    the common 2× reading zoom the vertical pan range is **0 pt** anyway, so
    vertical panning was redundant all along.

113. **A complete reference must be filed where the reader will look for it
    (2026-10-02).** The gesture sheet was a "trackpad guide" that never
    mentioned the mirror, and the mirror's only hint was one line carrying
    five gestures — the two also disagreed about what *three fingers* means
    (middle-click on the trackpad, free panning in the mirror). Scoping each
    section to its surface dissolved the ambiguity without a note explaining
    it. Two things the diff could not catch, only rendering it could:
    filing "two fingers sideways to move the view" under a heading that said
    **"Scroll & zoom"** hid the pan gesture from anyone who scans by heading,
    and the mirror borrowed **"Three & four fingers"** for a single row it
    does not have a gesture for. One scroll, not a segmented control: a tab
    per surface would *hide* half the content, which is the opposite of the
    point when the reason for writing it was completeness. **Generalizable:
    a documentation change is a layout change — render it and read it, and
    check that each row sits under a heading that describes it.**

114. **A hint and a reference are different jobs.** The mirror's coach mark
    existed to make the surface make sense once; it was also the *only*
    place five of the mirror's gestures were written down, so "shown once"
    quietly meant "unreadable after the first session". It is now three
    gestures plus a button into the full reference, reachable from the menu
    too. And `proxy.scrollTo` in a `.task` needs its target measured before
    the proxy will honour it, so it silently no-ops behind a magic sleep
    standing in for layout; `.defaultScrollAnchor` is declarative and cannot
    race. **Generalizable: when a one-shot hint is also the only copy, either
    it is a hint or it is documentation — it cannot be both, and the fix is a
    link, not more text.**

119. **「用户报了 A 就去修 A」漏掉的是同一个根因的另外三处，而这个产品里
    键帽、朗读标签、说明文字是**三份独立实现**。** 用户报「连接 Windows 后
    还是显示 Command」。查下来除修饰键行外还有：

    - **手势说明页**（`TrackpadGuideView`）写死「Lock ⌃⌥⌘⇧」「Mission Control」
      「the Mac」。它是**会话中被阅读**的说明，而两英寸之外的快捷键行已经显示
      `Ctrl / Alt / ⊞ / Shift` 了。**一份描述了错误机器的说明，比一份短说明更糟，
      因为读者无法判断哪几行可信。**
    - **VoiceOver 朗读标签**。Windows 那排和弦键**复用了 Mac 那排的
      accessibility label**，于是 `Ctrl+Z` 被念作「Mission Control」、`Ctrl+A`
      被念作「App Exposé」。**键帽文字是对的，所以没有任何检查能发现** —— 只有
      读屏用户听得到。修法是把整排抽成 `ShortcutChords` **数据**（键帽 + 朗读
      配成一对），视图就再也没有「拿错的标签」可言，测试也才握得住这一对。
    - **context chip 写死英文 `"Computer"`**，中文手机上和下面「按住说话」并排。
      catalog 里**早就有** `Computer` → 电脑，是调用点用了字面量所以查表从没发生。
      这条**只能靠看截图发现**（lesson 76 的纪律），在英文界面下它根本不存在。

    抽数据时还发现一个**语义错误**：`extra` 不是「叠加在 ⌘ 之上」的增量，而是
    **完整的修饰键掩码**（`modifierMask | extra`）。我的测试掩码漏了 bit 8
    （command，正是变成 Ctrl 的那位），于是误报了。**掩码常量必须从
    `TouchEvent.Modifier` 抄，不要手写。**

123. **Lesson 50(b) was wrong: `UIBackgroundModes: [audio]` does NOT break
     `.playAndRecord`. Measured on iPhone 14 / iOS 26, 2026-10-04 (lesson
     123 supersedes 50(b)).** The `AudioSessionProbe` e2e hook
     (`REMOTECRAB_E2E_AUDIOSESSION=1`) walks the session claims and reports
     each `setCategory` / `setActive` separately, so a failure names WHICH
     call failed. With the background mode **declared and read out of the
     real Info.plist** (`bgAudioDeclared=true`):

     ```
     claim record-from-clean        setCat=ok setActive=ok
     claim playback-from-record     setCat=ok setActive=ok   ← mic → speaker
     player silent-loop isPlaying=true
     claim record-from-playback     setCat=ok setActive=ok   ← speaker → mic
     claim playAndRecord-from-clean setCat=ok setActive=ok   ← **works**
     END steps=5 failures=0
     ```

     So the real cause of 561017449 was **(a) alone** —
     `AVCaptureDeviceInput(audio)` making `AVCaptureSession` manage the app's
     session — and (a) was already fixed with
     `automaticallyConfiguresApplicationAudioSession = false`. The mic uses
     `.record` because *the mic only records*, which is still the right
     choice; but the **stated reason was wrong**, and it cost a real
     decision: "mic and speaker cannot coexist" was believed to be an
     audio-session impossibility when it is not. Coexistence's real obstacle
     is **echo** (the phone mic hears the phone speaker), which wants
     `setVoiceProcessingEnabled`, not a different category.

     Two things generalise:
     * **A/B'd fixes that ship together were never isolated.** 50's own
       "isolation method" paragraph says the three variables were separated
       by *removing* things — which shows (a) mattered, and says nothing
       about (b). A conclusion needs a run where only (b) is present.
     * **An API constraint nobody likes is still a constraint until measured.**
       "iOS forbids this" was inherited as fact through several sessions.

     What the probe does NOT yet prove: two live `AVAudioEngine`s (mic input +
     speaker output) running at once under `.playAndRecord`, which is a
     different test.

126. **A property that outlived the code that fed it is worse than a missing
     one: the file still compiles and still looks complete (2026-10-04).**
     `SpeakerPlayer` had `receivedRms`, `receivedPeak` and an `envelope`
     buffer declared, and an `enqueue` that measured **nothing** — it appended
     the packet, incremented the counter and returned. A concurrent session's
     edit had removed the body while leaving the declarations.

     So every run printed `pcmRms=0` and an empty envelope, and I read that as
     "the phone receives silence" — then spent a long time diagnosing the
     codec, the transport and the ring buffer on the strength of it. The
     feature had been working the whole time; the user proved it by listening
     to it.

     The tell was available the whole time and I misread it: **`enqueued` was
     climbing while the envelope printed as an empty string**, and a property
     that grows on every packet cannot print empty unless the code appending to
     it is not executing. Two numbers disagreeing was evidence about the
     *instrument*, not about the *signal*.

     Rules this earned:
     * **When two measurements contradict each other, suspect the
       instrumentation before the data.** "The meter reads zero" and "the thing
       is off" are different claims, and I took the second.
     * **A declaration surviving an edit tells you nothing about the code
       around it.** Swift will not warn that a `private(set) var` is never
       assigned; it is only "unused" if nothing ever reads it either.
     * **Concurrently edited files make every measurement suspect.** When
       another session is committing in the same tree, a number that disagrees
       with theory is more likely to be a stale or partial build than a bug —
       and that is checkable: build into a dedicated derived-data path and
       assert on a marker string only the current build contains.

## 138

**One bug wore three disguises, and the counters were green through all of
them.**

Report: real playback works, but a video on the Mac comes across as "very
garbled, shrill", and will not switch off. The e2e suite was green.

The feature was doing a 20 ms timer (`tick`) that scheduled a **silent**
packet unconditionally — correctly, because `AVAudioPlayerNode.isPlaying` must
stay true or the system reclaims the audio session — while a second function
played real audio from the ring as fast as it arrived. Neither was wrong
alone. Together: 50 real packets a second **plus** 50 silent ones into a
player that drains 50, so the queue grew by ~50 packets — one second of
latency — every second. That single fact explains all three symptoms:
fragmented and stale audio, audio that keeps playing after the toggle, and a
green suite.

The suite was green because **nothing checked the filler**. `pcmRms != 0`
passes when half the timeline is zeros.

Two more rounds followed, both found by reading numbers rather than by
reasoning:

* The first fix gated playback on `pendingPlayback < 2`. But 2 buffers **is**
  the normal start-up cushion, so playback stalled the moment the player was
  healthy — the receive ring filled and `starved` climbed 253 → 687 by
  discarding the oldest audio. Queue depth answers "is the graph about to go
  dry", which is a question about *silence*; it is not a reason to stop
  feeding real audio.
* The second fix left the timer as the only thing feeding audio.
  `Task.sleep(for: .milliseconds(20))` measured **~30 ms**, so playback ran at
  33 packets/s against 46 arriving. A player that consumes 50 packets a
  second cannot be fed from a clock that drifts.

The shape that satisfies all three: **real audio is scheduled by the arrival
of real audio**, with the player's queue depth as a *feedback* term — schedule
only when the ring holds enough to refill the queue to the start-up cushion —
and **the timer keeps exactly one job**, keeping the graph alive, and never
runs while audio is waiting. Then the arrival and consumption rates cannot
drift apart however badly the timer does.

Measured on the device, same source, before → after:

| | before | after |
|---|---|---|
| filler (`silence`) | 916, 47% of scheduled | 2 |
| queue depth | growing, 18–20 | 0–3 |
| discarded (`starved`) | growing, 866 | 0 |
| `played` behind `enqueued` | 877 packets | 5 |

Generalisable, and it is the third time this project has been bitten by a
variant: **a timer that keeps an audio graph alive is not a scheduler.** It
looks like one, and it will happily double your output rate. The invariant is
not "keep feeding the player" but "**never add silence while real audio is
waiting**" — and the test for it is the filler share, which nobody had.

## 139

**A format declared one way and written another costs you a channel, and no
counter in the pipeline can see it.**

With every counter green and the sound still wrong, the fault had to be in
the samples. `SpeakerPlayer.init` built its `AVAudioFormat` with
`interleaved: true` and then filled buffers through
`int16ChannelData[channel][frame]` — the **planar** idiom.

Measured on the two channel pointers: **2 bytes apart**. So `dst[1][0]` and
`dst[0][1]` are the same address, and every right-channel sample was
overwritten by the next left-channel sample before anything read it.

Three complaints, one cause:
* **shrill** — the left channel played at double speed
* **not clear** — the right channel gone
* **noisy** — the survivors formed L,R pairs that never existed in the
  source, i.e. comb filtering

The silence path had the same mismatch, so the periodic filler was
mono-mono-mono too.

Two fixes, and the second was not the one I expected:

1. `SpeakerPCMWriter` writes **either** layout correctly, and the caller asks
   `format.isInterleaved` at runtime instead of remembering. One test
   reproduces the clobbering verbatim, so if the premise ever changes the
   test fails rather than quietly ceasing to mean anything.
2. The format is now **planar**, because that is what `AVAudioPlayerNode`
   renders natively. The interleaved format bought nothing and cost measured
   latency: the device sat at `queued=9` (~200 ms) with `starved` still
   climbing, and both went flat on the change.

The reason no existing check caught it: **the packets arriving from the Mac
are correct**; the corruption happened on the way into the audio buffer. Only
reading the buffer back proves anything, and it has to be read back **per
channel**:

```
outL=-6402 outR=-3366 STEREO-OK
```

Two different values is the fix. Under the old writer they were byte-identical,
which is also the shape of the bug: "one channel at double speed, the other
discarded".

The general rule: **when a format is declared, the write path must derive its
indexing from the format, not from the mental model of it.** `interleaved` is
a one-word difference with a two-byte pointer offset.

## 140

**A diagnostic can be the thing that breaks the feature — and one that
reports "silence" when it is the one lying is worse than none.**

To check playback objectively I tapped the audio node's output. It cost three
iterations, and every failure mode looked like a broken player:

* tapped the node, `format: nil` → reported **silent** every run
* tapped the **mixer** instead → the mixer renders in the mixer's own format,
  Float32, so the tapped buffer's `int16ChannelData` is nil; the guard
  returned early and the number was still **silent**
* tapped with the Int16 format → **`App terminated due to signal 5`**

That last one is the generalisable part. `installTap` on an audio node, fed
from an audio thread, traps the process. A tap whose format does not match
the node's output does not merely report the wrong thing — in this build it
removed the feature entirely.

So I deleted it. The same fact is provable from the calling thread by reading
the first frame back out of the buffer the player was handed, which is what
`outL/outR` does, and that cannot take anything down. **A temporary
measurement has no business being able to take the feature down**, and a
diagnostic that can only ever print "silent" is indistinguishable from one
whose silence is real.

## 141

**The first number in a bug report can be the phone's own opinion of itself.**

Chasing "the picture is soft", a handoff across two machines recommended
raising the encoder's bitrate coefficient, on the strength of a receiver
printing `6220 kbps` — which turned out to be exactly
`1920 × 1080 × 30 × 0.1`, the phone's **request**, read back out of
`IBStreamMetadata`, not a measurement of the wire.

`H264Encoder` set both `kVTCompressionPropertyKey_AverageBitRate` and
`kVTCompressionPropertyKey_Quality`, and `VTCompressionProperties.h`
documents neither as taking precedence. Measured with
`scripts/vt-bitrate-probe.swift` against the real encoder:

| Quality | achieved |
|---|---|
| 0.50 | 4,989 kbps |
| **0.70 (shipped)** | **9,179 kbps** |
| **0.75** | **10,886 kbps** |
| 0.80 | 13,552 kbps |

Asking for 6,220 and for 9,331 produced **byte-identical output** (3,442,273
bytes). Not imprecise — inert. So the phone had been reporting an invented
rate since the property list was written, and **the cross-machine acceptance
criterion built on that number would have gone green while the picture stayed
exactly as soft.**

The lesson is lesson 137's cousin: *an acceptance test that cannot fail is
worse than none.* Here the failing branch was a measurement that was never a
measurement. Whenever a symptom is "quality too low", verify that the knob you
are about to turn is connected to the thing you are about to measure — and
when two properties are set, do not assume the more obvious one is in charge.

## 144 · 按例子写的守测试，覆盖率是 0

2026-10-05。`testNoSessionSurfaceNamesAMac` 列了 **26 个 key**，
而那 26 个**全都已经是干净的** —— 它从来没抓到过任何东西。
它是**修完之后**按例子列的，不是从界面推出来的，所以新增的泄漏从它旁边走过去。

实测：catalog 里「已上线文案含 Mac」的 key 有 **19** 个，那份清单覆盖 **0** 个。

换成按界面走之后（列 10 个会话期文件 → 解析 `IBLocale.swift` 拿到
`IBLocale.<Enum>.<symbol>` → catalog key → 检查每种语言）**当场抓到**：

* **4 条半吊子** —— `zh-Hans` 已经改成「电脑」，**`en` 的 value 从来没被碰过**。
  同一个界面上中文用户看到「电脑」、英文用户看到 "your Mac"。
  特征是：**只审一个语言就会漏**，而只审 key 会漏得更多（key 只是查找标识，
  我曾把一个 key 当成文案报成 bug，而它的 value 早就是 "Send to computer"）。
* **7 条没人分类过的** —— 3 条权限文案，加 4 条手势页的 **Mac 分支**。
  后者存在**正是因为**手势页按平台分流（lesson 115），
  删掉会让 Mac 用户读到 Windows 文案 —— 所以它们是**故意的**，
  必须写成具名断言让「故意」读起来像决定。

另一半同样重要：`deliberateMacText` 给每条例外写明理由，
并有一条反向断言「catalog 里任何含 Mac 的 key 都必须在清单里」——
**这才把「26 个 key 的清单」变成「全部的清单」**。它当场抓到了我自己：
我加的 `Download for Mac` 例外是陈旧的，那条文案早就改成「Download the desktop app」。

**教训**：守测试的清单要按**界面**列，不按**字符串**列；
而且必须配一条反向断言，否则清单会静默缩小。

## 145 · 一个悄悄什么都没扫的解析器，和一张干净的健康报告长得一模一样

2026-10-05。`SessionSurfaceCopyTests` 靠正则 + 解析 `IBLocale.swift` 建立
`符号 → catalog key` 的映射。写错了四次，每一次都是**测试自己报出来的**
（把「未解析的符号」写成硬失败），因为绿测试在这种测试里毫无信息量：

1. 符号切到**第一个** `(` 之前 —— 而那属于 `IBL(`，于是每个符号都变成
   `open = IBL`，全部查不到。
2. `public static func name(…) -> String { String(format: IBL(…), x) }`
   的 key **在函数体里、跨行**。只认 `public static let` 就漏掉 8 个。
3. `IBLocale.Pairing` 里有**嵌套** `enum Attempt`，单名扫描永远出不来，
   于是 nest 之后每个声明都挂在错的名字下。
4. 修第 3 个时引入的：对**任何** `}` 都出栈，结果在第一个函数体里就清空了 ——
   511 个符号只解析出 376 个。区分「enum 的 body 闭合」和「函数的 body 闭合」
   靠的是**括号深度**，不是看到 `}` 就弹。

两条覆盖率下限让它变响而不是变绿：`> 400` 个符号被解析、`> 40` 条会话文案被扫。
（`> 400` 这个数字是量出来的 —— 脚本第一次能跑时解析出 511 个。）

---

154. **`try? await Task.sleep` 在任务被取消时会吞掉取消错误、立刻继续往下跑 —— 于是"取消一个定时器"变成了"立刻执行它"。**
    手写看门狗/兜底最常见的写法：
    ```swift
    task = Task {
        try? await Task.sleep(for: .seconds(3))   // ← 陷阱
        guard ... else { return }
        doTheFallback()
    }
    ```
    单独看没问题。但它和「收到真实信号就 `task.cancel()`」放在一起时是致命的：
    取消会让 `Task.sleep` **抛 `CancellationError`**，`try?` 把它吞掉，
    于是**代码继续执行**，兜底逻辑**立刻**跑，而不是永远不跑。
    这一次的现场：手机有个 3 秒「legacy 兜底」（把没发 hello 的老电脑按 first-come
    接受）。新加的 `.off` 分支里取消了它 —— 结果**同一条连接先收到 `sessionReply off`、
    10 毫秒后又收到 `accepted`**，那台刚被拒绝的 Mac 被当成 `Computer (legacy)` 又接了
    进来。用户的描述是「断开之后又连上、还是个新名字」。
    **证据怎么拿到的**：手机 `forensic.log` 里每个连接都是
    `hello → sendSessionReply off → sendSessionReply accepted`；Mac 日志对应
    `sessionReply: off` 紧跟 `sessionReply: accepted`（差 12ms）。**连接上两个应答
    是"取消后继续"的指纹。**
    规则：`try? await Task.sleep` 之后**必须**再检查 `Task.isCancelled`；
    更稳的写法是
    ```swift
    do { try await Task.sleep(...) } catch { return }
    ```
    —— 取消即 return，而不是吞掉错误继续。**同类一起审**：同一个文件里
    `slowRetryTask` 的 15s 轮询也是这个形状（取消后会多跑一次 `retryNow()`），一并修了。

155. **`NWBrowser` 用 `.bonjour` 描述符时，结果里**没有** TXT —— 要么用 `.bonjourWithTXTRecord`，要么拿不到任何 TXT 字段。**
    手机端浏览 `_remotecrab-computer._tcp` 看谁在线。代码用
    `NWBrowser(for: .bonjour(type:domain:), using:)`，把结果里
    `case .bonjour(record) = result.metadata` 当 TXT 读。实测 iPhone 14：
    **浏览器 `results=1`，但 `metadata` 是 `.none`**，`record.dictionary` 从没被填过，
    于是每一台都「读不到 id」被跳过、`online=0`。**这不是网络问题** ——
    同一时刻 `dig @224.0.0.251 -p 5353 ... PTR` 和 `dns-sd -L` 都能看到记录、TXT
    就在里面（`id=ECBDD7BA… platform=macos`）。
    修法：描述符换成 **`.bonjourWithTXTRecord(type:domain:)`**，TXT 才进 `metadata`。
    规则：**`NWBrowser` 默认的 `.bonjour` 描述符不保证带 TXT；需要 TXT 就用
    `.bonjourWithTXTRecord`。** 用户的「看不到在线状态」在拿到 `results=1 bonjour=0`
    这一行计数日志之前，看起来和「广播没发出去」一模一样。

156. **保活已经让监听活着时，还去 `stopStreaming()/startStreaming()` 重建它，只会打断所有连接。**
    手机在回前台时，如果「当前没有连接」，就做一次完整的
    `stopStreaming(); startStreaming()` —— 目的是恢复「被 iOS 后台挂起的监听」。
    可我们已经有音频保活（`BackgroundKeepAlive`，`.playback` + 循环静音 buffer），
    **监听根本没被挂起**。于是每次回前台（用户切到微信再切回来）都白白把一个好的
    监听拆掉重建，**正在进行的连接全部 `connection reset by peer`**。
    Mac 日志里就是 `Connection reset by peer` 每十几秒一次、以及
    「Bonjour endpoint … not ready after 8s」。
    修法：`handleDidBecomeActive` 只在**没有保活**（保活关闭）时才重建；
    保活生效时监听本来就在，直接返回。规则：**一个"恢复"动作必须先确认"真的坏了"再动手；
    无条件执行的恢复，本身就是一种破坏。**（同 lesson 143/130 的家族：
    清理/恢复代码的早退条件写错，伤害比不做更大。）
