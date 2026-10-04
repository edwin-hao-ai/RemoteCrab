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

# Restart the RECEIVER, not just check it. This script force-terminates the
# phone to install a fresh build, which leaves the Mac holding a connection
# object for a process that no longer exists: it then never re-dials, so the
# phone ends up accepting a DIFFERENT computer and every assertion fails for a
# state real usage never produces. Both ends have to start clean.
if pgrep -f "RemoteCrab.app/Contents/MacOS/RemoteCrab$" >/dev/null; then
  pkill -f "RemoteCrab.app/Contents/MacOS/RemoteCrab$" 2>/dev/null
  sleep 3
fi
open -a /Applications/RemoteCrab.app
for _ in $(seq 1 12); do
  pgrep -f "RemoteCrab.app/Contents/MacOS/RemoteCrab$" >/dev/null && break
  sleep 1
done
if pgrep -f "RemoteCrab.app/Contents/MacOS/RemoteCrab$" >/dev/null; then
  ok "RemoteCrab receiver restarted (fresh connection state)"
else
  bad "RemoteCrab receiver would not start"
  exit 4
fi

# The MAC side has to contain this feature too. Installing a fresh iOS app
# against a months-old receiver produced a completely convincing false
# failure: the phone entered speaker mode, the player started, and the Mac
# simply had no code to react — its own log line did not even mention
# "speaker". Same class of error as testing a stale phone build, one level up.
RECV_APP=/Applications/RemoteCrab.app
if [[ -d "$RECV_APP" ]]; then
  RECV_MARKERS=$(strings "$RECV_APP/Contents/MacOS/RemoteCrab" 2>/dev/null | grep -c "speaker capture started" || true)
  if [[ "${RECV_MARKERS:-0}" -lt 1 ]]; then
    bad "the INSTALLED receiver has no speaker code (build from $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$RECV_APP/Contents/Info.plist" 2>/dev/null || echo '?'))"
    echo "         Install a current receiver first — ./scripts/release-mac.sh <version>"
    echo "         A scratch build in /tmp will NOT do: the Screen Recording grant is"
    echo "         keyed to the signing identity, so it reports 'not granted'."
    exit 4
  fi
  ok "the installed receiver contains the speaker code"
fi

# --- build and install. The first version of this script launched whatever
# --- happened to be installed, and ran a build from before the speaker hook
# --- existed: the feature reported four failures while the code under test
# --- was not on the phone at all. A stale artifact is indistinguishable from
# --- a broken feature, so the harness builds what it tests.
say "building for the phone"
# There are SEVERAL DerivedData directories for this project, so "the first
# match" is a coin flip and routinely picks a build from before the feature
# existed. A timestamp taken before the build is the only reliable selector.
touch /tmp/e2e-speaker-build-start
( cd "$ROOT" && xcodebuild -project RemoteCrabCapture.xcodeproj -scheme RemoteCrabCapture \
    -destination "id=$PHONE_UDID" -configuration Debug build \
    CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-5XNDF727Y6}" ) \
  > /tmp/e2e-speaker-build.log 2>&1
if ! grep -q "\*\* BUILD SUCCEEDED" /tmp/e2e-speaker-build.log; then
  bad "build failed — see /tmp/e2e-speaker-build.log"
  exit 4
fi
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "RemoteCrabCapture.app" \
        -path "*Debug-iphoneos*" -newer /tmp/e2e-speaker-build-start 2>/dev/null | head -1)
if [[ -z "$APP" ]]; then
  # xcodebuild considered it up to date and wrote nothing; fall back to the
  # newest product, then let the marker check below decide.
  APP=$(find ~/Library/Developer/Xcode/DerivedData -name "RemoteCrabCapture.app" \
          -path "*Debug-iphoneos*" 2>/dev/null | xargs -I{} stat -f "%m {}" {} 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)
fi
if [[ -z "$APP" ]]; then bad "no RemoteCrabCapture.app produced"; exit 4; fi
# The Debug build's real code lives in the .debug.dylib, so the main binary
# is ~92 KB and a marker string will not be found in it.
# NOT `strings | grep -q`: under `pipefail`, grep -q exits early, `strings`
# takes SIGPIPE, and the pipeline reports failure even though grep matched —
# which reads as "the code is missing" for a build that has it. Count instead.
MARKERS=$(strings "$APP/RemoteCrabCapture.debug.dylib" 2>/dev/null | grep -c "speaker audio enqueued" || true)
if [[ "${MARKERS:-0}" -lt 1 ]]; then
  bad "the built app does not contain the speaker code — wrong DerivedData picked up"
  exit 4
fi
ok "built an app that actually contains the speaker code"
xcrun devicectl device install app --device "$PHONE_UDID" "$APP" >/dev/null 2>&1 \
  && ok "installed" || { bad "install failed"; exit 4; }

# A previous `--console` launch leaves the app alive holding its listener on
# port 8765, and the next launch then dies with "Address already in use".
xcrun devicectl device process terminate --device "$PHONE_UDID" com.ibridge.iBridgeCapture >/dev/null 2>&1
sleep 2

# The Mac log capture MUST be running before the phone launches. The phone
# connects and sends its feature state within a second or two of launch, so
# starting the stream afterwards misses the only window that matters — which
# is exactly what happened: an empty Mac log and four confident failures.
say "watching the Mac receiver log"
# The WHOLE subsystem, not one category: "speaker capture started" is logged
# by ReceiverSession, so a category-scoped predicate silently watches a log
# that can never contain the line the assertion looks for — an assertion that
# cannot fail is worse than no assertion.
( /usr/bin/log stream --predicate 'subsystem == "com.remotecrab"' \
    --info --debug --style compact > /tmp/e2e-speaker-mac.log 2>&1 ) &
LOG_PID=$!
sleep 3   # let the stream attach before anything can be logged

# A known 1 kHz tone, so "audio arrived" can be told apart from "digital
# silence arrived". Without something playing, the Mac's system output is
# silent and every packet-count assertion passes while the user hears nothing.
if [[ ! -f /tmp/e2e-speaker-tone.wav ]]; then
  python3 - <<'PYGEN'
import math, struct, wave
w = wave.open('/tmp/e2e-speaker-tone.wav','wb')
w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
frames = b''.join(struct.pack('<hh', int(11000*math.sin(2*math.pi*1000*i/48000)),
                             int(11000*math.sin(2*math.pi*1000*i/48000)))
                    for i in range(48000*20))
w.writeframes(frames); w.close()
PYGEN
fi

say "launching the phone with REMOTECRAB_E2E_SPEAKER=1"
timeout 60 xcrun devicectl device process launch --device "$PHONE_UDID" \
  --terminate-existing \
  --environment-variables '{"REMOTECRAB_E2E_SPEAKER":"1","REMOTECRAB_AUTO_START":"1"}' \
  "$BUNDLE" >/tmp/e2e-speaker-console.log 2>&1 &
LAUNCH_PID=$!

sleep 4
say "playing a 1 kHz tone on the Mac (so the audio is not digital silence)"
( afplay /tmp/e2e-speaker-tone.wav >/dev/null 2>&1 ) &
TONE_PID=$!
sleep 11
kill "$TONE_PID" 2>/dev/null; wait "$TONE_PID" 2>/dev/null
kill "$LOG_PID" 2>/dev/null; wait "$LOG_PID" 2>/dev/null

say "pulling the phone forensic log"
rm -f /tmp/e2e-speaker-phone.log
xcrun devicectl device copy from --device "$PHONE_UDID" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" --source Documents/forensic.log \
  --destination /tmp/e2e-speaker-phone.log >/dev/null 2>&1

# --- assertions
say "assertions"

# The phone only streams to one computer at a time. If another Mac (or the
# Windows receiver) already owns it, this Mac never gets a session and every
# assertion below fails for a reason that has nothing to do with this feature.
# Reported separately, because "the phone is busy" and "the speaker path is
# broken" look identical otherwise.
if grep -q "sessionReply: busy" /tmp/e2e-speaker-mac.log 2>/dev/null; then
  OWNER=$(grep -o "sessionReply: busy owner=.*" /tmp/e2e-speaker-mac.log | tail -1)
  echo "  [SKIP] the phone is held by another computer: \"$OWNER\""
  echo "         That is correct behaviour, not a failure of this feature."
  echo "         Disconnect the other computer (or pick this Mac on the phone),"
  echo "         then re-run. Nothing below can be trusted until then."
  exit 3
fi
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
  # 4c. The one that separates "bytes moved" from "sound moved": the phone
  #     measures the energy of the PCM it received, and a tone playing on the
  #     Mac must show up there. A silent system passes every count above.
  RMS=$(echo "$LINE" | sed -E 's/.*pcmRms=([0-9]+).*/\1/')
  if [[ -n "${RMS:-}" && "${RMS:-0}" -gt 500 ]]; then
    ok "4c. the received audio is NOT silence (pcmRms=$RMS) — sound, not just bytes"
  else
    bad "4c. the received audio is digital silence (pcmRms=${RMS:-?}) — packets moved but no sound did"
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
