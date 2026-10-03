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

pass=0; fail=0; skipped=0
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
# Do NOT swallow the launch result. A locked iPhone makes devicectl fail
# with "Unable to launch … because the device was not, or could not be,
# unlocked", and when that output is discarded the run continues to the
# assertions — where the app simply never started, so EVERY marker is
# missing and the suite reports ~24 product failures for what is really one
# precondition. Worse, the phone's forensic.log is APPENDED, so a stale
# file from an earlier run can satisfy an assertion and report a false PASS.
# Fail loudly here instead.
LAUNCH_OUT=$(xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
  --environment-variables '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_MIC":"1","REMOTECRAB_E2E_INPUT":"1","REMOTECRAB_E2E_SEND_FILE":"1","REMOTECRAB_E2E_CLIPBOARD":"1","REMOTECRAB_E2E_SWITCH":"com.apple.TextEdit","REMOTECRAB_E2E_SCREEN":"1","REMOTECRAB_E2E_SCREEN_INPUT":"1","REMOTECRAB_E2E_INSTALLED_APPS":"1","REMOTECRAB_E2E_DESKTOP":"1","REMOTECRAB_E2E_EXTEND":"1","REMOTECRAB_E2E_NOTIFY_TAP":"1"}' \
  "$BUNDLE_IOS" 2>&1)
if [ $? -ne 0 ] || echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not launch the app on the iPhone:"
  echo "$LAUNCH_OUT" | sed 's/^/      /' | head -20
  if echo "$LAUNCH_OUT" | grep -qi "Locked"; then
    echo ""
    echo "  → UNLOCK THE IPHONE and keep the screen on, then re-run."
    echo "    (iOS suspends the app while locked, so nothing it advertises"
    echo "     is reachable and every assertion below would fail for that"
    echo "     reason alone.)"
  fi
  exit 2
fi
echo "  launched OK"
echo "  waiting 30s for the scripted run…"
sleep 12
# The relay needs a live session; fire a real banner and let it cross the
# wire, then let the iPhone run the same action a tap would.
#
# Unique content per attempt, because macOS can decline to banner a repeat,
# and `caffeinate -u` first because no banner is shown while the display
# sleeps. Fired here — before the Desktop hook hides every app — so the
# desktop state can't be a factor.
for attempt in 1 2 3; do
  caffeinate -u -t 2 >/dev/null 2>&1 || true
  osascript -e "display notification \"e2e relay $attempt $(date +%s)\" with title \"RemoteCrab E2E\" subtitle \"relay\"" >/dev/null 2>&1 || true
  sleep 5
  if grep -q "relaying notification from" "$LOG" 2>/dev/null; then
    echo "  relayed on attempt $attempt"
    break
  fi
  echo "  no banner relayed yet (attempt $attempt)"
done
echo "  waiting for the rest of the scripted run…"
sleep 14
pkill -f "log stream --predicate" 2>/dev/null

# Best-effort: pull the iPhone's forensic log so we can assert the mirror
# actually DECODED on the device (not just that the Mac encoded + sent).
#
# The file is APPENDED, so it can hold lines from an EARLIER run — and a
# stale marker then reports a false PASS for a feature this run never
# exercised. Delete it first (the app recreates it on launch) and refuse to
# use it if it predates the run: an iOS assertion that cannot be attributed
# to this run must not count either way.
IOS_LOG=/tmp/remotecrab-ios-forensic.log
rm -f "$IOS_LOG"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_IOS" --source Documents/forensic.log \
  --destination "$IOS_LOG" >/dev/null 2>&1 || true
IOS_LOG_FRESH=1
if [ -f "$IOS_LOG" ]; then
  IOS_LOG_AGE=$(( $(date +%s) - $(stat -f %m "$IOS_LOG") ))
  # Anything older than 10 minutes cannot be from this run.
  if [ "$IOS_LOG_AGE" -gt 600 ]; then
    IOS_LOG_FRESH=0
    echo "  ⚠ the iPhone's forensic.log is ${IOS_LOG_AGE}s old — a previous run."
    echo "    Its markers are NOT evidence for this run; iOS-side assertions are skipped."
  else
    cat "$IOS_LOG" >> "$LOG"
  fi
else
  IOS_LOG_FRESH=0
  echo "  ⚠ could not pull forensic.log; iOS-side assertions are skipped."
fi

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
# This marker only ever appears in the PHONE's forensic log, so it is the
# one assertion that proves the pixels reached the device. Gate it on the
# log being from this run (see the freshness note above) so a leftover file
# can't report a pass for a mirror this run never received.
if [ "$IOS_LOG_FRESH" -eq 1 ]; then
  check "first screen frame decoded OK"   "mirror frame decoded on iPhone"
else
  echo "  ⤼ SKIP mirror frame decoded on iPhone — forensic.log not attributable to this run"
  skipped=$((skipped+1))
fi
check "-> global"                         "mirror input injected on Mac"
# A scroll must never move the pointer while the cursor is already inside
# the mirrored window: that teleporting was most of why "the pointer never
# lands where I tapped".
#
# TWO traps this assertion has to avoid, both of which produced a
# convincing wrong answer first:
#
#  1. Count, don't check for a marker — the old behaviour logged the same
#     line three times.
#  2. Scope the count to ONE target. This run also flips to the extended
#     virtual display (REMOTECRAB_E2E_EXTEND), and when the mirror changes
#     window the cursor legitimately must be re-placed — a second
#     "placed" line is then correct, not a regression. So only consider the
#     scrolls that arrive while the geometry still matches the window the
#     click landed in.
#  3. Require BOTH branches. Asserting only "left alone" passes trivially
#     when the pre-click scroll is dropped before reaching the injector —
#     a green run that proves nothing.
#
# `grep -c` prints "0" AND exits non-zero on no match, so `|| echo 0` would
# append a second "0" and break the integer test.
#  4. Count ONLY the Mac's injector lines. `$LOG` also has the phone's
#     forensic log appended to it, and that file contains its own "screen
#     input scroll" lines — counting the bare substring double-counts them
#     and makes the arithmetic nonsense.
# Delegates to scripts/e2e-cursor-guard.sh, which is separately runnable
# against a known log in BOTH directions — see that file for why a
# placement after a target change is not a regression, and why the reason
# has to come from the injector rather than be inferred from geometry here.
if "$ROOT/scripts/e2e-cursor-guard.sh" "$LOG" 2>/tmp/remotecrab-cursor-guard.txt; then
  printf '  \033[32m\u2713\033[0m %s\n' \
    "scrolling never steals the cursor ($(tr '\n' ' ' </tmp/remotecrab-cursor-guard.txt))"
  pass=$((pass+1))
else
  printf '  \033[31m\u2717\033[0m %s\n' \
    "scrolling never steals the cursor ($(tr '\n' ' ' </tmp/remotecrab-cursor-guard.txt))"
  fail=$((fail+1))
fi
check "installed apps"                    "installed-app list published (Open App…)"
check "showDesktop requested"             "Desktop quick action (showDesktop)"
check "toggle extended display"           "Extended Display toggle fired (top-bar button path)"
check "virtual display created"           "Extended Display: virtual display created"
check "streaming extended display"        "mirror streams the virtual display"
# Assert the INTENT ("the Mac resumed following"), not a particular reason
# label: after a Show Desktop the follow legitimately resolves to whole-display
# capture (lesson 73), so requiring reason=follow made this depend on hook
# timing rather than on the mutual toggle working.
check "screen mirror following frontmost app" "switched Extended → window mirror (resumed following)"
check "streaming display"                 "mirror followed Show Desktop → display capture"
check "notification relay started"        "notification relay armed"
# The relay can only be exercised if macOS actually SHOWED a banner. The
# scanner's debug line is the signal that the input existed: with
# `banners=0` on every tick a missing relay is indistinguishable from "no
# banner on screen" (locked/asleep display, coalescing), so report that as
# skipped rather than as a broken feature. `banners=1` means a real banner
# appeared, and then the relay MUST have forwarded it.
if grep -qE "banners=[1-9]" "$LOG" 2>/dev/null; then
  # The Mac logs "activated app" for the app-switch hook too, so it is a
  # false positive here; "[notify] tap:" is emitted only by the router
  # that a banner tap (or REMOTECRAB_E2E_NOTIFY_TAP) drives.
  check "relaying notification from"        "notification relayed to the iPhone"
  # Escaped: in a BRE `[notify]` is a CHARACTER CLASS, so an unescaped
  # pattern can never match the literal marker.
  check '\[notify\] tap:'                  "tapping the notification switched the Mac app"
else
  echo "  ⤼ SKIP notification relay — macOS showed no banner during the run"
  echo "       (scanner saw banners=0 on every tick; see AGENTS lesson 82 for the"
  echo "        manual real-device verification of the full relay + tap chain)"
  skipped=$((skipped + 2))
fi

echo
echo "== $pass passed, $fail failed, $skipped skipped =="
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
