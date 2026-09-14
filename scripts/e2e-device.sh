#!/usr/bin/env bash
#
# RemoteCrab device end-to-end test.
#
# Drives the iPhone app headlessly (env flags, no taps) against a real
# Mac receiver and asserts the expected `com.remotecrab` log markers:
#   connect handshake, video, audio, touch, key, file transfer,
#   clipboard, app switch, recording.
#
# Prereqs:
#   • iPhone connected via USB (`xcrun devicectl list devices` = available)
#   • iPhone unlocked, screen on, RemoteCrab app allowed on Local Network
#   • Mac receiver has the Accessibility grant
#
# Usage:  ./scripts/e2e-device.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${REMOTECRAB_DEVICE:-866A1921-B588-59D5-A1B7-B266103B2E49}"
TEAM="${REMOTECRAB_TEAM:-5XNDF727Y6}"
BUNDLE_IOS="com.ibridge.iBridgeCapture"
DD_ROOT="$ROOT/.build/e2e-derived"
DD_MAC="$DD_ROOT/Build/Products/Debug/RemoteCrab.app"
DD_IOS="$DD_ROOT/Build/Products/Debug-iphoneos/RemoteCrabCapture.app"
LOG=/tmp/remotecrab-e2e.log

pass=0; fail=0
check() { # check <marker> <label>
  if grep -aq "$1" "$LOG"; then
    printf '  \033[32m✓\033[0m %s\n' "$2"; pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s  (missing: %s)\n' "$2" "$1"; fail=$((fail+1))
  fi
}

echo "== RemoteCrab device e2e =="

echo "[1/5] devices"
if ! xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE.*available"; then
  echo "  device $DEVICE not available — connect + unlock the iPhone"; exit 2
fi

echo "[2/5] build (signed)"
xcodebuild -project "$ROOT/RemoteCrabReceiver.xcodeproj" -scheme RemoteCrabReceiver -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-e2e-macbuild.log 2>&1 || { echo "  mac build failed"; exit 1; }
xcodebuild -project "$ROOT/RemoteCrabCapture.xcodeproj" -scheme RemoteCrabCapture -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-e2e-iosbuild.log 2>&1 || { echo "  ios build failed"; exit 1; }

echo "[3/5] deploy + install"
pkill -9 -x RemoteCrab 2>/dev/null; sleep 1
rm -rf /Applications/RemoteCrab.app && ditto "$DD_MAC" /Applications/RemoteCrab.app
xcrun devicectl device install app --device "$DEVICE" "$DD_IOS" >/dev/null 2>&1

echo "[4/5] run"
pkill -f "log stream --predicate" 2>/dev/null
nohup log stream --predicate 'subsystem == "com.remotecrab"' --info --style compact > "$LOG" 2>&1 &
disown 2>/dev/null || true
sleep 1
# TextEdit is the app-switcher target + the typing target.
open -a TextEdit; sleep 1
env REMOTECRAB_E2E_RECORD=1 /Applications/RemoteCrab.app/Contents/MacOS/RemoteCrab >/dev/null 2>&1 &
disown 2>/dev/null || true
sleep 3
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
  --environment-variables '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_MIC":"1","REMOTECRAB_E2E_INPUT":"1","REMOTECRAB_E2E_SEND_FILE":"1","REMOTECRAB_E2E_CLIPBOARD":"1","REMOTECRAB_E2E_SWITCH":"com.apple.TextEdit"}' \
  "$BUNDLE_IOS" >/dev/null 2>&1
echo "  waiting 22s for the scripted run…"
sleep 22
pkill -f "log stream --predicate" 2>/dev/null

echo "[5/5] assertions"
check "sessionReply: accepted"            "iPhone accepted the Mac (handshake)"
check "video frames received:"            "video frames decoded"
check "audio packets received:"           "audio packets received"
check "touch events received:"            "touch injection path"
check "key events received:"              "key injection path"
check "receiving file"                    "file offer received"
check "file saved"                        "file saved + Finder revealed"
check "clipboard received from iPhone"    "clipboard iPhone → Mac"
check "activated app"                     "app switch (activateApp)"
check "recording saved"                   "recording written to ~/Movies/RemoteCrab"

echo
echo "== $pass passed, $fail failed =="
echo "log: $LOG"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
