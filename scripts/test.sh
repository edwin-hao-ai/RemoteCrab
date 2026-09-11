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

# CI builds use their own DerivedData so an unsigned gate build never
# clobbers the signed product that install/deploy scripts copy from
# the default DerivedData.
CI_DERIVED_DATA="$ROOT/.build/ci-derived-data"

# 1. iBridgeCore package — 49 unit + integration + e2e tests
#    covering: wire protocol, Bonjour discovery, event pipeline,
#    feature store, trackpad math, text diffing.
echo ""
echo "── iBridgeCore package tests ──"
if swift test --package-path iBridgeCore 2>&1 | tail -10; then
  pass "iBridgeCore tests (49 e2e + unit)"
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
    -derivedDataPath "$CI_DERIVED_DATA/ios" \
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
    -derivedDataPath "$CI_DERIVED_DATA/mac" \
    build CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -3; then
  pass "iBridgeReceiver builds"
else
  fail "iBridgeReceiver build"
fi

echo ""
echo -e "${GREEN}All checks passed.${RESET}"