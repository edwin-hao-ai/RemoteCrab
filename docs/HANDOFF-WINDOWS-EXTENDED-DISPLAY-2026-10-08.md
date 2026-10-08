# Handoff — Windows Extended Display (iPhone as a second screen)

> 2026-10-08. Written on a Windows 11 Home (10.0.26300) machine **without**
> the WDK and **without** elevation, so the driver could be written but not
> built, signed, or run. Read the "What is verified" table before trusting
> anything else. The receiver half is built and green; the driver is a first
> cut that must be compiled and device-tested on a machine that has the WDK.

## The shape of the problem (already established, do not re-litigate)

Windows has **no user-mode way to add a display**. macOS uses the private
`CGVirtualDisplay`; Windows needs an **IddCx indirect display driver** (UMDF,
signed). This is not a preference — it is the only mechanism. The phone's
button was hidden for Windows precisely because the receiver could not back it
(`ContentView.swift`, old `if !engine.connectedIsWindows`).

So "implement Extended Display on Windows" = write a driver + sign it + install
it, and everything around it. This change does all of the surrounding work and
writes the driver; it cannot finish the driver on this machine.

## What is implemented

| Piece | File(s) | Verified? |
|---|---|---|
| `extendedDisplay` capability (Swift) | `RemoteCrabCore/…/IBEvents.swift` (`IBClientHello.Capability`) | ✅ compiles; test added |
| Mac advertises it | `RemoteCrabReceiver/ReceiverSession.swift` | ✅ (same pattern as existing caps) |
| iOS gates the row on the capability, platform as legacy fallback | `RemoteCrabCapture/ContentView.swift`, `CaptureEngine.swift` (`peerSupportsExtendedDisplay`) | ✅ compiles; test added |
| Capability on the wire (Rust) | `rc-protocol/src/events.rs` (`CAP_EXTENDED_DISPLAY`) | ✅ |
| Receiver advertises it only when the driver answers | `rc-net/src/lib.rs` (`Config.extended_display`), `rc-net/src/supervisor.rs` | ✅ **integration test green** (`rc-net/tests/session.rs::extended_display_capability_follows_the_driver_flag`) |
| Driver contract: control pipe + frame ring + liveness | `windows/crates/rc-vdisplay/` | ✅ **5 unit tests green** |
| Receiver streams the virtual display | `windows/crates/rc-app/src/mirror.rs` (`Source::VirtualDisplay`), `src/main.rs` (`Extend`) | ✅ compiles; window path unchanged and its tests pass |
| `--vdisplay-probe` diagnostic | `windows/crates/rc-app/src/args.rs`, `src/main.rs`, `src/help.rs` | ✅ test added |
| MSI installs/removes the driver (one UAC) | `windows/tools/RemoteCrab.wxs` (`VdisplayDriver`, `AddVdisplayDriver`) | ⚠️ **not built** (needs a driver payload) |
| **The driver** | `windows/drivers/rc-idd/` (`.cpp`, `.h`, `.inf`, `.vcxproj`, `build.ps1`, `README.md`) | ❌ **written, never compiled** |

Commands that were run and passed on this machine:

```
cd windows
cargo test --workspace          # all green
cargo clippy --workspace --all-targets -- -D warnings   # clean
cargo build --workspace         # clean
cargo run -p rc-app -- --vdisplay-probe   # "driver not found" — correct, none installed
```

## What is NOT done (and why)

1. **The driver has never been compiled.** This machine has no WDK
   (`IddCx.h` absent, no `km` headers) and no elevation. `windows/drivers/rc-idd/`
   is adapted from Microsoft's `IddSampleDriver`; expect compile fixes. See its
   `README.md` for the build.
2. **No signature.** A driver will not load on a normal machine unsigned. Test
   signing is the dev path; end users need Microsoft **attestation signing**
   (free with an EV cert) or WHQL. That cert is the same one already blocking
   Windows code signing (`docs/WINDOWS_TODO.md` §2.1).
3. **Nothing device-tested.** The monitor has never appeared; the ring has never
   carried a composed desktop frame; the phone has never rendered one.
4. **Geometry is derived by matching the monitor size** (`rc-vdisplay::
   find_monitor_rect`). The IddCx driver has no API to report the desktop
   position the OS assigns its monitor, so the receiver enumerates monitors and
   matches the requested pixel size. Unambiguous in practice (the virtual
   monitor is the only one we did not physically plug in), but it is a
   heuristic — a machine with a second physical monitor at the exact same
   resolution would need a better key. This is the first thing to harden once
   the driver runs.

## The contract (so a driver author needs nothing else)

Control pipe `\\.\pipe\RemoteCrabVDisplay`, byte mode, one line in / one out:

| Request | Reply |
|---|---|
| `PING` | `PONG 1` |
| `MONITOR <w> <h>` | `OK` / `ERR <reason>` |
| `MONITOR OFF` | `OK` |

Frame ring `%ProgramData%\RemoteCrab\vdisplay-ring.bin` — same layout as the
virtual camera (`rc-vcam/src/shm.rs`, read by `rc-vdisplay`): 64-byte header
(`magic 'RCMV'`, version, width, height, fps, stride=width*4, `u64 frame_seq`,
`u64 write_idx`), then two BGRA buffers. Driver fills the non-current buffer,
flips `write_idx`, bumps `frame_seq`. The receiver advertises
`extendedDisplay` iff `PING` answers, and streams the ring's newest frame as
`screenSps`/`screenPps`/`screenVideo` + `screenInfo` with `appId = "extended"`
(the same `appId` the Mac sends, so the phone's `ScreenShareView` is unchanged).

## How to finish it

On a machine with the WDK + MSVC + admin:

1. **Build the driver.** `cd windows\drivers\rc-idd; pwsh -File build.ps1`.
   Fix whatever the compiler says — this is the untested part.
2. **Test-sign + install** on a throwaway machine (`bcdedit /set testsigning on`,
   self-signed cert, `signtool`, then `pnputil /add-driver rc-idd.inf /install`).
   Confirm `Get-PnpDevice -FriendlyName 'RemoteCrab Display'` and
   `remotecrab --vdisplay-probe` → `protocol version 1`.
3. **Verify the ring.** With the driver installed and `MONITOR 1920 1200` sent,
   `rc-vdisplay`'s reader should see `frame_seq` climbing. A tiny tool can dump
   one frame to PNG the same way `rc-vcam-source/examples/dump_ring.rs` does.
4. **Verify the phone.** Build the iOS app with this Swift change; with a
   driver-equipped PC connected, the mirror dropdown must show **Extended
   Display**, and tapping it must bring up a real monitor in the PC's Display
   Settings and stream it to the phone. Input mapping uses
   `find_monitor_rect`'s rect.
5. **Sign for release** (EV cert + attestation) and stage the driver files into
   the MSI payload; `release-windows.sh` must pass `-d VdisplayBuild=true` so
   `RemoteCrab.wxs` includes them.

## Risks / things that will bite

- **A driver is not "simple install" without signing.** The install itself is
  one UAC (the MSI is already elevated and runs `pnputil`), but a user on a
  machine with Secure Boot and no signed catalog gets a driver that silently
  does not load — and the receiver then reports no capability, so the phone
  shows no row. That is the honest failure mode; do not paper over it.
- **IddCx mode negotiation.** The driver creates the monitor with **no EDID** and
  answers `GetDefaultDescriptionModes` with exactly the requested size; the OS
  intersects monitor modes with target modes. If the requested size is not in
  `QueryTargetModes`, the monitor may come up at a different resolution than the
  ring expects — the swap-chain copy checks `desc.Width == ring.width()` and
  drops mismatches rather than tearing, but the stream would be blank. Keep the
  two in sync.
- **The ring holds a NULL DACL** (everyone can read/write), same as the virtual
  camera's, because the driver runs in a service session. It contains screen
  pixels being sent to the phone anyway, and is not network-reachable, but note
  it in any security review.
- **Removing the monitor matters.** `MONITOR OFF` (and disconnect/teardown) must
  call `IddCxMonitorDeparture`, or the user is left with a phantom second screen
  in Display Settings after the phone leaves. The driver does this; verify it.

## Files changed

- `RemoteCrabCore/Sources/RemoteCrabCore/Networking/IBEvents.swift` — `extendedDisplay` capability
- `RemoteCrabCore/Tests/RemoteCrabCoreTests/CapabilityNegotiationTests.swift` — 2 tests
- `RemoteCrabReceiver/ReceiverSession.swift` — Mac advertises it
- `RemoteCrabCapture/CaptureEngine.swift` — `peerCapabilities` / `peerSupportsExtendedDisplay`
- `RemoteCrabCapture/ContentView.swift` — row gated on the capability
- `windows/Cargo.toml` — new `rc-vdisplay` member/dep
- `windows/crates/rc-vdisplay/**` — new crate (contract + ring + probe)
- `windows/crates/rc-protocol/src/events.rs` — `CAP_EXTENDED_DISPLAY`
- `windows/crates/rc-net/src/lib.rs`, `src/supervisor.rs`, `tests/session.rs` — capability plumbing + test
- `windows/crates/rc-app/src/mirror.rs`, `src/main.rs`, `src/args.rs`, `src/help.rs` — virtual-display source + probe
- `windows/tools/RemoteCrab.wxs` — driver payload + `pnputil` install/remove
- `windows/drivers/rc-idd/**` — the driver (new)
