#!/usr/bin/env bash
#
# RemoteCrab SIMULATOR end-to-end test.
#
# The simulator's Bonjour service is invisible to the host Mac's
# NWBrowser (see AGENTS.md real-device lesson 11), but the simulator
# shares the host network stack, so the iOS app's TCP listener is
# reachable at 127.0.0.1:8765. This script points the receiver's
# direct-IP fallback at 127.0.0.1 (remotecrab.lastPhoneIP) and lets
# the normal fallback loop connect — no product code changes.
#
# What this verifies (receiver-log markers, same as e2e-device.sh):
#   handshake, audio (Opus encode path!), touch, key, file transfer,
#   clipboard, app switch.
# What it CANNOT verify: video frames (simulator has no camera),
# recording (needs video), Bonjour discovery, pairing prompts.
#
# Usage:  ./scripts/e2e-simulator.sh [simulator-udid]
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM="${REMOTECRAB_TEAM:-5XNDF727Y6}"
BUNDLE_IOS="com.ibridge.iBridgeCapture"
DD_ROOT="$ROOT/.build/e2e-derived"
DD_MAC="$DD_ROOT/Build/Products/Debug/RemoteCrab.app"
DD_SIM="$ROOT/.build/e2e-sim-derived"
LOG=/tmp/remotecrab-e2e-sim.log
RECEIVER_DOMAIN="com.remotecrab.RemoteCrabReceiver"

pass=0; fail=0
check() { # check <marker> <label>
  if grep -aq "$1" "$LOG"; then
    printf '  \033[32m✓\033[0m %s\n' "$2"; pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s  (missing: %s)\n' "$2" "$1"; fail=$((fail+1))
  fi
}

echo "== RemoteCrab simulator e2e =="

# --- [1/6] pick a simulator -------------------------------------------------
echo "[1/6] simulator"
if [[ $# -ge 1 ]]; then
  SIM="$1"
else
  SIM=$(xcrun simctl list devices booted 2>/dev/null \
      | grep -E 'iPhone.*Booted' | head -1 \
      | grep -oE '[A-F0-9-]{36}' || true)
  if [[ -z "${SIM:-}" ]]; then
    SIM=$(xcrun simctl list devices available 2>/dev/null \
        | grep -E 'iPhone' | head -1 \
        | grep -oE '[A-F0-9-]{36}' || true)
  fi
fi
[[ -z "${SIM:-}" ]] && { echo "  no iPhone simulator found"; exit 2; }
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1
echo "  using $SIM"

# --- [2/6] builds -----------------------------------------------------------
echo "[2/6] build (receiver signed, iOS app for simulator)"
xcodebuild -project "$ROOT/RemoteCrabReceiver.xcodeproj" -scheme RemoteCrabReceiver -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-e2e-sim-macbuild.log 2>&1 \
  || { echo "  mac build failed (see /tmp/remotecrab-e2e-sim-macbuild.log)"; exit 1; }
xcodebuild -project "$ROOT/RemoteCrabCapture.xcodeproj" -scheme RemoteCrabCapture -configuration Debug \
  -destination "id=$SIM" -derivedDataPath "$DD_SIM" build CODE_SIGNING_ALLOWED=NO \
  >/tmp/remotecrab-e2e-sim-iosbuild.log 2>&1 \
  || { echo "  ios build failed (see /tmp/remotecrab-e2e-sim-iosbuild.log)"; exit 1; }
APP_SIM=$(find "$DD_SIM" -name "RemoteCrabCapture.app" -path "*Debug-iphonesimulator*" | head -1)
[[ -z "$APP_SIM" ]] && { echo "  simulator .app not found"; exit 1; }

# --- [3/6] deploy -----------------------------------------------------------
echo "[3/6] deploy + install"
pkill -9 -x RemoteCrab 2>/dev/null; sleep 1
rm -rf /Applications/RemoteCrab.app && ditto "$DD_MAC" /Applications/RemoteCrab.app
xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
xcrun simctl uninstall "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
xcrun simctl install "$SIM" "$APP_SIM" >/dev/null
# Grant BOTH camera and microphone: requestPermissions() awaits the
# camera prompt before the listener starts — an untapped prompt in the
# simulator deadlocks the whole launch (port 8765 never opens).
for p in camera microphone; do
  xcrun simctl privacy "$SIM" grant "$p" "$BUNDLE_IOS" 2>/dev/null || true
done

# Point the receiver's direct-IP fallback at the simulator. The old
# value is restored at the end so the real phone's fallback still works.
OLD_IP=$(defaults read "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP 2>/dev/null || echo "")
defaults write "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP "127.0.0.1"

# --- [4/6] run --------------------------------------------------------------
echo "[4/6] run"
pkill -f "log stream --predicate" 2>/dev/null
nohup log stream --predicate 'subsystem == "com.remotecrab"' --info --style compact > "$LOG" 2>&1 &
disown 2>/dev/null || true
sleep 1
# TextEdit is the typing target + the app-switcher target.
open -a TextEdit; sleep 1
/Applications/RemoteCrab.app/Contents/MacOS/RemoteCrab >/dev/null 2>&1 &
disown 2>/dev/null || true
sleep 3
SIMCTL_CHILD_REMOTECRAB_AUTO_START=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_AUTOPAIR=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_MIC=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_INPUT=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_SEND_FILE=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_CLIPBOARD=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_SWITCH="com.apple.TextEdit" \
  xcrun simctl launch "$SIM" "$BUNDLE_IOS" >/dev/null
echo "  waiting 30s for the scripted run (fallback probes after ~5s)…"
sleep 30
pkill -f "log stream --predicate" 2>/dev/null

# --- [5/6] assertions -------------------------------------------------------
echo "[5/6] assertions"
check "sessionReply: accepted"            "iPhone accepted the Mac (handshake via 127.0.0.1)"
check "audio packets received:"           "audio packets received (Opus encode path)"
check "touch events received:"            "touch injection path"
check "key events received:"              "key injection path"
check "receiving file"                    "file offer received"
check "file saved"                        "file saved + Finder revealed"
check "clipboard received from iPhone"    "clipboard iPhone → Mac"
check "activated app"                     "app switch (activateApp)"
echo "  -- skipped vs device e2e: video frames, recording (no camera in simulator)"

# --- [6/6] cleanup ----------------------------------------------------------
echo "[6/6] cleanup"
if [[ -n "$OLD_IP" ]]; then
  defaults write "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP "$OLD_IP"
else
  defaults delete "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP 2>/dev/null || true
fi
pkill -9 -x RemoteCrab 2>/dev/null
xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
echo "  receiver stopped — relaunch it from /Applications/RemoteCrab.app when needed"

echo
echo "== $pass passed, $fail failed =="
echo "log: $LOG"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
