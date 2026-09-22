#!/usr/bin/env bash
#
# Run all automated tests for RemoteCrab. Designed to be CI-friendly
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

# 1. RemoteCrabCore package — 109 unit + integration + e2e tests
#    covering: wire protocol, Bonjour discovery, event pipeline,
#    feature store, trackpad math, text diffing, Opus codec.
echo ""
echo "── RemoteCrabCore package tests ──"
if swift test --package-path RemoteCrabCore 2>&1 | tail -10; then
  pass "RemoteCrabCore tests (109 e2e + unit)"
else
  fail "RemoteCrabCore tests"
fi

# 2. RemoteCrabCapture — compiles cleanly (no camera on the CI box).
echo ""
echo "── RemoteCrabCapture build ──"
if xcodebuild \
    -project RemoteCrabCapture.xcodeproj \
    -scheme RemoteCrabCapture \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    -derivedDataPath "$CI_DERIVED_DATA/ios" \
    build CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -3; then
  pass "RemoteCrabCapture builds"
else
  fail "RemoteCrabCapture build"
fi

# 3. RemoteCrabReceiver — compiles cleanly.
echo ""
echo "── RemoteCrabReceiver build ──"
if xcodebuild \
    -project RemoteCrabReceiver.xcodeproj \
    -scheme RemoteCrabReceiver \
    -configuration Debug \
    -derivedDataPath "$CI_DERIVED_DATA/mac" \
    build CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -3; then
  pass "RemoteCrabReceiver builds"
else
  fail "RemoteCrabReceiver build"
fi

echo ""
echo -e "${GREEN}All checks passed.${RESET}"