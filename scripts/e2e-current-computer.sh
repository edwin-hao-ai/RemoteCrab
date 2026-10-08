#!/usr/bin/env bash
#
# Real-device e2e for the phone-initiated connection v2 design
# (docs/superpowers/specs/2026-10-08-phone-initiated-connection-v2-design.md).
#
# It drives ONE Mac under several identities so a single machine can stand in
# for "computer A", "computer B" and "a legacy receiver", and asserts the three
# acceptance criteria of the design on a real iPhone:
#
#   §3 / §8.1  tap-to-switch < 2 s, no re-confirmation, no busy lock
#   §7.3       forget a computer → row gone, no auto-dial, its knock goes pending
#   §4.4 / §6  new phone + OLD receiver → falls back to the inbound knock+dial-back
#
# Identity model
# --------------
# `REMOTECRAB_E2E_MAC_ID` overrides the receiver's id per process. A and B are
# two ids of the SAME Mac; because a real A/B are two machines with two token
# stores, the harness snapshots + swaps the app's UserDefaults domain
# (`com.remotecrab.RemoteCrabReceiver`) between B and the A round-trip. Without
# that, B's `accepted` would overwrite A's token (the store is one slot per
# phone) and "switch back to an already-paired A" would fail peer-auth — an
# artefact of one machine impersonating two, not a product defect.
#
# The legacy phase runs the user's own previously-installed release build
# (backed up to $RELEASE_BACKUP before we deploy the dev build). That build
# predates `IBPhoneHello` (verified: it has "advertising presence" but no
# "inbound phoneHello"), so it is a genuine legacy receiver: it treats the
# phone's dial as a knock and dials back.
#
# Prereqs: iPhone unlocked + screen on (USB), Mac Accessibility granted, and no
# iOS Simulator advertising `_remotecrab._tcp` (this script shuts sims down).
# The deploy backs up + restores your /Applications/RemoteCrab.app AND your Mac
# receiver UserDefaults on exit.
#
# Usage: ./scripts/e2e-current-computer.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${REMOTECRAB_DEVICE:-866A1921-B588-59D5-A1B7-B266103B2E49}"
TEAM="${REMOTECRAB_TEAM:-5XNDF727Y6}"
BUNDLE_IOS="com.ibridge.iBridgeCapture"
MAC_DOMAIN="com.remotecrab.RemoteCrabReceiver"
DD_ROOT="$ROOT/.build/e2e-current-derived"
DD_MAC="$DD_ROOT/Build/Products/Debug/RemoteCrab.app"
DD_IOS="$DD_ROOT/Build/Products/Debug-iphoneos/RemoteCrabCapture.app"
RELEASE_BACKUP=/tmp/remotecrab-e2e-current-release.app
PREFS_BACKUP=/tmp/remotecrab-e2e-current-userprefs.plist
SNAP_A=/tmp/remotecrab-e2e-current-snapA.plist
SNAP_B=/tmp/remotecrab-e2e-current-snapB.plist
ID_A="e2e-a-$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-8)"
ID_B="e2e-b-$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-8)"
ID_L="e2e-l-$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-8)"
MAC_PID=""
# Set once the dev build is in /Applications so cleanup knows to restore.
DEPLOYED=0

stop_log() { pkill -f "log stream --predicate" 2>/dev/null; sleep 1; }
start_log() {
  stop_log
  : > "$1"
  nohup log stream --predicate 'subsystem == "com.remotecrab"' --info --style compact > "$1" 2>&1 &
  disown 2>/dev/null || true
  sleep 1
}
kill_mac() {
  if [ -n "$MAC_PID" ]; then kill -9 "$MAC_PID" 2>/dev/null; MAC_PID=""; fi
  pkill -9 -x RemoteCrab 2>/dev/null
  sleep 2
}
cleanup() {
  kill_mac
  stop_log
  # Restore the user's receiver defaults first (the dev build and the legacy
  # phase both mutate the same domain), then the /Applications install.
  if [ -f "$PREFS_BACKUP" ]; then
    defaults import "$MAC_DOMAIN" "$PREFS_BACKUP" >/dev/null 2>&1 \
      && echo "  ↩︎ restored your Mac receiver preferences"
    rm -f "$PREFS_BACKUP"
  fi
  if [ -d "$RELEASE_BACKUP" ]; then
    rm -rf /Applications/RemoteCrab.app
    ditto "$RELEASE_BACKUP" /Applications/RemoteCrab.app
    rm -rf "$RELEASE_BACKUP"
    echo "  ↩︎ restored your release install to /Applications/RemoteCrab.app"
  fi
  rm -f "$SNAP_A" "$SNAP_B"
}
trap cleanup EXIT

pass=0; fail=0
check() { # check <file> <literal> <label>
  # -F: markers contain `[e2e]` / `[hs]` — as a regex `[...]` is a character
  # class, so `grep "[e2e] …"` matches nothing and every assertion false-fails.
  if grep -aqF -- "$2" "$1"; then
    printf '  \033[32m✓\033[0m %s\n' "$3"; pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s  (missing: %s)\n' "$3" "$2"; fail=$((fail+1))
  fi
}
check_absent() { # check_absent <file> <literal> <label>
  if grep -aqF -- "$2" "$1"; then
    printf '  \033[31m✗\033[0m %s  (unexpected: %s)\n' "$3" "$2"; fail=$((fail+1))
  else
    printf '  \033[32m✓\033[0m %s\n' "$3"; pass=$((pass+1))
  fi
}
# delta <log> <start-regex> <end-regex> → seconds between the first start and the
# first following end, from the `log stream` millisecond timestamps (the phone's
# Forensic.log is only 1 s resolution, so timing is measured Mac-side).
delta() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
from datetime import datetime
log, startre, endre = sys.argv[1], sys.argv[2], sys.argv[3]
tpat = re.compile(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)')
st = en = None
for line in open(log, errors='replace'):
    m = tpat.match(line)
    if not m:
        continue
    ts = datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S.%f')
    if st is None and re.search(startre, line):
        st = ts
    elif st is not None and re.search(endre, line):
        en = ts
        break
print(f"{(en - st).total_seconds():.3f}" if st and en else "NA")
PY
}
lt2() { # lt2 <seconds> <label> → assert a measured delta is a number < 2.0
  local v="$1"
  if [ "$v" = "NA" ]; then
    printf '  \033[31m✗\033[0m %s  (no measurable timestamps)\n' "$2"; fail=$((fail+1))
  elif python3 -c "import sys; sys.exit(0 if 0 <= float('$v') < 2.0 else 1)"; then
    printf '  \033[32m✓\033[0m %s  (%ss < 2s)\n' "$2" "$v"; pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s  (%ss ≥ 2s)\n' "$2" "$v"; fail=$((fail+1))
  fi
}

pull_ios() { # pull_ios <dest>
  rm -f "$1"
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_IOS" --source Documents/forensic.log \
    --destination "$1" >/dev/null 2>&1 || true
}

launch_ios() { # launch_ios <json-env>
  xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --environment-variables "$1" "$BUNDLE_IOS"
}

wait_accepted() { # wait_accepted <mac-log> <seconds>
  for _ in $(seq 1 "$2"); do grep -aq "sessionReply: accepted" "$1" && return 0; sleep 1; done
  return 1
}

echo "== RemoteCrab phone-initiated-connection v2 device e2e =="
echo "   identities: A=${ID_A:0:8}  B=${ID_B:0:8}  legacy=${ID_L:0:8}"

echo "[0/8] preconditions"
if ! xcrun devicectl list devices 2>/dev/null | grep -Eq "$DEVICE.*(available|connected)"; then
  echo "  device $DEVICE not available — connect + unlock it"; exit 2
fi
xcrun simctl shutdown all >/dev/null 2>&1 || true

echo "[1/8] build (signed)"
xcodebuild -project "$ROOT/RemoteCrabReceiver.xcodeproj" -scheme RemoteCrabReceiver -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-ec-macbuild.log 2>&1 \
  || { echo "  mac build failed (see /tmp/remotecrab-ec-macbuild.log)"; exit 1; }
xcodebuild -project "$ROOT/RemoteCrabCapture.xcodeproj" -scheme RemoteCrabCapture -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-ec-iosbuild.log 2>&1 \
  || { echo "  ios build failed (see /tmp/remotecrab-ec-iosbuild.log)"; exit 1; }

echo "[2/8] deploy"
kill_mac
rm -rf "$RELEASE_BACKUP" "$PREFS_BACKUP" "$SNAP_A" "$SNAP_B"
[ -d /Applications/RemoteCrab.app ] && ditto /Applications/RemoteCrab.app "$RELEASE_BACKUP"
defaults export "$MAC_DOMAIN" "$PREFS_BACKUP" >/dev/null 2>&1 || true
[ -f "$PREFS_BACKUP" ] || echo "  ⚠ could not back up the Mac receiver prefs; cleanup cannot restore them"
rm -rf /Applications/RemoteCrab.app && ditto "$DD_MAC" /Applications/RemoteCrab.app
DEPLOYED=1
echo "  (temporary dev-signed build; your install + prefs are restored on exit)"
xcrun devicectl device install app --device "$DEVICE" "$DD_IOS" >/dev/null 2>&1 \
  || { echo "  iOS install failed"; exit 1; }

MAC_BIN=/Applications/RemoteCrab.app/Contents/MacOS/RemoteCrab
run_mac() { # run_mac <id> [<bin>] → starts the receiver, sets MAC_PID
  local id="$1" bin="${2:-$MAC_BIN}"
  REMOTECRAB_E2E_MAC_ID="$id" "$bin" >/dev/null 2>&1 &
  MAC_PID=$!
  sleep 4
}

# ---------------------------------------------------------------------------
echo "[3/8] Phase A — phone pairs with computer A (fresh, first contact)"
LOG_A=/tmp/remotecrab-ec-a.log
start_log "$LOG_A"
run_mac "$ID_A"
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_RESET_PAIRING":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not launch the app on the iPhone:"; echo "$LAUNCH_OUT" | sed 's/^/      /' | head -10
  echo "  → UNLOCK THE IPHONE and keep the screen on, then re-run."; exit 2
fi
wait_accepted "$LOG_A" 40 || echo "  ⚠ no accepted within 40s in Phase A"
stop_log
pull_ios /tmp/remotecrab-ec-ios-a.log
kill_mac
defaults export "$MAC_DOMAIN" "$SNAP_A" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
echo "[4/8] Phase B — switch to computer B (paired second; must not be busy-locked)"
LOG_B=/tmp/remotecrab-ec-b.log
start_log "$LOG_B"
run_mac "$ID_B"
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not relaunch the app: $LAUNCH_OUT"; exit 2
fi
wait_accepted "$LOG_B" 40 || echo "  ⚠ no accepted within 40s in Phase B"
stop_log
pull_ios /tmp/remotecrab-ec-ios-b.log
kill_mac
defaults export "$MAC_DOMAIN" "$SNAP_B" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
echo "[5/8] Phase C — switch BACK to already-paired A (no approval; must be accepted)"
# Restore A's token store so peer-auth can prove A (one Mac standing in for two).
[ -f "$SNAP_A" ] && defaults import "$MAC_DOMAIN" "$SNAP_A" >/dev/null 2>&1 || true
LOG_C=/tmp/remotecrab-ec-c.log
start_log "$LOG_C"
run_mac "$ID_A"
# NOTE: deliberately NO REMOTECRAB_E2E_AUTOPAIR — reaching `accepted` without it
# is the "no re-confirmation" proof.
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not relaunch the app: $LAUNCH_OUT"; exit 2
fi
wait_accepted "$LOG_C" 40 || echo "  ⚠ no accepted within 40s in Phase C"
stop_log
pull_ios /tmp/remotecrab-ec-ios-c.log

# ---------------------------------------------------------------------------
echo "[6/8] Phase D — forget the current computer (row gone + no auto-dial + pending)"
# A (dev build) is still running from Phase C. Relaunch the phone with the
# forget hook; the hook runs BEFORE auto-dial, so nothing may dial A.
LOG_D=/tmp/remotecrab-ec-d.log
start_log "$LOG_D"
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_FORGET_CURRENT":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not relaunch the app: $LAUNCH_OUT"; exit 2
fi
# The pick hook needs 20 s to conclude "no eligible online computer" (A is
# suppressed) — that is the row-gone proof.
sleep 24
# Knock A's presence port so it dials the phone back; the phone no longer has A
# paired, so the inbound handshake must be answered `pending`, never accepted.
nc -z -G 2 127.0.0.1 8766 >/dev/null 2>&1 || true
sleep 8
stop_log
pull_ios /tmp/remotecrab-ec-ios-d.log
kill_mac

# ---------------------------------------------------------------------------
echo "[7/8] Phase E — legacy receiver (release build, no IBPhoneHello support)"
# Put the user's release build back at the canonical path so running it does not
# look like the host app "moved" to the system-extension manager.
if [ -d "$RELEASE_BACKUP" ]; then
  rm -rf /Applications/RemoteCrab.app && ditto "$RELEASE_BACKUP" /Applications/RemoteCrab.app
fi
LOG_E=/tmp/remotecrab-ec-e.log
start_log "$LOG_E"
run_mac "$ID_L" /Applications/RemoteCrab.app/Contents/MacOS/RemoteCrab
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not relaunch the app: $LAUNCH_OUT"; exit 2
fi
wait_accepted "$LOG_E" 40 || echo "  ⚠ no accepted within 40s in Phase E"
stop_log
pull_ios /tmp/remotecrab-ec-ios-e.log
kill_mac

# ---------------------------------------------------------------------------
echo "[8/8] assertions"
DELTA_A=$(delta "$LOG_A" "inbound phoneHello from" "sessionReply: accepted")
DELTA_B=$(delta "$LOG_B" "inbound phoneHello from" "sessionReply: accepted")
DELTA_C=$(delta "$LOG_C" "inbound phoneHello from" "sessionReply: accepted")

echo "  -- Phase A (pair A) --"
check "$LOG_A" "sessionReply: accepted" "A accepted the phone's dial"
check "$LOG_A" "inbound phoneHello from" "A saw the phone-initiated hello (dial path, not knock)"
check /tmp/remotecrab-ec-ios-a.log "[e2e] pick online dial" "phone ran the picker row's dial action"
check /tmp/remotecrab-ec-ios-a.log "[dial] outbound to" "phone opened an outbound dial"
check_absent /tmp/remotecrab-ec-ios-a.log "[hs] sendSessionReply busy" "phone did not answer busy"
lt2 "$DELTA_A" "Phase A dial→accepted"

echo "  -- Phase B (switch to B) --"
check "$LOG_B" "sessionReply: accepted" "B accepted (no busy lock from current=A)"
check "$LOG_B" "inbound phoneHello from" "B saw the phone-initiated hello"
check_absent /tmp/remotecrab-ec-ios-b.log "[hs] sendSessionReply busy" "phone did not answer busy"
lt2 "$DELTA_B" "Phase B dial→accepted"

echo "  -- Phase C (switch back to paired A, no AUTOPAIR) --"
check "$LOG_C" "sessionReply: accepted" "paired A accepted without re-confirmation"
check /tmp/remotecrab-ec-ios-c.log "[auth] receiver proved the token" "peer-auth proved the stored token (no approval card)"
check_absent /tmp/remotecrab-ec-ios-c.log "[hs] sendSessionReply busy" "phone did not answer busy"
lt2 "$DELTA_C" "Phase C dial→accepted"

echo "  -- Phase D (forget current) --"
check /tmp/remotecrab-ec-ios-d.log "[e2e] forgot current computer ${ID_A:0:8}" "phone forgot the current computer on launch"
check /tmp/remotecrab-ec-ios-d.log "[e2e] pick online: no eligible online computer found" "forgotten computer is gone from the picker roster (suppressed)"
check_absent /tmp/remotecrab-ec-ios-d.log "[dial] auto-dial last computer" "phone did not auto-dial the forgotten computer"
check "$LOG_D" "sessionReply: pending" "a knock from the forgotten computer is answered pending (re-approval)"
check_absent "$LOG_D" "sessionReply: accepted" "the forgotten computer was NOT auto-accepted"

echo "  -- Phase E (legacy receiver fallback) --"
check /tmp/remotecrab-ec-ios-e.log "[dial] outbound to ${ID_L:0:8}" "phone dialed the legacy receiver"
check /tmp/remotecrab-ec-ios-e.log "[dial] no clientHello from ${ID_L:0:8}" "phone gave up the dial after no clientHello (legacy fallback)"
check "$LOG_E" "sessionReply: accepted" "legacy receiver's dial-back was accepted (inbound fallback connected)"

echo ""
echo "pass=$pass fail=$fail"
echo "  timing: A=${DELTA_A}s  B=${DELTA_B}s  C=${DELTA_C}s"

# Leave the phone without this run's e2e identities in its pairing list.
launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_E2E_RESET_PAIRING":"1"}' >/dev/null 2>&1 || true
sleep 3

[ "$fail" -eq 0 ]
