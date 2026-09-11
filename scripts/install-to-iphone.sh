#!/usr/bin/env bash
# Install iBridgeCapture to your iPhone 14 after you've logged into
# Apple ID in Xcode (Xcode → Settings → Accounts).
#
# Usage:
#     ./scripts/install-to-iphone.sh
#     ./scripts/install-to-iphone.sh --auto-start
#
# The --auto-start flag sets the IBRIDGE_AUTO_START=1 env var on the
# installed app so it skips onboarding and auto-starts streaming.
#
# Prerequisites:
#   • Apple ID logged in via Xcode (Xcode → Settings → Accounts)
#   • iPhone 14 (or any iOS 17+ device) plugged in via USB
#   • iPhone unlocked and "Trust this Mac" dialog accepted

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHONE_UDID=$(xcrun devicectl list devices 2>&1 \
    | grep -E 'iPhone.*available' | head -1 \
    | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
if [[ -z "$PHONE_UDID" ]]; then
    PHONE_UDID="866A1921-B588-59D5-A1B7-B266103B2E49"   # iPhone 14 default
fi

AUTO_START=0
if [[ "${1:-}" == "--auto-start" ]]; then
    AUTO_START=1
fi

echo "═══════════════════════════════════════════════════════"
echo "  iBridge install to iPhone"
echo "═══════════════════════════════════════════════════════"
echo "Device:       $PHONE_UDID"
echo "Auto-start:   $AUTO_START"
echo ""

# 1. Build for the device
echo "→ Building iBridgeCapture for device..."
cd "$ROOT"
xcodebuild \
    -project iBridgeCapture.xcodeproj \
    -scheme iBridgeCapture \
    -destination "id=$PHONE_UDID" \
    -configuration Debug \
    build \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM=5XNDF727Y6 2>&1 | tail -3
echo ""

# 2. Locate the built .app
APP=$(find ~/Library/Developer/Xcode/DerivedData \
    -name "iBridgeCapture.app" -path "*Debug-iphoneos*" 2>/dev/null | head -1)
if [[ -z "$APP" ]]; then
    echo "❌ Build didn't produce iBridgeCapture.app for device"
    echo "   Check the Xcode log for the failure reason."
    exit 1
fi
echo "→ Built: $APP"

# 3. Install on device
echo ""
echo "→ Installing on iPhone..."
xcrun devicectl device install app --device "$PHONE_UDID" "$APP" 2>&1 | tail -3

# 4. Permissions
# Note: Xcode 26's devicectl no longer has `device privacy grant`.
# Camera/mic/local-network grants persist on the device from the first
# interactive run; if this is a fresh device, launch once without
# --auto-start and grant the prompts manually.
echo ""
echo "→ Permissions: assumed already granted (devicectl no longer"
echo "   supports `privacy grant`; grant manually on first run)."

# 5. Launch
echo ""
echo "→ Launching on iPhone..."
if [[ $AUTO_START == 1 ]]; then
    echo "   (with IBRIDGE_AUTO_START=1 + IBRIDGE_AUTOSTREAM=1)"
    xcrun devicectl device process launch --device "$PHONE_UDID" --terminate-existing \
        --environment-variables '{"IBRIDGE_AUTO_START":"1","IBRIDGE_AUTOSTREAM":"1"}' \
        com.ibridge.iBridgeCapture 2>&1 | tail -1
else
    xcrun devicectl device process launch --device "$PHONE_UDID" --terminate-existing \
        com.ibridge.iBridgeCapture 2>&1 | tail -1
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✓ Installed iBridgeCapture on your iPhone"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Next: open the app, grant Local Network permission,"
echo "and tap the big red button to start streaming."
echo ""
if [[ $AUTO_START == 0 ]]; then
    echo "💡 Re-run with --auto-start to skip onboarding and"
    echo "   auto-start streaming on next install:"
    echo "   ./scripts/install-to-iphone.sh --auto-start"
fi