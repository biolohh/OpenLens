#!/usr/bin/env bash
# iOS 18 UI smoke test (ios18 branch): builds the app + OpenLensUITests, connects the
# app to a real OpenCode server through the deep link, walks the main screens and
# exports the screenshots. Run on macOS with Xcode 26+ and an iOS 18 simulator.
#
# Usage:
#   OPENLENS_SMOKE_URL=http://host:port [OPENLENS_SMOKE_USER=opencode] OPENLENS_SMOKE_PASS=... \
#   [OPENLENS_SMOKE_SESSION_TITLE=<existing session>] [OPENLENS_SMOKE_PROMPT=<one prompt to send>] \
#     scripts/smoke-ios18.sh <simulator-udid> [output-dir]
# The password may also come on stdin (one line) to keep it out of process arguments:
#   printf '%s\n' "$PASS" | OPENLENS_SMOKE_URL=... scripts/smoke-ios18.sh <udid> --pass-stdin
set -uo pipefail
cd "$(dirname "$0")/.."

SIM="${1:?simulator udid}"
OUT="build/smoke"
if [ "${2:-}" = "--pass-stdin" ]; then
  IFS= read -r OPENLENS_SMOKE_PASS
elif [ -n "${2:-}" ]; then
  OUT="$2"
fi
: "${OPENLENS_SMOKE_URL:?set OPENLENS_SMOKE_URL}"

command -v xcodegen >/dev/null || { echo "xcodegen is missing"; exit 1; }
xcodegen generate --quiet
rm -rf "$OUT" build/smoke.xcresult
mkdir -p "$OUT"

xcrun simctl boot "$SIM" 2>/dev/null
xcrun simctl bootstatus "$SIM" -b >/dev/null

TEST_RUNNER_OPENLENS_SMOKE_URL="$OPENLENS_SMOKE_URL" \
TEST_RUNNER_OPENLENS_SMOKE_USER="${OPENLENS_SMOKE_USER:-opencode}" \
TEST_RUNNER_OPENLENS_SMOKE_PASS="${OPENLENS_SMOKE_PASS:-}" \
TEST_RUNNER_OPENLENS_SMOKE_SESSION_TITLE="${OPENLENS_SMOKE_SESSION_TITLE:-}" \
TEST_RUNNER_OPENLENS_SMOKE_PROMPT="${OPENLENS_SMOKE_PROMPT:-}" \
xcodebuild test \
  -project OpenLens.xcodeproj \
  -scheme OpenLensSmoke \
  -destination "id=$SIM" \
  -derivedDataPath build/DD-smoke \
  -resultBundlePath build/smoke.xcresult \
  CODE_SIGNING_ALLOWED=NO > build/smoke.log 2>&1
rc=$?

xcrun xcresulttool export attachments --path build/smoke.xcresult --output-path "$OUT" >/dev/null 2>&1
grep -E "Test Case .*(passed|failed|skipped)|error:|\*\* TEST" build/smoke.log | sort -u
echo "screenshots: $OUT ($(ls "$OUT" | grep -c '\.png$') png)"
exit $rc
