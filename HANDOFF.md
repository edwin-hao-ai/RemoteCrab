# Handoff: website landing pages + promo video

## Branch / Worktree
- Branch: `main` (both repos), no worktree
- iBridge: `e226737` … session work in `c3a77d8`
- VGOAPP: `eb40913`
- Both pushed and in sync with origin.

## Status
- Started: 2026-09-27
- Last update: 2026-09-27
- Completion: ~85%
- Committed: yes (3 commits this session)

## Done
- [x] **Ten per-feature landing pages** at `/remotecrab/features/<slug>/`:
      extended-display · camera · microphone · screen-mirror · trackpad ·
      keyboard · voice · app-switcher · transfer · automation. Each with its
      own `<title>`/description/hreflang; one shared
      `RemoteCrabFeaturePage.tsx` template; one JS bundle for all ten (the
      slug is read from the URL). Site only — no app impact.
- [x] **`/remotecrab/suites/`** — the context-mode registry: 18 suites,
      49 real bundle IDs, transcribed from `ContextProfiles.swift`, with
      suite titles taken from the app's own `IBLocale` strings. Main page
      links to it above the FAQ.
- [x] **The site never mentioned extended display or screen mirror** — both
      shipped long ago (AGENTS lesson 64/70) and were absent from the site.
      Added, plus real capture on every page.
- [x] **`scripts/capture-feature-shots.sh`** — drives the app on a booted
      simulator through the E2E hooks, one launch per surface. Per-locale
      (`-en`). Three new E2E sheet hooks (`context`/`send`/`settings`).
- [x] **`scripts/_shot_ok.py`** now rejects system alerts (AGENTS lesson 76).
- [x] **Real screenshots in both locales** on the site. 7 slugs per language.
- [x] **Three YouTube videos published** (see below), all 公开.
- [x] ReplayKit demo recorder moved to `#if DEBUG` only (no release cost).

## TODO
- [ ] **Captions as a real track.** All three videos have only burned-in
      subtitles. SRT files are ready at
      `~/Videos/RemoteCrab/final/remotecrab-promo-{75s,50s,50s-en}.srt`.
      YouTube's subtitle row stays disabled until its own auto-transcript
      exists; when it does, upload each SRT by hand (Content → edit →
      视频元素 → 字幕 → 添加).
- [ ] **Four screenshots still have no real capture** — `screen-mirror`,
      `extended-display`, `app-switcher`, `voice`. They need a live Mac
      session; the receiver's link kept dropping with a simulator peer
      (`no pong for 9s`), so those surfaces never populated. A real iPhone
      against a real Mac should work — `scripts/e2e-device.sh`.
- [ ] **Video colour is still the weak spot.** Cut 2 fixed motion and real UI
      but the frame palette is still near-black + blue/purple, which is what
      the user first rejected. Three options were offered: a warm accent
      against the cold ground, letting the captures bleed light onto the
      background, or inverting to a light ground. Not attempted.
- [ ] **Pricing.** The site still says 免费 / no subscription in the hero and
      FAQ; the user intends to charge. Blocked on the user for price and
      free-tier boundary. Do not invent one.

## Decisions
- **Kickstarter is not the channel.** Analysed against NanoKVM/Duet: both
  are *hardware*, and crowdfunding only works at high ticket or where
  aggregation is required. Also "Kickstarter is not a store" rules out
  selling an App Store app as a reward. Landing page + waitlist is the
  prerequisite for any crowdfunding, and it does not exist yet.
- **Website and video may differ in register.** The site stays quiet and
  restrained (it converts); the video has to fight for attention. Cut 1
  applied site restraint to the video and was correctly rejected as static.
- **A workflow tool no shipping user needs goes in `#if DEBUG` or
  `scripts/`** (the user's own line, now in AGENTS "What NOT to do").
- **Screen-mirror / extended-display beats stay drawn, never faked.** Frame
  4's worker was told explicitly to refuse substituting another real
  screenshot; it labelled the two drawn beats `ILLUSTRATED`.

## Failed Approaches
- **Screenshot capture without a boot-cycle.** Seeding `TCC.db` and calling
  it done: ten of ten frames were permission alerts. `tccd` caches every
  decision in memory; the simulator has no `killall`, and
  `launchctl kickstart system/com.apple.tccd` is the wrong target
  (`user/com.apple.tccd` is rejected by `simctl spawn`). Only a
  shutdown/boot makes it reload. Now in the script.
- **`simctl privacy` for the camera** is a silent no-op after a reboot
  (lesson 27), which is why the camera prompt kept covering the surface.
- **`captions.mjs` "succeeding" with no output.** The shared skills dir is a
  symlink, so the script's main guard never fires. Exit 0, no file. Invoke
  by the real path under `~/.claude/skills/`.
- **YouTube Studio title/description via `evaluate` or CSS `fill`.** The
  fields are in a shadow root; only `fill` with an `snapshot` `@e` ref works,
  and the refs appear only after the upload finishes. An unchecked `fill`
  failure is how a 1.4 KB description ended up in the title field once.
- **Making the second promo video playable.** It is 公开 with no
  restrictions and 0:57 recognised in Studio, but the watch page never
  returned player data (checked over ~5 min, then the third upload rendered
  fine). Not diagnosed; may be propagation, may not be.

## Blockers
- Pricing decision (user).
- The four unshot screenshots need a real iPhone + a stable Mac session.

## Next Step Recommendation
1. Add the SRT caption tracks to all three videos once YouTube's
   auto-transcript appears — the tracks are the durable, accessible form;
   the burned-in ones cannot be turned off.
2. Decide the free/paid split, then re-sweep the site copy (hero, FAQ,
   `compatibility` strip) — it currently claims free with no subscription.
3. A real-device pass for the four missing captures
   (`scripts/e2e-device.sh` with the four E2E surface hooks).
4. Video colour iteration, after watching cut 2 with fresh eyes.

## Verification Before Continuing
- `./scripts/test.sh` — 206 tests + both app targets.
- `cd ~/VGOAPP && npm run build`, then a headless-Chrome screenshot of the
  changed route in BOTH locales (`--lang=en-US` to force the English path,
  since the provider reads `navigator.language` first).
- `https://vgoapp.com/remotecrab/{,suites/,features/<slug>/}` → 200.
- `./scripts/capture-feature-shots.sh <sim> .build/shot-dd <out> [-en]` —
  every slug must pass `_shot_ok.py`; **then look at the images**.

## Related Files
- `scripts/capture-feature-shots.sh` — the screenshot pipeline
- `scripts/_shot_ok.py` — readiness check (alert rejection)
- `scripts/marketing-video.sh` — Mac+phone side-by-side compositor (unused
  so far; the HyperFrames path won)
- `RemoteCrabCapture/ScreenRecorder.swift` — DEBUG-only ReplayKit recorder
- `RemoteCrabCapture/ContentView.swift` — new E2E sheet hooks
- AGENTS.md lessons 76-78 + the off-repo tooling notes
- VGOAPP: `src/pages/RemoteCrabFeaturePage.tsx`,
  `src/pages/RemoteCrabSuitesPage.tsx`,
  `src/i18n/remotecrab{Features,Suites,Content}.ts`
