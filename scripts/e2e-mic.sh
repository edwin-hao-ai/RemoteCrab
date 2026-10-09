#!/usr/bin/env bash
# RemoteCrab microphone end-to-end.
#
# Proves the phone's microphone audio actually reaches the Mac with a REAL,
# non-silent signal — not merely that packets arrive. It:
#   1. relaunches the receiver and streams its unified log,
#   2. launches the iPhone with the mic forced on,
#   3. plays a tone on the MAC (the phone is next to it) so the phone's mic has
#      something to hear,
#   4. asserts the receiver logged `mic level: rms=<n>` with <n> above a floor.
#
# A run with a silent or dead mic path reports rms well under the floor.
#
# Usage: ./scripts/e2e-mic.sh
# Env: REMOTECRAB_PHONE_UDID, REMOTECRAB_APP, REMOTECRAB_MIC_RMS_FLOOR (default 150)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${REMOTECRAB_APP:-/Applications/RemoteCrab.app}"
FLOOR="${REMOTECRAB_MIC_RMS_FLOOR:-150}"
LOG=/tmp/remotecrab-mic-mac.log
TONE=/tmp/remotecrab-mic-tone.wav

DEVICE="${REMOTECRAB_PHONE_UDID:-$(xcrun devicectl list devices 2>/dev/null \
  | grep -E 'iPhone.*available' | head -1 \
  | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')}"

fail() { echo "  ✗ $1"; exit 1; }
ok()   { echo "  ✓ $1"; }

echo "== RemoteCrab microphone e2e =="
[ -n "${DEVICE:-}" ] || fail "no available iPhone (unlock it and reconnect)"
[ -d "$APP" ]        || fail "no receiver at $APP"
echo "  device: $DEVICE"
echo "  app:    $APP  (rms floor $FLOOR)"

# A short, loud 440 Hz tone the phone's mic can hear.
if [ ! -f "$TONE" ]; then
  /usr/bin/python3 - "$TONE" <<'PY'
import sys, wave, struct, math
path = sys.argv[1]
rate = 44100
secs = 3
amp = 20000
w = wave.open(path, "w")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
frames = bytearray()
for i in range(rate * secs):
    v = int(amp * math.sin(2 * math.pi * 440 * i / rate))
    frames += struct.pack("<h", v)
w.writeframes(bytes(frames)); w.close()
PY
fi
[ -f "$TONE" ] || fail "could not generate the tone"

# Fresh receiver + a clean log window.
pkill -x RemoteCrab 2>/dev/null; sleep 1
: > "$LOG"
/usr/bin/log stream --predicate 'subsystem == "com.remotecrab"' --info --style compact > "$LOG" 2>&1 &
LOGPID=$!
sleep 1
open "$APP"
sleep 4

echo "→ launching the iPhone with the mic forced on..."
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
  --environment-variables '{"REMOTECRAB_AUTO_START":"1","REMOTECRAB_AUTOSTREAM":"1","REMOTECRAB_E2E_AUTOPAIR":"1","REMOTECRAB_E2E_RESET_PAIRING":"1","REMOTECRAB_E2E_PICK_ONLINE":"1","REMOTECRAB_E2E_MIC":"1"}' \
  com.ibridge.iBridgeCapture >/dev/null 2>&1 || true

echo "→ waiting for the session to be granted..."
for _ in $(seq 1 40); do grep -aq "adopting inbound session" "$LOG" && break; sleep 1; done
grep -aq "adopting inbound session" "$LOG" || { kill "$LOGPID" 2>/dev/null; fail "the phone never connected"; }
ok "phone connected to the Mac"

echo "→ playing a 440 Hz tone on the Mac (feeding the phone's mic)..."
for _ in 1 2 3; do afplay "$TONE" & AP=$!; wait "$AP"; done

echo "→ waiting for microphone level markers..."
for _ in $(seq 1 30); do grep -aq "mic level: rms=" "$LOG" && break; sleep 1; done
kill "$LOGPID" 2>/dev/null

PACKETS=$(grep -aoE "audio packets received: [0-9]+" "$LOG" | tail -1 || true)
RMS=$(grep -aoE "mic level: rms=[0-9]+" "$LOG" | sed 's/.*=//' | sort -n | tail -1 || true)
PEAK=$(grep -aoE "peak=[0-9]+" "$LOG" | sed 's/.*=//' | sort -n | tail -1 || true)
echo "  ${PACKETS:-no audio-packet marker}"
echo "  mic max rms=${RMS:-none} peak=${PEAK:-none}"

echo "-- assertions --"
[ -n "$PACKETS" ] && ok "audio packets arrived (transport+codec)" || fail "no audio packets reached the Mac"
if [ -n "$RMS" ] && [ "$RMS" -ge "$FLOOR" ]; then
  ok "microphone carried a REAL signal (rms $RMS ≥ $FLOOR)"
else
  fail "microphone level ${RMS:-0} below $FLOOR — silent/absent audio"
fi
echo "== microphone e2e passed =="
