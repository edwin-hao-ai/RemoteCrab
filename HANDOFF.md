# Handoff: RemoteCrab v1.0 release

## Status
- Started: 2026-09-18 (continuation of the 2026-09-18 kimi session)
- Last update: 2026-09-19
- Completion: 95% — everything agent-doable is done; **iOS 1.0 is submitted for review**
- Committed: yes (`909254e`, `8a511c4`, `962bae9`; earlier `8cf12bd`, `9d2a399`)

## Done this session
- **TestFlight**: build `2026091802` attached to version 1.0 + Internal group
  (`IN_BETA_TESTING`). Tooling: `scripts/ios-app-store-testflight.py`.
- **Mac 1.0 distribution**: `scripts/release-mac.sh 1.0` → Developer ID sign +
  notarize + staple the app, the embedded virtual-mic pkg, and the DMG
  (`dist/RemoteCrab-1.0.dmg`, Gatekeeper-accepted). No provisioning profile
  needed (see AGENTS lesson 29). Also `build-mic-driver-pkg.sh` gained
  `--timestamp`.
- **Domain**: `remotecrab.app` → `vgoapp.com/remotecrab/`; new product page +
  `/remotecrab/privacy/` in `~/VGOAPP`, deployed to the VPS
  (`VGOAPP/scripts/deploy.sh`). ASC marketing/support URLs updated.
- **iOS download guidance**: `RemoteCrabLinks`; "Download for Mac" on the
  onboarding pair page, the waiting card, and Settings.
- **App Review notes** written (Demo Mode path, Mac download, permissions,
  privacy) + **demo video** `vgoapp.com/downloads/RemoteCrab-demo.mp4`
  (`scripts/demo-video.sh`).
- Fixed a latent trap: `project-ios.yml` now owns the version +
  `ITSAppUsesNonExemptEncryption`, so `xcodegen` can't revert them.

## TODO (human)
- [ ] ASC → App Information → **privacy policy URL** =
      `https://vgoapp.com/remotecrab/privacy/` (the API does not expose it).
- [ ] Install TestFlight `2026091802`; confirm the download buttons appear.
- [ ] Watch the review. If Apple asks for a real-camera demo, record the iPhone
      screen and re-stitch via `scripts/demo-video.sh` (same URL, swap file).

## TODO (product, not required for this release)
- [ ] Background microphone is NOT implemented (`UIBackgroundModes` absent).
- [ ] VoiceOver / Dynamic Type device pass; crash reporting.

## Decisions
- Mac app ships **outside** the Mac App Store (needs Accessibility + a CMIO
  system extension) — Developer ID + notarization.
- vgoapp.com (the VGO studio Vite site) hosts the product/privacy pages and
  the DMG, rather than a separate remotecrab.app site.
- Demo video uses a Simulator (macOS can't CLI-record a physical iPhone screen);
  the camera tile is empty and that is stated honestly in the review notes.

## Blockers / watch-outs
- The App Store `privacyPolicyUrl` cannot be set via the ASC API — browser only.
- `productsign` prompts once for the login-keychain password (key `diiformac`).
- scp/rsync to the VPS intermittently fail with "Connection closed" (fail2ban?);
  `cat file | ssh … 'cat > remote'` is more reliable.

## Verification
- `./scripts/test.sh` — 94 tests + both app builds (green).
- `spctl -a -vvv dist/RemoteCrab-1.0.dmg` → accepted, Notarized Developer ID.
- `python3 scripts/ios-app-store-testflight.py --status` — builds/version/groups.
- Live: `curl -I https://vgoapp.com/remotecrab/` and `/remotecrab/privacy/` → 200.

## Related files
- `scripts/release-mac.sh`, `scripts/build-mic-driver-pkg.sh`
- `scripts/ios-app-store-testflight.py`, `scripts/demo-video.sh`
- `RemoteCrabCore/Sources/RemoteCrabCore/State/RemoteCrabLinks.swift`
- `docs/RELEASE_READINESS.md`, `AGENTS.md` (lessons 29-36)
