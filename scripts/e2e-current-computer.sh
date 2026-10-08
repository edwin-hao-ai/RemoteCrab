#!/usr/bin/env bash
#
# Real-device e2e for the phone-initiated connection v2 design
# (docs/superpowers/specs/2026-10-08-phone-initiated-connection-v2-design.md).
#
# One Mac stands in for three computers, and the harness asserts the design's
# three acceptance criteria on a real iPhone:
#
#   §3 / §8.1  tap-to-switch < 2 s, no re-confirmation, no busy lock
#   §7.3       forget a computer → row gone, no auto-dial, its knock goes pending
#   §4.4 / §6  new phone + OLD receiver → falls back to the inbound knock+dial-back
#
# Identity model
# --------------
# Each "computer" is an independent COPY of the built app with its own bundle id
# (and therefore its own UserDefaults domain, hence its own pairing-token store).
# That is the faithful model: two real Macs never share a token slot, and the
# app's token index is one slot per phone. The copies are ad-hoc re-signed and
# run from /tmp — the user's /Applications install is never touched, and each
# copy's domain is seeded with `remotecrab.sysexSubmittedAppPath` so the
# system-extension manager sees "up to date" and neither activates nor
# deactivates the user's camera extension (this run never uses it).
#
# A and B are the dev build under env identity `REMOTECRAB_E2E_MAC_ID`; the
# legacy copy is the user's own installed release build (verified pre-`IBPhoneHello`:
# it has "advertising presence" but no "inbound phoneHello"), so it treats the
# phone's dial as a knock and dials back.
#
# Prereqs: iPhone unlocked + screen on (USB), Mac Accessibility granted, and no
# iOS Simulator advertising `_remotecrab._tcp` (this script shuts sims down).
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

# Three stand-in computers. Unique-ish ids so a stale record on the phone cannot
# mask a result; distinct bundle ids so their token stores are independent.
SUFFIX="$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-6)"
ID_A="e2e-a-$SUFFIX"
ID_B="e2e-b-$SUFFIX"
ID_L="e2e-l-$SUFFIX"
APP_A="/tmp/remotecrab-t17-A.app"
APP_B="/tmp/remotecrab-t17-B.app"
APP_L="/tmp/remotecrab-t17-L.app"
BID_A="com.remotecrab.RemoteCrabReceiver.t17a.$SUFFIX"
BID_B="com.remotecrab.RemoteCrabReceiver.t17b.$SUFFIX"
BID_L="com.remotecrab.RemoteCrabReceiver.t17l.$SUFFIX"
MAC_PID=""

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
  for d in "$BID_A" "$BID_B" "$BID_L"; do defaults delete "$d" >/dev/null 2>&1; done
  rm -rf "$APP_A" "$APP_B" "$APP_L"
  rm -f ~/Library/Preferences/"$BID_A".plist ~/Library/Preferences/"$BID_B".plist ~/Library/Preferences/"$BID_L".plist
  echo "  ↩︎ removed the harness copies (your /Applications/RemoteCrab.app was never touched)"
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
check_first_reply_pending() { # the forgotten computer must be answered pending, not accepted
  local first
  first=$(grep -aF -- "sessionReply:" "$1" 2>/dev/null | head -1)
  if printf '%s' "$first" | grep -aqF -- "pending"; then
    printf '  \033[32m✓\033[0m %s\n' "$2"; pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s  (first reply was: %s)\n' "$2" "${first:-<none>}"; fail=$((fail+1))
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
  local i
  for i in 1 2 3; do
    rm -f "$1"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_IOS" --source Documents/forensic.log \
      --destination "$1" >/dev/null 2>&1 || true
    [ -s "$1" ] && return 0
    sleep 2
  done
  echo "  ⚠ could not pull the iOS forensic log to $1"
  return 1
}
launch_ios() { # launch_ios <json-env>
  xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    --environment-variables "$1" "$BUNDLE_IOS"
}
wait_accepted() { # wait_accepted <mac-log> <seconds>
  for _ in $(seq 1 "$2"); do grep -aq "sessionReply: accepted" "$1" && return 0; sleep 1; done
  return 1
}
# `adopting inbound session` is emitted ONLY when the receiver actually grants
# the inbound candidate. `sessionReply: accepted` also matches the phone's own
# `inbound sessionReply: accepted` line — which the receiver logs even while it
# is still holding the connection for the first-contact prompt — so it is NOT a
# grant. A security fix made that distinction load-bearing; assert the grant.
wait_granted() { # wait_granted <mac-log> <seconds>
  for _ in $(seq 1 "$2"); do grep -aq "adopting inbound session" "$1" && return 0; sleep 1; done
  return 1
}
# make_computer <src.app> <dst.app> <bundleid> → independent copy, signed, with
# the extension manager frozen at its own path.
make_computer() {
  rm -rf "$2"
  ditto "$1" "$2" || { echo "  ✗ could not copy $1"; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $3" "$2/Contents/Info.plist" \
    || { echo "  ✗ could not set bundle id for $2"; exit 1; }
  codesign --force --deep --sign - "$2" >/dev/null 2>&1 \
    || { echo "  ✗ could not re-sign $2"; exit 1; }
  defaults write "$3" remotecrab.sysexSubmittedAppPath "$2"
  # Disable the receiver's own auto-dial. A fresh computer has not yet seen this
  # phone as phone-initiated, so on discovery it would dial the phone too — and
  # that race (design §6) would let B connect *before* the tap, so the phone's
  # dial path would never be exercised. The phone dialling us is the whole point.
  defaults write "$3" remotecrab.autoReconnect -bool false
}
run_mac() { # run_mac <id> <app> [approve|no-approve] → starts the receiver, sets MAC_PID
  # `approve` (default) sets REMOTECRAB_E2E_AUTO_APPROVE_INBOUND=1 so an
  # unpaired phone's first contact is granted without a Mac-side click.
  # `no-approve` is the negative case: the hook is absent, so the first-contact
  # prompt must hold the line and the phone must NOT be granted.
  local id="$1" app="$2" mode="${3:-approve}"
  if [ "$mode" = "no-approve" ]; then
    REMOTECRAB_E2E_MAC_ID="$id" "$app/Contents/MacOS/RemoteCrab" >/dev/null 2>&1 &
  else
    REMOTECRAB_E2E_MAC_ID="$id" REMOTECRAB_E2E_AUTO_APPROVE_INBOUND=1 \
      "$app/Contents/MacOS/RemoteCrab" >/dev/null 2>&1 &
  fi
  MAC_PID=$!
  sleep 4
}
seed_data() { # seed_data <bundleid> <key> <json> → write a JSON string as the key's Data value
  local hex
  hex=$(printf '%s' "$3" | xxd -p | tr -d '\n')
  defaults write "$1" "$2" -data "$hex"
}

echo "== RemoteCrab phone-initiated-connection v2 device e2e =="
echo "   identities: A=${ID_A}  B=${ID_B}  legacy=${ID_L}"

echo "[0/9] preconditions"
if ! xcrun devicectl list devices 2>/dev/null | grep -Eq "$DEVICE.*(available|connected)"; then
  echo "  device $DEVICE not available — connect + unlock it"; exit 2
fi
xcrun simctl shutdown all >/dev/null 2>&1 || true

echo "[1/9] build (signed)"
xcodebuild -project "$ROOT/RemoteCrabReceiver.xcodeproj" -scheme RemoteCrabReceiver -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-ec-macbuild.log 2>&1 \
  || { echo "  mac build failed (see /tmp/remotecrab-ec-macbuild.log)"; exit 1; }
xcodebuild -project "$ROOT/RemoteCrabCapture.xcodeproj" -scheme RemoteCrabCapture -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DD_ROOT" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates >/tmp/remotecrab-ec-iosbuild.log 2>&1 \
  || { echo "  ios build failed (see /tmp/remotecrab-ec-iosbuild.log)"; exit 1; }

echo "[2/9] deploy"
kill_mac
make_computer "$DD_MAC" "$APP_A" "$BID_A"
make_computer "$DD_MAC" "$APP_B" "$BID_B"
if [ ! -d /Applications/RemoteCrab.app ]; then
  echo "  ✗ /Applications/RemoteCrab.app not found (needed as the genuine legacy receiver)"; exit 1
fi
make_computer /Applications/RemoteCrab.app "$APP_L" "$BID_L"
echo "  (3 isolated receiver copies in /tmp; the user's install is untouched)"
xcrun devicectl device install app --device "$DEVICE" "$DD_IOS" >/dev/null 2>&1 \
  || { echo "  iOS install failed"; exit 1; }

# ---------------------------------------------------------------------------
echo "[3/9] Phase A0 — unpaired first contact WITHOUT the auto-approve hook"
# The security fix (58e3851) holds an unpaired inbound phone at a Mac-side
# first-contact prompt until a human confirms. With the hook OFF the phone must
# NOT be granted — the negative the grant assertions below depend on. Without
# this, a run could "pass" A/B on the phone's own `accepted` while the Mac never
# actually admitted the phone.
LOG_A0=/tmp/remotecrab-ec-a0.log
start_log "$LOG_A0"
run_mac "$ID_A" "$APP_A" no-approve
# The phone's presence browser occasionally delivers the computer without its
# TXT id on the first snapshot (lesson 155's intermittent cousin), so the pick
# hook loops out seeing "no eligible online computer" and never dials. Relaunch
# gives a fresh browse; the Mac stays up throughout. Up to 3 tries. (If the flag
# leaked on, the Mac would grant on the first dial and the absent-grant
# assertion below would still catch it — the retry does not weaken the negative.)
A0_ENV='{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_RESET_PAIRING":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}'
for attempt in 1 2 3; do
  LAUNCH_OUT=$(launch_ios "$A0_ENV" 2>&1)
  if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
    echo "  ✗ could not launch the app: $LAUNCH_OUT"; exit 2
  fi
  # The pick loop runs up to 20 s; 30 s also covers the handshake + prompt.
  for _ in $(seq 1 30); do grep -aq "first contact from" "$LOG_A0" && break; sleep 1; done
  grep -aq "first contact from" "$LOG_A0" && break
  echo "  … A0 attempt $attempt: the Mac did not see a dial (phone presence flapped) — retrying"
done
stop_log
pull_ios /tmp/remotecrab-ec-ios-a0.log
kill_mac

# ---------------------------------------------------------------------------
echo "[4/9] Phase A — phone pairs with computer A (fresh, first contact)"
LOG_A=/tmp/remotecrab-ec-a.log
start_log "$LOG_A"
run_mac "$ID_A" "$APP_A"
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_RESET_PAIRING":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not launch the app on the iPhone:"; echo "$LAUNCH_OUT" | sed 's/^/      /' | head -10
  echo "  → UNLOCK THE IPHONE and keep the screen on, then re-run."; exit 2
fi
wait_granted "$LOG_A" 40 || echo "  ⚠ not granted within 40s in Phase A"
stop_log
pull_ios /tmp/remotecrab-ec-ios-a.log
kill_mac
# Teach stand-in B that this phone dials itself (copy A's phone-initiated marker
# and its name→id link). Without it a freshly-created B neither knows the phone
# nor has a token, so it auto-dials on discovery AND reconnects after a drop —
# racing the phone's own dial. B is a stand-in for a computer the phone has
# already paired, so this state is faithful.
PHONE_ID=$(grep -a "inbound phoneHello from" "$LOG_A" | head -1 | sed -E 's/.*\(([^)]+)\)[^)]*$/\1/')
PHONE_NAME=$(grep -a "inbound phoneHello from" "$LOG_A" | head -1 | sed -E 's/.*inbound phoneHello from (.*) \(.*\)$/\1/')
if [ -n "$PHONE_ID" ] && [ -n "$PHONE_NAME" ]; then
  echo "   seeding B with phone-initiated identity ${PHONE_ID:0:8}… ($PHONE_NAME)"
  seed_data "$BID_B" remotecrab.mac.phoneInitiated "[\"$PHONE_ID\"]"
  seed_data "$BID_B" remotecrab.mac.phoneIdByName "{\"RemoteCrab — $PHONE_NAME\":\"$PHONE_ID\"}"
else
  echo "  ⚠ could not read the phone identity from Phase A — B may auto-dial"
fi

# ---------------------------------------------------------------------------
echo "[5/9] Phase B — switch to computer B (paired second; must not be busy-locked)"
LOG_B=/tmp/remotecrab-ec-b.log
start_log "$LOG_B"
run_mac "$ID_B" "$APP_B"
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not relaunch the app: $LAUNCH_OUT"; exit 2
fi
wait_granted "$LOG_B" 40 || echo "  ⚠ not granted within 40s in Phase B"
stop_log
pull_ios /tmp/remotecrab-ec-ios-b.log
kill_mac

# ---------------------------------------------------------------------------
echo "[6/9] Phase C — switch BACK to already-paired A (no approval; must be accepted)"
# A keeps its own token store (independent bundle id), so peer-auth proves it.
LOG_C=/tmp/remotecrab-ec-c.log
start_log "$LOG_C"
run_mac "$ID_A" "$APP_A"
# NOTE: deliberately NO REMOTECRAB_E2E_AUTOPAIR — reaching `accepted` without it
# is the "no re-confirmation" proof.
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not relaunch the app: $LAUNCH_OUT"; exit 2
fi
wait_granted "$LOG_C" 40 || echo "  ⚠ not granted within 40s in Phase C"
stop_log
pull_ios /tmp/remotecrab-ec-ios-c.log

# ---------------------------------------------------------------------------
echo "[7/9] Phase D — forget the current computer (row gone + no auto-dial + pending)"
# A (dev copy) is still running from Phase C, so the picker sees A online yet
# suppressed — that is the row-gone proof. Relaunch the phone with the forget
# hook; the hook runs BEFORE auto-dial, so nothing may dial A.
LOG_D=/tmp/remotecrab-ec-d.log
start_log "$LOG_D"
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_FORGET_CURRENT":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not relaunch the app: $LAUNCH_OUT"; exit 2
fi
# The pick hook needs 20 s to conclude "no eligible online computer" (A is
# suppressed) — that is the row-gone proof.
sleep 24
# Now have the OLD receiver dial the forgotten phone (design §7.3 invariant 3:
# a forgotten computer that dials in must go `pending`). The dev copy is swapped
# for the legacy copy advertising A, so exactly ONE spontaneous dial happens —
# a scripted knock to the dev copy raced with its own discovery re-dial and the
# phone's single handshake slot dropped the clientHello.
kill_mac
defaults write "$BID_L" remotecrab.autoReconnect -bool true
run_mac "$ID_A" "$APP_L"
sleep 12
stop_log
pull_ios /tmp/remotecrab-ec-ios-d.log
kill_mac

# ---------------------------------------------------------------------------
echo "[8/9] Phase E — legacy receiver (release build, no IBPhoneHello support)"
# Disable the legacy copy's own auto-dial this time, so the phone's dial to it is
# the only connection: that is what exercises the §4.4 fallback (the receiver
# treats the dial as a knock and dials back).
defaults write "$BID_L" remotecrab.autoReconnect -bool false
LOG_E=/tmp/remotecrab-ec-e.log
start_log "$LOG_E"
run_mac "$ID_L" "$APP_L"
LAUNCH_OUT=$(launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_PICK_ONLINE":"1"}' 2>&1)
if echo "$LAUNCH_OUT" | grep -qi "error\|denied\|Locked"; then
  echo "  ✗ could not relaunch the app: $LAUNCH_OUT"; exit 2
fi
wait_accepted "$LOG_E" 40 || echo "  ⚠ no accepted within 40s in Phase E"
stop_log
pull_ios /tmp/remotecrab-ec-ios-e.log
kill_mac

# ---------------------------------------------------------------------------
echo "[9/9] assertions"
DELTA_A=$(delta "$LOG_A" "inbound phoneHello from" "adopting inbound session")
DELTA_B=$(delta "$LOG_B" "inbound phoneHello from" "adopting inbound session")
DELTA_C=$(delta "$LOG_C" "inbound phoneHello from" "adopting inbound session")

echo "  -- Phase A0 (unpaired inbound, NO auto-approve) --"
check "$LOG_A0" "first contact from" "Mac raised the first-contact prompt for an unpaired phone"
check "$LOG_A0" "inbound phoneHello from" "the A0 dial really reached the receiver (negative is not vacuous)"
check_absent "$LOG_A0" "adopting inbound session" "unpaired inbound phone was NOT granted before approval"
check_absent "$LOG_A0" "[e2e] auto-approving" "auto-approve hook stayed inert without the flag"

echo "  -- Phase A (pair A) --"
check "$LOG_A" "adopting inbound session" "A granted the phone's dial (grant marker, not the phone's reply)"
check "$LOG_A" "inbound phoneHello from" "A saw the phone-initiated hello (dial path, not knock)"
check /tmp/remotecrab-ec-ios-a.log "[e2e] pick online dial" "phone ran the picker row's dial action"
check /tmp/remotecrab-ec-ios-a.log "[dial] outbound to" "phone opened an outbound dial"
check /tmp/remotecrab-ec-ios-a.log "[hs] hello id=${ID_A}" "phone accepted a session with A"
check_absent /tmp/remotecrab-ec-ios-a.log "[hs] sendSessionReply busy" "phone did not answer busy"
lt2 "$DELTA_A" "Phase A dial→granted"

echo "  -- Phase B (switch to B) --"
check "$LOG_B" "adopting inbound session" "B granted (no busy lock from current=A)"
check "$LOG_B" "inbound phoneHello from" "B saw the phone-initiated hello"
check /tmp/remotecrab-ec-ios-b.log "[hs] hello id=${ID_B}" "phone accepted a session with B"
check_absent /tmp/remotecrab-ec-ios-b.log "[hs] sendSessionReply busy" "phone did not answer busy"
lt2 "$DELTA_B" "Phase B dial→granted"

echo "  -- Phase C (switch back to paired A, no AUTOPAIR) --"
check "$LOG_C" "adopting inbound session" "paired A granted without re-confirmation"
check /tmp/remotecrab-ec-ios-c.log "[auth] receiver proved the token" "peer-auth proved the stored token (no approval card)"
check_absent /tmp/remotecrab-ec-ios-c.log "[hs] sendSessionReply busy" "phone did not answer busy"
lt2 "$DELTA_C" "Phase C dial→granted"

echo "  -- Phase D (forget current) --"
check /tmp/remotecrab-ec-ios-d.log "[e2e] forgot current computer ${ID_A:0:8}" "phone forgot the current computer on launch"
check /tmp/remotecrab-ec-ios-d.log "[e2e] pick online: no eligible online computer found" "forgotten computer is gone from the picker roster (suppressed)"
check_absent /tmp/remotecrab-ec-ios-d.log "[dial] auto-dial last computer" "phone did not auto-dial the forgotten computer"
check "$LOG_D" "sessionReply: pending" "the forgotten computer dialing in is answered pending (re-approval)"
check_first_reply_pending "$LOG_D" "the forgotten computer is NOT auto-accepted (first reply is pending)"

echo "  -- Phase E (legacy receiver fallback) --"
check /tmp/remotecrab-ec-ios-e.log "[dial] outbound to ${ID_L:0:8}" "phone dialed the legacy receiver"
check /tmp/remotecrab-ec-ios-e.log "userInitiated=false" "phone's accepted session arrived inbound (fallback, not the dial)"
check "$LOG_E" "sessionReply: accepted" "legacy receiver's dial-back was accepted (inbound fallback connected)"

echo ""
echo "pass=$pass fail=$fail"
echo "  timing: A=${DELTA_A}s  B=${DELTA_B}s  C=${DELTA_C}s"

# Leave the phone without this run's e2e identities in its pairing list.
launch_ios '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_E2E_RESET_PAIRING":"1"}' >/dev/null 2>&1 || true
sleep 3

[ "$fail" -eq 0 ]
