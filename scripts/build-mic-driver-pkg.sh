#!/usr/bin/env bash
#
# Build a double-clickable installer package for the RemoteCrab virtual
# microphone. End users run THIS (double-click → one admin prompt),
# never a shell script. Installer.app copies the HAL driver into
# /Library/Audio/Plug-Ins/HAL and restarts coreaudiod.
#
# SIGNING RULE (hard-won): the driver must be signed with **Developer ID
# Application**, not "Apple Development" — coreaudiod runs with library
# validation and silently refuses to load development-signed HAL
# plug-ins (the pkg installs fine; the device just never appears).
#
# The app embeds the produced pkg (Contents/Resources) and opens it
# from Preferences → Microphone Driver. For public distribution, also
# productsign with a "Developer ID Installer" cert and notarize:
#   productsign --sign "Developer ID Installer: …" in.pkg out.pkg
#   xcrun notarytool submit out.pkg --keychain-profile … --wait
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${REMOTECRAB_DERIVED:-$ROOT/.build/mic-derived}"
TEAM="${REMOTECRAB_TEAM:-5XNDF727Y6}"
IDENTITY="${REMOTECRAB_MIC_IDENTITY:-Developer ID Application}"
VERSION="${REMOTECRAB_MIC_VERSION:-0.2.1}"
DRIVER_NAME="RemoteCrabMicrophone.driver"
OUT_DIR="$ROOT/dist"
OUT="$OUT_DIR/RemoteCrabMicrophone.pkg"

echo "== building $DRIVER_NAME (identity: $IDENTITY, arch: x86_64) =="
# x86_64 on purpose: macOS hosts each third-party driver in a
# Core-Audio-Driver-Service.helper of matching architecture. The arm64
# helper is arm64e and calls the driver's vtable with `blraaz` (pointer
# authentication); a plain arm64 binary's vtable entries are unsigned,
# so the authenticated call faults (SIGILL in init_driver_interface,
# right after "Loading server plug-in X…" with no "Done"). Every
# shipping third-party driver on this machine (Teams/Lark/TFF/…) is
# x86_64 — the x86_64 helper has no PAC and just works. Rosetta is
# present on every Apple Silicon Mac that has run any x86_64 app.
xcodebuild -project "$ROOT/RemoteCrabReceiver.xcodeproj" -scheme RemoteCrabMicrophone \
  -configuration Release -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  build >/tmp/remotecrab-mic-pkg-build.log 2>&1 \
  || { echo "build failed — see /tmp/remotecrab-mic-pkg-build.log"; exit 1; }

DRIVER="$(find "$DERIVED/Build/Products" -maxdepth 3 -name "$DRIVER_NAME" | head -1)"
[ -n "$DRIVER" ] || { echo "driver not found under $DERIVED"; exit 1; }

STAGE="$(mktemp -d)"
SCRIPTS="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$SCRIPTS"' EXIT
mkdir -p "$STAGE/Library/Audio/Plug-Ins/HAL"
cp -R "$DRIVER" "$STAGE/Library/Audio/Plug-Ins/HAL/"

cat > "$SCRIPTS/postinstall" <<'EOS'
#!/bin/sh
# Restart coreaudiod so it loads the new HAL plug-in.
killall coreaudiod 2>/dev/null || true
exit 0
EOS
chmod +x "$SCRIPTS/postinstall"

mkdir -p "$OUT_DIR"
pkgbuild --root "$STAGE" --scripts "$SCRIPTS" \
  --identifier "com.remotecrab.RemoteCrabMicrophone" --version "$VERSION" \
  --install-location / "$OUT"

echo "== built $OUT =="
echo "Sign + notarize this before public distribution, then embed it in the app"
echo "so Preferences → Microphone Driver can open it with one click."
