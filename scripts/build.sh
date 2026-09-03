#!/bin/bash
# impl: VLC-001 rule 12 — generate, build, then verify. A build that produces an
# unverifiable bundle exits non-zero.
#
# Usage: scripts/build.sh [--adhoc] (the flag is forwarded to compile_app.sh)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
CONFIG="${CONFIG:-Debug}"
# `build/` is xcodebuild's own default output root, so a build from Xcode.app and
# a build from this script land in the same place instead of leaving two copies
# of Play.app at different ages.
DERIVED="$ROOT/build"

if [ ! -f "$ROOT/Vendor/libvlc/lib/libvlc.5.dylib" ]; then
  echo "build: vendoring libvlc first"
  ./scripts/vendor_libvlc.sh
fi

# impl: NOTARY-001 rule 12 — xcodebuild refuses CLT-only hosts, so the CLT driver
# (scripts/compile_app.sh) builds there instead. Same output path either way.
if xcodebuild -version >/dev/null 2>&1 && command -v xcodegen >/dev/null 2>&1; then
  echo "build: xcodegen generate"
  xcodegen generate --quiet

  echo "build: xcodebuild ($CONFIG)"
  set -o pipefail
  xcodebuild \
    -project Play.xcodeproj \
    -scheme Play \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' \
    build 2>&1 | grep -E '^(/|.*(error|warning|BUILD|Signing|payload:|sign_vlc_payload):)' || true
else
  echo "build: no Xcode — CLT path (scripts/compile_app.sh)"
  ./scripts/compile_app.sh "$@"
fi

APP="$DERIVED/Build/Products/$CONFIG/Play.app"
[ -d "$APP" ] || { echo "build: FAILED — no Play.app at $APP" >&2; exit 1; }

echo
./scripts/verify_signing.sh "$APP"

echo
echo "build: $APP"
du -sh "$APP"
