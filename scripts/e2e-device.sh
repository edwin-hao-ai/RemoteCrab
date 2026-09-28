#!/usr/bin/env bash
#
# RemoteCrab device end-to-end test.
#
# Drives the iPhone app headlessly (env flags, no taps) against a real
# Mac receiver and asserts the expected `com.remotecrab` log markers:
#   connect handshake, video, audio, touch, key, file transfer,
#   clipboard, app switch, recording, app-window mirror, the switcher's
#   installed-app launcher + Desktop quick action.
#
# Prereqs:
#   • iPhone connected via USB (`xcrun devicectl list devices` = available)
#   • iPhone unlocked, screen on, RemoteCrab app allowed on Local Network
#   • Mac receiver has the Accessibility grant
#   • NO other device advertising `_remotecrab._tcp` on the LAN — quit the
#     iOS Simulator's RemoteCrab (and any iPad/second phone) first, or the
#     Mac dials the leftover advertiser and every assertion fails with no
#     handshake (lesson 66).  `xcrun simctl shutdown all`
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
# The deploy step overwrites /Applications/RemoteCrab.app with a locally
# built (Apple Development) binary. That is a SIGNING-IDENTITY change for
# the app as far as TCC is concerned, so it silently drops EVERY grant the
# user had — Accessibility AND Screen Recording (lesson 79). Keep a copy of
# whatever was installed and put it back on exit, so running the e2e does
# not cost the user their permissions or their release build.
RELEASE_BACKUP=/tmp/remotecrab-e2e-release-install.app
restore_release_install() {
  [ -d "$RELEASE_BACKUP" ] || return 0
  pkill -9 -x RemoteCrab >/dev/null 2>&1 || true
  rm -rf /Applications/RemoteCrab.app
  ditto "$RELEASE_BACKUP" /Applications/RemoteCrab.app
  rm -rf "$RELEASE_BACKUP"
  echo "  ↩︎ restored your release install to /Applications/RemoteCrab.app"
}
trap restore_release_install EXIT

pass=0; fail=0
check() { # check <marker> <label>
  if grep -aq -- "$1" "$LOG"; then
    printf '  \033[32m✓\033[0m %s\n' "$2"; pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s  (missing: %s)\n' "$2" "$1"; fail=$((fail+1))
  fi
}

echo "== RemoteCrab device e2e =="

echo "[1/5] devices"
if ! xcrun devicectl list devices 2>/dev/null | grep -Eq "$DEVICE.*(available|connected)"; then
  echo "  device $DEVICE not available — connect + unlock it"; exit 2
fi
# A leftover iOS Simulator run advertises the same Bonjour service and steals
# the connection before the real iPhone can be reached (lesson 66) — shut
# every simulator down first so exactly one device is advertising.
xcrun simctl shutdown all >/dev/null 2>&1 || true

echo "[2/5] build (signed)"
xcodebuild -project "$ROOT/RemoteCrabReceiver.xcodeproj" -scheme RemoteCrabReceiver -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-e2e-macbuild.log 2>&1 || { echo "  mac build failed"; exit 1; }
xcodebuild -project "$ROOT/RemoteCrabCapture.xcodeproj" -scheme RemoteCrabCapture -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-e2e-iosbuild.log 2>&1 || { echo "  ios build failed"; exit 1; }

echo "[3/5] deploy + install"
pkill -9 -x RemoteCrab 2>/dev/null; sleep 1
rm -rf "$RELEASE_BACKUP"
[ -d /Applications/RemoteCrab.app ] && ditto /Applications/RemoteCrab.app "$RELEASE_BACKUP"
rm -rf /Applications/RemoteCrab.app && ditto "$DD_MAC" /Applications/RemoteCrab.app
echo "  (using a temporary dev-signed build; your install is backed up + restored on exit)"
xcrun devicectl device install app --device "$DEVICE" "$DD_IOS" >/dev/null 2>&1

echo "[4/5] run"
pkill -f "log stream --predicate" 2>/dev/null
nohup log stream --predicate 'subsystem == "com.remotecrab"' --info --style compact > "$LOG" 2>&1 &
disown 2>/dev/null || true
sleep 1
# TextEdit is the app-switcher target + the typing target.
# TextEdit is the app-switcher target + the typing target.
# Script Editor is the sender of an `osascript display notification`,
# and the tap can only activate a RUNNING app (a quit one is ignored).
open -a TextEdit; sleep 1
open -a "Script Editor"; sleep 1
env REMOTECRAB_E2E_RECORD=1 REMOTECRAB_DEBUG_NOTIFY=1 REMOTECRAB_E2E_NOTIFY_RELAY=1 \
    /Applications/RemoteCrab.app/Contents/MacOS/RemoteCrab >/dev/null 2>&1 &
disown 2>/dev/null || true
sleep 3
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
  --environment-variables '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_MIC":"1","REMOTECRAB_E2E_INPUT":"1","REMOTECRAB_E2E_SEND_FILE":"1","REMOTECRAB_E2E_CLIPBOARD":"1","REMOTECRAB_E2E_SWITCH":"com.apple.TextEdit","REMOTECRAB_E2E_SCREEN":"1","REMOTECRAB_E2E_SCREEN_INPUT":"1","REMOTECRAB_E2E_INSTALLED_APPS":"1","REMOTECRAB_E2E_DESKTOP":"1","REMOTECRAB_E2E_EXTEND":"1","REMOTECRAB_E2E_NOTIFY_TAP":"1"}' \
  "$BUNDLE_IOS" >/dev/null 2>&1
echo "  waiting 30s for the scripted run…"
sleep 20
# The relay needs a live session; fire a real banner and let it cross the
# wire, then let the iPhone run the same action a tap would.
#
# Wake the display first: macOS does NOT show a banner (so the AX tree has
# no banner element and the relay has nothing to forward) while the screen is
# asleep, which made this assertion fail for a reason that had nothing to do
# with the relay. `caffeinate -u` simulates user activity to wake it.
caffeinate -u -t 3 >/dev/null 2>&1 || true
sleep 1
osascript -e 'display notification "e2e relay check" with title "RemoteCrab E2E" subtitle "relay"' >/dev/null 2>&1 || true
echo "  fired a notification; waiting for the relay + tap…"
sleep 12
pkill -f "log stream --predicate" 2>/dev/null

# Best-effort: pull the iPhone's forensic log so we can assert the mirror
# actually DECODED on the device (not just that the Mac encoded + sent).
IOS_LOG=/tmp/remotecrab-ios-forensic.log
rm -f "$IOS_LOG"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_IOS" --source Documents/forensic.log \
  --destination "$IOS_LOG" >/dev/null 2>&1 || true
[ -f "$IOS_LOG" ] && cat "$IOS_LOG" >> "$LOG"

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
check "screen mirror created"             "screen mirror requested (screenControl.start)"
check "screenInfo status=ok"              "frontmost window resolved"
check "streaming window"                  "ScreenCaptureKit stream started"
check "screen frames sent:"               "mirror frames encoded + sent"
check "first screen frame decoded OK"     "mirror frame decoded on iPhone"
check "-> global"                         "mirror input injected on Mac"
check "installed apps"                    "installed-app list published (Open App…)"
check "showDesktop requested"             "Desktop quick action (showDesktop)"
check "toggle extended display"           "Extended Display toggle fired (top-bar button path)"
check "virtual display created"           "Extended Display: virtual display created"
check "streaming extended display"        "mirror streams the virtual display"
check "reason=follow"                     "switched Extended → window mirror (mutual toggle)"
check "streaming display"                 "mirror followed Show Desktop → display capture"
check "notification relay started"        "notification relay armed"
check "relaying notification from"        "notification relayed to the iPhone"
check "activated app"                     "tapping the notification switched the Mac app"

echo
echo "== $pass passed, $fail failed =="
echo "log: $LOG"

# Leave the app terminated. A headless run launches with REMOTECRAB_AUTO_START=1,
# which skips onboarding; if that instance stays alive, a later manual tap on
# the icon just resumes it and the user never sees onboarding ("居然没有
# onboarding 页面" — it was the e2e instance, not a missing flow).
#
# `devicectl device process terminate` requires `--pid`, so terminate by the
# pid we read back from the device's process list.
PID="$(xcrun devicectl device info processes --device "$DEVICE" --json-output /tmp/remotecrab-e2e-procs.json >/dev/null 2>&1; \
  python3 -c 'import json,sys
try:
    d=json.load(open("/tmp/remotecrab-e2e-procs.json"))
    ps=d["result"]["runningProcesses"]
    print(next((p.get("processIdentifier","") for p in ps if "RemoteCrabCapture" in (p.get("executable") or "")), ""))
except Exception:
    print("")' 2>/dev/null)"
if [ -n "$PID" ]; then
  xcrun devicectl device process terminate --device "$DEVICE" --pid "$PID" --kill >/dev/null 2>&1 || true
fi

exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
