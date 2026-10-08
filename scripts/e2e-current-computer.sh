#!/usr/bin/env bash
#
# Targeted device e2e: the "current computer" switch to a computer that is
# ONLINE (announcing `_remotecrab-computer._tcp`) but has never been seen by
# the phone.
#
# That is exactly the path the 2026-10-07 current-computer design routes a new
# computer through (design §2: "the user picks it on the phone, arming
# `preferred` … the only way it can reach the approval step"). It was broken:
# `nameForComputer` resolved names from connected/paired/seen only, so the arm
# resolved to nil and the computer fell through to `busy(current)` — no
# approval card, the switch silently did nothing.
#
# One Mac is enough, in three phases:
#   A. connect it under its normal id  → the phone gains a `current` (persisted)
#   B. relaunch the SAME Mac under a fresh id (REMOTECRAB_E2E_MAC_ID) → it now
#      announces a computer the phone has never seen, and its dial is answered
#      `busy(current)` (it stands by)
#   C. relaunch the iOS app (UserDefaults preserved, so `current` is still the
#      old id) with REMOTECRAB_E2E_PICK_ONLINE=1 → the app runs the picker row's
#      exact action on that online computer. Assert the arm resolved a name from
#      presence and the dial reached the approval step (pending/accepted), not
#      `busy`.
#
# Prereqs: iPhone unlocked + screen on (USB), Mac Accessibility granted, and no
# iOS Simulator advertising `_remotecrab._tcp` (this script shuts them down).
# The deploy backs up + restores your /Applications/RemoteCrab.app on exit.
#
# Usage: ./scripts/e2e-current-computer.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${REMOTECRAB_DEVICE:-866A1921-B588-59D5-A1B7-B266103B2E49}"
TEAM="${REMOTECRAB_TEAM:-5XNDF727Y6}"
BUNDLE_IOS="com.ibridge.iBridgeCapture"
DD_ROOT="$ROOT/.build/e2e-current-derived"
DD_MAC="$DD_ROOT/Build/Products/Debug/RemoteCrab.app"
DD_IOS="$DD_ROOT/Build/Products/Debug-iphoneos/RemoteCrabCapture.app"
RELEASE_BACKUP=/tmp/remotecrab-e2e-current-release.app
NEW_ID="e2e-$(uuidgen)"
MAC_PID=""

stop_log() { pkill -f "log stream --predicate" 2>/dev/null; sleep 1; }
start_log() {
  stop_log
  : > "$1"
  nohup log stream --predicate 'subsystem == "com.remotecrab"' --info --style compact > "$1" 2>&1 &
  disown 2>/dev/null || true
  sleep 1
}
cleanup() {
  [ -n "$MAC_PID" ] && kill -9 "$MAC_PID" 2>/dev/null
  pkill -9 -x RemoteCrab 2>/dev/null
  stop_log
  if [ -d "$RELEASE_BACKUP" ]; then
    rm -rf /Applications/RemoteCrab.app
    ditto "$RELEASE_BACKUP" /Applications/RemoteCrab.app
    rm -rf "$RELEASE_BACKUP"
    echo "  ↩︎ restored your release install to /Applications/RemoteCrab.app"
  fi
}
trap cleanup EXIT

pass=0; fail=0
check() { # check <file> <marker> <label>
  # -F: markers contain `[e2e]` / `[hs]` — as a regex `[...]` is a character
  # class, so `grep "[e2e] pick…"` matches nothing and every phone-side
  # assertion reports a false failure. Literal match is what we mean.
  if grep -aqF -- "$2" "$1"; then
    printf '  \033[32m✓\033[0m %s\n' "$3"; pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s  (missing: %s)\n' "$3" "$2"; fail=$((fail+1))
  fi
}

echo "== RemoteCrab current-computer device e2e =="
echo "   new identity for Phase B: ${NEW_ID:0:8}…"

echo "[0/6] preconditions"
if ! xcrun devicectl list devices 2>/dev/null | grep -Eq "$DEVICE.*(available|connected)"; then
  echo "  device $DEVICE not available — connect + unlock it"; exit 2
fi
xcrun simctl shutdown all >/dev/null 2>&1 || true

echo "[1/6] build (signed)"
xcodebuild -project "$ROOT/RemoteCrabReceiver.xcodeproj" -scheme RemoteCrabReceiver -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-ec-macbuild.log 2>&1 \
  || { echo "  mac build failed (see /tmp/remotecrab-ec-macbuild.log)"; exit 1; }
xcodebuild -project "$ROOT/RemoteCrabCapture.xcodeproj" -scheme RemoteCrabCapture -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-ec-iosbuild.log 2>&1 \
  || { echo "  ios build failed (see /tmp/remotecrab-ec-iosbuild.log)"; exit 1; }

echo "[2/6] deploy"
pkill -9 -x RemoteCrab 2>/dev/null; sleep 1
rm -rf "$RELEASE_BACKUP"
[ -d /Applications/RemoteCrab.app ] && ditto /Applications/RemoteCrab.app "$RELEASE_BACKUP"
rm -rf /Applications/RemoteCrab.app && ditto "$DD_MAC" /Applications/RemoteCrab.app
echo "  (temporary dev-signed build; your install is backed up + restored on exit)"
xcrun devicectl device install app --device "$DEVICE" "$DD_IOS" >/dev/null 2>&1 \
  || { echo "  iOS install failed"; exit 1; }

launch_ios() { # launch_ios <json-env>
  xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --environment-variables "$1" "$BUNDLE_IOS"
}

echo "[3/6] Phase A — connect under the normal id (phone gains a current)"
LOG_A=/tmp/remotecrab-ec-a.log
start_log "$LOG_A"
/Applications/RemoteCrab.app/Contents/MacOS/RemoteCrab >/dev/null 2>&1 &
MAC_PID=$!
sleep 2
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_RESET_PAIRING":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not launch the app on the iPhone:"; echo "$LAUNCH_OUT" | sed 's/^/      /' | head -10
  echo "  → UNLOCK THE IPHONE and keep the screen on, then re-run."; exit 2
fi
for _ in $(seq 1 25); do grep -aq "sessionReply: accepted" "$LOG_A" && break; sleep 1; done
stop_log

echo "[4/6] Phase B — relaunch the Mac under a fresh id (online, never seen)"
LOG_B=/tmp/remotecrab-ec-b.log
kill -9 "$MAC_PID" 2>/dev/null; MAC_PID=""
sleep 3
start_log "$LOG_B"
REMOTECRAB_E2E_MAC_ID="$NEW_ID" /Applications/RemoteCrab.app/Contents/MacOS/RemoteCrab >/dev/null 2>&1 &
MAC_PID=$!
for _ in $(seq 1 25); do grep -aq "sessionReply: busy" "$LOG_B" && break; sleep 1; done
stop_log

echo "[5/6] Phase C — run the picker's tap on the online computer"
LOG_C=/tmp/remotecrab-ec-c.log
start_log "$LOG_C"
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not relaunch the app on the iPhone:"; echo "$LAUNCH_OUT" | sed 's/^/      /' | head -10; exit 2
fi
# Give the hook time to find the online computer, arm it, and let the switch run.
sleep 20
stop_log

# The phone-side markers live in the app's forensic.log (forensic markers are
# APPENDED, so a stale file must not count — gate on freshness).
IOS_LOG=/tmp/remotecrab-ec-ios.log
rm -f "$IOS_LOG"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_IOS" --source Documents/forensic.log \
  --destination "$IOS_LOG" >/dev/null 2>&1 || true
IOS_FRESH=0
if [ -f "$IOS_LOG" ]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$IOS_LOG") ))
  if [ "$AGE" -le 600 ]; then IOS_FRESH=1; else echo "  ⚠ forensic.log is ${AGE}s old — phone-side assertions skipped"; fi
fi

echo "[6/6] assertions"
check "$LOG_A" "sessionReply: accepted" "Phase A: phone accepted the Mac (phone now has a current)"
check "$LOG_B" "sessionReply: busy"     "Phase B: the never-seen identity stands by (busy)"
if [ "$IOS_FRESH" -eq 1 ]; then
  check "$IOS_LOG" "[e2e] pick online computer id=" "Phase C: the picker action ran on an online computer"
  check "$IOS_LOG" "[e2e] pick online resolved=true" "Phase C: arming resolved a name from presence (the fix)"
  check "$IOS_LOG" "[hs] sendSessionReply pending"  "Phase C: the picked computer reached the approval step (not busy)"
  check "$LOG_C"   "sessionReply: accepted"          "Phase C: the picked computer was accepted (switch completed)"
else
  echo "  ⤼ SKIP phone-side assertions — forensic.log not attributable to this run"
fi

echo ""
echo "pass=$pass fail=$fail"

# Leave the phone without this run's e2e identity in its pairing list or as its
# `current`, so the next launch of the real app does not hold the door for a
# machine that no longer exists. (This clears the allow-list too; the phone
# re-pairs normally on next use.)
launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_E2E_RESET_PAIRING":"1"}' >/dev/null 2>&1 || true
sleep 3

[ "$fail" -eq 0 ]
