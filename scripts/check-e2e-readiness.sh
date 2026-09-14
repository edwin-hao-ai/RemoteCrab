#!/usr/bin/env bash
# Check whether the e2e test between iPhone 14 and Mac can work
# by verifying both are on the same Bonjour-reachable subnet.
#
# Usage:
#     ./scripts/check-e2e-readiness.sh
#     ./scripts/check-e2e-readiness.sh [iPhone-udid]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHONE_UDID="${1:-866A1921-B588-59D5-A1B7-B266103B2E49}"

echo "═══════════════════════════════════════════════════════"
echo "  RemoteCrab e2e readiness check"
echo "═══════════════════════════════════════════════════════"
echo ""

# 1. Mac's WiFi subnet
echo "1. Mac's WiFi interface (en0):"
MAC_WIFI=$(rtk ipconfig getsummary en0 2>&1 | grep "IP Address" | head -1 || true)
if [[ -z "$MAC_WIFI" ]]; then
    MAC_WIFI=$(rtk ifconfig en0 2>&1 | awk '/inet /{print $2; exit}')
fi
echo "   $MAC_WIFI"
echo ""

# 2. iPhone's IP
echo "2. iPhone ($PHONE_UDID) info:"
rtk xcrun devicectl device info details -d $PHONE_UDID 2>&1 | grep -E "marketingName|osVersionNumber|transportType" | head -3
echo ""

# Try to ping common iPhone USB-tethering ranges
echo "   (Checking common iPhone USB-tethering ranges)"
for range in 192.168.0 192.168.1 192.168.2 192.168.3 192.168.31; do
    if rtk ping -c 1 -W 1 "$range.2" >/dev/null 2>&1; then
        echo "   Found host at $range.2 (likely iPhone USB-tethered)"
        break
    fi
done
echo ""

# 3. Check Bonjour sees the RemoteCrab service
echo "3. Bonjour browse for RemoteCrab service:"
rtk killall dns-sd 2>/dev/null || true
sleep 0.5
BONJOUR_OUT=$(rtk timeout 4 dns-sd -B _remotecrab._tcp 2>&1)
echo "$BONJOUR_OUT" | grep -E "Instance Name|Error" | head -5 || true
echo ""

# 4. Check Mac receiver is running
echo "4. Mac RemoteCrabReceiver status:"
RECV_PID=$(pgrep -f RemoteCrabReceiver 2>&1 | head -1)
if [[ -n "$RECV_PID" ]]; then
    echo "   ✓ Running (PID $RECV_PID)"
else
    echo "   ✗ NOT running"
    echo "   Fix: open RemoteCrabReceiver.xcodeproj in Xcode and ⌘R"
fi
echo ""

# 5. Check if iPhone has the app installed
echo "5. RemoteCrabCapture on iPhone:"
APP_BUNDLE_ID="com.ibridge.iBridgeCapture"
xcrun devicectl device install list 2>&1 | grep -i "$APP_BUNDLE_ID" | head -1 || true
echo ""

# 6. Test summary
echo "═══════════════════════════════════════════════════════"
echo "  Next steps to get e2e working:"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  1. UNPLUG iPhone 14 from USB"
echo "  2. Connect iPhone 14 to the SAME WiFi network as the Mac"
echo "     (Settings → WiFi → pick your home network)"
echo "  3. On iPhone 14, open Settings → General → VPN & Device Management"
echo "     → trust the 'Apple Development: Edwin Hao' certificate"
echo "  4. Run RemoteCrabCapture on the iPhone 14 (it's already installed)"
echo "  5. Tap the big red START button. The Local Network prompt appears"
echo "     → tap Allow."
echo "  6. On Mac, click the RemoteCrab menu bar icon"
echo "     → it should show 'CONNECTED' within 1-2 seconds"
echo ""
echo "  Tip: run './scripts/check-e2e-readiness.sh' again after these"
echo "       steps. The 'Bonjour browse' section should list a service"
echo "       from your iPhone (in addition to the simulator)."