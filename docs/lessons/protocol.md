# 协议、跨进程与并发

> wire format、actor 隔离、e2e 与打包

Part of [`AGENTS.md`](../../AGENTS.md). Entries keep their original numbers
so a cross-reference from another lesson still resolves.

1. **Swift `Data` slices keep the parent's indices.** `data[4..<n]`
   has `startIndex == 4`, so `slice[0]` traps (SIGTRAP) on the very
   first frame. This killed the app at launch. Always subscript

3. **MenuBarExtra labels: SF Symbols, or a proper template IMAGE asset.**
   A custom `Canvas` label renders as a solid blob; hardcoded `.white`
   art is invisible in light menu bars. SF Symbols get template
   rendering for free. For the app's own logo, ship a **monochrome
   transparent-background image set** with
   `"template-rendering-intent": "template"` (`MenuBarIcon.imageset`,
   mastered from `assets/menu-bar-icon.svg` via `rsvg-convert`) and use
   `Image("MenuBarIcon").renderingMode(.template)` — macOS then tints it
   for light/dark. That's how the menu bar shows the monitor-buddy logo

5. **The mic path needs two non-obvious things on device.** (a) An
   active `AVAudioSession` in a record-capable category before
   `AVAudioEngine.start()`, or the input tap never fires. (b) The
   input node delivers **Float32 non-interleaved**, so
   `buffer.int16ChannelData` is nil — a `guard let int16` silently
   drops every buffer. Convert to Int16 (mix to mono) yourself.
   Both bugs fail 100% silently: no error, no crash, just zero

6. **Backgrounding kills video but not audio — by design of iOS, and
   it does NOT auto-recover.** AVCaptureSession gets interrupted
   (video device unavailable in background); the MicrophoneEncoder's
   separate AVAudioEngine survives. Symptom: after a reconnect, audio
   flows but the Mac shows "No video" forever. CaptureEngine observes
   `.AVCaptureSessionWasInterrupted / InterruptionEnded / RuntimeError`
   and restarts the session, and `handleDidBecomeActive` force-checks

9. **The black video scare was a covered camera, not the decoder.**
   `CaptureEngine` streams the `.back` camera; a phone face-down on a
   desk is perfectly black. To tell "lens covered" from "decoder emits
   black", run the receiver with `REMOTECRAB_DEBUG_FRAME_PROBE=1` and read
   the `frame probe: min/max/avg` line (true black → `max≈0`; a real
   scene → `avg≈140`). The probe reads pixels via a `CGContext`: CI's
   PNG writer is blocked by the sandbox and a failed CI render reads

10. **Accessibility grant survives an in-place redeploy.** Overwriting
    `/Applications/RemoteCrabReceiver.app` with `ditto` (same path, same
    bundle id, same cert) keeps the TCC grant; a path/signature change
    drops it. TCC is cached per process — **restart the app after

16. **`H264Decoder.emit` must not build a `CIContext` per frame.** It
    did — 30 expensive context creations a second showed up as visible

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

93. **Splitting a 212 KB AGENTS.md nearly destroyed 26 lessons (2026-09-30).**
    The archive is 92 numbered entries; the goal was an index plus
    `docs/lessons/*.md`. Two attempts failed, and both failures were the
    same mistake in different clothes: **inferring structure instead of
    measuring it.**
    - I wrote a keyword classifier and *looked at the output* — lesson 20
      "Personal Hotspot breaks Bonjour" landed in the iOS file, 61 "voice
      disconnect" in the connection file, 27 "simulator TCC" in the
      protocol file. I had already been told once that a first draft's
      plausibility was not evidence (lesson 7), and I did it again.
    - I then assumed the real-hardware list was 26 entries because that was
      how many a `blocks[:26]` slice returned. It was 25, so the slice also
      swallowed the **first global lesson**; and since my theme sets were
      keyed by number, entries 1-26 of the global list were re-filed under
      the device list's numbers. The index silently began at 27. I only
      caught it because the numbers were supposed to be 1-92 and the index
      said 27-92 — an assertion, not a spot check, is what found it.
    **The transferable part:** the sequence of numbers in the source is the
    ground truth and it was right there — `[1..75, 79..92]`, no restart. I
    went looking for a second "1" to split on, and when there wasn't one I
    reached for a slice length instead of asking why. When a document is
    being restructured, print the invariant, assert it, and make the script
    refuse to write if the count moved. A refactor that does not verify its
    own output is a refactor that deletes whatever it failed to model.

111. **Five ways the device e2e produced a wrong verdict in one session
    (2026-10-02).** None of them were the product; all of them looked like
    product failures or passes. (1) The launcher's output went to
    `/dev/null`, so a **locked iPhone** (`FBSOpenApplicationErrorDomain …
    Locked`) became *24 missing-marker failures* instead of one
    precondition error — fail loudly at the launch. (2) The phone's
    `forensic.log` is **appended**, so a marker from a run three hours
    earlier satisfied an assertion and reported a **false PASS**; compare
    the file's mtime and SKIP rather than count anything un-attributable.
    (3) The staged binaries **predated the fix**, and the probe said so
    wrongly: `strings` on the app binary found nothing because a Debug build
    keeps the real code in `RemoteCrabCapture.debug.dylib` (the binary is
    92 KB). Check for your own **string literals in the dylib**, not a hash.
    (4) The frame that exercises the branch under test was **silently
    dropped**: the phone sees `screenInfo.status == .ok` before the Mac's
    `lastScreenInfo` lands (that assignment hops through the main actor), and
    `handleScreenInput` returns early until it does — so the "place the
    cursor once" path never ran and the assertion passed *vacuously*.
    (5) Counting across the target boundary invented a regression: this run
    also flips to the extended virtual display, and when the mirror changes
    window the cursor **must** be re-placed, so `placed=2` was correct.
    **Generalizable rule: an assertion that passes when its branch never
    executed is worse than no assertion.** Require both branches, scope the
    count to one target, count only the side that owns the marker, and prove
    the assertion **fails** on a hand-built log of the old behaviour before
    believing a green run. (`grep -c` also prints `0` *and* exits non-zero
    on no match, so `$(grep -c … || echo 0)` yields the unusable `0\n0`.)

112. **Two geometry hypotheses died cheaply, and that is the point.** A user
    reported mirror taps landing off-target "sometimes right, sometimes off
    by a distance". The obvious suspects were a titlebar offset and a
    ZStack layout shift. Both were killed by measurement before a line was
    edited: `SCWindow.frame` vs `CGWindowListCopyWindowInfo` bounds on this
    machine came back `cgOriginDelta=0.00 cgSizeDelta=0.00x0.00` for a real
    1224×800 app window (capture box and mapping box are the same box), and
    a headless SwiftUI host showed the gesture overlay's frame stays at
    `0,0 393×852` regardless of zoom — so `contentUV`'s coordinates and
    `displayedContentRect` share an origin after all. What remained was the
    gesture transform itself, which is where the 168 pt pinch came from.
    **Generalizable: "occasionally right, off by a varying distance" is a
    transform symptom, not a mapping symptom — and a symmetric error that
    scales with zoom is the signature of a wrong anchor, not a wrong box.**
