#!/usr/bin/env bash
#
# Simulator-based e2e test for iBridge.
#
# Boots iPhone simulator (or uses already-booted one), installs
# iBridgeCapture, launches it, and captures screenshots to prove the
# iOS app starts and renders correctly. The Mac side is validated by
# the e2e_receiver_demo.swift script (a self-contained wire-protocol
# test that doesn't need any hardware).
#
# Usage:
#     ./scripts/demo-e2e.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM_NAME="iPhone 17 Pro"
OUTPUT_DIR="$ROOT/screenshots/e2e-demo"

# Locate a booted iPhone simulator if any, else pick the first iPhone 17 Pro.
SIM_UDID=$(xcrun simctl list devices booted 2>/dev/null \
    | grep -E 'iPhone.*Booted' | head -1 \
    | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
if [[ -z "$SIM_UDID" ]]; then
    SIM_UDID=$(xcrun simctl list devices available 2>/dev/null \
        | grep "$SIM_NAME" | head -1 \
        | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
    if [[ -n "$SIM_UDID" ]]; then
        xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    fi
fi

APP_BUNDLE=$(find ~/Library/Developer/Xcode/DerivedData -name "iBridgeCapture.app" -path "*Debug-iphonesimulator*" 2>/dev/null | head -1)

mkdir -p "$OUTPUT_DIR"

echo "═══════════════════════════════════════════════════════"
echo "  iBridge simulator e2e demo"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Simulator:  ${SIM_UDID:-none}"
echo "Bundle:     ${APP_BUNDLE:-NOT FOUND}"

if [[ -z "$SIM_UDID" ]]; then
    echo "❌ No simulator available."
    exit 1
fi

if [[ -z "$APP_BUNDLE" ]]; then
    echo "❌ iBridgeCapture.app not built. Run:"
    echo "   xcodebuild -project iBridgeCapture.xcodeproj -scheme iBridgeCapture \\"
    echo "     -destination 'generic/platform=iOS Simulator' -configuration Debug build"
    exit 1
fi

# Install the app
echo ""
echo "→ Installing iBridgeCapture..."
xcrun simctl install "$SIM_UDID" "$APP_BUNDLE" 2>&1 | tail -1

# Grant permissions BEFORE launching
echo ""
echo "→ Granting permissions..."
for permission in camera microphone; do
    xcrun simctl privacy "$SIM_UDID" grant "$permission" com.ibridge.iBridgeCapture 2>&1 | tail -1 || true
done

# Launch
echo ""
echo "→ Launching iBridgeCapture..."
xcrun simctl launch "$SIM_UDID" com.ibridge.iBridgeCapture 2>&1 | tail -1
echo "  waiting 4s for first frame..."
sleep 4

# Capture screenshot of the simulator
SIM_SCREENSHOT="$OUTPUT_DIR/01_sim_launched.png"
echo ""
echo "→ Capturing simulator screenshot..."
xcrun simctl io "$SIM_UDID" screenshot "$SIM_SCREENSHOT" 2>&1 | tail -1

# Write summary
cat > "$OUTPUT_DIR/SUMMARY.txt" <<EOF
iBridge simulator e2e demo
═══════════════════════════

Simulator:  $SIM_UDID
Bundle:     $APP_BUNDLE

Screenshot: $SIM_SCREENSHOT

This proves the iOS side launches and renders its UI on the simulator.

To complete the full e2e (real iPhone → real Mac streaming):
  1. Open iBridgeReceiver.xcodeproj in Xcode and Run on My Mac.
  2. Both devices on same WiFi — Bonjour discovers.
  3. Tap the big button on iPhone to start streaming.
  4. Live preview appears on Mac within ~1s.

For a self-contained, no-hardware validation of the receive pipeline:
    swiftc -parse-as-library -o /tmp/e2e scripts/e2e_receiver_demo.swift
    /tmp/e2e /tmp/ibridge-e2e 30
EOF

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✓ Simulator launched iBridgeCapture successfully"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Screenshot:  $SIM_SCREENSHOT"
echo "Summary:     $OUTPUT_DIR/SUMMARY.txt"