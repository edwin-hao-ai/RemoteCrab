#!/usr/bin/env bash
# Capture raw RemoteCrabCapture UI screenshots from a booted simulator for
# App Store Connect composites. Real app UI, captured per locale.
#
# Usage:
#   scripts/capture-asc-raw.sh <sim-udid> <derived-data-path> <out-dir>
#
# Produces <out-dir>/<locale>/<surface>.png for locale in zh-Hans,en-US and
# surface in camera,trackpad,keyboard,trackpad-mic.
set -euo pipefail

SIM="${1:?sim udid}"
DD="${2:?derived data path}"
OUT="${3:?output dir}"
BUNDLE_IOS="com.ibridge.iBridgeCapture"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APP_SIM=$(find "$DD" -name "RemoteCrabCapture.app" -path "*Debug-iphonesimulator*" 2>/dev/null | head -1 || true)

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1
xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
if [[ -n "$APP_SIM" ]]; then
  xcrun simctl uninstall "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
  xcrun simctl install "$SIM" "$APP_SIM" >/dev/null
else
  echo "  (derived data not found, using the app already installed on the sim)"
fi
for p in camera microphone; do
  xcrun simctl privacy "$SIM" grant "$p" "$BUNDLE_IOS" 2>/dev/null || true
done

set_language() {
  local lang="$1" loc="$2"
  xcrun simctl spawn "$SIM" defaults write "Apple Global Domain" AppleLanguages -array "$lang"
  xcrun simctl spawn "$SIM" defaults write "Apple Global Domain" AppleLocale -string "$loc"
}

shot() {
  local locale_dir="$1" name="$2"; shift 2
  # remaining args: KEY=VALUE env pairs for the app
  mkdir -p "$OUT/$locale_dir"
  local attempt
  for attempt in 1 2 3 4; do
    xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
    sleep 2
    local prefix=()
    for kv in "$@"; do prefix+=("SIMCTL_CHILD_${kv}"); done
    env "${prefix[@]}" xcrun simctl launch "$SIM" "$BUNDLE_IOS" >/dev/null
    sleep $((6 + attempt * 3))
    xcrun simctl io "$SIM" screenshot "$OUT/$locale_dir/$name.png" >/dev/null 2>&1
    if python3 "$ROOT/scripts/_shot_ok.py" "$OUT/$locale_dir/$name.png" ${CONNECTED:+--connected}; then
      echo "  $locale_dir/$name.png (attempt $attempt)"
      xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
      return 0
    fi
    echo "  … $name not ready, retrying"
  done
  echo "  WARN: $locale_dir/$name.png may be bad" >&2
  xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
}

ONLY_LOCALE="${4:-}"

# Inbox content for the notifications slide. Injected through the
# environment (never shipped in the app); `append` prepends, so the LAST
# entry is what appears at the top of the list.
SEED_EN='[{"app":"Calendar","title":"Design review","subtitle":"in 10 minutes","body":""},{"app":"Slack","title":"#design","subtitle":"","body":"Ada: shipping the new onboarding today"},{"app":"Xcode","title":"Build Succeeded","subtitle":"","body":"RemoteCrab — 0 errors, 2 warnings"},{"app":"OpenCode","title":"Task finished","subtitle":"","body":"Refactored the pairing store — 12 files changed"}]'
SEED_ZH='[{"app":"日历","title":"设计评审","subtitle":"10 分钟后","body":""},{"app":"飞书","title":"设计群","subtitle":"","body":"Ada：新版引导页今天上线"},{"app":"Xcode","title":"构建成功","subtitle":"","body":"RemoteCrab — 0 错误，2 警告"},{"app":"OpenCode","title":"任务完成","subtitle":"","body":"重构了配对存储 — 12 个文件"}]'

for round in "zh-Hans zh_CN" "en-US en_US"; do
  set -- $round
  LANG_CODE="$1"; LOCALE="$2"
  [[ -n "$ONLY_LOCALE" && "$LANG_CODE" != "$ONLY_LOCALE" ]] && continue
  echo "== locale $LANG_CODE =="
  set_language "$LANG_CODE" "$LOCALE"

  if [[ "$LANG_CODE" == "zh-Hans" ]]; then SEED="$SEED_ZH"; else SEED="$SEED_EN"; fi

  shot "$LANG_CODE" camera \
    REMOTECRAB_AUTO_START=1 REMOTECRAB_AUTOSTREAM=1 REMOTECRAB_E2E_AUTOPAIR=1 REMOTECRAB_E2E_SURFACE=camera
  shot "$LANG_CODE" trackpad \
    REMOTECRAB_AUTO_START=1 REMOTECRAB_E2E_AUTOPAIR=1 REMOTECRAB_E2E_SURFACE=trackpad
  shot "$LANG_CODE" keyboard \
    REMOTECRAB_AUTO_START=1 REMOTECRAB_E2E_AUTOPAIR=1 REMOTECRAB_E2E_SURFACE=keyboard
  shot "$LANG_CODE" trackpad-mic \
    REMOTECRAB_AUTO_START=1 REMOTECRAB_E2E_AUTOPAIR=1 REMOTECRAB_E2E_MIC=1 REMOTECRAB_E2E_SURFACE=trackpad
  shot "$LANG_CODE" notifications \
    REMOTECRAB_AUTO_START=1 REMOTECRAB_E2E_AUTOPAIR=1 REMOTECRAB_E2E_SHEET=notifications \
    REMOTECRAB_E2E_NOTIFY_SEED="$SEED"
  shot "$LANG_CODE" context \
    REMOTECRAB_AUTO_START=1 REMOTECRAB_E2E_AUTOPAIR=1 REMOTECRAB_E2E_SHEET=context
done

xcrun simctl terminate "$SIM" "$BUNDLE_IOS" 2>/dev/null || true
echo "done -> $OUT"
