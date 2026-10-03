# Handoff: Windows MSI packaging + virtual camera

> Unrelated to the website handoff that used to be the only `HANDOFF.md`; that
> one is kept as-is. This is the Windows release thread.

- Repo: `E:\RemoteCrab`, branch `main`, no worktree
- Last pushed: `792da15` — "The manifest had never been built. Six defects…"
- Tree clean and in sync with origin at time of writing.
- Date: 2026-10-03

## Done

- [x] `.NET SDK 9.0.318` + `WiX 4.0.5` installed. WiX 7 was installed first and
      removed again — it demands accepting the OSMF EULA, which nobody should
      do on the user's behalf.
- [x] **`windows/tools/RemoteCrab.wxs` compiles.** It had never been built.
      Six defects fixed, worst first: it unregistered a CLSID
      (`{8B2C4D19-…}`) that exists nowhere in the product; used the WiX **v3**
      `Schedule="installRemoveInitializeVersion"`; guarded the MinGW runtime
      behind a preprocessor variable nobody defined; duplicated cleanup logic
      the app already owns; `sed` ate the backslashes in `@PAYLOAD@`; plus
      schema drift.
- [x] **The installer registers the virtual camera** (`9a0e742`). The package is
      perMachine, so it is elevated for its whole run; it was spending that on
      copying files and then telling users to open an elevated PowerShell. One
      UAC prompt at install time, which is what every Windows app does; **no
      second prompt during use**.
- [x] Cleanup runs the product's own `--uninstall-vcam-machine` as a deferred
      SYSTEM action (type 3170, sequence 3499, just before `RemoveFiles`).
      Machine-wide only — under SYSTEM `%APPDATA%` is the *system profile's*,
      so the full command deleted the wrong user's data. Never prompts. The COM
      keys are in the Registry table now, so Windows Installer removes those
      itself; the action is there only for the ring file's NULL DACL.
- [x] MSI built and verified: `dist/RemoteCrab-1.0.0.msi`, 1,794,048 bytes.
      File table holds **exactly** `remotecrab.exe` + `rc_vcam_source.dll` —
      the `MsvcBuild` guard works. 393 tests pass, clippy `-D warnings` clean.
- [x] **Full install→use cycle verified on the real machine.** Installed with
      `msiexec /i` and one UAC click, no other command:
      CLSID written to `C:\Program Files\RemoteCrab\rc_vcam_source.dll` ·
      `ThreadingModel = Both` · DLL present · `remotecrab.exe --vcam-selftest`
      from the installed copy → `vcam_consume` reports
      **`PASS — 11 samples, 34560 changing bytes`**.
- [x] **No second elevation after install.** A non-admin process can create
      files in `%ProgramData%\RemoteCrab` (the `Users` ACE carries `Write`), and
      the self-test that published those frames was itself non-elevated.
- [x] The MSI is **unsigned**, so `verify` still exits nonzero. That is correct,
      not a bug. See the SmartScreen note below.

## Known remaining friction

- [ ] **SmartScreen, not UAC, is the real install-time complaint.** An unsigned
      exe triggers "Windows protected your PC", which needs *More info* →
      *Run anyway*. That is a more confusing screen than the UAC prompt users
      already expect, and it cannot be removed by any amount of installer work —
      only a code signing certificate (OV ≈ $150–300/yr) clears it. Decide
      whether to buy one before any public distribution.

## Blocked — needs the user

- [ ] **The uninstall half is still untested.** Everything above is the install
      path. Work through `docs/WINDOWS_TODO.md`'s checklist — the
      `%ProgramData%\RemoteCrab\vcam-ring.bin` line is the one most likely to
      fail, because of the NULL DACL.
- [ ] Still unverified: the tray's UAC row (now a fallback rather than the main
      path, since the installer registers), and a human looking at the picture in
      the Windows Camera app. `vcam_consume` only proves Media Foundation hands
      over changing bytes.

## Bugs found while testing — fixed in `9a0e742`

- [x] **`VcamError::Stale` was unreachable.** `win.rs` already compared the
      registered DLL path against its own; on a mismatch it fell through to
      `RegCreateKeyExW`, got `ACCESS_DENIED`, and returned the generic
      `NeedsElevation` — so the one error that could explain "your camera is
      registered to a copy you deleted" never reached a user, who was told they
      were not an administrator. Usually they were. Now returned, with a test
      holding its message to the standard the other arms meet.

- [x] **The one-shot flags never self-elevated while their error text promised
      a UAC window** — *"approve the Windows prompt and it is done"*. The tray
      self-elevated; `main.rs` did not. A terminal user was told to approve a
      dialog that never appeared, which is exactly how this session got stuck.
      `run_elevated_job` is now `run_one_shot`, which prompts when it needs to
      and says plainly when the user declines or a policy blocks the prompt.

  Two WiX v4 traps, both of which compile to a manifest that installs nothing
  useful, were hit on the way: a nested `RegistryKey` rejects `Root` (WIX0064),
  and its `Key` is *appended* to the parent rather than relative — repeating the
  full path produced `…\CLSID\{9D4B…}\CLSID\{9D4B…}\InprocServer32`.


## Drift, deliberately not started

- [ ] Mac/iOS side (`docs/WINDOWS-GAPS-2026-10-03.md`): Windows key row in
      `KeyboardScreen.swift`; `ContextProfiles.swift` should match on
      `AppInfo.name` for Windows. Needs a Mac toolchain — unavailable here.
- [ ] The user decided **not** to split the seven oversized files. Recorded in
      `docs/WINDOWS-DECISIONS-2026-10-03.md`. Do not reopen unless asked.
