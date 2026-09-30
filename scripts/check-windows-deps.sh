#!/usr/bin/env bash
# Check what a built remotecrab.exe needs from the machine it runs on.
#
# Why this is a script and not a judgement call: the failure it prevents is
# "it works on my machine" — the exe starts fine on a build box that happens to
# have MinGW's runtime lying around, and dies on a clean install with no error
# a user can act on.
#
# The measured reality of a `x86_64-pc-windows-gnu` build (2026-09-30):
#
#   api-ms-win-crt-*.dll   the Universal CRT. Present on Windows 10+ via the
#                          API-set forwarders, so NOT a problem in practice.
#   libstdc++-6.dll        MinGW's C++ runtime, pulled in by OpenH264's C++.
#                          ** Not on any stock Windows.** Must be shipped next
#                          to the exe, or statically linked.
#   libgcc_s_seh-1.dll     the same story, and it appears the moment anything
#                          needs the unwinder.
#
# An MSVC build has neither problem — that is the target a real release wants,
# and it cannot be produced from a Mac (openh264-sys2 needs MSVC or a working
# GNU C++ toolchain for that triple).
#
# Usage:  scripts/check-windows-deps.sh [path/to/remotecrab.exe]
# Exit:   0 = every out-of-box dependency is resolvable; 1 = one is not.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXE="${1:-}"

if [[ -z "$EXE" ]]; then
    EXE="$(ls -1 "$HOME"/.cargo/shared-target/x86_64-pc-windows-gnu/release/remotecrab.exe 2>/dev/null | head -1)"
fi
if [[ -z "$EXE" || ! -f "$EXE" ]]; then
    echo "no remotecrab.exe found — build it first:" >&2
    echo "  cargo build --release -p rc-app --target x86_64-pc-windows-gnu" >&2
    exit 1
fi

OBJDUMP="$(command -v x86_64-w64-mingw32-objdump || command -v llvm-objdump || true)"
if [[ -z "$OBJDUMP" ]]; then
    echo "need x86_64-w64-mingw32-objdump (brew install mingw-w64) or llvm-objdump" >&2
    exit 1
fi

DIR="$(cd "$(dirname "$EXE")" && pwd)"

# DLLs Windows 10 (1607+) and Windows 11 always have, by name. Deliberately a
# name list rather than "anything under api-ms-win-*": an api-set entry is a
# forwarder, and the forwarder resolves to something in the box, but a *misspelt*
# one fails at load with an unhelpful error.
in_box() {
    case "$1" in
        KERNEL32.dll|kernel32.dll|NTDLL.dll|ntdll.dll|USER32.dll|user32.dll|\
        GDI32.dll|gdi32.dll|ADVAPI32.dll|advapi32.dll|SHELL32.dll|shell32.dll|\
        OLE32.dll|ole32.dll|OLEAUT32.dll|oleaut32.dll|WS2_32.dll|ws2_32.dll|\
        COMBASE.dll|combase.dll|bcryptprimitives.dll|MSVCRT.dll|msvcrt.dll|\
        api-ms-win-*|MFPLAT.dll|mfplat.dll|MFSENSORGROUP.dll|mfsensorgroup.dll|\
        MMDEVAUDIO.dll|mmdevapi.dll|IPHLPAPI.dll|iphlpapi.dll|AVRT.dll|avrt.dll|\
        dxgi.dll|DXGI.dll|RPCRT4.dll|rpcrt4.dll|sechost.dll|SECHOST.dll)
            return 0 ;;
        *) return 1 ;;
    esac
}

echo "remotecrab.exe: $EXE"
"$OBJDUMP" -p "$EXE" | sed -n 's/.*DLL Name: //p' | tr -d '\r' | sort -u > /tmp/rc-dlls.txt
total=$(wc -l < /tmp/rc-dlls.txt | tr -d ' ')
echo "imports: $total DLLs"
echo

missing=0
ship=()
while IFS= read -r dll; do
    [[ -z "$dll" ]] && continue
    if in_box "$dll"; then
        continue
    fi
    if [[ -f "$DIR/$dll" ]]; then
        ship+=("$dll (next to the exe)")
        continue
    fi
    missing=$((missing + 1))
    echo "MISSING  $dll"
done < /tmp/rc-dlls.txt

if [[ ${#ship[@]} -gt 0 ]]; then
    echo
    echo "shipped alongside the exe:"
    printf '  %s\n' "${ship[@]}"
fi

echo
if [[ $missing -gt 0 ]]; then
    cat >&2 <<EOF
$missing DLL(s) are neither part of Windows nor next to the exe.
The build will start on this machine and fail on a clean install.

Two ways out, in order of preference:
  1. Build the MSVC target on Windows:
       rustup target add x86_64-pc-windows-msvc
       cargo build --release -p rc-app --target x86_64-pc-windows-msvc
     No MinGW runtime, and the ABI every Windows tool expects.
  2. Ship the MinGW runtime next to the exe — the installer must copy it, and
     it must NOT be one PATH lookup away from somewhere else on the machine.
EOF
    exit 1
fi

echo "OK — every dependency is either in the box or shipped with the exe."
echo "     (An MSVC build has no out-of-box dependency at all; prefer it.)"
