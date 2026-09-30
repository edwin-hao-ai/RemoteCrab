# Windows receiver

> 跨编译、虚拟摄像头与托盘

Part of [`AGENTS.md`](../../AGENTS.md). Entries keep their original numbers
so a cross-reference from another lesson still resolves.

68. **Windows parity round 2 + a cross-compile check that actually compiles
    the Windows code (2026-09-26).** Two things:
    (a) **The macOS `cargo check`/`clippy` never type-checks the Windows
    receiver.** Every real Win32 module is `#[cfg(windows)]` (`rc-os::apps`,
    `clipboard`, `windows`, and the `#[cfg(windows)]` arms in
    `rc-app/main.rs`), so on the Mac they are simply excluded — a latent
    compile error (`TerminateProcess(...).as_bool()` on a
    `windows::core::Result`, not a `BOOL`) shipped in the activate/quit
    commit and only surfaced when cross-checked. To actually validate:
    `brew install mingw-w64`, `rustup target add x86_64-pc-windows-gnu`, then
    `cargo check`/`clippy --target x86_64-pc-windows-gnu --workspace`
    (the msvc target can't build OpenH264 from macOS; the GNU target can,
    once mingw is present). The **runtime** paths still need a real Windows
    box — the user runs that.
    (b) **Windows data-plane parity**: `activateApp`/`quitApp` were being
    dropped (fixed — see the activate/quit + feature-control commit);
    `windowListRequest` (0x17) was unhandled, so the iPhone's window-based
    `AppSwitcherView` (it renders `engine.macWindows`, NOT `macApps`) was
    always empty. `rc-os::windows::build_window_list` now enumerates
    top-level windows (`PrintWindow` + `PW_RENDERFULLCONTENT` for
    GPU-composited ones) and returns a JPEG thumbnail per window via the
    pure, unit-tested `rc-os::thumbnail::encode_bgra_jpeg` (box-downscale →
    `jpeg-encoder`); window `id` is `"<pid>:<hwnd>"` (the iPhone keeps only
    ids containing `:`) and `app_id` is `"pid:<pid>"` to match the app list.
    `activateApp` now also matches the tapped card's `windowTitle`. The PC
    clipboard can be pushed to the iPhone with the `clipboard` console
    command (`clipboardSet` 0x13 was receive-only before). And the iOS app
    now hides its mirror button while `connectedIsWindows` (that receiver
    has no window-capture path, so the button only ever dead-ended) —
    `CaptureEngine.startScreenMirror()` guards the other entry points too.
    **Recording**: the new pure crate `rc-record` (`--record` / console
    `record`) muxes the iPhone's own H.264 into an MP4 (passthrough, no
    re-encode) + a PCM WAV sidecar (the `mp4` crate only muxes AAC and the
    project refuses an FFI AAC encoder) under
    `%USERPROFILE%\Videos\RemoteCrab`; unit-tested on the host. **AWDL**:
    Windows cannot do Apple Wireless Direct Link (proprietary Apple link
    layer; `includePeerToPeer` is Apple-only; OWL targets Linux) — the
    router-less paths are the iPhone Personal Hotspot / USB tethering, which
    the direct-IP fallback already covers (`HOTSPOT_GATEWAY 172.20.10.1` +
    last-IP + `/24` sweep). **App-window mirror**: `rc-protocol` now has the
    `ScreenControl`/`ScreenInput`/`ScreenInfo` structs + codecs (tested) and
    `rc-net` dispatches `screenControl`/`screenInput`; the new `rc-mirror`
    crate captures the target window (`PrintWindow` + `PW_RENDERFULLCONTENT`),
    H.264-encodes it with OpenH264, and `rc-app` streams
    `screenSps`/`screenPps`/`screenVideo` + `screenInfo` from a dedicated
    thread (input is mapped via `rc-input`'s absolute `screen_actions`).
    Because Windows now supports it, the iOS mirror button is **no longer
    hidden** for `connectedIsWindows`. **Switcher quick destinations**
    (2026-09-26, both receivers): the switcher's top row now has **Desktop**
    — a new `IBSystemCommand.showDesktop` (0x19) kind; the Mac hides every
    other regular app then activates Finder (hiding is what uncovers it;
    activating Finder alone only raises a Finder window), Windows sends
    Win+D — and **Open app…**, a searchable installed-app launcher on a new
    frame pair (`installedAppsRequest` 0x20 / `installedApps` 0x21):
    `InstalledApp.id` carries exactly what `launchApp` wants as its argument
    (bundle id on the Mac — `InstalledAppsCatalog` scans /Applications
    (+Utilities), /System/Applications, CoreServices and ~/Applications,
    deduped by bundle id — Start Menu `.lnk` path on Windows, so
    `ShellExecuteW` handles it). **Tray + real app icons** (2026-09-26,
    both the P2 experience gap and the switcher's fallback icons):
    `rc-app` puts an icon in the notification area (`Shell_NotifyIconW` +
    a message-only window on a dedicated thread; every menu pick routes
    through a channel to the app's `select!` loop — the tray thread owns
    nothing) and its menu mirrors the Mac menu-bar popover's structure and
    wording (`State::pill_label`/`phone_name`/`pill_latency_ms` for the
    status row; the SAME four toggles the Mac shows — camera/mic/trackpad/
    keyboard — then Start/Stop Recording, Send Clipboard to iPhone,
    Reconnect, Disconnect, Quit; `--no-tray` skips it). `build_app_list`
    now renders each process's 48 px icon (`SHGetFileInfoW` → `DrawIconEx`
    into a 32-bit DIB → RGBA → PNG in the pure, tested `rc-os::icon`),
    cached per exe path — the same fill the Mac does on the explicit
    `appListRequest`. **Still open on Windows**: virtual mic (see
    the blueprint below) and the self-drawn tray panel (§5f of
    `docs/WINDOWS_HANDOFF.md`); `cargo test --workspace` 207 +
    host/windows clippy clean, now enforced by CI.
