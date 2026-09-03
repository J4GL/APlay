#!/bin/bash
# impl: NOTARY-001 rule 7 — Developer ID sign → verify → zip → notarize →
# staple → spctl → DMG pipeline, CLT-only (rule 12).
# impl: NOTARY-001 rule 9 — human-invoked only. Never called from build.sh,
# test.sh, or hooks: notarisation uploads the binary to Apple, which must stay
# an explicit, deliberate act.
#
# Usage: scripts/release.sh [--check-only]
# Env:
#   IDENTITY=signing identity          (default "Developer ID Application")
#   PLAY_NOTARY_PROFILE                (default PLAY_NOTARY)
#   PREREQ_TIMEOUT / BUILD_TIMEOUT / VERIFY_TIMEOUT /
#   STAPLE_TIMEOUT / SPCTL_TIMEOUT / DMG_TIMEOUT (defaults below)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
TEAM="V786D35WNB"
DEVID="Developer ID Application"
IDENTITY="${IDENTITY:-$DEVID}"
PROFILE="${PLAY_NOTARY_PROFILE:-PLAY_NOTARY}"
PREREQ_TIMEOUT="${PREREQ_TIMEOUT:-120}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-300}"
STAPLE_TIMEOUT="${STAPLE_TIMEOUT:-300}"
SPCTL_TIMEOUT="${SPCTL_TIMEOUT:-120}"
DMG_TIMEOUT="${DMG_TIMEOUT:-600}"

CHECK_ONLY=0
if [ "${1:-}" = "--check-only" ]; then
  CHECK_ONLY=1
elif [ $# -gt 0 ]; then
  echo "usage: scripts/release.sh [--check-only]" >&2; exit 2
fi

die() { echo "release: $*" >&2; exit 1; }

# impl: NOTARY-001-S1 — no silent fallback to a dev identity that notarisation
# would reject. An Apple Development-looking "success" is the failure mode.
[ "${PLAY_ALLOW_ADHOC:-0}" != "1" ] \
  || die "PLAY_ALLOW_ADHOC=1 is set — release.sh never signs ad-hoc. Unset it."

# --- prerequisite checks (NOTARY-001 rule 3) --------------------------------
# impl: NOTARY-001 rule 12 — every tool below ships in the Command Line Tools;
# xcodebuild/xcodegen are never invoked (rule 7 would fail on this machine).
for t in swiftc codesign ditto hdiutil spctl xcrun python3; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
done

DEVID_LINE="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -F "$DEVID" | head -1 || true)"
PROFILE_OK=0
timeout "$PREREQ_TIMEOUT" xcrun notarytool history \
  --keychain-profile "$PROFILE" >/dev/null 2>&1 && PROFILE_OK=1 || true

missing=0
if [ -z "$DEVID_LINE" ]; then
  echo "release: MISSING prerequisite — no '$DEVID' signing identity in the keychain." >&2
  echo "release: create one at https://developer.apple.com/account/resources/certificates" >&2
  echo "release: (CSR on this Mac, download the .cer, double-click to install)" >&2
  missing=1
fi
if [ $PROFILE_OK -ne 1 ]; then
  echo "release: MISSING prerequisite — no notarytool profile '$PROFILE'." >&2
  echo "release: xcrun notarytool store-credentials \"$PROFILE\" --apple-id <apple-id> --team-id $TEAM --password <app-specific-password>" >&2
  missing=1
fi
# impl: NOTARY-001 rule 2 — the repo never sees credentials, so there is
# nothing to prompt for; absence stops the run, never a question.
[ $missing -eq 0 ] || die "prerequisites missing — stopped before building anything."

CN="$(echo "$DEVID_LINE" | sed -n 's/.*"\(.*\)".*/\1/p')"
echo "$DEVID_LINE" | grep -q "($TEAM)" \
  || die "identity '$CN' is not on Team $TEAM."

if [ $CHECK_ONLY -eq 1 ]; then
  # impl: NOTARY-001-H1 — report only, no build, no submission.
  echo "release: identity: $CN"
  echo "release: profile '$PROFILE' responds to notarytool history"
  echo "release: prerequisites OK"
  exit 0
fi

# --- release log (NOTARY-001 rule 11) ---------------------------------------
VERSION="$(python3 -c 'import plistlib,sys; print(plistlib.load(open("Sources/Play/Info.plist","rb"))["CFBundleShortVersionString"])')"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/build/release"
mkdir -p "$OUT"
LOG="$OUT/release-$VERSION-$STAMP.log"
exec > >(tee -a "$LOG") 2>&1
set -x

# impl: NOTARY-001 rule 4 — exactly four deltas vs development, forced here so
# the caller's environment cannot silently weaken them.
export CONFIG=Release
# impl: NOTARY-001 rule 4 — compile_app.sh recomputes IDENTITY from its own
# default and re-exports CODE_SIGN_IDENTITY from it, so IDENTITY itself must
# be exported; CODE_SIGN_IDENTITY alone gets clobbered (seen: payload signed
# Apple Development despite CODE_SIGN_IDENTITY=Developer ID Application).
export IDENTITY="$IDENTITY"
export CODE_SIGN_IDENTITY="$IDENTITY"
export ENTITLEMENTS="$ROOT/Play-Release.entitlements"
export PLAY_TIMESTAMP_FLAG="--timestamp"

echo "release: identity: $CN"
echo "release: log: $LOG"

# --- clean CLT-only build (NOTARY-001 rules 7.2, 12, 13) --------------------
timeout "$BUILD_TIMEOUT" ./scripts/compile_app.sh
APP="$ROOT/build/Build/Products/Release/Play.app"
[ -d "$APP" ] || die "no Play.app at $APP"

# impl: NOTARY-001-S3 — get-task-allow is caught locally, before any upload.
timeout "$SPCTL_TIMEOUT" codesign -d --entitlements - "$APP" > "$OUT/entitlements.plist"
grep -q 'get-task-allow' "$OUT/entitlements.plist" \
  && die "Play.app carries com.apple.security.get-task-allow, which notarisation rejects (NOTARY-001 rule 4). Nothing uploaded."

# impl: NOTARY-001 rule 7.3 — identity gate before Apple is involved. The
# timestamp half of 7.3 is enforced by forcing PLAY_TIMESTAMP_FLAG above plus
# the notary Accepted / spctl verdicts below: no offline check exists on
# macOS 26 (see the NOTE in verify_signing.sh), and a fake one is worse.
timeout "$VERIFY_TIMEOUT" ./scripts/verify_signing.sh "$APP" --require-developer-id

# impl: NOTARY-001 rules 7.5, 8 and NOTARY-001-S2 — one submission per
# shippable object. Prints the full log on rejection (the status alone never
# names the offending binary) and removes the rejected file so it cannot be
# mistaken for a release. Sets SUBID to the latest submission id.
notarize() {
  local file="$1" tag="$2" out rc status
  out="$OUT/$tag.out"
  if timeout 2000 xcrun notarytool submit "$file" \
      --keychain-profile "$PROFILE" --wait --timeout 30m > "$out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  cat "$out"
  SUBID="$(grep -E '^  id: ' "$out" | head -1 | awk '{print $2}')"
  status="$(grep -E '^  status: ' "$out" | tail -1 | awk '{print $2}')"
  [ $rc -eq 0 ] && [ "$status" = "Accepted" ] || {
    [ -n "${SUBID:-}" ] && timeout "$SPCTL_TIMEOUT" xcrun notarytool log "$SUBID" \
      --keychain-profile "$PROFILE" || true
    rm -f "$file"
    die "notarisation of $file did not report Accepted (status: ${status:-submit-failed}). Nothing stapled from it."
  }
}

# --- zip → submit (NOTARY-001 rules 7.4, 7.5) --------------------------------
ZIP="$OUT/Play-$VERSION.zip"
timeout "$DMG_TIMEOUT" ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP" "submit-$STAMP"

# --- staple → validate → spctl (NOTARY-001 rules 7.6, 7.7, 10) ---------------
timeout "$STAPLE_TIMEOUT" xcrun stapler staple "$APP"
timeout "$STAPLE_TIMEOUT" xcrun stapler validate "$APP"
timeout "$VERIFY_TIMEOUT" ./scripts/verify_signing.sh "$APP" --require-developer-id --require-spctl
SPCTL_OUT="$(timeout "$SPCTL_TIMEOUT" spctl -a -vv -t install "$APP" 2>&1)"
echo "$SPCTL_OUT"
echo "$SPCTL_OUT" | grep -q 'accepted' && echo "$SPCTL_OUT" | grep -q 'Notarized Developer ID' \
  || die "spctl did not report accepted source=Notarized Developer ID."

# --- DMG of the stapled app, submitted and stapled too (NOTARY-001 rule 7.8) --
# The DMG is its own notarisation object: stapling looks up the ticket issued
# for the dmg itself, so it needs its own submission (seen: stapling a dmg
# built from the stapled app fails with Error 65, "Record not found").
# The image carries Play.app plus an Applications symlink for drag-and-drop
# install. ditto (not cp) stages the signed bundle so the ticket and xattrs
# survive the copy; hdiutil preserves the symlink.
DMG="$OUT/Play-$VERSION.dmg"
STAGE_DMG="$OUT/dmg-staging"
rm -rf "$STAGE_DMG"
mkdir -p "$STAGE_DMG"
timeout "$DMG_TIMEOUT" ditto "$APP" "$STAGE_DMG/Play.app"
ln -s /Applications "$STAGE_DMG/Applications"
timeout "$DMG_TIMEOUT" hdiutil create -volname "Play $VERSION" \
  -srcfolder "$STAGE_DMG" -ov -format UDZO "$DMG"
rm -rf "$STAGE_DMG"
notarize "$DMG" "submit-dmg-$STAMP"
timeout "$STAPLE_TIMEOUT" xcrun stapler staple "$DMG" \
  || { rm -f "$DMG"; die "stapler staple failed for $DMG."; }
timeout "$STAPLE_TIMEOUT" xcrun stapler validate "$DMG"

set +x
echo
echo "release: DONE — $DMG (this is the GitHub artifact, with $LOG attached)"
echo "release: zip: $ZIP (submission vehicle for the app ticket)"
