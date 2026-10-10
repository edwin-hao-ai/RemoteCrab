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

115. **A second platform turns "the shortcut set" into a per-platform
    question, and the shortcut set is not the only thing that differs.**
    The Windows handoff said the context sheet was "always empty" there and
    proposed matching apps by name. Matching was necessary and nowhere near
    sufficient, because `ContextAction.key` carries a **macOS virtual
    keycode + modifier bitmask** and every action in all 19 suites was
    menu-verified on a Mac. Three separate defects sat behind the one
    symptom:

    - `ContextSheetView.swift:42` rendered the console **system** grid
      *unconditionally*, so every Windows user already saw 8 buttons — of
      which **4 were wrong**: brightness (`system_keys.rs:33` returns
      `false`, so the button does nothing), Lock Screen (⌃⌘Q collapses to
      `Ctrl+Q` via `keymap.rs:147`'s `COMMAND | CONTROL`, i.e. **quit**),
      and "Safari" (`ContextSheetView.swift:147` hardcoded `bing.com`, so a
      button labelled Safari opened Bing).
    - `keymap.rs:147` ORs ⌘ and ⌃ into **one indistinguishable Ctrl**, so
      the agent suite's ⌃C "Interrupt" and ⌘C "Copy" became the same
      keystroke — and in Windows Terminal Ctrl+C *is* interrupt, so the
      Copy button interrupted.
    - The handoff's "no protocol change needed for the Win key" is true
      only for a bare ⊞ tap. The modifier mask defined just 1/2/4/8 and
      `COMMAND` collapses to Ctrl, so ⊞E/⊞R/⊞D/⊞L were **unreachable**:
      a chord needs a `META` bit (16, previously unused).

    The generalizable shape: **when the peer OS changes, the *action set*
    must be resolved per platform and must never fall back to the other
    platform's set** (`windowsActions ?? []`, never `?? actions`) — because
    a fallback does not yield a missing button, it yields a *wrong* button.
    `ContextProfiles.appActions(for:platform:)` and
    `testNoTwoWindowsActionsCollapseToTheSameKeystroke` exist to make that
    class of collapse impossible to reintroduce. Two smaller rules from the
    same session: a label and the argument it triggers must travel **in the
    same value** (`.systemArg`), or they drift; and "this app has no
    verified mapping" is a legitimate state that should fall through to a
    working section, not be filled with a guess — PowerPoint and Windows
    Terminal copy/paste were deliberately **cut**, and
    `testPowerPointIsNotYetMapped` asserts the absence so the omission reads
    as a decision.

116. **A persisted format that will later carry untrusted input needs its
    origin in the data, and the merge has to replace by `id`.**
    `ContextProfiles` was already `Codable` with a comment about growing
    into a marketplace, which made it easy to assume the format was ready.
    It was not, for a reason that is only visible once you ask *who* writes
    these files: a profile is **executable input** — it replays real key
    events into a machine that already holds Accessibility permission — so a
    downloaded one is not data, it is a trust decision. Two fields came out
    of that: `schemaVersion` (a file claiming a newer version must be
    *refused with a readable reason*, never half-read) and `source`
    (`.builtin` / `.userFile` / `.remote`) so a button's origin is visible
    in the sheet and disableable by whoever owns the machine. The merge
    order (`userFile > remote > builtin`, **replacing** by id) is the other
    half: the old lookup was first-match-wins over one flat list, so a
    user-installed suite could never take effect — **installing a profile
    changed nothing and said nothing**.

    And the mechanical trap, which is the same shape as rule 2: adding
    `schemaVersion: Int` non-optionally would make synthesized `Codable`
    **throw** on every file written before this change, and this project's
    loaders swallow decode errors. The hand-written `init(from:)` with
    `decodeIfPresent` + a test that loads the **previous** format byte-for-
    byte is not ceremony; it is the difference between "your suites
    vanished" and a working upgrade.

117. **The e2e assertion that failed on a correct run was describing the
    fix, not the invariant — and only the component under test knows why.**
    `scrolling never steals the cursor` went red on real hardware. The
    injector's condition is `!hasPlacedCursor || !lastCursorInside(target)`,
    so after the mirror switches window — or flips to the extended virtual
    display, which the same run triggers on a timer — re-placing is
    **correct**. The assertion counted placements globally, which is the
    false verdict AGENTS.md already records as 跨目标切换计数. Two attempts to
    infer the reason from the log's `origin/size` geometry **in bash** were
    both wrong: BSD `sed` has no `\?`, so the pattern silently matched
    nothing and *looked* like "no regression"; and "same target as the
    click" is **not** "cursor was already inside the target", because a
    prior scroll can leave the cursor on a different display entirely.

    The fix was to make `CGEventInjector` state the reason in its own
    marker line (`first scroll of session` / `target changed` / `STOLE:
    cursor was already inside the target`) and have the assertion read
    that. **Generalizable: when an assertion has to distinguish two
    legitimate outcomes, the reason must come from the component that holds
    the state — inferring it downstream re-derives the bug.** Two supporting
    rules, both from the same fix: move an e2e assertion into its own
    runnable script so it can be exercised against a **known** log in both
    directions (it now passes the real run's shape *and* still fails on an
    injected steal — an assertion only a live 30-second race can exercise is
    one nobody can prove still catches anything), and note that requiring
    positive evidence ("a scroll was left alone") is **unsatisfiable** when
    two scripts race on one timeline — guard vacuity by requiring the
    *precondition* (a click, ≥1 post-click scroll), not the outcome.

118. **一个平台参数如果三个视图共用，其中一个漏传就是最难发现的那类 bug ——
    而它的症状是「同一个 app 里不同界面的键不一样」。** `ab86efe`（今天早些时候）
    把 ⊞ 行加到了**键盘**界面，`IBModifierBar.visibleModifiers(for:)` 是对的。
    但修饰键行其实有**两个来源**：键盘界面自己画，而**触控板和投屏**共用
    `IBShortcutBar`，后者调 `IBModifierBar(activeModifiers:onModifierKey:)`
    **没传 `platform`**，于是走缺省 `.mac`。结果：Windows 用户在最常用的两个
    界面上看到 `⌃⌥⌘⇧`，只有第三个界面对。
    **文档里写过的落点救了它也差点害了它**：`WINDOWS-GAPS-2026-10-03.md` §3
    明确点名「`KeyboardScreen.swift:345` 已经在用它」，于是实施者只改了那一处。
    **点名一个文件等于替其他调用点背书。**
    修法不是「记得传」，是**去掉默认值**：`IBModifierBar.init` /
    `IBShortcutBar.init` / `ScreenShareView.platform` / `TrackpadGuideView`
    四处现在都没有 `platform` 的缺省值，**编译器强制表态**。
    一般化：**一个参数被 N 个调用点共用时，缺省值是「漏传」的隐式许可，
    而类型系统比 code review 更擅长数调用点。**
    验证方式值得抄：把真的 `IBShortcutBar` 塞进 `NSWindow` 截图
    （`ImageRenderer` 不给 `ScrollView` 布局，会静默不画内容），
    **双向确认**——改回旧代码渲染出 `⌃⌥⌘⇧`，改回来才出 `Ctrl Alt ⊞ Shift`。

## 148 · 交接文档里的「**没做**」也是断言 —— 而且比「做了」更容易过期

2026-10-06，接 lesson 117 的反面。lesson 117 讲的是「交接文档里的『已实现』是
最强的断言，因为别人无法验证」；这一条是它的镜像，而且**更隐蔽**：

我在 `docs/HANDOFF-WINDOWS-2026-10-05.md` 写下「`0x25 requestKeyframe`
**没有任何地方发送**」，依据是一条 `grep -rn "RequestKeyframe" rc-app rc-net`
返回空。Windows session 回填：发送端在 `rc-app/src/main.rs:718-738`，而且
满足我列的全部三条要求。我复核 —— **他们是对的，我错了**。

**差别只在于我在一棵没拉取的树上 grep。** 我整个 session 都在审计「别人声称做了
但其实没做」，然后自己在**已经做了**的事上写了「没做」，而且用的是**同一种
证据形式**（一次 grep）。

**为什么负面断言更危险**：

* 「已做」被推翻时，有人会发现 —— 功能坏了，对不上。
* 「没做」被推翻时，**没有任何东西会坏**。它只是让下一个人**重新实现一遍**，
  或者像我这次一样，把一条已经完成的活又写进待办。
* 而「没做」的证据（一次 grep、一个 `ls`）看起来和「做了」的证据**一样硬**。

**规则**：**断言别人的东西「没做」之前，先 `git fetch`，并在拉取后的树上确认；
把这个基线 commit 号写进文档**（我写了 `code_baseline: 0e9f423`，而那条断言就是
在那个基线上做的 —— 有用的信息本来就在手边，没用上）。
**并且：把「没做」写成「我没找到证据它做了，基线是 X」，而不是「它没做」。**

## 149 · 会输出判决的工具，必须能用**它自己的输入**推翻自己的判决

2026-10-06。「预览花屏的根因是 B 帧」这个结论，是靠在
`docs/demo/remotecrab-demo.mp4` 上跑 OpenH264 得来的。要判断 iOS 要不要加
`NumberOfBFramesBetweenReferenceFrames: 0`，最直接的办法就是让真实的编码器回答。

`scripts/vt-bframe-probe.swift` 拿 `H264Encoder.createSession` 的**原样 7 个 key**
跑真VideoToolbox，150 帧确定性噪声，输出 Annex-B 给 ffprobe：

| mode | `AllowFrameReordering` | `has_b_frames` |
|---|---|---|
| `shipping`（线上那套 key） | `false` | **0** |
| `reorder`（**对照组**） | `true` | **2** |

**对照组才是这个工具存在的理由。** 如果两档都打 0，那不是「线上配置没有 B 帧」，
而是「这个探针看不见 B 帧」—— 而这两种情况在输出上**完全一样**。
lesson 76/111 是同一个形状：断言必须能反向失败。

（顺带：`reorder` 的 **2** 和那个 demo 文件的 `has_b_frames=2` 一模一样 ——
说明那个文件就是一个「允许重排序」的编码结果，也就是 libx264 的默认值。
见 lesson 150。）

另外两条同源的：

* 探针**先读 `H264Encoder.swift` 确认那 7 个 key 还在**，对不上就退出。
  否则它会安静地测量上个月的配置，而**输出的数字仍然看起来完全正常**——
  这是 lesson 141「手机报告的是它自己以为的事」的同构版。
* 第一版探针有**两个 bug，都是跑出来的**：VideoToolbox 回的是
  **AVCC（长度前缀）**，我直接写文件，ffprobe 读出来是
  `profile=unknown width=0 has_b_frames=0` —— **一个完美解析、答案全错的文件**。
  而 NAL 普查是空的，正好是「错」的第一个信号。第二个是
  `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` 的**返回值是 OSStatus 不是
  数量**，我拿它当 count，于是 SPS/PPS 一个没取到，ffprobe 报
  `non-existing PPS 0 referenced`。**一个工具写出无人能解析的产物，而产物本身
  看起来是有内容的** —— 所以「产出非零」不等于「产出可读」。

## 150 · 仓库里那个「看起来像产品录制的」文件，可能**根本不是产品录的**

2026-10-06，接 lesson 141。`docs/demo/remotecrab-demo.mp4` 被当作
「本产品自己录的 demo」用来**证明产品的码流有 B 帧**。它不是。

它是 `scripts/demo-video.sh:99` 用 **`-c:v libx264 -preset medium -crf 20`**
生成的，输入是 `screencapture -V 33` 录的 **macOS 屏幕**（模拟器窗口 + Mac
接收端窗口并排）：

```
$ ffprobe -v error -select_streams v:0 -show_entries stream=profile,has_b_frames,width,height \
    -of default=nw=1 docs/demo/remotecrab-demo.mp4
profile=High        has_b_frames=2        width=1468   height=1180
```

三条各自都足以推翻它：

* `High profile` + `has_b_frames=2` 是 **libx264 的默认值**，不是 VideoToolbox 的；
* **1468x1180 是并排合成画面**，而产品的码流是 **1080x1920** —— 尺寸上就不可能；
* 输入是 **macOS 录屏**，模拟器**没有摄像头**，所以它连手机的画面都不是。

**而它的数字全部可复现**：`decode_file` 27 帧 / 728 NAL / 694 无输出 / refused 1388，
我逐个重跑一帧不差。**工具是对的、测量是对的、结论是错的** —— 因为输入不是
被测对象。所以「我复现了你的数字」根本不构成「你的结论成立」的证据。

**规则**：**引用仓库里任何文件作为产品行为的证据之前，先问「它是谁生成的」。**
`screencapture` / `ffmpeg` / 拼图 / 缩放 / 转码，都会在产物里留下**不是产品的**
指纹。凡是「我们录的」「我们导出的」这类描述，都应该能指到**生成它的命令**；
指不到就不该被当证据。这和 lesson 141（「`IBStreamMetadata` 报的是请求的码率」）
是同一条：**测量的对象必须真的是被测的那个东西。**

---

152. **一个「安全的默认值」喂给解码器就不安全 —— 两端对同一个未知字节的默认必须一致。**
    Swift 的 `IBWire.Kind` 对未知 kind 返回 `.unknown` 并丢弃；Rust 的
    `Kind::from_u8_or_video` 却 `_ => Kind::Video`，把任何它不认识的 kind 当
    H.264 NAL 喂进解码器。每一端各自看代码都「合理」（前向兼容的默认），
    合起来是：一端新增一个 kind，另一端若没登记，**画面花掉且日志里一个字都没有**。
    更坏的是两边的测试**各自把相反的行为 pin 住了**
    （`test_an_unknown_kind_is_never_reported_as_video` vs
    `unknown_kind_still_falls_back_to_video`）—— 两边都绿，协议已经分叉。
    **规则**：未知输入在两端必须是同一个语义，且必须是「丢弃」而不是「猜一个类型」。
    新增一个 kind 时，两端的测试要断言**同一个不可变式**。
    修法：Rust 加 `Kind::Unknown`，`from_u8` 返回它；`dispatch` 的 catch-all 已经忽略。

153. **一台「已配对」的电脑会自己重连，所以手机端的「断开」会被对端抹掉。**
    iPhone 上点「断开连接」只是 `connection.cancel()` + 清 owner。可那台 Mac
    是已配对、且自己在跑重连循环的，下一拍就拨回来，`PairingPolicy` 见 token 有效
    **直接接受**。用户按了断开，一秒后又是连着的 —— 因为「谁有权连接」这件事，
    手机从来没有表达过「不」。
    修法不是补一个按钮，而是给协议**一个诚实的应答值 `sessionReply.result = "off"`**
    （不是 `busy`——那是在撒谎说「被别的电脑占用」；也不是 `denied`——那要用户手动撤销）。
    手机记住「用户踢掉了这台」，它再拨就回 `off`；用户重新选中任意电脑即清除。
    **无法用 `busy`/`denied` 复用的原因**：两者的文案和恢复语义都不同，复用等于给用户
    一句假话（AGENTS 规则 1）。这条同时是一个协议设计的教训：
    **"拒绝"至少有三种不同的含义（被别人占用 / 明确拒绝 / 用户暂时不要），各需要不同的
    字和不同的恢复动作。**

157. **一个纯服务端也能主动触发「你连我」—— 用一个只表示意图的短连接。**
    这个产品的数据连接永远是电脑拨手机（手机是服务端）。所以手机点「连接这台电脑」
    时**不能开数据 socket**，只能干等那台电脑自己重试（Mac 5s、Windows 更久）。
    修法：接收端在一个**固定端口 8766**（也就是它的 presence 监听口）上监听，
    **任何到该端口的入站连接都只表示一件事：「马上拨回我」**。手机点一下时，拨这个
    端口一次然后立刻挂断。数据会话方向、握手、配对全部不变。
    这个模式值得记住：**当一端的角色被架构固定为「只能被动接受」时，仍然可以给它一个
    「只承载意图、不承载数据」的出口** —— 它触发对端行动，而不是自己建立一个会话。
    代价几乎为零，而且完全向后兼容（旧接收端不监听该端口，手机就回退到轮询）。

169. **加一层横切（加密）时，要覆盖每一条发送路径 —— 而只断言「发送方日志」的 e2e 永远抓不到「接收方丢弃」。**
    F1 给每个帧加密，但**只有走 `IBEventBroadcaster` 的帧被加密**。iOS 的视频/metadata/
    SPS/PPS、Mac 的扬声器音频、app 列表、窗口列表、已安装应用、特性开关、剪贴板、文件回执、
    相机切换 —— **十几处直接调 `connection.send`，绕过了加密器**。接收端对授权后的**每一帧**
    都尝试解密，于是这些明文帧被当成密文、**静默丢弃**。
    症状极具误导性：`e2e-device.sh` **25/25 全绿**（它断言 Mac 的**发送**日志，不看手机是否收到），
    而 `e2e-speaker.sh` 立刻红（它真的断言「手机收到并播放」）。
    **两条规则**：
    - 新增一层横切（加密/压缩/审计）时，**先列出所有出站点**，逐个决定「走新层还是明确豁免」，
      并用一个**能证伪**的测试（在本端断言**对端收到**）钉住它，而不是只看本端发出。
    - 一个「本端发出去就行」的断言，在跨端功能上等于没有断言。
    **定位工具**：`TransportCipher.fingerprint(key)` —— 两端各自打印密钥的短哈希，
    不一致就说明某一端的派生输入（token / 两个 nonce）不同，**一句话指出是哪一端**。
    这条 bug 的定位就靠它 + 「手机日志里 `sealed frame failed to open (speakerAudio)`」。

172. **跨 `await` 的「重新解析」必须在使用前重读当前状态，否则一个过期的决定会覆盖新状态。**
    `ScreenStreamer.resolveAndStart` 先读 `extendedDisplayID`，再 `await` 一串
    `SCShareableContent`；期间 `extend()` 把虚拟屏设上了。等那个 resolve 跑到「没有可用窗口
    → 整屏」分支时，它**用它开头读到的 `nil`** 去配置，把 `screenInfo` 的 appId 从 `"extended"`
    覆盖成 `"display"` —— 手机端的 `isExtendedDisplayOn`（`appId == "extended"`）于是读错，
    开关/切换 UI 与 Mac 真实状态失同步。
    修法：在真正动手的 `configureDisplayStream` 里**再读一次** `extendedDisplayID`，
    让过期的 `nil` 让位给活的扩展屏。**规则**：一个跨越 `await` 的决策，在**执行**那一刻
    要重新校验它的前提；「读一次、想一会儿、再动手」在并发下等价于「用一个可能已经过期的值」。

173. **测试 hook 里「取第一个 X」在真实网络上是不确定的 —— 尤其当网络里还有别的东西。**
    `REMOTECRAB_E2E_PICK_ONLINE` 取 `onlineComputers.first`。用户 LAN 上有一台**真实的
    Windows 接收端**（`rc-fe3a662f`）在广播 presence，于是手机拨了**那台**，e2e 的 A/B
    拿不到连接，整套 0/25。**这不是产品 bug** —— 手机主动连接本身是通的（它连上那台 PC 并
    accepted 了）。是 hook 的选法不确定。
    修法：hook 优先选**带 `e2e-` 前缀的身份**，并给 e2e 的接收端一个 `e2e-` MAC id。
    **规则**：e2e 里任何「第一个 / 最近一个 / 任意一个」的选择都要能**指定**，否则它只在
    「恰好只有被测对象」的网络上成立，而真实用户的网络从来不是。
