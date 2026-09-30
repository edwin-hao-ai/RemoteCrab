# 连接、配对与重连

> Bonjour、热点、重连与状态机

Part of [`AGENTS.md`](../../AGENTS.md). Entries keep their original numbers
so a cross-reference from another lesson still resolves.

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

28. **Bonjour endpoint description strings escape bytes as `\DDD`
    (2026-09-16).** `"\(result.endpoint)"` for a service endpoint is a
    display string like `RemoteCrab\032-\032iPhone…._remotecrab._tcp.local`
    (`\032` = space, em dash = `\226\128\148`). Never show it raw — use
    `DiscoveredPhone.displayEndpoint` (decimal-escape → UTF-8 decoder in
    `ReceiverSession.swift`). `phone.endpoint` on a Bonjour-discovered
    phone is display-only (dialing goes through `serviceEndpoint`); on a
    direct-link phone it's the IP.

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

40. **Only ONE row may anchor itself above the system keyboard
    (2026-09-22).** In keyboard mode both `KeyboardScreen`'s shortcut bar
    (padded by `keyboardHeight`) and `ContentView`'s PTT row (pushed up by
    SwiftUI keyboard avoidance) landed in the same band, so the blue ⌨️
    toggle covered the context chip and ⏎. Fix: `ContentView` does not
    render `pttRow` while `activeSurface == .keyboard` — that surface
    already has a "back to trackpad" button in its header. If a bottom
    control must exist in keyboard mode, it belongs INSIDE KeyboardScreen's
    layout, not as a ContentView overlay.

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

59. **The Mac picker listed the connected Mac twice (2026-09-24).** The
    sheet renders `preferred` / `session` (current owner) / `paired`
    (allow-list); the connected Mac appeared in the session row AND the
    paired row. Filter the paired list by `id != connectedMacId &&
    name != pendingMacName`.

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

---

94. **A timer cannot decide whether a remote list is empty (2026-09-30).**
    "打开 App…" flashed *No apps listed yet* on every first open, then popped
    the real grid in underneath. The sheet had a `Task.sleep(500ms)` and a
    `loaded` flag standing in for the receiver's answer — and the measured
    cold cost of producing that answer is **2356 ms** (113 apps, one
    rasterised icon each, `/Applications` walk on the dev Mac; a warm
    `NSCache` is 1 ms, which is why it only ever happened once per launch).
    **Only the arrival of `installedApps` (0x21) may end a wait.** The
    round trip belongs to the *other* machine, so any timeout on our side is
    a guess that becomes a lie to the user.
    - The timeout did not even buy what it claimed. Its stated purpose was
      "so an empty result shows the empty state instead of an endless
      spinner" — but it merged three genuinely different states: still
      working, *genuinely* zero apps, and nobody answering (the receiver
      sends 0x21 only in answer to 0x20, so silence is a dead link or a
      receiver too old to know the frame). One `Bool` cannot carry three
      sentences, and it was carrying the wrong one. `IBListRequestGate` is
      now four phases, and a late answer is still accepted so a slow
      receiver heals instead of demanding a retry.
    - **A deadline is still needed** — without one, a disconnected Mac
      spins forever. But it must be long enough to clear the *measured*
      round trip (8 s, with a test asserting it exceeds the measured 2.4 s
      so nobody tunes it down for a "snappier" feel), and it must not touch
      an already-answered gate.
    - Same class, opposite direction: a **list you already have must stay on
      screen** while a refresh is in flight. Swapping 113 usable tiles for a
      spinner to prove we are working is a downgrade.

    The same report contained a second bug with the same root cause — no
    refresh mechanism, because the list the picker renders and the event
    that changes it were never connected:
    - The switcher renders `macWindows`, but the Mac's workspace observer
      only republished the window list on `didTerminateApplication`. A
      launch sent `appList`, **a frame the picker does not render**, so an
      app opened from the launcher could not become a card until the sheet
      was reopened. **Check what the view actually binds before adding a
      refresh — the event was firing, into a field nobody looked at.**
    - `didLaunchApplication` alone is not enough: it fires when the process
      appears, usually *before* it has a window, so the rebuild lists an app
      with no card — the original complaint, just later. The usable signal
      is the launch **plus** the activation that follows, so
      `IBChangeCoalescer` (pure, tested) collapses the pair into one rebuild
      once the burst goes quiet. `didActivate` on its own fires on every app
      switch and every dialog, which is why it only counts while a launch is
      pending.
    - The 30 s "picker is probably open" gate was **shorter than the flow it
      had to survive** (open the picker, browse the launcher, pick an app),
      so the refresh was dropped exactly when it was needed. Now 120 s.
    - Windows had the identical shape (window list republished on quit only)
      and no launch observer at all, so it got a **condition-polled**
      refresh on its own thread — the select loop stays free, and a slow
      launch is not published as an empty result.

### The 14.6 MB frame behind it, and why JPEG was the wrong answer

The round trip was not slow because of the timer. It was slow because the
`installedApps` frame was **14.25 MB**: `InstalledAppsCatalog` drew each
icon through `NSImage.lockFocus` into a "96 pt" box, `lockFocus` sizes the
backing store to the *current backing scale* (so 96 pt became **192×192**),
and a 192×192 **lossless** PNG of a macOS icon is ~94 KB. 113 apps = 10.7 MB
of PNG = 14.25 MB of base64, one message.

The obvious fix is JPEG: measured 7 KB per icon, 12× smaller, same pixels.
**It was implemented, shipped to a real iPhone, and reverted.** JPEG has no
alpha channel, a macOS icon is a *squircle with transparent corners*, and the
encoder fills those corners with opaque white — the phone drew a **white
square behind every single tile**. Verified on the device, not reasoned
about. Two more dead ends measured while looking for the right answer:
`kCGImageDestinationLossyCompressionQuality` (PNG palette quantisation) is
**silently ignored** by ImageIO's PNG encoder — three settings produced byte-
identical output; and the "94 KB per icon" figure is an artefact of the
`lockFocus` path, not of PNG — drawn into an explicit rep the same 192 px
icon is 31 KB.

The size was won on the **pixel axis** instead, which is where the defect
actually was:

| shape | frame | per icon | corners |
|---|---|---|---|
| `lockFocus` 96 pt → PNG (old) | 14.25 MB | 94 KB | ok |
| explicit rep 192 px → PNG | 3.5 MB | 31 KB | ok |
| **explicit rep 128 px → PNG** | **2.40 MB** | **15 KB** | **ok** |
| explicit rep 192 px → JPEG | 1.06 MB | 6 KB | **white squares** |

128 px is not a guess: the launcher tile is 64 pt and an iPhone 14 is @2x, so
it is pixel-exact for the device it shipped on. **Re-measuring the old code
on an idle machine also corrected a number reported earlier as 6.7–16 s: it
is 5.5–7.1 s. The 16 s was a measurement made while a build was running.**

### What only the device could find

Two of these are invisible to code review and to every unit test:

- **The sheet is reachable before the Mac is.** It can be opened from the
  switcher the instant the app launches, while the handshake is still
  running, and `.task` fires once — so the sheet sat on "not connected" for
  the whole handshake (8 s on a real session) and needed a manual refresh
  for a link that had already come up. Fixed by re-requesting on
  `connectionState → .connected`. Nothing about the state machine was wrong;
  what was missing was the *second* trigger.
- **`launchApp` succeeding logs nothing.** `SystemCommandHandler` only logs
  the failure branch, so a successful launch is invisible on the Mac side —
  which is exactly the event bug 2 depends on. Worth a log line next time.

### Do not run the receiver from a scratch path (see also lesson 80)

Testing from `/tmp` looked harmless and was not. Two separate things broke:

1. `ensureRegistered()` sees "the host app moved" whenever the binary is not
   at the path recorded for the system extension, so **every run from
   `/tmp` submits a deactivation request for the user's approved virtual
   camera** (and every run from `/Applications` afterwards sees the
   `/tmp` path in the record and re-registers). This is lesson 80's trap in a
   new shape: the *test* was what moved the app, and the app's own
   self-repair logic is what armed the damage.
2. The Screen Recording TCC grant is keyed to the signing identity, so the
   scratch build reports "not granted" while the installed one is still
   authorised — which looks exactly like a permissions bug in the product.

And: **two receivers running at once fight over the same phone.** An earlier
session had been restarted from `/Applications` and was not visible in
`pgrep -f RemoteCrabReceiver` (the binary is `RemoteCrab`). Count the
processes, do not pattern-match the name.

### Finally: installing the receiver the right way

Replacing the build under `/Applications` does **not** need a provisioning
profile dance, because `release-mac.sh` already encodes the whole recipe:
archive with automatic signing, replace `Contents/embedded.provisionprofile`
with the Developer ID profile that carries the System Extension Install
entitlement, then re-sign the nested system extension, Sparkle and its XPC
services, then the app — `codesign --force --options runtime --timestamp`,
no `--deep`. Do that and all three things that `/tmp` had broken come back:

```
accessibility trusted: true
extension registration is up to date        ← no re-registration, approval kept
published 6 windows (1 with previews, canCapture=true)   ← Screen Recording kept
```

Same binary identity ⇒ every TCC grant survives. The scratch build was
never a signing problem to be worked around; it was a different app as far
as the system is concerned.

### Device results (iPhone 14 / iOS 26, Mac build 11)

```
15:42:18 [launcher] requested with no link
15:42:18 [launcher] requested                     ← the connectionState retry
15:42:19 [launcher] answered: 113 apps, 2458KB, after 1246ms
23:57:25 published 6 windows (1 with previews, canCapture=true)
23:57:51 window list: 7 windows from 25 SC windows
23:57:51 published 7 windows                      ← Safari launched; nobody asked
```

The last pair is bug 2: the old code republished the window list **only** on
termination, so a launch produced no such line at all. The 0.9 s is the
settle delay plus the poll interval, and it is a *push* — the phone made no
request. An earlier attempt at the same test, with the picker closed for 11
minutes, produced **no** refresh, which is the `windowPickerFreshness` gate
working: the same mechanism neither fires when nobody is looking nor stays
silent when they are.

    351 Core tests, both app targets, Windows suite. Everything above is
    device-verified on one phone and one Mac.
