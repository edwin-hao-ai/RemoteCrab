#!/usr/bin/env bash
#
# RemoteCrabReceiver — Developer ID sign + notarize + DMG.
#
# Not for the Mac App Store: the receiver needs a CoreMediaIO system
# extension and a CoreAudio HAL plug-in, so it ships outside MAS
# (Developer ID + notarization is what lets it run under Gatekeeper).
#
# Usage:
#   ./scripts/release-mac.sh 1.0 [--skip-pkg] [--skip-app]
#
# Prerequisites:
#   - keychain has "Developer ID Application" and "Developer ID Installer"
#     for team 5XNDF727Y6
#   - notarization creds:  source ~/.config/mddock/production.env
#     (APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID)
#
# Why this script exists instead of `xcodebuild -exportArchive`:
#   Our App Store Connect API key does not have "cloud-managed
#   distribution certificates" permission, so the export step fails with
#   "Cloud signing permission error". We instead archive with automatic
#   development signing (which works) and re-sign every nested binary
#   with Developer ID by hand. Verified: this notarizes Accepted with a
#   CMIO system extension and an app extension embedded, and needs NO
#   Developer ID provisioning profile (none of our entitlements require
#   one).
set -euo pipefail

VERSION="${1:?Usage: release-mac.sh <version> [--skip-pkg] [--skip-app]}"
shift || true
SKIP_PKG=false
SKIP_APP=false
for arg in "$@"; do
  case "$arg" in
    --skip-pkg) SKIP_PKG=true ;;
    --skip-app) SKIP_APP=true ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM="${REMOTECRAB_TEAM:-5XNDF727Y6}"
DEV_ID_APP="Developer ID Application: Beijing VGO Co;Ltd (${TEAM})"
DEV_ID_INSTALLER="Developer ID Installer: Beijing VGO Co;Ltd (${TEAM})"
OUT="$ROOT/dist"
ARCHIVE="$ROOT/build/mac-release/RemoteCrabReceiver.xcarchive"
APP="$ROOT/build/mac-release/RemoteCrab.app"
DMG="$OUT/RemoteCrab-${VERSION}.dmg"

# Apple's timestamp server sometimes hangs behind a proxy/VPN; MDDock's
# wrapper replaces --timestamp with --timestamp=none only when
# MDDOCK_CODESIGN_TIMESTAMP=none is set (notarization would then fail,
# so leave it unset unless debugging).
if [[ -d "$HOME/.config/mddock/bin" ]]; then
  export PATH="$HOME/.config/mddock/bin:$PATH"
fi

command -v xcrun >/dev/null || { echo "Xcode command line tools required"; exit 1; }

# --- notarization creds -------------------------------------------------
if [[ -z "${APPLE_ID:-}" || -z "${APPLE_PASSWORD:-}" || -z "${APPLE_TEAM_ID:-}" ]]; then
  echo "ERROR: APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID not set." >&2
  echo "  Run: set -a; source ~/.config/mddock/production.env; set +a" >&2
  exit 1
fi
notarize() {
  local path="$1"
  local id
  id="$(xcrun notarytool submit "$path" \
    --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" \
    --wait --output-format json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
  local status
  status="$(xcrun notarytool info "$id" \
    --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" \
    --output-format json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
  echo "  notarization $id: $status"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" \
      --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" >&2 || true
    return 1
  fi
}

# --- 1. virtual-mic installer pkg (Developer ID Installer + notarized) ---
if [[ "$SKIP_PKG" == false ]]; then
  echo "==> [1/5] build + sign + notarize the virtual-mic pkg"
  REMOTECRAB_MIC_IDENTITY="Developer ID Application" \
  REMOTECRAB_MIC_VERSION="$VERSION" \
    "$ROOT/scripts/build-mic-driver-pkg.sh"
  rm -f "$OUT/RemoteCrabMicrophone.signed.pkg"
  # productsign hits the keychain for the Developer ID Installer key; the
  # first run shows a GUI password prompt ("diiformac"). Choose
  # "Always Allow" once and it never asks again.
  productsign --sign "$DEV_ID_INSTALLER" \
    "$OUT/RemoteCrabMicrophone.pkg" "$OUT/RemoteCrabMicrophone.signed.pkg"
  mv "$OUT/RemoteCrabMicrophone.signed.pkg" "$OUT/RemoteCrabMicrophone.pkg"
  notarize "$OUT/RemoteCrabMicrophone.pkg"
  xcrun stapler staple "$OUT/RemoteCrabMicrophone.pkg"
  xcrun stapler validate "$OUT/RemoteCrabMicrophone.pkg"
else
  echo "==> [1/5] skipping pkg (--skip-pkg)"
fi

# --- 2. archive (automatic development signing) -------------------------
if [[ "$SKIP_APP" == false ]]; then
  echo "==> [2/5] archive RemoteCrabReceiver"
  rm -rf "$ROOT/build/mac-release"
  mkdir -p "$ROOT/build/mac-release"
  ( cd "$ROOT" && xcodegen generate --spec project-mac.yml >/dev/null )
  ( cd "$ROOT" && xcodebuild \
      -project RemoteCrabReceiver.xcodeproj \
      -scheme RemoteCrabReceiver \
      -configuration Release \
      -destination 'platform=macOS' \
      -archivePath "$ARCHIVE" \
      archive CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
      >/tmp/remotecrab-mac-archive.log 2>&1 ) \
    || { echo "archive failed — see /tmp/remotecrab-mac-archive.log"; exit 1; }

  cp -R "$ARCHIVE/Products/Applications/RemoteCrab.app" "$APP"
  # The archive embeds a *development* provisioning profile; a Developer
  # ID app must not carry it (entitlements here need no profile at all).
  rm -f "$APP/Contents/embedded.provisionprofile"
  # Swap in the signed/notarized mic pkg if we built one.
  if [[ -f "$OUT/RemoteCrabMicrophone.pkg" ]]; then
    cp "$OUT/RemoteCrabMicrophone.pkg" "$APP/Contents/Resources/RemoteCrabMicrophone.pkg"
  fi

  echo "==> [3/5] re-sign nested code + app with Developer ID"
  SX="$APP/Contents/Library/SystemExtensions/com.remotecrab.RemoteCrabReceiver.Camera.systemextension"
  AX="$APP/Contents/PlugIns/RemoteCrabAudioExtension.appex"
  [[ -d "$SX" ]] && codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" \
    --entitlements "$ROOT/RemoteCrabCameraExtension/CameraExtension.entitlements" "$SX"
  [[ -d "$AX" ]] && codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" \
    --entitlements "$ROOT/RemoteCrabAudioExtension/AudioExtension.entitlements" "$AX"
  codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" \
    --entitlements "$ROOT/RemoteCrabReceiver/RemoteCrabReceiver.entitlements" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"

  echo "==> [4/5] notarize + staple the app"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/build/mac-release/app.zip"
  notarize "$ROOT/build/mac-release/app.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
else
  echo "==> [2-4/5] skipping app (--skip-app)"
fi

# --- 5. DMG -------------------------------------------------------------
echo "==> [5/5] build + sign + notarize the DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/RemoteCrab.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "RemoteCrab" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$DEV_ID_APP" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo ""
echo "✅ Release artifacts:"
echo "   app: $APP"
echo "   dmg: $DMG"
echo "   pkg: $OUT/RemoteCrabMicrophone.pkg"
echo ""
echo "Upload to vgoapp.com (rsync to the VPS /var/www/vgoapp/downloads/):"
echo "   rsync -avzP --partial '$DMG' <user>@<vps>:/var/www/vgoapp/downloads/"
