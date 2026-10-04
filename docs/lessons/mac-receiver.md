# Mac receiver：CMIO、音频驱动与发布

> sysex、公证、Sparkle 与签名

Part of [`AGENTS.md`](../../AGENTS.md). Entries keep their original numbers
so a cross-reference from another lesson still resolves.

4. **`./scripts/test.sh` used to clobber signed builds.** Its
   `CODE_SIGNING_ALLOWED=NO` builds wrote into the same DerivedData
   that deploy scripts copy from — deploying right after gating
   shipped an app with zero entitlements (sysex activation then
   fails with "Missing entitlement"). Gate builds now use
   `.build/ci-derived-data`. If you touch signing, verify the deployed

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

88. **Three bugs in a row, all the same shape: the protocol was tested and
    the wiring was not (2026-09-30 evening).** Capability negotiation, the
    latency probe, and the settings deep-link each shipped with green unit
    tests and a working pure-logic model, and each failed the first time it
    met a real device. The pattern is worth more than the three fixes:
    - **`IBClientHello.capabilities`**: 7 tests passed — including "a phone
      only probes when the receiver advertised it" — and the receiver never
      sent the field, because I only ever edited `ReceiverSession`'s
      *consumer*. The negotiation degraded to "never measure anything", which
      looked exactly like the bug I was fixing.
    - **The ping payload**: `IBPingProbe` was exhaustively tested (including
      20 probes against a clock three hours out), and `sendLatencyProbe` fed
      `sendPingEcho` a whole *frame* where it wanted a *payload* — 13 bytes
      instead of 8, rejected as malformed every three seconds. The receiver
      log said it outright; the symptom was that latency simply never appeared.
    - **The settings URL**: verified by calling `NSWorkspace.open` and
      believing its return value. It means "the request was accepted", not
      "this pane exists" — all four candidates returned true while the first
      had not existed since macOS 25 (`com.apple.ExtensionsPreferences` is
      absent from the 32 pane identifiers still in the binary).
    **The rule:** a test that exercises a struct proves the struct is
    self-consistent. It cannot prove anyone ever *calls* it. For a
    cross-process feature, the assertion that matters is the marker in the
    *other* process's log — `latency measured: 8ms`, `activated app …
    raised=true` — not a unit test on your own side of a wire.

89. **`CFBundleVersion` is three numbers wearing one name, and two of them
    must never move (2026-09-30).** Bumping the release with
    `s.replace('CFBundleVersion: "8"', 'CFBundleVersion: "9"')` matched
    **two** lines — the app *and* the camera system extension — and an
    `assert count == 2` confirmed my own wrong assumption instead of
    challenging it. Replacing a system extension **resets the user's
    approval**: the camera vanishes from every app and has to be re-approved
    in System Settings (lesson 5). The mic driver is the same class. Only the
    app's number rises; the sysex and HAL plug-in stay frozen, because a
    Sparkle update replaces the app bundle alone (lesson 74(e)).
    `scripts/check-bundle-versions.sh` now refuses a release that moves
    them, comparing against the last committed yml rather than trusting a
    hard-coded list — a check that only *reports* the values cannot fail, and
    that was its own first (useless) version. It runs before anything is
    signed. Two traps while writing it: the app's display name contains a
    space, so awk `$2` matched `RemoteCrab` and every check came back "not
    found" (a guard that cries wolf is worse than no guard); and it correctly
    blocked a legitimate rebuild because I had already regenerated the appcast
    locally, so "version must exceed the appcast" must be judged against what
    is *published*, not what is on disk.

90. **Re-cutting a release over the same build number reaches nobody
    (2026-09-30).** The user said "nobody has downloaded it yet, just re-send
    build 9." Sparkle offers an update only when the published version is
    *higher* than the installed one, so re-cutting 9 skips everyone whose
    updater had already fetched it — precisely the people a fix is for. Cut
    10. The cost is one line; the cost of being wrong is a bug that is
    already shipped and cannot be pushed. Same instinct, opposite sign, as
    "nobody is on 1.0 yet so I can break 1.1" — both were about who the
    update *reaches*, not about whether a fix is needed.

91. **A stalled build is usually the network, and my diagnostics were worse
    than the retry (2026-09-30).** `codesign` reported `The timestamp service
    is not available` and I escalated to telling the user their proxy was
    intercepting Apple's notarization hosts — DNS showed
    `timestamp.apple.com → 198.18.0.241`, the Clash fake-IP range, which looked
    conclusive. The user, who had hit this exact wall in another project
    before, said it could not be happening. I had spent several probes trying
    to route around it; simply running the script again succeeded on the first
    attempt. **A measurement I can make is not a measurement of the thing**:
    `curl` failing to a host says the path `curl` took was broken, not that
    notarization would fail. When a script that succeeded earlier fails, the
    first hypothesis is transient, not a structural diagnosis.

92. **Parallel sessions will commit my working tree, and my own commits will
    silently omit half of it (2026-09-30).** Three times today a concurrent
    session swept the tree into its own commit — `0b89c23` "fix(windows)"
    carrying six iOS files, `aefd9c7` holding four of my leftovers. So the
    *code* was always safe while the *record* was wrong, twice: an iOS fix
    filed under a Windows headline, and a capability declaration that existed
    only in my unstaged tree, which is how the receiver ended up never
    sending a field that lesson 88 says it must send. When work in a shared
    repo is going out, re-read `git status` before assuming your commit
    contains your work, and stage deliberately rather than adding whole
    directories.
    **The same day, worse: `git stash` + `git reset`, which empties the
    tree.** The sequence was `reset: moving to HEAD` twice in the reflog,
    then their commit. Nothing was destroyed *because* they had stashed
    first — and that is the only reason. The part worth remembering is
    **which files the stash does not cover**:
    - **Tracked modifications go into the stash.** All 12 of my edited files
      survived only because of it. If they had reset *without* stashing, the
      work would have needed redoing from conversation history.
    - **Untracked new files are left alone** — so they are the *only*
      survivors, and that is precisely the dangerous case. Five new files
      (a type plus its tests) were still on disk when a commit landed that
      **referenced them by name**. So HEAD referenced a type that did not
      exist in HEAD: **the repository did not compile for anyone who cloned
      it**, and it stayed that way until the next commit. *A working tree can
      be fine while HEAD is broken*, because `swift build` reads the tree,
      not the commit.
    Recovery, in the order that matters: **tag the stash first**
    (`git tag stash-backup-YYYY-MM-DD stash@{0}`) and dump
    `git stash show -p` to a file — a concurrent session can `pop` or `drop`
    it at any moment, and then the recovery path is gone. Then restore
    **file by file** with `git checkout stash@{0} -- <path>`, never
    `git stash pop`: that stash was *mixed*, holding their Windows work and
    mine, and popping it would have re-introduced files they had already
    committed. Check each candidate — `git stash show --name-only` first,
    and diff to confirm a file is yours (an iOS file I thought I had never
    touched was in there, carrying only my own comment).
    **Verify HEAD independently, not the tree:**
    `git clone --no-local . /tmp/x && cd /tmp/x/Package && swift build`.
    The tree building proves nothing about the commit.
    And expect a chunk of your work to end up **inside someone else's commit**
    (`baff770`, "narrow the pre-existing crash"), which is untidy but far
    cheaper to live with than a rebase that fights their session. Leave it;
    note it in the closeout.

124. **Apple's Opus codec does NOT round-trip stereo through
     `AudioConverter` on macOS 26 — measure before building a music
     feature on it (2026-10-04).** For "use the iPhone as the speaker" the
     obvious transport is the existing mono Opus path with
     `channels: 2`. Measured, in a throwaway harness:

     | | encoded packet | decoded samples / 20 ms packet |
     |---|---|---|
     | mono 440 Hz | ~51 B | 960 (= 960 frames) |
     | stereo, left 440 Hz loud / right silent | ~115 B | **960** |

     The encoder really is doing stereo (2.3x the packet). The decoder
     returns **mono**, and at about a third of the input amplitude. Read as
     interleaved stereo, L and R come out with identical rms — which is the
     signature of a collapsed stream, not of a quiet one.

     **It is not the platform.** `afconvert`'s own stereo Opus round trip
     is correct on the same machine: encode a 1 s stereo WAV to
     `opus@48000`, decode it back, and the channels survive intact (L
     rms 8426, R rms 0 for loud-left/silent-right). So `AudioConverter`
     with the ASBDs we build is the thing that is wrong, and there is a
     good chance it is fixable — this lesson records that it is **not yet
     diagnosed**, not that stereo Opus is impossible.

     Two dead ends already checked, so nobody repeats them:
     * `AudioStreamBasicDescription` has **no** `mChannelsPerPacket` field
       in this SDK — only `mChannelsPerFrame`. The Opus "channels per
       packet" idea has nowhere to live.
     * `afconvert -d "opus@48000/2"` is **rejected** by ExtAudioFileSetProperty.
       Plain `-d opus@48000` works and inherits the source channel count, so
       `afconvert` is a usable reference even though you cannot ask it for a
       channel count.

     What the feature shipped with instead: **uncompressed PCM**
     (`AudioPacket.codec == "pcm"`, `channels: 2`). 48 kHz stereo Int16 is
     1.5 Mbps, which is small beside the H.264 already on the same link,
     and it costs **zero codec latency** — which matters more than the
     bandwidth here, because end-to-end delay is the feature's weak point.
     The lesson is not "avoid stereo Opus"; it is **"a platform support
     matrix is an assumption until you measure a round trip on your own
     OS, and a silent mono collapse is the failure mode you will not
     notice without two deliberately different channels."**

125. **A ring buffer read on a different thread than its writer needs the
     indices to have exactly one owner each — and a level log on BOTH sides
     of a pipeline is worth more than every packet counter (2026-10-04).**
     The "use the iPhone as the speaker" capture path ends with a ring: a
     CoreAudio realtime callback writes 512-frame chunks, a 10 ms pump reads
     960 frames (20 ms) and ships them. Symptom: packets flow at exactly the
     right rate, 492 of them reach the phone, the phone plays them, and the
     user hears **digital silence**.

     What located it was logging the signal level **twice, at the two ends of
     the suspect boundary**, in the same log line if possible:

     ```
     speaker packet:     bytes=3840 rms=0    peak=0     ← the assembled packet
     speaker tap level:  rms=1989 peak=8856             ← what the tap delivered
     ```

     Correctly sized, correctly paced, entirely silent — with the source
     loud, in the same instant. Every counter before that (packets sent,
     packets received, packets played, starved=0) said the pipeline was fine,
     because none of them measured *amplitude*.

     The structural lesson: **the realtime thread and the pump thread were both
     writing `readIndex`** — the callback's overflow handling does
     `readIndex = writeIndex - capacity` while the pump does
     `readIndex &+= 960`. Two writers to one index is a data race, and the
     unsigned `writeIndex &- readIndex` then wraps, so the
     `available >= framesPerPacket` guard passes on a garbage value and the
     pump reads slots that are not what it thinks they are. The fix is to give
     each index ONE owner — the callback publishes `writeIndex` and an
     overflow *count*, and only the pump advances `readIndex` — but note the
     race was only the *proximate* cause; the amplitude log is what made it
     findable at all.

     Generalisable, and it is the second time this session: **a test that
     counts things cannot see a value problem.** "492 packets arrived" and "the
     sound arrived" are different claims, and only one of them was true.
