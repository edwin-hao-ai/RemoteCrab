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

# TextEdit is the typing target + the drag stage. Force a deterministic
# state: one fresh document in front. Close existing documents through
# AppleScript, NOT a ⌘⌥W keystroke — that keystroke races the following
# `make new document` and can close the document it just created, which
# leaves the run with no typing/drag target (the 2026-09-19 failure:
# window moved (0,0), doc ''). Verify the document exists, fail fast.
osascript -e 'tell application "TextEdit" to activate' >/dev/null 2>&1
osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1 || true
sleep 0.5
osascript -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1 || true
sleep 0.5
if [[ "$(osascript -e 'tell application "TextEdit" to count documents' 2>/dev/null || echo 0)" -lt 1 ]]; then
  echo "  TextEdit setup failed: no document open"
  exit 1
fi
SAVED_CLIP=$(pbpaste 2>/dev/null || true)

# Cursor warp helper (CGWarpMouseCursorPosition needs no permission).
WARP_SRC="$DD_SIM/warp.swift"
WARP="$DD_SIM/warp"
cat > "$WARP_SRC" <<'EOF'
import CoreGraphics
import Foundation
let a = CommandLine.arguments
if a.count >= 2, a[1] == "screen" {
    print(Int(CGDisplayBounds(CGMainDisplayID()).height))
} else if a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) {
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    CGAssociateMouseAndMouseCursorPosition(1)
}
EOF
swiftc -O -o "$WARP" "$WARP_SRC" 2>/dev/null || { echo "  swiftc failed for warp helper"; exit 1; }

/Applications/RemoteCrab.app/Contents/MacOS/RemoteCrab >/dev/null 2>&1 &
disown 2>/dev/null || true
sleep 3
SIMCTL_CHILD_REMOTECRAB_AUTO_START=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_AUTOPAIR=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_MIC=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_INPUT=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_DRAG=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_SEND_FILE=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_CLIPBOARD=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_SWITCH="com.apple.TextEdit" \
  xcrun simctl launch "$SIM" "$BUNDLE_IOS" >/dev/null
echo "  scripted run started; orchestrating drag phases via clipboard markers…"

# The simulator window steals focus when the app launches. As soon as
# the handshake completes (grant time — E2E_INPUT types at grant+3s),
# pull TextEdit back to the front so the keystrokes land in it.
(
  deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if grep -aq "sessionReply: accepted" "$LOG" 2>/dev/null; then
      osascript -e 'tell application "TextEdit" to activate' >/dev/null 2>&1
      exit 0
    fi
    sleep 0.3
  done
) &

# The iPhone stages its cursor at the ABSOLUTE point (0.3H, 0.3H)
# (the injector clamps to screen bounds, so the scripted bursts are
# deterministic), then sets a clipboard marker. Between the marker and
# the drag this script moves the target window UNDER the cursor —
# the iPhone only sends relative moves, so the stage comes to it.
poll_clip() { # poll_clip <marker> <timeout-s> — waits for pbpaste == marker
  local deadline=$((SECONDS + $2))
  while (( SECONDS < deadline )); do
    [[ "$(pbpaste 2>/dev/null)" == "$1" ]] && return 0
    sleep 0.3
  done
  return 1
}
te_pos() { osascript -e 'tell application "System Events" to tell process "TextEdit" to get position of window 1' 2>/dev/null | tr -d ' '; }
te_size() { osascript -e 'tell application "System Events" to tell process "TextEdit" to get size of window 1' 2>/dev/null | tr -d ' '; }
te_setpos() { osascript -e "tell application \"System Events\" to tell process \"TextEdit\" to set position of window 1 to {$1, $2}" >/dev/null 2>&1; }
te_ta_pos() { osascript -e 'tell application "System Events" to tell process "TextEdit" to get position of text area 1 of scroll area 1 of window 1' 2>/dev/null | tr -d ' '; }

expect() { # expect <0|1> <label> <detail>
  if [[ "$1" == "0" ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$2"; pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s  (%s)\n' "$2" "$3"; fail=$((fail+1))
  fi
}

SCREEN_H=$("$WARP" screen)
# The staged cursor point and the expected drag1 displacement.
TX=$(( SCREEN_H * 3 / 10 )); TY=$TX
EXP_DX1=$(( SCREEN_H * 12 / 100 )); EXP_DY1=$(( SCREEN_H * 72 / 1000 ))

DRAG1_OK=1; DRAG2_OK=1; DRAG1_DETAIL=""; DRAG2_DETAIL=""

if poll_clip "e2e-drag1" 60; then
  SZ=$(te_size); W=${SZ%,*}
  # Title bar center under the cursor (keep the window onscreen).
  WX=$(( TX - W / 2 )); (( WX < 0 )) && WX=0
  WY=$(( TY - 13 ));   (( WY < 40 )) && WY=40
  te_setpos "$WX" "$WY"; sleep 0.5
  P0=$(te_pos); X0=${P0%,*}; Y0=${P0#*,}
  if poll_clip "e2e-drag1-done" 20; then
    P1=$(te_pos); X1=${P1%,*}; Y1=${P1#*,}
    MX=$(( X1 - X0 )); MY=$(( Y1 - Y0 ))
    # The window follows the cursor 1:1; allow ±45 px of slop.
    if (( MX > EXP_DX1 - 45 && MX < EXP_DX1 + 45 && MY > EXP_DY1 - 45 && MY < EXP_DY1 + 45 )); then
      DRAG1_OK=0
    fi
    DRAG1_DETAIL="moved ($MX,$MY), expected ≈($EXP_DX1,$EXP_DY1)"
  else
    DRAG1_DETAIL="no e2e-drag1-done marker"
  fi
else
  DRAG1_DETAIL="no e2e-drag1 marker"
fi

if poll_clip "e2e-drag2" 30; then
  # First text line under the cursor, measured live: the window's
  # header (title + toolbar + ruler ≈ 100 pt on this machine) varies,
  # so read the AX text-area origin and offset from it. The typed
  # text sits just left of the cursor; the iPhone drags left across
  # it, then ⌘C locally.
  WIN=$(te_pos); TA=$(te_ta_pos)
  WINX=${WIN%,*}; WINY=${WIN#*,}; TAX=${TA%,*}; TAY=${TA#*,}
  TDX=$(( TAX - WINX )); TDY=$(( TAY - WINY ))
  WX=$(( TX - 240 - TDX )); (( WX < 0 )) && WX=0
  WY=$(( TY - 12 - TDY ));  (( WY < 40 )) && WY=40
  te_setpos "$WX" "$WY"; sleep 0.5
  DOC=$(osascript -e 'tell application "TextEdit" to get text of document 1' 2>/dev/null || true)
  if poll_clip "e2e-drag2-done" 20; then
    sleep 0.5
    osascript -e 'tell application "TextEdit" to activate' \
              -e 'tell application "System Events" to keystroke "c" using command down' >/dev/null 2>&1
    sleep 0.5
    SEL=$(pbpaste 2>/dev/null || true)
    if [[ -n "$SEL" && "RemoteCrab-e2e-OK" == *"$SEL"* ]]; then
      DRAG2_OK=0
    fi
    DRAG2_DETAIL="clipboard after drag-select+⌘C: '$SEL' (doc: '$DOC')"
  else
    DRAG2_DETAIL="no e2e-drag2-done marker (doc: '$DOC')"
  fi
else
  DRAG2_DETAIL="no e2e-drag2 marker"
fi

# Let the remaining scripted e2e steps (file, switch) settle.
sleep 5
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
expect "$DRAG1_OK" "window drag: TextEdit window moved by injected drag" "$DRAG1_DETAIL"
expect "$DRAG2_OK" "text selection: drag-select → ⌘C lands on the clipboard" "$DRAG2_DETAIL"
echo "  -- skipped vs device e2e: video frames, recording (no camera in simulator)"

# --- [6/6] cleanup ----------------------------------------------------------
echo "[6/6] cleanup"
[[ -n "${SAVED_CLIP:-}" ]] && printf '%s' "$SAVED_CLIP" | pbcopy
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
