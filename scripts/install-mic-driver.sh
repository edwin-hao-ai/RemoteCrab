#!/usr/bin/env bash
#
# Install the iBridge virtual-microphone HAL driver so every Mac app
# (Zoom, QuickTime, Voice Memos, Dictation…) can pick "iBridge
# Microphone" as an input device.
#
# This is the BlackHole/Loopback install model: a HAL AudioServerPlugIn
# in /Library/Audio/Plug-Ins/HAL + a coreaudiod restart. It needs admin
# rights, so it prompts for your password once. Audio is interrupted for
# a moment while coreaudiod restarts.
#
# Usage:  ./scripts/install-mic-driver.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${IBRIDGE_DERIVED:-$ROOT/.build/mic-derived}"
TEAM="${IBRIDGE_TEAM:-5XNDF727Y6}"
DRIVER_NAME="FamiliarMicrophone.driver"
DEST="/Library/Audio/Plug-Ins/HAL/$DRIVER_NAME"

echo "== [1/4] building $DRIVER_NAME (Release) =="
xcodebuild -project "$ROOT/iBridgeReceiver.xcodeproj" -scheme iBridgeMicrophone \
  -configuration Release -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
  -allowProvisioningUpdates build >/tmp/ibridge-mic-build.log 2>&1 \
  || { echo "build failed — see /tmp/ibridge-mic-build.log"; exit 1; }

DRIVER="$(find "$DERIVED/Build/Products" -maxdepth 3 -name "$DRIVER_NAME" | head -1)"
[ -n "$DRIVER" ] || { echo "built driver not found under $DERIVED"; exit 1; }

echo "== [2/4] installing to $DEST (admin required) =="
sudo rm -rf "$DEST"
sudo cp -R "$DRIVER" "$DEST"
sudo chown -R root:wheel "$DEST"

echo "== [3/4] restarting coreaudiod =="
sudo killall coreaudiod 2>/dev/null || true
sleep 1

echo "== [4/4] done =="
echo "“iBridge Microphone” should now appear in System Settings → Sound → Input,"
echo "and in any app's microphone picker. Run scripts/uninstall-mic-driver.sh to remove it."
