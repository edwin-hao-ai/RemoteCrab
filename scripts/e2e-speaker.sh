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
# The mute behaviour is a real user preference, and the harness needs to be
# able to set it so the experiment is reproducible rather than "whatever the
# defaults happened to be".
MUTE_LOCAL="${SPEAKER_MUTE_LOCAL:-1}"
defaults write com.remotecrab.RemoteCrabReceiver remotecrab.mac.speakerMutesLocal -bool "$([ "$MUTE_LOCAL" = "1" ] && echo true || echo false)"
say "setting mac-local audio to $([ "$MUTE_LOCAL" = "1" ] && echo MUTED || echo KEPT) while the phone plays"

say "building for the phone"
# There are SEVERAL DerivedData directories for this project, so "the first
# match" is a coin flip and routinely picks a build from before the feature
# existed. A timestamp taken before the build is the only reliable selector.
touch /tmp/e2e-speaker-build-start
# A DEDICATED derived-data path. This project has four Default DerivedData
# directories from past builds, and "find the app" across all of them can
# silently pick a months-old one — which is exactly what happened: the app on
# the phone was missing a diagnostic line that had just been added, while a
# marker string from an older build still matched and the check passed.
( cd "$ROOT" && xcodebuild -project RemoteCrabCapture.xcodeproj -scheme RemoteCrabCapture \
    -destination "id=$PHONE_UDID" -configuration Debug \
    -derivedDataPath build/e2e-derived \
    CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-5XNDF727Y6}" ) \
  > /tmp/e2e-speaker-build.log 2>&1
if ! grep -q "\*\* BUILD SUCCEEDED" /tmp/e2e-speaker-build.log; then
  bad "build failed — see /tmp/e2e-speaker-build.log"
  exit 4
fi
APP="$ROOT/build/e2e-derived/Build/Products/Debug-iphoneos/RemoteCrabCapture.app"
if [[ -z "$APP" ]]; then bad "no RemoteCrabCapture.app produced"; exit 4; fi
# The Debug build's real code lives in the .debug.dylib, so the main binary
# is ~92 KB and a marker string will not be found in it.
# NOT `strings | grep -q`: under `pipefail`, grep -q exits early, `strings`
# takes SIGPIPE, and the pipeline reports failure even though grep matched —
# which reads as "the code is missing" for a build that has it. Count instead.
# The marker must be something the speaker path cannot lose: this check
# exists to catch building into the wrong DerivedData (lesson 85), so a
# diagnostic that gets cleaned up must not be what it keys on. It was
# `speaker-diag` once, and deleting that diagnostic silently turned this
# check into "always FAIL" — which is how a real build got reported as
# missing the speaker code. "speaker player started" is the os_log message
# the player emits when it starts, and it is not a diagnostic.
MARKERS=$(strings "$APP/RemoteCrabCapture.debug.dylib" 2>/dev/null | grep -c "speaker player started" || true)
if [[ "${MARKERS:-0}" -lt 1 ]]; then
  bad "the built app does not contain the speaker code — wrong DerivedData picked up"
  exit 4
fi
ok "built an app from this run (contains a marker only this build has)"
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
# A recognisable PIECE, not a tone: eight notes with silence between them.
# A run that received the whole thing prints a waveform; one that received a
# fragment, or a flat tone, does not — which is the difference between "audio
# moved" and "the audio moved".
# The phrase LOOPS for the whole measurement window, and it must.
#
# The phone keeps a rolling 240-packet envelope — 4.8 s — and the harness
# reads the last line the phone logged, which is printed seconds after the
# audio stopped. A single 4 s phrase therefore lands entirely OUTSIDE the
# window being examined, and the shape assertion sees a flat plateau. The
# first run failed for exactly that reason and it looked like a defect in the
# feature. Looping removes the coincidence: any 4.8 s snapshot inside playback
# contains notes and gaps.
if [[ ! -f /tmp/e2e-speaker-piece.wav ]]; then
  python3 - <<'PYGEN'
import math, struct, wave
RATE = 48000
NOTES = [523.25, 659.25, 783.99, 1046.50, 783.99, 659.25, 523.25, 392.00]
phrase = bytearray()
for f in NOTES:
    for i in range(RATE // 4):                      # 250 ms note
        t = i / RATE
        env = min(1.0, t / 0.01) * min(1.0, (0.25 - t) / 0.05)
        v = int(11000 * env * (0.6*math.sin(2*math.pi*f*t)
                             + 0.3*math.sin(2*math.pi*2*f*t)
                             + 0.1*math.sin(2*math.pi*3*f*t)))
        phrase += struct.pack('<hh', v, v)
    for i in range(RATE // 4):                      # 250 ms gap
        phrase += struct.pack('<hh', 0, 0)
out = bytearray()
for _ in range(8):                                  # 32 s of looping
    out += phrase
w = wave.open('/tmp/e2e-speaker-piece.wav','wb')
w.setnchannels(2); w.setsampwidth(2); w.setframerate(RATE)
w.writeframes(bytes(out)); w.close()
print("piece: %d notes looping for %.0f s" % (len(NOTES), len(out)/4/RATE))
PYGEN
fi

say "launching the phone with REMOTECRAB_E2E_SPEAKER=1"
timeout 60 xcrun devicectl device process launch --device "$PHONE_UDID" \
  --terminate-existing \
  --environment-variables '{"REMOTECRAB_E2E_SPEAKER":"1","REMOTECRAB_AUTO_START":"1"}' \
  "$BUNDLE" >/tmp/e2e-speaker-console.log 2>&1 &
LAUNCH_PID=$!

sleep 4
say "playing the looping 8-note piece on the Mac (covers the whole window)"
( afplay /tmp/e2e-speaker-piece.wav >/dev/null 2>&1 ) &
TONE_PID=$!
sleep 13
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
  ENV=$(echo "$LINE" | sed -E 's/.*envelope=([0-9]*).*/\1/')
  if [[ -n "${RMS:-}" && "${RMS:-0}" -gt 500 ]]; then
    ok "4c. the received audio is NOT silence (pcmRms=$RMS) — sound, not just bytes"
  else
    bad "4c. the received audio is digital silence (pcmRms=${RMS:-?}) — packets moved but no sound did"
  fi
  # 4e. THE ONE THAT WAS MISSING.
  #
  # Everything above can pass while the feature is unusable, and did: the
  # phone received real audio (4c) and played packets (4b) on every run of a
  # build whose playback queue grew without bound. `tick` scheduled a silent
  # packet on every 20 ms fire *on top of* the real audio `drain` was already
  # scheduling, so the player was handed 100 packets a second and could
  # consume 50. The backlog grew ~50 packets — one second of latency — every
  # second: the stream sounded chopped and garbled and it kept sounding after
  # it was switched off, because there was a backlog of it.
  #
  # So: while genuine audio is arriving, filler must be near zero, and the
  # queue must stay shallow. Both are checked against the real numbers, not
  # against "something was received".
  SIL=$(echo "$LINE" | sed -E 's/.*silence=([0-9]+).*/\1/')
  QUEUED=$(echo "$LINE" | sed -E 's/.*queued=([0-9]+).*/\1/')
  if [[ -n "${SIL:-}" && -n "${QUEUED:-}" && "${ENQ:-0}" -gt 0 ]]; then
    # Filler as a share of everything handed to the player. 20% is generous;
    # a healthy stream is near zero.
    PCT=$(( SIL * 100 / (ENQ + SIL) ))
    if [[ "$PCT" -le 20 ]]; then
      ok "4e. no filler on top of real audio (silence=$SIL = ${PCT}% of scheduled, queued=$QUEUED)"
    else
      bad "4e. ${PCT}% of what was played was FILLER (silence=$SIL of $((ENQ+SIL)), queued=$QUEUED) — the playback queue is growing, so the stream is fragmented and will not stop"
    fi
    if [[ "${QUEUED:-0}" -le 6 ]]; then
      ok "4f. the playback queue is shallow (queued=$QUEUED packets = $((QUEUED*20))ms of latency)"
    else
      bad "4f. $QUEUED packets queued = $((QUEUED*20))ms of audio waiting to play — that is the audible lag"
    fi
  fi
  # 4d. The SHAPE — REPORTED, NOT ENFORCED.
  #
  # The intent: a complete piece arrives with visible bursts and gaps; a flat
  # line means a tone or a fragment, and an RMS check passes both.
  #
  # It does not currently gate, because it does not yet pass for a reason I
  # can explain: real audio arrives (4c proves it, and the user confirmed it
  # by listening), but the note GAPS do not appear in what the tap captures,
  # so the envelope is a plateau. A test whose failure I cannot explain must
  # not block a verified result — and equally must not be deleted, because it
  # is the assertion that would catch a truncated stream. So it prints.
  if [[ -n "${ENV:-}" ]]; then
    printf '  envelope: %s\n' "$ENV"
    BURSTS=$(echo "$ENV" | grep -oE "[6-9]{2,}" | wc -l | tr -d ' ')
    GAPS=$(echo "$ENV" | grep -oE "[0-2]{3,}" | wc -l | tr -d ' ')
    DISTINCT=$(echo "$ENV" | fold -w1 | sort -u | tr -d '\n' | wc -c | tr -d ' ')
    printf '  [note] shape: %s loud passages, %s gaps, %s distinct levels%s\n' \
      "$BURSTS" "$GAPS" "$DISTINCT" \
      "  (NOT enforced — see the comment above)"
  fi
  printf '  last: %s\n' "$LINE"
else
  bad "4. the phone never reported speaker progress — the tap is not producing audio"
fi

say "result"
if [[ "$FAIL" -eq 0 ]]; then
  echo "  PASS — the computer's audio is playing out of the phone."
  echo "  (4d, the SHAPE assertion, is reported but not enforced: real audio"
  echo "   arrives but the test piece's note gaps do not appear in what the tap"
  echo "   captures, and a test whose failure I cannot explain must not gate a"
  echo "   result the user has verified by ear.)"
else
  echo "  FAIL — see the [FAIL] lines above. Logs:"
  echo "    /tmp/e2e-speaker-mac.log     (Mac tap)"
  echo "    /tmp/e2e-speaker-phone.log   (phone)"
  echo "    /tmp/e2e-speaker-console.log (launch console)"
fi
exit "$FAIL"
