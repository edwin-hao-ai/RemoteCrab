#!/usr/bin/env bash
#
# 生成 Sparkle appcast.xml（EdDSA 签名，私钥取自登录钥匙串）。
#
# Usage:
#   ./scripts/make-appcast.sh 1.0
#   SPARKLE_GENERATE_APPCAST=/path/to/generate_appcast ./scripts/make-appcast.sh 1.0
#
# 前置：dist/RemoteCrab-<version>.zip 已由 scripts/release-mac.sh 产出。
set -euo pipefail

VERSION="${1:?Usage: make-appcast.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$ROOT/dist/RemoteCrab-${VERSION}.zip"
APPDIR="$ROOT/dist/appcast"
BASE_URL="${REMOTECRAB_DOWNLOAD_BASE:-https://vgoapp.com/downloads/}"

[[ -f "$ZIP" ]] || { echo "missing $ZIP — run scripts/release-mac.sh $VERSION first" >&2; exit 1; }

GEN="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$GEN" ]]; then
  GEN="$(find "$ROOT/.build" "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*sparkle*/bin/generate_appcast' 2>/dev/null | head -1)"
fi
[[ -x "$GEN" ]] || { echo "generate_appcast not found; set SPARKLE_GENERATE_APPCAST" >&2; exit 1; }

# 只保留最新一个包，appcast 只含一条最新记录。
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
cp "$ZIP" "$APPDIR/"

"$GEN" --download-url-prefix "$BASE_URL" "$APPDIR"

echo ""
echo "✅ appcast: $APPDIR/appcast.xml"
echo "   上传（沿用 VPS 的 cat|ssh 更稳）："
echo "   cat '$APPDIR/appcast.xml' | ssh <vps> 'cat > /var/www/vgoapp/downloads/appcast.xml'"
echo "   cat '$ZIP'                | ssh <vps> 'cat > /var/www/vgoapp/downloads/RemoteCrab-${VERSION}.zip'"
