#!/usr/bin/env bash
#
# Capture one real RemoteCrabCapture UI screenshot per website feature page.
#
# The website's feature pages each render a <slug>.png above the fold. Rather
# than mock them, this drives the real app on a booted simulator with the same
# E2E hooks the e2e suite uses, so every page shows the actual product surface.
#
# Usage:
#   scripts/capture-feature-shots.sh <sim-udid> <derived-data-path> <out-dir>
#   scripts/capture-feature-shots.sh <sim> <dd> <out> --only camera,voice
#   LANG_OVERRIDE=en-US scripts/capture-feature-shots.sh <sim> <dd> <out>
#
# The site's feature pages ship BOTH locales, so this must run once per
# locale: the product UI is localised, and an English page showing a Chinese
# screenshot (or an English promo cut showing one) reads as a different app.
# Pass an explicit suffix as the 4th arg to keep the sets apart:
#   scripts/capture-feature-shots.sh <sim> <dd> <out> -en
#
# Per-slug notes (each is the deepest state we can reach without a human tap):
#   trackpad        the surface itself, cursor dot live
#   keyboard        the surface with the system input bar
#   camera          the camera surface in Demo Mode (the sim has no camera, so
#                   the real preview path can't be driven; Demo Mode is the
#                   honest stand-in and is what App Review sees too)
#   microphone      the mic feature sheet
#   screen-mirror   the mirror surface, window streaming
#   extended-display  the extended-display surface
#   app-switcher    the switcher sheet, populated from the live app list
#   transfer        the send-file sheet
#   automation      the context (scenario-mode) sheet
#   voice           hold-to-talk mid-hold
set -euo pipefail

SIM="${1:?sim udid}"
DD="${2:?derived data path}"
OUT="${3:?output dir}"
ONLY="${5:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_IOS="com.ibridge.iBridgeCapture"
APP_SIM=$(find "$DD" -name "RemoteCrabCapture.app" -path "*Debug-iphonesimulator*" 2>/dev/null | head -1 || true)

mkdir -p "$OUT"

[[ -n "$APP_SIM" ]] || { echo "derived data not found: $DD" >&2; exit 1; }
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
xcrun simctl uninstall "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
xcrun simctl install "$SIM" "$APP_SIM" >/dev/null

# Camera TCC does not survive a sim reboot (lesson 27) and the simulator has no
# camera anyway; microphone and photos do matter for the sheets we capture.
for p in microphone photos; do
  xcrun simctl privacy "$SIM" grant "$p" "$BUNDLE_IOS" 2>/dev/null || true
done
# Seed TCC.db directly for the two services `simctl privacy` cannot be trusted
# with:
#   • kTCCServiceLocalNetwork is not a grantable service at all (it errors), and
#     without it the first frame is the system "find devices on your local
#     network?" alert;
#   • kTCCServiceCamera is dropped on every simulator reboot (lesson 27), so
#     `simctl privacy grant camera` silently does nothing and the camera
#     prompt covers the surface.
# _shot_ok.py rejects both alerts, so without this the run fails for a reason
# that has nothing to do with the surface being captured.
TCC_DB="$HOME/Library/Developer/CoreSimulator/Devices/$SIM/data/Library/TCC/TCC.db"
if [[ -f "$TCC_DB" ]]; then
  xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
  for svc in kTCCServiceLocalNetwork kTCCServiceCamera kTCCServiceMicrophone kTCCServicePhotos kTCCServiceSpeechRecognition; do
    sqlite3 "$TCC_DB" "INSERT OR REPLACE INTO access
      (service,client,client_type,auth_value,auth_reason,auth_version,policy_id,flags,last_modified)
      VALUES ('$svc','$BUNDLE_IOS',0,2,3,1,0,0,strftime('%s','now'));"
  done
  echo "  seeded TCC grants (local network, camera, mic, photos, speech)"
  # The seed is INERT until tccd re-reads the file: tccd caches every
  # decision in memory, and there is no `killall` inside the simulator to
  # bounce it. Boot-cycling the device is the only reliable reload, so do it
  # here rather than after the fact — otherwise every capture is a system
  # alert and _shot_ok.py rejects all of them.
  xcrun simctl shutdown "$SIM" 2>/dev/null || true
  sleep 4
  xcrun simctl boot "$SIM" 2>/dev/null || true
  for _ in $(seq 1 40); do
    if xcrun simctl list devices 2>/dev/null | grep -q "($SIM) (Booted)"; then break; fi
    sleep 3
  done
  sleep 6
fi
# SUFFIX is appended to every filename so the zh-Hans and en-US sets coexist.
SUFFIX="${4:-}"
case "$SUFFIX" in
  -en) APP_LANG="en-US"; APP_LOCALE="en_US" ;;
  *)   APP_LANG="zh-Hans"; APP_LOCALE="zh_CN" ;;
esac
xcrun simctl spawn "$SIM" defaults write "Apple Global Domain" AppleLanguages -array "$APP_LANG"
xcrun simctl spawn "$SIM" defaults write "Apple Global Domain" AppleLocale -string "$APP_LOCALE"

# Never let a coach-mark sheet cover the surface we are trying to photograph.
xcrun simctl spawn "$SIM" defaults write "$BUNDLE_IOS" remotecrab.ios.trackpadGuideShown -bool true

# Each entry: <slug>|<extra env assignments, space separated>|<settle seconds>
# The base env (AUTO_START + AUTOPAIR) is applied to every shot.
CASES=(
  "trackpad|REMOTECRAB_E2E_SURFACE=trackpad REMOTECRAB_E2E_MIC=1|13"
  "keyboard|REMOTECRAB_E2E_SURFACE=keyboard|14"
  "camera|REMOTECRAB_E2E_SURFACE=camera REMOTECRAB_AUTOSTREAM=1|14"
  "microphone|REMOTECRAB_E2E_MIC=1|12"
  "screen-mirror|REMOTECRAB_E2E_SURFACE=screen REMOTECRAB_E2E_SCREEN=1|20"
  "extended-display|REMOTECRAB_E2E_SURFACE=screen REMOTECRAB_E2E_EXTEND=1|20"
  "app-switcher|REMOTECRAB_E2E_SHEET=switcher|13"
  "transfer|REMOTECRAB_E2E_SHEET=send REMOTECRAB_E2E_SEND_FILE=3|14"
  "automation|REMOTECRAB_E2E_SHEET=context|13"
  "voice|REMOTECRAB_E2E_VOICE=1 REMOTECRAB_E2E_VOICE_SECONDS=4|11"
)

wanted() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }

for entry in "${CASES[@]}"; do
  slug="${entry%%|*}"; rest="${entry#*|}"
  envs="${rest%%|*}"; settle="${rest##*|}"
  wanted "$slug" || continue

  echo "== $slug"
  xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
  sleep 1
  # demoMode makes the camera surface render a stand-in (no sim camera) and
  # keeps the app usable with no Mac; the receiver is running on 127.0.0.1 so
  # the paired state and the app list are real either way.
  prefix=(SIMCTL_CHILD_REMOTECRAB_AUTO_START=1 SIMCTL_CHILD_REMOTECRAB_E2E_AUTOPAIR=1)
  for kv in $envs; do prefix+=("SIMCTL_CHILD_${kv}"); done
  env "${prefix[@]}" xcrun simctl launch "$SIM" "$BUNDLE_IOS" >/dev/null 2>&1

  sleep "$settle"
  xcrun simctl io "$SIM" screenshot "$OUT/$slug$SUFFIX.png" >/dev/null 2>&1
  if python3 "$ROOT/scripts/_shot_ok.py" "$OUT/$slug$SUFFIX.png" >/dev/null 2>&1; then
    echo "   ok  $OUT/$slug.png"
  else
    # One retry with a longer settle: several of these wait on a handshake or a
    # sheet animation, and a short first attempt reads as a blank frame.
    sleep 6
    xcrun simctl io "$SIM" screenshot "$OUT/$slug$SUFFIX.png" >/dev/null 2>&1
    echo "   retried $slug"
  fi
  xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
done

echo "done -> $OUT"
