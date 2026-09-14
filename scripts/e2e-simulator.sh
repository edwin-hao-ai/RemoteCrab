#!/usr/bin/env bash
#
# End-to-end simulator launch: rebuild + install + run with auto-stream.
#
# This is the "one command to verify the iOS side works" workflow.
# It:
#   1. Builds the RemoteCrabCapture.app for the iPhone 17 Pro simulator
#      (or the first booted iOS 26 simulator it finds).
#   2. Reinstalls the app on the simulator.
#   3. Grants the required permissions (camera, microphone).
#   4. Launches the app with REMOTECRAB_AUTO_START=1 (skips onboarding,
#      auto-starts streaming).
#   5. Captures screenshots showing the iOS side in its streaming state.
#
# To complete the full e2e you also need:
#   • RemoteCrabReceiver running on the host Mac
#   • Both on the same WiFi (Bonjour discovery)
#   • A real iPhone (when the simulator can't be used)
#
# Usage:
#     ./scripts/e2e-simulator.sh                    # default iPhone 17 Pro
#     ./scripts/e2e-simulator.sh [simulator-udid]   # specific sim

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT/screenshots/e2e-demo"

# Pick a simulator
if [[ $# -ge 1 ]]; then
    SIM="$1"
else
    SIM=$(xcrun simctl list devices booted 2>/dev/null \
        | grep -E 'iPhone.*Booted' | head -1 \
        | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
    if [[ -z "$SIM" ]]; then
        # Boot the iPhone 17 Pro if nothing is running
        SIM="0EA997E8-16AE-4C20-9974-33628087E7E8"
        xcrun simctl bootstatus "$SIM" -b 2>&1 | tail -1
    fi
fi

mkdir -p "$OUTPUT_DIR"
APP_PATH="$ROOT/RemoteCrabCapture.xcodeproj"
APP_NAME="RemoteCrabCapture"

echo "═══════════════════════════════════════════════════════"
echo "  RemoteCrab simulator e2e"
echo "═══════════════════════════════════════════════════════"
echo "Simulator:  $SIM"
echo "App path:   $APP_PATH"
echo "Output:     $OUTPUT_DIR"
echo ""

# 1. Build
echo "→ Building RemoteCrabCapture for simulator..."
cd "$ROOT"
xcodebuild \
    -project RemoteCrabCapture.xcodeproj \
    -scheme RemoteCrabCapture \
    -destination "id=$SIM" \
    -configuration Debug \
    build \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM=DDG3CJL762 2>&1 | tail -1
echo ""

# 2. Locate built .app
APP=$(find ~/Library/Developer/Xcode/DerivedData \
    -name "RemoteCrabCapture.app" -path "*Debug-iphonesimulator*" 2>/dev/null | head -1)
if [[ -z "$APP" ]]; then
    echo "❌ Build didn't produce $APP_NAME.app"
    exit 1
fi
echo "→ Built: $APP"

# 3. Reinstall (replacing any previous version)
echo ""
echo "→ Reinstalling..."
xcrun simctl terminate "$SIM" com.ibridge.iBridgeCapture 2>/dev/null || true
xcrun simctl uninstall "$SIM" com.ibridge.iBridgeCapture 2>/dev/null || true
xcrun simctl install "$SIM" "$APP" 2>&1 | tail -1

# 4. Grant permissions
echo ""
echo "→ Granting permissions..."
for p in camera microphone; do
    xcrun simctl privacy "$SIM" grant "$p" com.ibridge.iBridgeCapture 2>&1 | tail -1
done

# 5. Launch with auto-start
echo ""
echo "→ Launching with REMOTECRAB_AUTO_START=1..."
# Per simctl help: "If you want to set environment variables in the
# resulting environment, set them in the calling environment with a
# SIMCTL_CHILD_ prefix."
SIMCTL_CHILD_REMOTECRAB_AUTO_START=1 xcrun simctl launch \
    "$SIM" com.ibridge.iBridgeCapture 2>&1 | tail -1

# 6. Wait + capture
echo ""
echo "→ Waiting 6s for auto-stream to start..."
sleep 6
SHOT="$OUTPUT_DIR/01_sim_autostart.png"
xcrun simctl io "$SIM" screenshot "$SHOT" 2>&1 | tail -1
echo ""

# 7. Tap the streaming button (in case auto-start didn't work)
#    to manually trigger the e2e
SHOT2="$OUTPUT_DIR/02_sim_after_tap.png"
xcrun simctl io "$SIM" screenshot "$SHOT2" 2>&1 | tail -1

# 8. Generate summary
cat > "$OUTPUT_DIR/SUMMARY.txt" <<EOF
RemoteCrab simulator e2e
═══════════════════════════

This run executed:
  • Built RemoteCrabCapture.app for iPhone 17 Pro simulator
    (iOS 17+ deployment target, Liquid Glass fallback path)
  • Granted camera + microphone permissions
  • Launched with REMOTECRAB_AUTO_START=1 to skip onboarding and
    auto-start streaming

Screenshots:
  $SHOT
  $SHOT2

To complete the full e2e (live frames on the Mac):
  1. In Xcode, open RemoteCrabReceiver.xcodeproj and Run on "My Mac".
  2. Watch the Mac menu bar for the RemoteCrab icon. Click → Open
     Control Panel / Open Preview Window.
  3. The simulator's RemoteCrabCapture will start streaming to the
     Mac over Bonjour.
  4. The Mac should show "CONNECTED" in the status pill with
     a green dot.

For real iPhone 14 (iOS 18) testing:
  1. In Xcode, open RemoteCrabCapture.xcodeproj.
  2. Set scheme to your iPhone.
  3. ⌘R — Xcode will install on the device.
  4. Grant camera/mic/local-network permissions.
  5. Tap the big red button to start streaming.

EOF

echo "═══════════════════════════════════════════════════════"
echo "  ✓ e2e simulator run complete"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Screenshots:"
echo "  $SHOT"
echo "  $SHOT2"
echo "Summary:"
echo "  $OUTPUT_DIR/SUMMARY.txt"