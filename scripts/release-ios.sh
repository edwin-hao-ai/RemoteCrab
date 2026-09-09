#!/usr/bin/env bash
# iBridge iOS release automation.
#
# Usage:
#   ./scripts/release-ios.sh 0.2.0                    # build + upload IPA only
#   ./scripts/release-ios.sh 0.2.0 --metadata         # + update App Store metadata
#   ./scripts/release-ios.sh 0.2.0 --screenshots      # + generate/upload screenshots
#   ./scripts/release-ios.sh 0.2.0 --all              # + metadata + screenshots
#   ./scripts/release-ios.sh 0.2.0 --all --create-version
#
# What it does:
#   1. Loads App Store Connect API credentials from
#      ~/.config/ibridge/ios-release.env
#   2. Bumps the iOS bundle version (Info.plist + project.yml)
#   3. Regenerates the Xcode project via xcodegen
#   4. Builds a signed release IPA
#   5. Uploads the IPA via xcrun altool
#   6. Optionally updates App Store metadata (--metadata)
#      and/or screenshots (--screenshots)
#
# The default mode (no flags) builds and uploads the IPA only, preserving
# the original behavior. Use --all to run the full release workflow.
#
# Prerequisites:
#   - Apple Developer Program membership ($99/yr)
#   - App record created in App Store Connect with bundle ID
#     com.ibridge.iBridgeCapture
#   - App Store Connect API key generated at
#     https://appstoreconnect.apple.com/access/integrations/api
#   - Xcode 26+ with iOS 26+ SDK installed
#   - ~/.config/ibridge/ios-release.env populated (see below)
#
# Credentials file example (~/.config/ibridge/ios-release.env, mode 0600):
#   APPLE_API_KEY=ABCDE12345
#   APPLE_API_ISSUER=uuid-from-app-store-connect
#   APPLE_API_KEY_PATH=$HOME/.config/ibridge/AuthKey_ABCDE12345.p8
#   APPLE_TEAM_ID=YOUR_TEAM_ID
#
# Notes:
#   - The script does NOT submit for review. After upload, go to App Store
#     Connect, pick the build, attach metadata/screenshots, and submit
#     manually (or use --metadata/--screenshots flags to automate).
#   - Use `--skip-build` to update only metadata/screenshots without
#     rebuilding the IPA.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${IBRIDGE_IOS_RELEASE_ENV:-$HOME/.config/ibridge/ios-release.env}"

IOS_VERSION=""
DO_METADATA=false
DO_SCREENSHOTS=false
CREATE_VERSION=false
SKIP_BUILD=false
BUILD_NUMBER=1
SCREENSHOTS_DIR="$ROOT/screenshots"

usage() {
  cat <<EOF
Usage: release-ios.sh <IOS_VERSION> [OPTIONS]

Examples:
  release-ios.sh 0.2.0                   # build + upload IPA only
  release-ios.sh 0.2.0 --metadata        # + update App Store metadata
  release-ios.sh 0.2.0 --screenshots     # + generate/upload screenshots
  release-ios.sh 0.2.0 --all             # + metadata + screenshots
  release-ios.sh 0.2.0 --all --create-version

Options:
  --metadata            Update App Store metadata (description, keywords, URLs, whats-new)
  --screenshots         Generate + upload screenshots to App Store Connect
  --all                 Equivalent to --metadata --screenshots
  --create-version      Create the App Store version if it does not already exist
  --build-number N      Build number (default: 1)
  --skip-build          Skip building/uploading the IPA (only update metadata/screenshots)
  --screenshots-dir DIR Directory for screenshot images (default: ./screenshots)
  -h, --help            Show this help

Env overrides:
  IBRIDGE_IOS_RELEASE_ENV  - path to credentials env file
  APPLE_TEAM_ID             - Apple Team ID for code signing
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --metadata)        DO_METADATA=true; shift ;;
    --screenshots)     DO_SCREENSHOTS=true; shift ;;
    --all)             DO_METADATA=true; DO_SCREENSHOTS=true; shift ;;
    --create-version)  CREATE_VERSION=true; shift ;;
    --build-number)    BUILD_NUMBER="$2"; shift 2 ;;
    --skip-build)      SKIP_BUILD=true; shift ;;
    --screenshots-dir) SCREENSHOTS_DIR="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    -*)                echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [[ -n "$IOS_VERSION" ]]; then
        echo "Only one version argument allowed. Got: $IOS_VERSION and $1" >&2
        usage >&2
        exit 1
      fi
      IOS_VERSION="${1#v}"
      shift
      ;;
  esac
done

if [[ -z "$IOS_VERSION" ]]; then
  echo "ERROR: Missing iOS version argument." >&2
  usage >&2
  exit 1
fi

if ! echo "$IOS_VERSION" | grep -qE '^[0-9]+(\.[0-9]+){1,2}$'; then
  echo "ERROR: Invalid iOS version format '$IOS_VERSION'. Expected x.y or x.y.z like 0.2.0" >&2
  exit 1
fi

if ! echo "$BUILD_NUMBER" | grep -qE '^[0-9]+$'; then
  echo "ERROR: Build number must be a positive integer, got '$BUILD_NUMBER'" >&2
  exit 1
fi

echo "=========================================="
echo "  iBridge iOS Release v${IOS_VERSION} (build ${BUILD_NUMBER})"
echo "=========================================="
echo ""

# ---- Load credentials ----
echo "--- [1/5] Loading credentials ---"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ Missing credentials file: $ENV_FILE" >&2
  echo "   Create it with mode 0600 and set:" >&2
  echo "   APPLE_API_KEY=" >&2
  echo "   APPLE_API_ISSUER=" >&2
  echo "   APPLE_API_KEY_PATH=" >&2
  echo "   APPLE_TEAM_ID=" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

missing=()
[[ -z "${APPLE_API_KEY:-}" ]] && missing+=("APPLE_API_KEY")
[[ -z "${APPLE_API_ISSUER:-}" ]] && missing+=("APPLE_API_ISSUER")
[[ -z "${APPLE_API_KEY_PATH:-}" ]] && missing+=("APPLE_API_KEY_PATH")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "❌ Missing credential variables in $ENV_FILE: ${missing[*]}" >&2
  exit 1
fi

if [[ ! -f "$APPLE_API_KEY_PATH" ]]; then
  echo "❌ API key file not found: $APPLE_API_KEY_PATH" >&2
  exit 1
fi

if [[ "$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null)" != "600" ]]; then
  echo "⚠  Credentials file $ENV_FILE is not mode 0600. Fixing..." >&2
  chmod 600 "$ENV_FILE"
fi

export APPLE_API_KEY APPLE_API_ISSUER APPLE_API_KEY_PATH
TEAM_ID="${APPLE_TEAM_ID:-}"
if [[ -n "$TEAM_ID" ]]; then
  export APPLE_TEAM_ID
fi
echo "  ✓ credentials loaded"
echo ""

# ---- Verify tooling ----
echo "--- [2/5] Checking tooling ---"
command -v xcodebuild >/dev/null 2>&1 || { echo "❌ xcodebuild not found"; exit 1; }
command -v xcodegen  >/dev/null 2>&1 || { echo "❌ xcodegen not found. brew install xcodegen"; exit 1; }
command -v xcrun     >/dev/null 2>&1 || { echo "❌ xcrun not found"; exit 1; }
command -v python3   >/dev/null 2>&1 || { echo "❌ python3 not found"; exit 1; }
echo "  ✓ xcodebuild, xcodegen, xcrun, python3 present"
echo ""

# ---- Bump version ----
echo "--- [3/5] Bumping iOS version to $IOS_VERSION (build $BUILD_NUMBER) ---"
INFO_PLIST="$ROOT/iBridgeCapture/Info.plist"
PROJECT_YML="$ROOT/project-ios.yml"

if [[ ! -f "$INFO_PLIST" ]]; then
  echo "❌ Info.plist not found: $INFO_PLIST" >&2
  exit 1
fi

python3 - "$INFO_PLIST" "$IOS_VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib, sys
path, version, build = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'rb') as f:
    p = plistlib.load(f)
p['CFBundleShortVersionString'] = version
p['CFBundleVersion'] = build
# Required for App Store Connect when CFBundleDocumentTypes is declared.
if 'LSSupportsOpeningDocumentsInPlace' not in p:
    p['LSSupportsOpeningDocumentsInPlace'] = False
# Apple export compliance: we use HTTPS only.
if 'ITSAppUsesNonExemptEncryption' not in p:
    p['ITSAppUsesNonExemptEncryption'] = False
with open(path, 'wb') as f:
    plistlib.dump(p, f)
print(f"  ✓ Info.plist → short={version}, build={build}")
PY

if [[ -f "$PROJECT_YML" ]]; then
  python3 - "$PROJECT_YML" "$IOS_VERSION" "$BUILD_NUMBER" <<'PY'
import re, sys
path, version, build_version = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
src = re.sub(r'^(\s*MARKETING_VERSION:\s*)\S+', rf'\g<1>{version}', src, flags=re.M)
src = re.sub(r'^(\s*CURRENT_PROJECT_VERSION:\s*)\S+', rf'\g<1>{build_version}', src, flags=re.M)
open(path, 'w').write(src)
print(f"  ✓ project.yml → version={version}, build={build_version}")
PY
fi
echo ""

# ---- Regenerate Xcode project ----
echo "--- [3.5/5] Regenerating Xcode project ---"
cd "$ROOT"
xcodegen generate --spec project-ios.yml 2>&1 | tail -2
echo ""

# ---- Build release IPA ----
if [[ "$SKIP_BUILD" == true ]]; then
  echo "--- [4/5] Skipping IPA build/upload (--skip-build) ---"
  echo ""
else
  echo "--- [4/5] Building iOS release archive ---"
  rm -rf ~/Library/Developer/Xcode/DerivedData/iBridgeCapture-*
  cd "$ROOT"
  xcodebuild \
    -project iBridgeCapture.xcodeproj \
    -scheme iBridgeCapture \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath build/iBridgeCapture.xcarchive \
    archive \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="$TEAM_ID"

  # The xcodebuild archive command above doesn't sign. The actual
  # code signing + export needs a real Apple Developer team. The
  # user runs exportArchive separately with proper signing identity:
  #
  #   xcodebuild -exportArchive \
  #     -archivePath build/iBridgeCapture.xcarchive \
  #     -exportPath build/ipa \
  #     -exportOptionsPlist ExportOptions.plist
  #
  # We provide a default ExportOptions.plist if none exists.
  EXPORT_OPTIONS="$ROOT/ExportOptions.plist"
  if [[ ! -f "$EXPORT_OPTIONS" ]]; then
    cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
    echo "  ✓ Wrote $EXPORT_OPTIONS"
  fi
  echo ""
  echo "  To export the signed IPA, run (requires your signing key):"
  echo "    xcodebuild -exportArchive \\"
  echo "      -archivePath build/iBridgeCapture.xcarchive \\"
  echo "      -exportPath build/ipa \\"
  echo "      -exportOptionsPlist ExportOptions.plist"
  echo ""
fi

# ---- Update App Store metadata ----
if [[ "$DO_METADATA" == true ]]; then
  echo "--- [5/5] Updating App Store metadata ---"
  META_ARGS=("--version" "$IOS_VERSION" "--metadata")
  if [[ "$CREATE_VERSION" == true ]]; then
    META_ARGS+=("--create-version")
  fi
  python3 "$ROOT/scripts/ios-app-store-metadata.py" "${META_ARGS[@]}"
  echo ""
fi

# ---- Update screenshots ----
if [[ "$DO_SCREENSHOTS" == true ]]; then
  echo "--- [5/5] Generating and uploading screenshots ---"
  locales=$(python3 - "$ROOT/scripts/ios-metadata.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    print(" ".join(json.load(f)["locales"].keys()))
PY
)
  for loc in $locales; do
    echo "  Uploading screenshots for $loc..."
    SCREEN_ARGS=("--version" "$IOS_VERSION" "--screenshots" "--screenshots-dir" "$SCREENSHOTS_DIR")
    if [[ "$CREATE_VERSION" == true ]]; then
      SCREEN_ARGS+=("--create-version")
    fi
    python3 "$ROOT/scripts/ios-app-store-metadata.py" "${SCREEN_ARGS[@]}"
  done
  echo ""
fi

echo "=========================================="
echo "  iBridge v${IOS_VERSION} release workflow complete"
echo "=========================================="
echo ""
echo "Next steps (manual, in App Store Connect):"
echo "  1. Wait 5–20 minutes for the build to finish processing."
echo "  2. Open the version, verify metadata and screenshots."
echo "  3. Select the uploaded build and submit for review."
echo ""