#!/usr/bin/env bash
# Build, sign and package RemoteCrab for Windows.
#
# Split from building because the three have very different lead times:
# building takes two minutes, signing needs a certificate that takes *weeks* to
# buy, and packaging needs a Windows toolchain. Keeping them apart means a
# missing certificate does not block a local build, and a build machine does
# not need the certificate.
#
# Run this on Windows. It refuses on anything else, because the whole point is
# that the output is a thing Windows will run — and a "works on my Mac" story
# is exactly how a release ships an exe that will not start on a clean install.
#
#   scripts/release-windows.sh build      # compile, unsigned, for testing
#   scripts/release-windows.sh deps       # what will this exe need at runtime
#   scripts/release-windows.sh sign       # sign an existing build
#   scripts/release-windows.sh package    # build + sign + produce the installer
#   scripts/release-windows.sh verify     # re-check a built artifact
#
# Environment:
#   RC_CERT_SHA1   thumbprint of the code-signing certificate (required to sign)
#   RC_CERT_PFX    path to the .pfx, if the cert is not in the user's store
#   RC_CERT_PASS   password for that .pfx
#   RC_VERSION     version to stamp; defaults to the workspace version
#
#   RUSTUP_TOOLCHAIN   which toolchain builds this. Worth setting explicitly.
#     `TARGET` below pins the *target* triple, but the toolchain that compiles
#     build scripts is the *host* one, and `rust-toolchain.toml` decides that by
#     naming `stable` — which on Windows resolves to `stable-x86_64-pc-windows-gnu`.
#     If that host cannot link (see the `dlltool` note in
#     `docs/WINDOWS_TODO.md` §2.3), the failure arrives three lines deep as
#     `error calling dlltool 'dlltool.exe': program not found`, which says
#     nothing about the real cause. Set it to a working host and the rest of this
#     script just works:
#         export RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-msvc

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIN="$REPO/windows"
PROFILE="release"
TARGET="x86_64-pc-windows-msvc"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# `powershell`, `signtool` and `dumpbin` are native Windows programs and cannot
# open an MSYS path. Handing one `/e/RemoteCrab/...` produces a file-not-found
# from the wrong tool, which reads as "this artifact has no version" rather
# than "you passed me a path I cannot use".
win_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s\n' "$1"
    fi
}

require_windows() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) die "this must run on Windows (it produces a .msi and signs a .exe). Use scripts/release-windows.sh from a Windows shell." ;;
    esac
}

# ---------------------------------------------------------------- version

# Reads the workspace manifest rather than accepting a version argument, so
# there is one place a release number lives: the same value the PE resource is
# built from. Cross-platform on purpose — asking "what version is this?" should
# not require a Windows machine.
version() {
    if [[ -n "${RC_VERSION:-}" ]]; then
        echo "$RC_VERSION"
        return
    fi
    # One source of truth: the workspace manifest. The PE resource reads the
    # same value at build time, so a hand-edited version string cannot drift
    # away from what Explorer shows.
    sed -n 's/^version = "\(.*\)"$/\1/p' "$WIN/Cargo.toml" | head -1
}

# ---------------------------------------------------------------- build

cmd_build() {
    require_windows
    local v; v="$(version)"
    note "building $TARGET $PROFILE, version $v"
    note "host toolchain: ${RUSTUP_TOOLCHAIN:-<from rust-toolchain.toml>}"
    # The MSVC target on purpose: it has no MinGW runtime to ship, and its ABI
    # is what every Windows tool expects. The GNU build pulls in
    # `libstdc++-6.dll`, which is on no stock Windows — see
    # `scripts/check-windows-deps.sh`, which is the judge of that.
    ( cd "$WIN" && cargo build -p rc-app --release --target "$TARGET" ) \
        || die "build failed"

    # The camera DLL is a *separate* cdylib and `-p rc-app` does not produce
    # it. It is not optional: the Frame Server loads it, Windows shows its own
    # publisher prompt for it, and `sign` below would otherwise skip it and
    # still exit 0.
    note "building the virtual-camera source (separate cdylib)"
    ( cd "$WIN" && cargo build -p rc-vcam-source --release --target "$TARGET" ) \
        || die "rc-vcam-source build failed"
    local dir="$WIN/target/$TARGET/$PROFILE"
    [[ -f "$dir/rc_vcam_source.dll" ]] \
        || die "rc_vcam_source.dll missing after build — the camera would silently not appear"
    note "built $dir/remotecrab.exe + rc_vcam_source.dll"
}

# ---------------------------------------------------------------- deps

cmd_deps() {
    local exe="${1:-$WIN/target/$TARGET/$PROFILE/remotecrab.exe}"
    [[ -f "$exe" ]] || die "no exe at $exe — run 'build' first"
    note "imports of $exe"
    # Reuse the Mac-runnable checker so the answer is the same on both sides.
    bash "$REPO/scripts/check-windows-deps.sh" "$exe"
}

# ---------------------------------------------------------------- sign

signing_available() {
    [[ -n "${RC_CERT_SHA1:-}" || -n "${RC_CERT_PFX:-}" ]]
}

# sign_one <path> — the exe and the camera DLL both have to be signed.
#
# The DLL is not optional. It is the COM in-process server the Frame Server
# loads, so Windows shows its own publisher prompt for it, and an unsigned DLL
# next to a signed exe reads as exactly the kind of thing antivirus flags.
sign_one() {
    local f="$1"
    [[ -f "$f" ]] || die "cannot sign missing file: $f"
    if [[ -n "${RC_CERT_PFX:-}" ]]; then
        note "importing $RC_CERT_PFX into the current user store"
        # `Import-PfxCertificate` needs the cert to be usable for code signing;
        # a cert bought without that EKU imports and then fails at sign time
        # with a message that does not say so.
        powershell -NoProfile -Command "
            Import-PfxCertificate -FilePath '$RC_CERT_PFX' \
                -CertStoreLocation 'Cert:\CurrentUser\My' \
                -Password (ConvertTo-SecureString -String '${RC_CERT_PASS:-}' -AsPlainText -Force) \
            | Select-Object -ExpandProperty Thumbprint" \
            || die "could not import the .pfx"
    fi
    [[ -n "${RC_CERT_SHA1:-}" ]] || die "no certificate: set RC_CERT_SHA1 (or RC_CERT_PFX)"

    note "signing $(basename "$f")"
    # `/fd sha256` is not optional: the default since 2016, but an unsigned
    # timestamp service or an old build script can still leave SHA-1 in there,
    # and SmartScreen treats the two very differently.
    signtool sign /sha1 "$RC_CERT_SHA1" /fd sha256 /tr http://timestamp.digicert.com \
        /td sha256 "$f" || die "signing failed for $f"
    # Confirm, because `signtool` exits 0 having signed nothing when the
    # certificate is expired — and an expired signature is worse than none,
    # since it looks deliberate.
    signtool verify /pa "$f" >/dev/null || die "signature does not verify: $f"
    note "signed and verified: $(basename "$f")"
}

cmd_sign() {
    require_windows
    signing_available || die "set RC_CERT_SHA1 or RC_CERT_PFX first"
    local dir="$WIN/target/$TARGET/$PROFILE"
    # The DLL lands next to the exe because `rc-vcam::source_dll_path` resolves
    # it from `current_exe()`'s directory.
    #
    # Both are *required*. An earlier version looped with `[[ -f "$dll" ]] &&`
    # so that a missing optional runtime was skipped — and a missing
    # `rc_vcam_source.dll` was skipped too, printing a success message and
    # exiting 0 with the one file that gets its own publisher prompt still
    # unsigned.
    sign_one "$dir/remotecrab.exe"
    sign_one "$dir/rc_vcam_source.dll"
    # `vcruntime140.dll` only exists on a non-`crt-static` build, so its
    # absence is the expected case and must not be an error.
    [[ -f "$dir/vcruntime140.dll" ]] && sign_one "$dir/vcruntime140.dll"
    return 0
}

# ---------------------------------------------------------------- package

cmd_package() {
    require_windows
    signing_available || die "set RC_CERT_SHA1 or RC_CERT_PFX — an unsigned installer is worse than no installer"
    cmd_build
    cmd_sign
    cmd_deps

    local v; v="$(version)"
    local out="$REPO/dist"
    mkdir -p "$out"

    local stage; stage="$out/wix-$v"
    rm -rf "$stage"; mkdir -p "$stage"
    cp "$WIN/tools/RemoteCrab.wxs" "$stage/"
    # Substitute what the build knows and the manifest must agree on.
    sed -i.bak \
        -e "s/@VERSION@/$v/g" \
        -e "s|@PAYLOAD@|$WIN/target/$TARGET/$PROFILE|g" \
        "$stage/RemoteCrab.wxs"
    rm -f "$stage/RemoteCrab.wxs.bak"

    # The install location is not cosmetic: `rc-vcam` resolves the DLL from
    # `current_exe()` and writes that **absolute path** into HKLM, then compares
    # it exactly on every run. A user who moves the folder gets a virtual camera
    # that silently stops appearing, and the only fix is another elevated write.
    # So the manifest's directory is fixed and documented.
    note "building the MSI (install dir: C:\\Program Files\\RemoteCrab)"
    local wxs; wxs="$(win_path "$stage/RemoteCrab.wxs")"
    local msi="$out/RemoteCrab-$v.msi"
    local wmsi; wmsi="$(win_path "$msi")"

    # v3 ships `candle` + `light`; v4 replaces both with a single `wix build`.
    # Checking for one and invoking the other is how you get a build that dies
    # with `candle: command not found` right after telling the operator to
    # install the version that does not provide it.
    if command -v wix >/dev/null 2>&1; then
        note "WiX v4 CLI"
        wix build "$wxs" -o "$wmsi" -arch x64 || die "MSI build failed (wix v4)"
    elif command -v candle >/dev/null 2>&1 && command -v light >/dev/null 2>&1; then
        note "WiX v3 candle + light"
        local wobj; wobj="$(win_path "$stage/RemoteCrab.wixobj")"
        candle -arch x64 -out "$wobj" "$wxs" \
            && light -out "$wmsi" "$wobj" \
            || die "MSI build failed (see the WiX output above)"
    else
        die "no WiX toolset found. Install v4:  dotnet tool install --global wix"
    fi
    [[ -f "$msi" ]] || die "the MSI was not produced at $msi"

    note "verifying the MSI is signed"
    sign_one "$msi"

    note "done: $msi"
    echo
    echo "Before shipping, run these on a clean Windows VM:"
    echo "  1. install the MSI, confirm no SmartScreen warning"
    echo "  2. scripts/check-windows-deps.sh on the installed remotecrab.exe"
    echo "  3. the tray row 'Install virtual camera' (the UAC path)"
    echo "  4. --uninstall-vcam, then confirm HKLM\\\\…\\\\CLSID is gone"
}

cmd_verify() {
    require_windows
    local dir="$WIN/target/$TARGET/$PROFILE"
    note "verifying build artifacts"
    [[ -f "$dir/remotecrab.exe" ]] || die "nothing built"
    # `powershell` is a native Windows program: an MSYS path like
    # `/e/RemoteCrab/...` reaches it verbatim and `Get-Item` fails, which this
    # function used to report as `NO VERSION RESOURCE` — a false alarm about
    # the one thing it is supposed to confirm.
    local win_exe; win_exe="$(win_path "$dir/remotecrab.exe")"
    local unsigned=0
    for f in remotecrab.exe rc_vcam_source.dll; do
        [[ -f "$dir/$f" ]] || { echo "  MISSING   $f"; unsigned=$((unsigned+1)); continue; }
        if signtool verify /pa "$dir/$f" >/dev/null 2>&1; then
            echo "  signed     $f"
        else
            echo "  UNSIGNED   $f"
            unsigned=$((unsigned+1))
        fi
    done
    # The icon and version have to be *in* the binary, not just intended.
    local fv
    fv="$(powershell -NoProfile -Command "(Get-Item '$win_exe').VersionInfo.FileVersion" 2>/dev/null | tr -d '\r')"
    if [[ -n "$fv" ]]; then
        echo "  version    $fv"
    else
        echo "  NO VERSION RESOURCE"
        unsigned=$((unsigned+1))
    fi
    cmd_deps || unsigned=$((unsigned+1))
    # This command exists to be read by whoever is about to ship, and also to
    # be run by a script. Printing `UNSIGNED` and exiting 0 lets a pipeline
    # treat an unsigned build as a passing one — the report and the exit code
    # have to agree, or only the report is doing any work.
    [[ "$unsigned" -eq 0 ]] || die "$unsigned problem(s) above — not shippable"
}

case "${1:-}" in
    version) version ;;
    build)   cmd_build ;;
    deps)    cmd_deps "${2:-}" ;;
    sign)    cmd_sign ;;
    package) cmd_package ;;
    verify)  cmd_verify ;;
    *) cat >&2 <<EOF
usage: scripts/release-windows.sh <command>

  version   print the version this would build (works anywhere)
  build     compile the MSVC release build (unsigned)
  deps      report the exe's runtime dependencies
  sign      sign the exe and the camera DLL
  package   build + sign + produce the signed MSI
  verify    check a built artifact's signature, version and dependencies

Everything except 'version' must be run on Windows.
EOF
       exit 2 ;;
esac
