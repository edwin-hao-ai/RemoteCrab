#!/usr/bin/env bash
#
# End-to-end verification for "use the iPhone as the speaker", on real
# hardware. Run AFTER the Mac's audio is healthy and the phone is connected:
#
#   sudo killall coreaudiod                 # if the audio stack is wedged
#   open -a /Applications/RemoteCrab.app    # the Developer ID build, so the
#                                           # Screen Recording grant applies
#   ./scripts/e2e-speaker.sh
#
# What it asserts, and why each one is not decorative:
#   1. the phone entered speaker mode            (phone forensic log)
#   2. the Mac started the tap                  (Mac receiver log)
#   3. the Mac actually CAPTURED audio frames   (not just "started")
#   4. audio ARRIVED at the phone and was played (not just "enabled")
# A run that only sees 1 and 2 has proved that a switch was thrown.
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHONE_UDID="${PHONE_UDID:-$(xcrun devicectl list devices 2>&1 \
  | grep -E 'iPhone.*available' | head -1 \
  | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')}"
BUNDLE="com.ibridge.iBridgeCapture"
FAIL=0

say()  { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  [ ok ] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=1; }

if [[ -z "$PHONE_UDID" ]]; then
  echo "No available iPhone. Unlock the phone and reconnect it, then retry."
  exit 2
fi

# --- precondition: the Mac needs a working audio stack, or the tap captures
# --- silence and every assertion below becomes meaningless.
say "preconditions"
COUNT=$(system_profiler SPAudioDataType 2>/dev/null | grep -c "Output Channels" || true)
if [[ "$COUNT" -gt 0 ]]; then
  ok "Mac reports $COUNT output device(s)"
else
  bad "Mac reports NO audio devices — run: sudo killall coreaudiod"
fi

if pgrep -x "RemoteCrab" >/dev/null || pgrep -f "RemoteCrab.app/Contents/MacOS" >/dev/null; then
  ok "RemoteCrab receiver is running"
else
  bad "RemoteCrab receiver is NOT running — open -a /Applications/RemoteCrab.app"
fi

# --- run the phone with the speaker hook
say "launching the phone with REMOTECRAB_E2E_SPEAKER=1"
timeout 60 xcrun devicectl device process launch --device "$PHONE_UDID" \
  --terminate-existing \
  --environment-variables '{"REMOTECRAB_E2E_SPEAKER":"1","REMOTECRAB_AUTO_START":"1"}' \
  "$BUNDLE" >/tmp/e2e-speaker-console.log 2>&1 &
LAUNCH_PID=$!

# The Mac must be logging while the feature turns on, otherwise "capture
# started" can never be observed.
say "watching the Mac receiver log (12 s)"
( /usr/bin/log stream --predicate 'subsystem == "com.remotecrab" AND category == "speaker-tap"' \
    --info --style compact > /tmp/e2e-speaker-mac.log 2>&1 ) &
LOG_PID=$!
sleep 12
kill "$LOG_PID" 2>/dev/null; wait "$LOG_PID" 2>/dev/null

say "pulling the phone forensic log"
rm -f /tmp/e2e-speaker-phone.log
xcrun devicectl device copy from --device "$PHONE_UDID" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" --source Documents/forensic.log \
  --destination /tmp/e2e-speaker-phone.log >/dev/null 2>&1

# --- assertions
say "assertions"
grep -q "speaker mode requested" /tmp/e2e-speaker-phone.log 2>/dev/null \
  && ok "1. the phone entered speaker mode" \
  || bad "1. the phone never entered speaker mode"

grep -q "speaker playback started" /tmp/e2e-speaker-phone.log 2>/dev/null \
  && ok "2b. the phone started the player" \
  || bad "2b. the phone did not start the player (see speakerStatus in the log)"

if grep -q "speaker capture started" /tmp/e2e-speaker-mac.log 2>/dev/null \
   || grep -q "speaker capture started" /tmp/e2e-speaker-console.log 2>/dev/null; then
  ok "2. the Mac started the system-audio tap"
else
  bad "2. the Mac never started the tap (Screen Recording grant? ScreenStreamer-style 4-part check)"
fi

# 3 + 4 come from the same line: non-zero enqueued AND played counts mean
# audio crossed the wire and came out of the speaker graph.
LINE=$(grep "speaker audio enqueued" /tmp/e2e-speaker-phone.log 2>/dev/null | tail -1)
if [[ -n "$LINE" ]]; then
  ENQ=$(echo "$LINE" | sed -E 's/.*enqueued=([0-9]+).*/\1/')
  PLAYED=$(echo "$LINE" | sed -E 's/.*played=([0-9]+).*/\1/')
  if [[ "${ENQ:-0}" -gt 0 ]]; then
    ok "4. $ENQ packets arrived at the phone"
  else
    bad "4. NO packets arrived at the phone"
  fi
  if [[ "${PLAYED:-0}" -gt 0 ]]; then
    ok "4b. $PLAYED packets were played out (not starved)"
  else
    bad "4b. packets arrived but none were played"
  fi
  printf '  last: %s\n' "$LINE"
else
  bad "4. the phone never reported speaker progress — the tap is not producing audio"
fi

say "result"
if [[ "$FAIL" -eq 0 ]]; then
  echo "  PASS — the computer's audio is playing out of the phone."
else
  echo "  FAIL — see the [FAIL] lines above. Logs:"
  echo "    /tmp/e2e-speaker-mac.log     (Mac tap)"
  echo "    /tmp/e2e-speaker-phone.log   (phone)"
  echo "    /tmp/e2e-speaker-console.log (launch console)"
fi
exit "$FAIL"
