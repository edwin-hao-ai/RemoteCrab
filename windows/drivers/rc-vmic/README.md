# rc-vmic — RemoteCrab virtual microphone driver

This is the Windows half of the **phone-as-a-microphone** feature: the piece
that makes the iPhone's mic a **real Windows input device** every app can select
("RemoteCrab Microphone" in Zoom / Teams / OBS / Voice Recorder).

> **Status: the receiver half is done and tested; the driver itself is NOT
> written yet.** This file is the driver's **contract + INF + implementation
> plan**. The **receiver half is real**: `windows/crates/rc-vmic` (the audio
> ring, 15 tests) plus the `rc-app` wiring that feeds it and the `--vmic-probe`
> diagnostic. Read "What is actually done" before claiming anything.

## Why a driver

Windows has **no user-mode way** to add an audio *input device* — unlike the
virtual camera (`MFCreateVirtualCamera`, no driver) and unlike macOS, whose
CoreAudio HAL plugin (`RemoteCrabMicDriver`) already ships. A selectable
microphone needs a signed **PortCls / sysvad-class kernel driver**.

So the feature has two paths, and only one of them ships today:

| Path | How | Ships | Needs |
|---|---|---|---|
| **A** | Play the phone's mic into an installed virtual audio cable (VB-CABLE / VoiceMeeter / VAC) via `rc-audio::pick_virtual_cable`; the meeting app selects the cable's *capture* endpoint | ✅ **yes** — free, signed, no driver of ours | the user installs the cable once (the first-run wizard's "Virtual microphone" page walks them through it) |
| **B** | This driver: `RemoteCrab Microphone` appears in every app's input list with no third-party cable | ❌ not yet | a **signed** kernel driver |

Path A is the answer for the overwhelming majority of users; Path B removes the
one manual step.

## The contract with the receiver (already implemented + tested)

`windows/crates/rc-vmic` is the receiver side; the driver must honour exactly
this.

**Control pipe** `\\.\pipe\RemoteCrabVMic` (byte mode, line-delimited ASCII):

| Request | Reply | Meaning |
|---|---|---|
| `PING` | `PONG 1` | liveness + protocol version |

`rc-app` only feeds the ring when `PING` answers (`rc_vmic::available()`), so a
driver that is not installed simply means the app never creates the ring.
`remotecrab --vmic-probe` prints the same answer from a shell.

**Audio ring** `%ProgramData%\RemoteCrab\vmic-ring.bin` — a single-producer /
single-consumer **byte ring** (see `windows/crates/rc-vmic/src/shm.rs`):

```
off  0  u32  magic          ('RCMA' = 0x52434D41)
off  4  u32  version        (1)
off  8  u32  sample_rate    (48000)
off 12  u32  channels       (1 — the phone's mic is mono)
off 16  u32  bits_per_sample(16)
off 20  u32  capacity_bytes (PCM area size)
off 24  u64  write_pos      (bytes appended by the app, monotonic)
off 32  u64  read_pos       (bytes consumed by the driver, monotonic)
off 40  u32  dropped_packets
off 44  u32  underruns
off 48  ..   reserved to 64
off 64  PCM area (capacity_bytes, circular; live byte at
        HEADER_SIZE + (pos % capacity_bytes))
```

The app appends 16-bit little-endian PCM and advances `write_pos`; the driver
reads `write_pos - read_pos` bytes, copies them out, and advances `read_pos`.
When the ring is empty the driver returns **silence** and leaves `read_pos`
alone (so the samples are still there next period) — that is what makes a late
phone a gap in the audio rather than a click or a stall.

> A latest-frame-wins slot (as the camera uses) is wrong here: dropping video
> frames is invisible, dropping PCM is a click. Hence a byte ring.

## What is actually done

| Piece | Where | State |
|---|---|---|
| Audio ring (format, writer, consistency checks) | `windows/crates/rc-vmic/src/{shm,writer}.rs` | ✅ compiles, **15 unit tests** (round-trip, wrap, drop-when-full, format rejection) |
| Driver probe (`PING`/`PONG`) | `windows/crates/rc-vmic/src/win.rs` | ✅ |
| App mirrors the decoded mic into the ring | `rc-app/src/vmic.rs`, `rc-audio` `set_tap` | ✅ wired; feeds only when the driver answers |
| `--vmic-probe` | `rc-app/src/{args,main}.rs` | ✅ |
| Path A (virtual cable) | `rc-audio` + first-run wizard page | ✅ **ships today** |
| **The driver** | this directory | ❌ **not written** — INF + contract + plan only |

## To finish the driver (on a machine with VS 2022 + WDK + a cert)

Base on Microsoft's **sysvad** sample
(`Windows-driver-samples/audio/sysvad`, MS-PL), specifically its WaveRT
miniports, and cut it down to a **capture-only** device:

1. One `IMiniportWaveRT` / `IMiniportWaveRTInputStream` that, in its
   `GetInputStream`/`SetState(RUN)` path, drains the ring above into the WaveRT
   buffer each period; on underrun it fills silence and does **not** advance
   `read_pos`.
2. A small thread (or `EvtTimerFunc`) that creates the control pipe
   `\\.\pipe\RemoteCrabVMic` with a permissive DACL (so a non-elevated app can
   `PING` it) and answers `PONG 1`.
3. Build (`cl`/`link` against `portcls.lib` + `ks.lib`, or the WDK MSBuild
   toolset — see `../rc-idd/build-cl.ps1` for the no-toolset path), then:
   - **test-sign** (`bcdedit /set testsigning on` + a self-signed cert) on a
     throwaway machine, or
   - **attestation-sign** with an EV cert for release.
4. `pnputil /add-driver rc-vmic.inf /install`, confirm the device under **Sound,
   video and game controllers**, and that a meeting app can select it.
5. Stage into the MSI alongside the virtual camera.

Until then: **Path A works**, the receiver half is tested, and this file is the
only honest description of the driver's state.
