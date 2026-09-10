# iBridge — Documentation

This directory holds the project's documentation. See the files
below in the order suggested for someone picking up the project cold.

## Reading order (recommended)

1. **[PRD.md](PRD.md)** — Product Requirements Document. What iBridge
   is, who it's for, scope across V0.1 → V1.0, what's explicitly
   out of scope, and the business model.
2. **[HANDOFF.md](../HANDOFF.md)** — Status handoff. What's done, what
   isn't, the single blocker preventing real-device e2e, and
   everything the next person needs to know to continue.
3. **[AGENTS.md](../AGENTS.md)** — Deep project context for an AI agent:
   repo layout, design system, wire protocol, how to add features,
   state vs. what's still needed for V1.0, what-not-to-do list.
4. **[E2E_TESTING.md](../E2E_TESTING.md)** — Step-by-step operator manual
   for getting the iPhone 14 ↔ Mac real-device e2e working.
5. **[PITFALLS.md](PITFALLS.md)** — Every gotcha we hit, organized by
   category. Read this before doing anything new.
6. **[SESSION_MEMORY.md](SESSION_MEMORY.md)** — A timeline of this
   development session, with the key decisions and lessons captured as
   they happened.

## Top-level docs (one level up)

- [README.md](../README.md) — Project overview + architecture diagram.
- [RUN.md](../RUN.md) — How to build and run the apps (sim and device).
- [PRIVACY.md](../PRIVACY.md) — Required for App Store / Google Play
  submission.
- [E2E_TESTING.md](../E2E_TESTING.md) — Same as above.
- [AGENTS.md](../AGENTS.md) — Same as above.
- [HANDOFF.md](../HANDOFF.md) — Same as above.

## Top-level scripts

- `scripts/test.sh` — Run all 26 unit + e2e tests + both builds.
- `scripts/install-to-iphone.sh` — Build + install on a real iPhone.
- `scripts/check-e2e-readiness.sh` — Sanity check Bonjour + permissions.
- `scripts/e2e-simulator.sh` — Full simulator e2e (auto screenshot).
- `scripts/release-ios.sh` — Build + upload IPA to App Store Connect.
- `scripts/render_ui_screenshots.swift` — Generate the design screenshots.
- `scripts/generate-ios-app-icons.sh` — Generate AppIcon set from a 1024² source.
- `scripts/ios-app-store-metadata.py` — App Store Connect API client.
- `scripts/e2e_receiver_demo.swift` — Headless CLI e2e for the receive
  pipeline (no real hardware needed).
