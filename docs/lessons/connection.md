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

### Telling whether an installed build is current — binary hash is useless

After the tree was reset I could not honestly answer "is `/Applications`
current?" and reached for the obvious tool: build it again and compare.
**That comparison cannot work.** Two Release builds of *identical source* in
this repo produced different Mach-O files (`30391a15…` vs `6bec6b93…`),
because Swift/LLVM embeds a fresh UUID per object file. The 352-byte delta
between the installed build and a fresh one was pure noise.

What does work is **string literals the change introduced**, because they
survive compilation intact and are absent from the old build:

```
installedApps frame:      已装 1  新构建 1   ← my frame-size log
windowPickerFreshness     已装 2  新构建 2   ← my picker-freshness property
activateAllWindows        已装 0  新构建 0   ← absent from BOTH: inlined
```

A keyword that greps zero on both sides tells you nothing — `activateApp`
switches to `.activateAllWindows`, and that selector does not appear in the
binary at all. So: verify the markers you can see, state plainly which ones
you could not check, and do not let a hash comparison stand in for evidence.

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

120. **22 条 e2e 断言因为一个被拒绝的握手而全红，而根因是「手机上还连着
    另一台电脑」—— 这是一个正确的产品行为。** 报的是「iOS 上还是显示 Command」，
    跑 `e2e-device.sh` 却得到 22 个失败，连握手本身都缺。第一反应是自己改坏了，
    但我的 diff **一行网络/配对代码都没有**。
    真因在两处日志的**并集**里 —— 脚本把手机 forensic 日志也拼进了同一个文件：
    - Mac：`sessionReply: busy owner=EDWIN`（每 16 秒重试一次）
    - 手机：两个不同 id 交替到达，`ownerSet=false`，一个 `accepted` 一个 `busy`

    读手机**持久化的 `seenComputers`** 一锤定音（别再从日志推断）：

    ```
    EDWIN   …-98db-0bce2018971c  streaming   ← 另一台机器
    EDWIN   …-98db-023a844ff7a4  streaming   ← 同一台，旧身份
    本机    ECBDD7BA-…           refusedBusy ← 被正确拒绝
    ```

    `…98db…` 两条 **node 相同、id 不同**。所以 e2e 的前置条件「一台 Mac + 一台手机」
    在这台机器上**不成立**。**教训：先确认那台电脑没连着手机，再跑 e2e**，
    否则一整轮的「红」会被误读成自己刚改的东西坏了（lesson 111）。
    **附带一条**：偏好锁 (`preferredMacs.preferredId`) 指向的是那个**已经不存在
    的旧 id**，而它 armed 的 10 分钟 TTL 是**按 id 判断**的 —— 我第一次重跑早了
    46 秒（`14:51:52` 起跑，TTL 到 `14:52:38`），结果一模一样。
    **时序断言要先算好时间。**

121. **`seen` 只按 `id` 去重，于是「按 id 删」永远删不掉换过身份的机器，
    而 `seenLimit = 20` 是唯一的上限。** Windows 接收端过去**每装一次换一个
    `pc_id`**（存在应用数据目录里，卸载清理会删），所以每重装一次手机就多一行
    同名条目 —— 用户报的「多个 Windows 设备」。`c9c0463` 修了接收端
    （`MachineGuid`），但**手机上的旧行没有任何机制会消失**。
    iOS 侧两条规则，都放在纯函数 `MacPairingStore.pruned` 里（`UserDefaults`
    之外可测）：**同名合并**（同名只留 `lastSeen` 最近的）和**30 天过期**。
    代价是两台真同名的机器会并成一行 —— 这是有意的选择，替代方案是一排
    相同行、且选错哪一行**看不出来**。
    **两条它绝不能做的事，各有一个测试替它说**：绝不碰 `paired`（token 在里面，
    删了要重新批准）；清掉指向已删 id 的偏好（留着会让所有其他电脑一直收到
    「使用中」）。

    **一个自己踩的坑**：第一版 fixture 按**最旧→最新**排列，结果「最后写入胜出」
    这个 bug 恰好和它一致，断言就**空过了**。真实 `seen` 是**最新在前**
    （`noteSeen` 插在 index 0），那个顺序下「最后写入胜出」保留的是**最旧**的。
    **把 fixture 排成它声称的顺序，否则你测的是另一个实现。**

122. **同名合并 + 过期，兜底还要给「点得动」这件事一个理由。** 纯函数被输入顺序
    坑了一次之后改成按 `lastSeen` 取最优、输出按 `lastSeen` 降序 —— 但
    `testEqualTimestampsStillProduceADeterministicOrder` 仍然失败，因为
    `seen(…, daysAgo: 0)` **每项各调一次 `Date()`**，所以「并列」其实差了几微秒。
    **并列要用一个共享的时间戳构造，否则测试根本没测并列。**
    顺带补了 `id` 作为 tiebreaker：不加的话行序（以及测试）会依赖哈希。

130. **一个「顺便清理」的早退优化，会把函数的承诺变成谎话 —— 而优化本身是对的。**
    `pruneStale` 原本长这样：

    ```swift
    if seen.count == before.count { return false }   // 没删任何东西就不用写盘
    if let preferredId, !seen.contains(...) { clearPreferred() }
    ```

    「数量没变就没动过数据」这个推理**是对的**（同名合并和过期都必然减员），
    所以它看不出错。但它让后置条件变成了假的：**偏好可以指向一个 `seen` 里
    根本没有的 id** —— `setPreferred(id:)` 接受任意字符串，而
    `CaptureEngine.setPreferredMac`（当时无调用者的死代码）正是这么调的。
    那种偏好会一直 armed 到 10 分钟 TTL 到期，期间**每一台**别的电脑都收到
    「使用中」。
    修法是把清理挪到早退**之前**，无条件执行 —— 一次字典查找而已。
    **教训：一个函数有后置条件，就不要用「顺便省掉一点工作」的早退把检查挡在
    后面；要么检查和写入绑在一起，要么就别声称这个后置条件。**
    而「无调用者」不是「不可达」的理由 —— 它是**等着被人接上**的理由。

131. **一个叫「Forget」的按钮，如果列表读的是另一个数据源，它就没做到它承诺的事。**
    「选择电脑」列表读的是 `seen`，而 Settings → 已配对电脑 → 「Forget」
    只调 `store.forget(id:)`，它只动 `paired`。结果：点了 Forget，
    回到列表那台机器**还在**（变成一个「未配对」的行）。而列表里的行本身
    是个「设置偏好」的按钮，不是删除 —— 所以用户**没有任何办法**清掉一行，
    只能等 30 天过期。`forgetSeen(id:)` 早就存在，**零调用者**。
    修法：`forget` 里一并 `forgetSeen`。删 `seen` 行是安全的 ——
    `PairingPolicy` 只读 `paired`（token）和 `preferred`（门），
    `seen` 的两个读者就是列表自己的图标和名字，而一台被忘记的电脑
    本来就不该再有图标。
    **一般化：一个控制项的名字是它对用户的承诺，去核对那个名字指向的
    到底是哪份数据。**

132. **「切换到另一台电脑」失败时，手机会把自己锁死 —— 而且锁的是所有人，包括
    正在用的那台。** 用户报「有时候连不上」，听起来像网络玄学，实际有一条精确的
    分界线。Mac 端对 `sessionReply` 有三种反应，**只有一种会自己回来**：

    | Mac 的状态 | 行为 | 切过去会怎样 |
    |---|---|---|
    | `busy` | `scheduleSlowRetry()` 每 15 秒 | ✅ 接得上 |
    | `denied` | `// Manual retry only`，**完全不排重试** | ❌ 永不 |
    | 关了自动重连 | `scheduleSlowRetry` 立刻 return | ❌ 永不 |

    睡着 / 不在同一网络 / 被拒绝 —— 这四种都是「它不会来了」，而手机**不知道**。
    更糟的是 `decide()` 对**每一个**非目标 id 无条件回 `busy`，而偏好的新鲜期是
    **10 分钟 TTL**。所以「选了一台不会来的电脑」= 手机在 10 分钟内谁都连不上，
    唯一出口是三层菜单深处的「取消」。**一次失败的切换就把手机变成砖。**
    修法不是加提示，是**给目标一个短宽限期**（30 秒 > 被拒电脑的 15 秒慢重试），
    到点自动放弃偏好、门重新对所有人开。实测：`t=0/15/29s` 旧 owner 拿到 `busy`，
    `t=31s` 变回 `pending`。**10 分钟自伤 → 30 秒自愈，零 UI。**
    关键实现位置：判据放在 store 的 `effectivePreferred()`，**不**放进
    `PairingPolicy` —— policy 只需要知道「有没有偏好」，时间概念留在 store，
    这样那条纯逻辑测试不需要时钟。

133. **「你现在归我控制」的释放入口不该叫「选择电脑」。** 用户问「被一台电脑占用了
    怎么让它断开」—— 而 Disconnect 藏在 **⋯ → Choose a Mac → 会话区**，
    一个想「别再操控我的手机」的人看到的是一个说自己想去挑电脑的按钮，
    触控板/键盘/投屏三个界面本身一个入口都没有。
    修法是 ConnectionSheet 在已连接时直接给一个 Disconnect（状态胶囊 1 跳可达）。
    **这不违反「不要把调试用的逃生口当产品出口」**：「别再操控我的输入」是用户的
    正当请求，而替代方案是十分钟锁死。

134. **共享工作树里并行 session 会把你**正在写**的代码用**它自己的**提交说明推上去。
    本轮第三次撞上：我的 Disconnect / `preferredGaveUp` / 6 条新文案被
    `2adb456 "fix(ios): two independent toggles behind the audio button"`
    一起提交了。危害不是代码错（HEAD 依然绿），而是**历史在说谎** ——
    后来的人读 `2adb456` 会以为音频按钮那件事顺带解决了 10 分钟锁死。
    **能做的只有诚实记录**：在自己的提交说明里写清「UI 那一半落在了 `2adb456`，
    因为并行 session 把它连同我的改动一起提交了」，**不要改写已经推送的历史**。
    （前面两次是我自己的问题：`git add -A` 捞进别人的半成品。这次是反向的 ——
    别人 `git add -A` 捞走我的。**共享工作树里 `git add -A` 是双向的陷阱。**）

135. **用「名字」而不是 id 过滤列表，在两台机器同名时不是「少一台」，是「一台都不剩」。**
    用户报「连上 Windows 之后想切回 Mac，完全切换不了」。真因不在网络：手机日志
    显示切换**确实发生过**（`06:21:08 hello ECBDD7BA ownerSet=false → accepted`），
    慢的原因是那 5 分钟里**本机接收端根本没在跑**（并行 session 正在重装）。
    但「完全切换不了」有第二个、也更致命的成因，在选择列表这一行：

    ```swift
    ForEach(engine.seenComputers.filter {
        $0.id != engine.connectedMacId && $0.name != engine.pendingMacName
    })
    ```

    按**名字**排除了待批准的那台。而这台机器当时恰好有**两台都叫 EDWIN**
    （Windows 接收端过去每装一次换一次身份，同名）。拿真实数据代进去：

    ```
    old rule lists: []          ← 一台都没有
    new rule lists: ["win-1", "mac-1"]
    ```

    **整个列表空掉。** 用户看到的字面意思就是「切换不了」——
    不是点不动，是**根本没有可点的东西**。
    修法：过滤只用 id；`pickerRows(seen:connectedId:)` 抽成纯函数可测。
    **关键性质：这个 bug 无法用「改一个值」逆向验证，因为修法是「删掉一个输入」** ——
    修好之后函数里根本没有 `pendingName` 这个参数，旧行为无法表达。
    这时候的证明方式是**拿用户真实数据把旧规则代进去跑一遍**，而不是伪造一次 revert。

136. **「状态说了什么」和「状态能做什么」是两根独立的线，缺一根用户就会卡住。**
    Mac 端被占用时只说「这台 iPhone 正被 EDWIN 使用」，然后给一个 **Retry** 按钮 ——
    而只要另一台电脑占着手机，**Retry 永远不可能成功**。该做的事（去手机上选这台电脑）
    在任何界面上都没有写。手机侧同样：切换进行中的状态**只在选择面板里渲染**，
    而 `currentAlert` 对 `.connected` 和 `.idle` 都返回 `nil` ——
    `setPreferredComputer` 会踢掉当前 owner，`clearOwner(.disconnected)` 把状态置成
    `.idle`，于是主界面从「正在接收 Windows 的画面」变成**什么都没有**。
    **一个正在工作的切换和一个失败的切换，在屏幕上长得一模一样** —— 这就是
    「让用户搞半天都搞不明白」的机械原因。
    修法两边对称：Mac 端补「去手机的『选择电脑』里选这台，重试单独点没用」，
    iOS 端把切换中/已放弃提到 `currentAlert` 的最前面（它必须**压过**
    connected 和 idle，因为那正是它俩返回 nil 的场景）。
    顺带删掉一个死 key（旧文案已无人引用）并修掉一处中文里多出的空格。
