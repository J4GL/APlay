#!/bin/bash
# impl: VLC-001 rule 10 — re-sign the libvlc payload inside-out, before Xcode signs the app.
#
# install_name_tool and the plain copy both invalidate VLC's original signature.
# Every regular file in Frameworks/ and PlugIns/vlc/ is re-signed with the SAME
# identity Xcode resolved for the app, so the Team IDs match and library
# validation is satisfied without an entitlement (rule 11).
set -euo pipefail

if [ "${PLAY_SKIP_PAYLOAD_SIGN:-0}" = "1" ]; then
  echo "sign_vlc_payload: SKIPPED (PLAY_SKIP_PAYLOAD_SIGN=1) — VLC-001-S2 test seam" >&2
  exit 0
fi

APP="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
FW="$APP/Frameworks"
PI="$APP/PlugIns/vlc"

# Xcode resolves the identity for us; never hardcode a hash (rule 10).
# Under the CLT driver (NOTARY-001 rule 13) only CODE_SIGN_IDENTITY exists.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [ "$IDENTITY" = "-" ] && [ "${PLAY_ALLOW_ADHOC:-0}" != "1" ]; then
  echo "sign_vlc_payload: refusing ad-hoc signature without PLAY_ALLOW_ADHOC=1" >&2
  exit 1
fi
if [ -z "$IDENTITY" ]; then
  echo "sign_vlc_payload: no signing identity resolved (EXPANDED_CODE_SIGN_IDENTITY empty)" >&2
  exit 1
fi

signed=0
# Regular files only — signing a symlink would merely re-sign its target twice.
while IFS= read -r -d '' f; do
  codesign --force --options runtime "${PLAY_TIMESTAMP_FLAG:---timestamp=none}" \
           --sign "$IDENTITY" "$f" >/dev/null 2>&1 \
    || { echo "sign_vlc_payload: FAILED on $f" >&2; exit 1; }
  signed=$((signed + 1))
done < <(find "$FW" "$PI" -type f -name '*.dylib' -print0 2>/dev/null)

echo "sign_vlc_payload: signed $signed payload dylibs with ${EXPANDED_CODE_SIGN_IDENTITY:-$IDENTITY}"
