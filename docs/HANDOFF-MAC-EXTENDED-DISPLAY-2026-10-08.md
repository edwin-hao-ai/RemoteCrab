# Handoff → Mac: Extended Display, the Swift half (needs Xcode)

> Windows session, 2026-10-08. This session implemented Windows Extended Display
> and, to make it work, touched the **Swift** side too: the `extendedDisplay`
> capability, the Mac advertising it, and the iOS row being gated on it.
>
> **None of the Swift changes have been compiled.** There is no Mac/Xcode on the
> Windows host, so this is an **unverified patch** the Mac session owns. (The
> repo's division-of-labor rule says Swift-only work should have been a document,
> not code; the user asked for the implementation, so here it is — please treat
> it as a proposal to build and test, not as done.)
>
> The Windows half is verified and green (`cargo test --workspace`, clippy,
> build, and the receiver self-tests). The driver is written but unbuilt — see
> [`HANDOFF-WINDOWS-EXTENDED-DISPLAY-2026-10-08.md`](HANDOFF-WINDOWS-EXTENDED-DISPLAY-2026-10-08.md).

## What changed on the Swift side

| File | Change |
|---|---|
| `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift` | new `IBClientHello.Capability.extendedDisplay` case |
| `RemoteCrabCore/Tests/RemoteCrabCoreTests/CapabilityNegotiationTests.swift` | 2 new tests (see below) |
| `RemoteCrabReceiver/ReceiverSession.swift` | the Mac now advertises `.extendedDisplay` in its `clientHello` |
| `RemoteCrabCapture/CaptureEngine.swift` | stores the peer's capabilities (`peerCapabilities`) from the live `clientHello`; `peerSupportsExtendedDisplay`; `grant(…capabilities:)`; reset in `clearOwner` |
| `RemoteCrabCapture/ContentView.swift` | the Extended Display row is gated on `!connectedIsWindows \|\| peerSupportsExtendedDisplay` instead of the bare `!connectedIsWindows` |

The old gate was hardcoded platform (`if !engine.connectedIsWindows`). The new
one is capability-driven, with the platform kept **only** as the fallback for a
legacy Mac that predates the flag but could always extend.

## What to run

1. **Package tests** (the two new ones are here):

   ```sh
   cd RemoteCrabCore && swift test
   # or the repo loop: ./scripts/test.sh
   ```

   - `CapabilityNegotiationTests.testExtendedDisplayIsCapabilityGated`
     — a Windows hello with no `extendedDisplay` decodes to `supports == false`;
     one that names it decodes to `true`.
   - `CapabilityNegotiationTests.testExtendedDisplayRoundTrips`
     — encode → parse → decode preserves `[.latencyProbe, .extendedDisplay]`.

2. **Both app targets**:

   ```sh
   xcodegen generate --spec project-ios.yml && xcodebuild -project RemoteCrabCapture.xcodeproj ...
   xcodegen generate --spec project-mac.yml && xcodebuild -project RemoteCrabReceiver.xcodeproj ...
   ```

   `TopBarIntegrityTests` must still pass — it asserts
   `engine.toggleExtendedDisplay()` still exists in `ContentView.swift` (it does).

3. **Real device (regression, no new hardware needed):** connect the Mac receiver
   and confirm the phone's mirror dropdown still shows **Extended Display**, and
   tapping it still creates the virtual display and streams it. The Mac path must
   be **byte-for-byte unchanged** — the only change is that the row is now
   capability-gated, and a Mac is not Windows, so the expression stays `true`.

## The behaviour to confirm (the whole point)

| Receiver | `extendedDisplay` advertised? | Row shown? |
|---|---|---|
| Mac (this build) | yes | yes |
| Mac (old build, no capability) | no | yes (platform fallback) |
| Windows + IddCx driver installed | yes | yes |
| Windows, no driver | no | **no** — the fix: no button that does nothing |

An old **iOS** build receiving the Mac's new `clientHello` ignores the unknown
capability word — already covered by
`CapabilityNegotiationTests.testUnknownCapabilitiesAreIgnoredNotFatal` and the
`[String]`-then-filter decode. So advertising it cannot break an older phone.

## What to look at while reviewing

- `ContentView.swift`: the gating expression and its comment. Confirm a
  non-Windows receiver is `true` and a driverless Windows receiver is `false`.
- `CaptureEngine.grant(…)`: `peerCapabilities` is set from **this connection's**
  hello only (never a remembered lookup), and `clearOwner` resets it — so a
  receiver that stops advertising the capability loses it, same as `platform`.
- `ReceiverSession.sendClientHello`: the Mac now lists four capabilities. No Mac
  behaviour depends on the new one; it is a declaration.

## Out of scope here

Actually finishing Windows Extended Display (building/signing the driver,
device e2e, the iPhone↔driver path) is the Windows driver's job, tracked in
`HANDOFF-WINDOWS-EXTENDED-DISPLAY-2026-10-08.md`. This document is only the
Swift half.
