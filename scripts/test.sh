#!/usr/bin/env bash
# impl: TEST-002 — run the suite with a hard timeout on every invocation.
#
# Usage:
#   scripts/test.sh                 # everything
#   scripts/test.sh PlayUnitTests   # one target
#   scripts/test.sh PlayUITests/BorderlessWindowTests/testWindowIsChromelessAndKey
set -euo pipefail
cd "$(dirname "$0")/.."

SUITE_TIMEOUT="${SUITE_TIMEOUT:-600}"
DERIVED="${DERIVED:-build}"   # same root as scripts/build.sh — one Play.app, one age

# impl: NOTARY-001 rule 12 — the XCTest/XCUITest runners ship only with full Xcode.
# Running a suite that cannot execute and reporting success would be worse than refusing.
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "test: FAIL — the test suite requires full Xcode (xcodebuild), which refuses" >&2
  echo "  CLT-only hosts: unit tests need the XCTest runner and UI tests need XCUITest," >&2
  echo "  neither of which the Command Line Tools ship. scripts/build.sh and" >&2
  echo "  scripts/make_fixtures.sh work without Xcode; this script does not." >&2
  exit 2
fi

# impl: TEST-001 rule 1 — fixtures are generated **before** xcodebuild, never
# during it. Encoding media inside a test run wedged the writer and took Play
# down with it; see TEST-001's Notes. Cached, so this is a no-op after the first
# run.
scripts/make_fixtures.sh

args=(-project Play.xcodeproj -scheme Play -configuration Debug
      -derivedDataPath "$DERIVED" -parallel-testing-enabled YES)

if [ $# -gt 0 ]; then
  for only in "$@"; do args+=(-only-testing:"$only"); done
fi

echo "test: xcodebuild test (timeout ${SUITE_TIMEOUT}s)"
set +e
timeout "$SUITE_TIMEOUT" xcodebuild "${args[@]}" test 2>&1 \
  | grep -vE '^\s+export |^note: ' \
  | grep -E "Test Case|Test Suite|error:|failed|passed|\*\*" \
  | tail -60
status=${PIPESTATUS[0]}
set -e

if [ "$status" -eq 124 ]; then
  echo "test: FAIL — suite exceeded ${SUITE_TIMEOUT}s" >&2
  exit 124
fi
exit "$status"
