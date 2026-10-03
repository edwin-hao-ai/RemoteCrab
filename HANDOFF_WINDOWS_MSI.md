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
- [x] Cleanup now runs **the product's own** `remotecrab.exe --uninstall-vcam`
      as a deferred SYSTEM custom action (type 3170, sequence 3499, just before
      `RemoveFiles`) rather than a second implementation in the installer. The
      ring file has a NULL DACL so the Frame Server can map it as LocalService —
      deleting it is not expressible in an MSI table. That duplication is
      exactly what let the wrong CLSID survive.
- [x] MSI built and verified: `dist/RemoteCrab-1.0.0.msi`, 1,794,048 bytes.
      File table holds **exactly** `remotecrab.exe` + `rc_vcam_source.dll` —
      the `MsvcBuild` guard works. 391 tests pass, clippy `-D warnings` clean.
- [x] **User installed it.** Verified on the installed copy:
      install dir holds exactly the 2 payload files · Start Menu uninstall
      shortcut present · MSI registered (`DisplayVersion 1.0.0`,
      `WindowsInstaller=1`) · HKCU markers set · `check-windows-deps.sh`
      against `C:\Program Files\RemoteCrab\remotecrab.exe` → 19 imports, OK ·
      installed exe self-reports `remotecrab 1.0.0` and starts cleanly.
- [x] The MSI is **unsigned**, so `verify` still exits nonzero. That is correct,
      not a bug.

## Blocked — needs the user

- [ ] **Re-register the virtual camera.** The CLSID currently points at
      `E:\RemoteCrab\windows\target\release\rc_vcam_source.dll` — left over from
      earlier dev testing. The installed exe correctly refuses rather than
      silently using the wrong DLL. One elevated command fixes it:

      ```powershell
      & "C:\Program Files\RemoteCrab\remotecrab.exe" --install-vcam
      ```

      I cannot run it: not an administrator, and `Start-Process -Verb RunAs`
      does not work from the constrained shell this session had.

- [ ] After that, re-run the chain that is still unproven end to end:
      `--vcam-selftest` from the **installed** exe →
      `cargo build --release -p rc-vcam --example vcam_consume` (lands in
      `windows/target/release/examples/`) → expect changing pixels.
- [ ] Still unverified: the tray's UAC "Install virtual camera" row, and a human
      looking at the picture in the Windows Camera app. `vcam_consume` only
      proves Media Foundation hands over changing bytes.
- [ ] Work through `docs/WINDOWS_TODO.md`'s uninstall checklist — the
      `%ProgramData%\RemoteCrab\vcam-ring.bin` line is the one most likely to
      fail.

## Bugs found while testing — not yet fixed

- [ ] **`VcamError::Stale` is never constructed.**
      `windows/crates/rc-vcam/src/error.rs:27` declares it, `:56` gives it a
      user-facing message, `:75` has a passing test asserting it is fixable by
      elevating — and nothing anywhere constructs it. `win.rs:75-79` already
      compares the registered DLL path against `source_dll_path()`; on mismatch
      it falls through to `RegCreateKeyExW`, gets `ACCESS_DENIED`, and returns
      the vague `NeedsElevation`. The app knows precisely what is wrong and says
      something generic instead. A dead variant with a test guarding an
      unreachable path.

- [ ] **Console one-shot flags never self-elevate, but the error message
      promises a UAC window.**
      `error.rs:49` reads *"needs administrator rights — approve the Windows
      prompt and it is done"*. The tray does self-elevate (`vcam.rs:83` →
      `elevate::run_elevated`), but `main.rs:158` runs `run_elevated_job`
      directly and `--vcam-selftest` only prints. A user who types the command is
      told to approve a window that never appears — which is exactly how this
      session got stuck.

      **Constraint on the fix:** the MSI invokes `--uninstall-vcam` as a
      deferred SYSTEM action. Naively adding self-elevation would make
      uninstall try to raise a UAC prompt inside an already-elevated install.
      Check "am I already elevated" first.

## Drift, deliberately not started

- [ ] Mac/iOS side (`docs/WINDOWS-GAPS-2026-10-03.md`): Windows key row in
      `KeyboardScreen.swift`; `ContextProfiles.swift` should match on
      `AppInfo.name` for Windows. Needs a Mac toolchain — unavailable here.
- [ ] The user decided **not** to split the seven oversized files. Recorded in
      `docs/WINDOWS-DECISIONS-2026-10-03.md`. Do not reopen unless asked.
