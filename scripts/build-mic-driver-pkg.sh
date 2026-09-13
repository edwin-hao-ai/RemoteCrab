#!/usr/bin/env bash
#
# Build a double-clickable installer package for the iBridge virtual
# microphone. End users run THIS (double-click → one admin prompt),
# never a shell script. Installer.app copies the HAL driver into
# /Library/Audio/Plug-Ins/HAL and restarts coreaudiod.
#
# The app can embed the produced pkg (Contents/Resources) and open it
# from Preferences → Microphone Driver. For public distribution, sign
# it with a "Developer ID Installer" cert and notarize:
#   productsign --sign "Developer ID Installer: …" in.pkg out.pkg
#   xcrun notarytool submit out.pkg --keychain-profile … --wait
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${IBRIDGE_DERIVED:-$ROOT/.build/mic-derived}"
TEAM="${IBRIDGE_TEAM:-5XNDF727Y6}"
VERSION="${IBRIDGE_MIC_VERSION:-0.2}"
DRIVER_NAME="FamiliarMicrophone.driver"
OUT_DIR="$ROOT/dist"
OUT="$OUT_DIR/FamiliarMicrophone.pkg"

echo "== building $DRIVER_NAME =="
xcodebuild -project "$ROOT/iBridgeReceiver.xcodeproj" -scheme iBridgeMicrophone \
  -configuration Release -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
  -allowProvisioningUpdates build >/tmp/ibridge-mic-pkg-build.log 2>&1 \
  || { echo "build failed — see /tmp/ibridge-mic-pkg-build.log"; exit 1; }

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
  --identifier "com.ibridge.iBridgeMicrophone" --version "$VERSION" \
  --install-location / "$OUT"

echo "== built $OUT =="
echo "Sign + notarize this before public distribution, then embed it in the app"
echo "so Preferences → Microphone Driver can open it with one click."
