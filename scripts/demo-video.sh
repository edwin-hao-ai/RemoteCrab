#!/usr/bin/env bash
#
# Record a RemoteCrab demo clip for App Review.
#
# Produces a side-by-side MP4: the iOS app (Simulator) on the left and the
# Mac receiver's connection self-check window on the right, driven by the
# app's own REMOTECRAB_E2E_* automation. Hosted at
# https://vgoapp.com/downloads/RemoteCrab-demo.mp4 and linked from the App
# Review notes.
#
# Why the Simulator: macOS has no CLI to record a physical iPhone's screen
# (the QuickTime device-recording route hangs on a TCC prompt), and App
# Review only needs to see the app working. The Simulator shares the host
# network stack, so the app's TCP listener is reachable at 127.0.0.1:8765 —
# scripts/e2e-simulator.sh's direct-IP trick (remotecrab.lastPhoneIP).
#
# Caveat: the Simulator has no camera, so both the camera tile on the Mac
# and any camera surface show no picture. Only a physical iPhone can.
#
# Usage:  ./scripts/demo-video.sh [out.mp4]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/docs/demo/remotecrab-demo.mp4}"
TEAM="${REMOTECRAB_TEAM:-5XNDF727Y6}"
BUNDLE_IOS="com.ibridge.iBridgeCapture"
RECEIVER_DOMAIN="com.remotecrab.RemoteCrabReceiver"
TITLE="RemoteCrab  -  your iPhone as a Mac camera, mic, trackpad and keyboard"
FONT="/System/Library/Fonts/Supplemental/Arial.ttf"
MAC_OUT=/tmp/remotecrab-demo-mac.mov

mkdir -p "$(dirname "$OUT")"

# --- 1. simulator ----------------------------------------------------------
SIM=$(xcrun simctl list devices booted 2>/dev/null | grep -E 'iPhone.*Booted' | head -1 \
      | grep -oE '[A-F0-9-]{36}' || true)
[[ -z "${SIM:-}" ]] && SIM=$(xcrun simctl list devices available 2>/dev/null | grep -E 'iPhone' \
      | head -1 | grep -oE '[A-F0-9-]{36}')
[[ -z "${SIM:-}" ]] && { echo "no iPhone simulator"; exit 1; }
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true
echo "simulator: $SIM"

# --- 2. build --------------------------------------------------------------
xcodebuild -project "$ROOT/RemoteCrabReceiver.xcodeproj" -scheme RemoteCrabReceiver -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$ROOT/.build/demo-mac" build \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
  -allowProvisioningUpdates >/tmp/demo-macbuild.log 2>&1 || { echo "mac build failed"; exit 1; }
xcodebuild -project "$ROOT/RemoteCrabCapture.xcodeproj" -scheme RemoteCrabCapture -configuration Debug \
  -destination "id=$SIM" -derivedDataPath "$ROOT/.build/demo-sim" build CODE_SIGNING_ALLOWED=NO \
  >/tmp/demo-iosbuild.log 2>&1 || { echo "ios build failed"; exit 1; }
APP_SIM=$(find "$ROOT/.build/demo-sim" -name "RemoteCrabCapture.app" -path "*Debug-iphonesimulator*" | head -1)

# --- 3. deploy -------------------------------------------------------------
xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
xcrun simctl uninstall  "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
xcrun simctl install    "$SIM" "$APP_SIM" >/dev/null
for p in camera microphone; do xcrun simctl privacy "$SIM" grant "$p" "$BUNDLE_IOS" 2>/dev/null || true; done

OLD_IP=$(defaults read "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP 2>/dev/null || echo "")
defaults write "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP "127.0.0.1"
pkill -9 -x RemoteCrab 2>/dev/null; sleep 1
/Applications/RemoteCrab.app/Contents/MacOS/RemoteCrab >/dev/null 2>&1 &
disown 2>/dev/null || true
sleep 3

# Open the self-check window (⌘T) and lay the two windows side by side.
osascript -e 'tell application "RemoteCrab" to activate' >/dev/null 2>&1; sleep 1
osascript -e 'tell application "System Events" to keystroke "t" using command down' >/dev/null 2>&1; sleep 1
osascript -e 'tell application "System Events" to tell process "Simulator" to set position of window 1 to {0, 30}' >/dev/null 2>&1
osascript -e 'tell application "System Events" to tell process "RemoteCrab" to set position of window "连接自检" to {520, 60}' >/dev/null 2>&1
osascript -e 'tell application "System Events" to tell process "Simulator" to set position of window 1 to {0, 30}' >/dev/null 2>&1

# --- 4. record -------------------------------------------------------------
echo "recording…"
rm -f "$MAC_OUT"
screencapture -V 33 -x "$MAC_OUT" & MAC_REC=$!
sleep 2
SIMCTL_CHILD_REMOTECRAB_AUTO_START=1 SIMCTL_CHILD_REMOTECRAB_AUTOSTREAM=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_AUTOPAIR=1 SIMCTL_CHILD_REMOTECRAB_E2E_MIC=1 \
SIMCTL_CHILD_REMOTECRAB_E2E_INPUT=1 SIMCTL_CHILD_REMOTECRAB_E2E_SURFACE=trackpad \
  xcrun simctl launch "$SIM" "$BUNDLE_IOS" >/dev/null 2>&1
sleep 1
osascript -e 'tell application "RemoteCrab" to activate' >/dev/null 2>&1
sleep 28
wait $MAC_REC 2>/dev/null

# --- 5. compose (crop both windows, hstack, title) -------------------------
# Window geometry assumed from step 3: simulator (0,30) 395x850 pt;
# self-check (520,60) 560x640 pt; 2x display → px coords below.
ffmpeg -loglevel error -y -i "$MAC_OUT" -filter_complex "\
[0:v]trim=start=5:end=29,setpts=PTS-STARTPTS[c];\
[c]split=2[a][b];\
[a]crop=770:1595:14:165,scale=-2:1080[sim];\
[b]crop=1120:1280:1040:120,scale=-2:1080[mac];\
[sim][mac]hstack=inputs=2[hs];\
[hs]pad=iw:ih+100:0:100:color=0x0a0a0f[t];\
[t]drawtext=fontfile=${FONT}:text='${TITLE}':fontcolor=white:fontsize=38:x=(w-text_w)/2:y=30[v]" \
  -map "[v]" -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -r 30 "$OUT"

# --- cleanup ---------------------------------------------------------------
xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
if [[ -n "$OLD_IP" ]]; then defaults write "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP "$OLD_IP"
else defaults delete "$RECEIVER_DOMAIN" remotecrab.lastPhoneIP 2>/dev/null || true; fi
echo "wrote $OUT"
echo "upload: cat '$OUT' | ssh root@158.247.219.230 'cat > /var/www/vgoapp/downloads/RemoteCrab-demo.mp4'"
