# Windows drivers — status (2026-10-11)

The two Windows features that need a **driver** are the only ones that cannot
be finished from a Mac. This file says exactly what exists, what is missing,
and what a person with a Windows machine + WDK + a code-signing certificate
must do. Read it before claiming either feature is done.

> Written on macOS. **Nothing here was built, signed, or run on Windows.**
> Every "done" below is receiver-side code that compiles and is unit-tested;
> every "not done" is a driver.

---

## 1. Extended Display (iPhone as a second monitor)

Windows has **no user-mode way to add a display** (macOS uses the private
`CGVirtualDisplay`). A monitor the OS and every app believe in has to come from
an **IddCx indirect display driver** — a UMDF (user-mode) driver, so it cannot
blue-screen, but it still must be **signed** and installed as a device.

| Piece | Where | State |
|---|---|---|
| `extendedDisplay` capability (wire) | `rc-protocol/src/events.rs`, `IBEvents.swift` | ✅ |
| Receiver advertises it only when the driver answers | `rc-net/src/lib.rs`, `supervisor.rs` | ✅ integration test green |
| Receiver streams the virtual display | `rc-app/src/mirror.rs` (`Source::VirtualDisplay`) | ✅ compiles, window path tests pass |
| `--vdisplay-probe` diagnostic | `rc-app/src/args.rs`, `main.rs` | ✅ |
| iOS row gated on the capability | `RemoteCrabCapture/ContentView.swift` (`canExtendDisplay`) | ✅ present; hidden on Windows until the driver works |
| MSI installs/removes the driver (one UAC) | `windows/tools/RemoteCrab.wxs` | ⚠️ not built (needs the driver payload) |
| **The driver** | `windows/drivers/rc-idd/` (`.cpp/.h/.inf/.vcxproj/build.ps1/README.md`) | ❌ **written, never compiled** |

**Contract** (so a driver author needs nothing else): control pipe
`\\.\pipe\RemoteCrabVDisplay` (`PING`→`PONG 1`, `MONITOR <w> <h>`→`OK`,
`MONITOR OFF`→`OK`); frame ring `%ProgramData%\RemoteCrab\vdisplay-ring.bin`
(same 64-byte-header BGRA double-buffer as the virtual camera). Full detail:
`windows/drivers/rc-idd/README.md`.

**To finish** (on a machine with VS 2022 + Windows SDK + WDK + admin):
1. `cd windows\drivers\rc-idd; pwsh -File build.ps1` — fix whatever the compiler
   says (this is the untested part; expect a few).
2. Test-sign + install on a throwaway machine (`bcdedit /set testsigning on`,
   self-signed cert, `signtool`, `pnputil /add-driver rc-idd.inf /install`).
   Confirm `Get-PnpDevice -FriendlyName 'RemoteCrab Display'` and
   `remotecrab --vdisplay-probe` → `protocol version 1`.
3. Verify the ring: send `MONITOR 1920 1200`, watch `frame_seq` climb, dump a
   frame to PNG (as `rc-vcam-source/examples/dump_ring.rs` does).
4. Verify the phone: build the iOS app with this change; with the driver
   installed the mirror dropdown must show **Extended Display** and tapping it
   must bring up a real monitor and stream it.
5. Release-sign (EV cert + Microsoft attestation signing) and stage the driver
   files into the MSI; `release-windows.sh` must pass `-d VdisplayBuild=true`.

---

## 2. Virtual microphone (phone mic as a Windows *input device*)

Two different things, often confused:

| Capability | State |
|---|---|
| **Play the phone's mic on this PC's speakers** | ✅ **done** — `rc-audio` (Opus/PCM → cpal), wired in `rc-app`, muted by default like the Mac |
| **Expose the phone's mic as a Windows microphone** (so Zoom/Teams can *select* it) | ❌ **not implemented** — needs a **signed WDK audio driver** (sysvad class). There is no `rc-vmic` crate and no driver. |

This was an explicit decision, not an oversight (`docs/WINDOWS_TODO.md` §4):
an unsigned driver is worse than no driver — a user sees an unsigned driver in
their antivirus and the whole product's reputation is gone. The Mac equivalent
(`RemoteCrabMicDriver`, a CoreAudio HAL plugin) already ships, so the Windows
half is the only gap.

**To do it** (a real project — budget days, not hours):
1. Base on Microsoft's **sysvad** sample (a virtual audio driver, `MakeAuth`
   signing). The receiver side needs a `rc-vmic` crate mirroring the virtual
   camera's file-backed ring (`rc-vcam/src/shm.rs`): the phone's PCM lands in
   the ring, the driver reads it.
2. Build with the WDK, test-sign, install (`pnputil`), confirm the device shows
   under **Sound, video and game controllers** and appears in an app's mic list.
3. Release-sign (EV cert + attestation) and stage into the MSI.
4. Until then: the phone's mic is audible on the PC (see above), and voice
   features on the phone work; it just is not a *selectable input device* on
   Windows yet.

---

## 3. The boundary, stated plainly

- Both drivers need **Windows + WDK + a code-signing certificate** (EV cert for
  attestation signing). None of that exists on macOS, and none of it can be
  emulated there.
- `cargo check --target x86_64-pc-windows-gnu` proves a crate **compiles**; it
  proves nothing about a driver loading, a monitor appearing, or audio flowing.
- So: the receiver halves and the contracts are done and tested; the drivers are
  the remaining, separately-scheduled work. Do not describe either feature as
  "done" to a user until step "verify on the phone" above passes.
