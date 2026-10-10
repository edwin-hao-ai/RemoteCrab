# rc-idd — RemoteCrab indirect display driver

This is the Windows half of **Extended Display**: the piece that makes the
iPhone a *real* second monitor. Windows has no user-mode way to add a display
(macOS uses the private `CGVirtualDisplay`), so a monitor that the OS and every
app believe in has to come from a driver. `rc-idd` is that driver.

> **Status: builds and packages; not yet signed or run on real hardware.**
> `build-cl.ps1` compiles the UMDF driver with `cl`/`link` and produces a
> catalog (`Inf2Cat`, signability clean) on a machine that has *only* the WDK +
> Build Tools — the standalone WDK does not register the MSBuild
> `WindowsUserModeDriver10.0` platform toolset, which is why `build.ps1`
> (msbuild) does not work there. It still cannot be *loaded* without a
> signature. The receiver side (`rc-vdisplay`, the capability, the phone UI)
> *is* built and tested; see the repo's handoff doc for exactly what is
> verified.

## What it is

An [IddCx](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview)
**indirect display driver** — a UMDF (user-mode) driver, so a bug in it cannot
blue-screen the machine. It creates a software display device; when the phone
asks to extend, it brings up one monitor at the requested size, the OS composes
the desktop for it, and the driver copies each composed frame into a shared
ring the receiver reads and streams.

It is adapted from Microsoft's
[IddSampleDriver](https://github.com/microsoft/Windows-driver-samples/tree/main/video/IndirectDisplay/IddSampleDriver)
(MIT). The IddCx plumbing follows that sample; the RemoteCrab-specific parts are
the frame ring and the control pipe.

## The contract with the receiver

Everything the receiver needs is already implemented and tested in
`windows/crates/rc-vdisplay`. The driver must honour exactly this:

**Control pipe** `\\.\pipe\RemoteCrabVDisplay` (byte mode, line-delimited
ASCII, one line in / one line out):

| Request | Reply | Meaning |
|---|---|---|
| `PING` | `PONG 1` | liveness + protocol version |
| `MONITOR <w> <h>` | `OK` / `ERR <reason>` | create the monitor at `w`×`h` |
| `MONITOR OFF` | `OK` | remove the monitor |

The receiver only advertises the `extendedDisplay` capability when `PING`
answers, so an uninstalled driver simply means the phone never shows the row.

**Frame ring** `%ProgramData%\RemoteCrab\vdisplay-ring.bin` — the same
double-buffered BGRA layout as the virtual camera
(`windows/crates/rc-vcam/src/shm.rs`, read back by `rc-vdisplay`):

```
off  0  u32 magic 'RCMV'   (0x52434D56)
off  4  u32 version        (1)
off  8  u32 width
off 12  u32 height
off 16  u32 fps
off 20  u32 stride         (= width*4)
off 24  u64 frame_seq      (incremented after each frame)
off 32  u64 write_idx      (0 or 1 — which buffer is newest)
off 40  ..  reserved to 64
off 64  buf0, buf1         (stride*height bytes each, BGRA)
```

The driver fills the non-current buffer, then flips `write_idx` and bumps
`frame_seq`. The receiver reads the newest. No other synchronisation.

## Build

Prerequisites, all on the machine doing the build:

1. **Visual Studio 2022** (or Build Tools) with the **Desktop C++** workload.
2. **Windows SDK** (10.0.22621 or newer).
3. **Windows Driver Kit (WDK)** matching the SDK — `winget install
   Microsoft.WindowsWDK.10.0.26100` (or the version matching your SDK).

Then either:

```powershell
# Preferred when only the WDK + Build Tools are present: compiles with cl/link
# directly, then runs stampinf + Inf2Cat, so one command yields the full
# package (dll + stamped inf + cat).
powershell -ExecutionPolicy Bypass -File build-cl.ps1            # Release | x64

# MSBuild path. Only works if the WDK registered its VS platform toolset —
# i.e. a full VS 2022 (driver workload) install, or a WDK installed while VS
# was already present.
pwsh -File build.ps1
```

Output lands in `x64\Release\`: `rc-idd.dll`, `rc-idd.inf` (stamped), `rc-idd.cat`.

> **Why two scripts.** The WDK's MSBuild integration (`WindowsUserModeDriver10.0`)
> is installed *into Visual Studio* by the WDK setup — but a standalone WDK
> installed via winget when VS was absent skips that step, so `build.ps1` fails
> with "platform toolset not found". `build-cl.ps1` does the same job with no
> VS toolset: it finds the WDK's IddCx/UMDF headers and libs, compiles, and
> packages. Either script works when the toolset *is* registered.

## Sign

A driver will not load on a normal Windows machine without a signed catalog.
For local development, enable test signing instead:

```powershell
# Elevated. Rebooting is required. Do this on a throwaway/test machine.
bcdedit /set testsigning on
# ... then, after building, sign the catalog with a self-signed cert:
New-SelfSignedCertificate -Type Custom -Subject "CN=RemoteCrab Test" `
  -KeyUsage DigitalSignature -CertStoreLocation Cert:\CurrentUser\My `
  -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")
# signtool sign /fd sha256 /a /s My rc-idd.cat   (then the .dll too)
```

For end users there is **no test signing**: the catalog must be signed by a
certificate chained to a Microsoft-trusted CA, via Microsoft's **attestation
signing** (free with an EV code-signing certificate, submitted through Partner
Center) or a full WHQL submission. That certificate purchase is the same one
already blocking Windows code signing — see `docs/WINDOWS_TODO.md` §2.1.

## Install

One elevated command installs the device (this is what the MSI runs, so the
user sees a single UAC prompt at install time):

```powershell
pnputil /add-driver rc-idd.inf /install
```

A **root-enumerated** software device (`Root\RemoteCrabDisplay`) appears; the
driver loads at boot and the control pipe comes up. The monitor itself is
created only on `MONITOR <w> <h>`, so a machine that never extends shows no
extra screen in Display Settings.

Verify:

```powershell
Get-PnpDevice -FriendlyName 'RemoteCrab Display'    # the software device
Get-ChildItem \\.\pipe\ | Where-Object Name -like '*RemoteCrabVDisplay*'
```

## Uninstall

```powershell
pnputil /delete-driver rc-idd.inf /uninstall
```

## How it works, in one paragraph

`DriverEntry` → `WdfDriverCreate`; device add configures IddCx and creates the
device; D0 entry starts `IddCxAdapterInitAsync`; when the adapter is ready the
control pipe starts. `MONITOR w h` opens the ring and creates one monitor with
no EDID, so the OS asks for default modes — which the driver answers with
exactly `w`×`h`. The OS assigns a swap-chain; the swap-chain thread copies each
composed BGRA frame through a staging texture into the ring. `MONITOR OFF`
departs the monitor; the receiver stops reading. No phantom screen survives a
session.
