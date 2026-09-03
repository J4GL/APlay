#!/usr/bin/env bash
# impl: TEST-001 rule 1 — generate the deterministic media fixtures.
#
# Run before the suite (scripts/test.sh does this for you). Fixtures are cached
# by filename and builder version, so a second run is a no-op.
set -euo pipefail
cd "$(dirname "$0")/.."

TIMEOUT="${FIXTURE_TIMEOUT:-300}"
BIN="$(mktemp -d)/make_fixtures"

echo "fixtures: compiling generator"
# impl: TEST-001 rule 1 — pin the target to MACOSX_DEPLOYMENT_TARGET (project.yml).
# An unpinned swiftc defaults to the SDK version, for which this CLT cannot rebuild
# the interface-only SDK modules (AVFoundation); measured 2026-09-03.
timeout 120 swiftc -O -target arm64-apple-macosx14.0 -o "$BIN" \
  Tests/Fixtures/FixtureBuilder.swift scripts/fixture_generator/main.swift

echo "fixtures: generating (timeout ${TIMEOUT}s)"
timeout "$TIMEOUT" "$BIN"
