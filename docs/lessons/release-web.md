# 发布、商店与网站

> App Store Connect、截图与部署

Part of [`AGENTS.md`](../../AGENTS.md). Entries keep their original numbers
so a cross-reference from another lesson still resolves.

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
