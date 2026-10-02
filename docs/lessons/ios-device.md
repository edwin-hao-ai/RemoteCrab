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
