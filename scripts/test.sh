#!/usr/bin/env bash
#
# Run all automated tests for iBridge. Designed to be CI-friendly
# (exits non-zero on any failure) and human-friendly (clear PASS / FAIL).
#
# Usage:
#     ./scripts/test.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Colors only when stdout is a TTY.
if [ -t 1 ]; then
  GREEN="\033[0;32m"
  RED="\033[0;31m"
  RESET="\033[0m"
else
  GREEN=""
  RED=""
  RESET=""
fi

pass() { echo -e "${GREEN}✓ $1${RESET}"; }
fail() { echo -e "${RED}✗ $1${RESET}"; exit 1; }

# 1. iBridgeCore unit + integration tests (wire protocol + Bonjour e2e).
echo ""
echo "── iBridgeCore package tests ──"
if swift test --package-path iBridgeCore 2>&1 | tail -20; then
  pass "iBridgeCore tests"
else
  fail "iBridgeCore tests"
fi

# 2. iBridgeCapture — compiles cleanly (no camera on the CI box).
echo ""
echo "── iBridgeCapture build ──"
if xcodebuild \
    -project iBridgeCapture.xcodeproj \
    -scheme iBridgeCapture \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    build CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -3; then
  pass "iBridgeCapture builds"
else
  fail "iBridgeCapture build"
fi

# 3. iBridgeReceiver — compiles cleanly.
echo ""
echo "── iBridgeReceiver build ──"
if xcodebuild \
    -project iBridgeReceiver.xcodeproj \
    -scheme iBridgeReceiver \
    -configuration Debug \
    build CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -3; then
  pass "iBridgeReceiver builds"
else
  fail "iBridgeReceiver build"
fi

echo ""
echo -e "${GREEN}All checks passed.${RESET}"