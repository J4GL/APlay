#!/bin/bash
# impl: VLC-001 rule 12 — the verification pass that fails a build rather than
# letting a broken bundle be reported as a success.
# impl: NOTARY-001 rule 7.3 — --require-developer-id for the release gate.
# NOTE: no --require-timestamp flag exists on purpose. On macOS 26 there is no
# locally observable trace of a secure timestamp to assert: no `Timestamp=`
# line at any codesign verbosity, no RFC3161 token bytes in the CMS (checked
# byte-level against Chrome, VS Code, Obsidian, Warp, Claude and Safari —
# all timestamped, none carries OID 1.2.840.113549.1.9.16.2.14), identical
# SuperBlob slot sets, and `Signed Time` present with and without --timestamp.
# A grep for `Timestamp=` matches nothing on any file and would fail a good
# release too, so it was removed rather than shipped. The timestamp proof is
# the chain release.sh enforces: forced --timestamp flag (NOTARY-001 rule 4)
# + notarytool Accepted + spctl Notarized Developer ID (rules 7.5, 7.7).
#
# impl: NOTARY-001 rule 7.7 — --require-spctl turns the spctl verdict into a
# failure. It is passed only AFTER stapling: a pre-notarisation build is
# always rejected by spctl, so requiring acceptance at step 7.3 would make the
# pipeline unwinnable (seen: release.sh died at 7.3 with everything else green).
#
# Usage: verify_signing.sh <path-to-APlay.app> [--require-developer-id] [--require-spctl]
set -uo pipefail

APP="${1:?usage: verify_signing.sh <APlay.app> [--require-developer-id] [--require-spctl]}"
REQUIRE_DEVID=0
REQUIRE_SPCTL=0
for arg in "${@:2}"; do
  [ "$arg" = "--require-developer-id" ] && REQUIRE_DEVID=1
  [ "$arg" = "--require-spctl" ] && REQUIRE_SPCTL=1
done

TEAM="V786D35WNB"
EXPECTED_PLUGINS=133
fail=0
note() { printf '  %-7s %s\n' "$1" "$2"; }
bad()  { note "FAIL" "$1"; fail=1; }
ok()   { note "ok" "$1"; }

echo "verify_signing: $APP"

[ -d "$APP" ] || { bad "no such app bundle"; exit 1; }

# --- structure --------------------------------------------------------------
fw_count=$(find "$APP/Contents/Frameworks" -maxdepth 1 -name 'libvlc*' | wc -l | tr -d ' ')
pi_count=$(find "$APP/Contents/PlugIns/vlc" -name '*.dylib' 2>/dev/null | wc -l | tr -d ' ')
[ "$fw_count" -eq 4 ] && ok "Frameworks: 4 libvlc entries" || bad "Frameworks: $fw_count libvlc entries, expected 4"
[ "$pi_count" -eq "$EXPECTED_PLUGINS" ] && ok "PlugIns/vlc: $pi_count plugins" \
  || bad "PlugIns/vlc: $pi_count plugins, expected $EXPECTED_PLUGINS"

for banned in libmacosx_plugin.dylib libosx_notifications_plugin.dylib plugins.dat; do
  [ -e "$APP/Contents/PlugIns/vlc/$banned" ] && bad "banned file present: $banned"
done
[ $fail -eq 0 ] && ok "no banned plugins present"

# --- app signature ----------------------------------------------------------
if codesign --verify --strict --verbose=4 "$APP" >/dev/null 2>&1; then
  ok "codesign --verify --strict passes"
else
  bad "codesign --verify --strict FAILED"
fi

appinfo=$(codesign -dvv "$APP" 2>&1)
echo "$appinfo" | grep -q "TeamIdentifier=$TEAM" && ok "app TeamIdentifier=$TEAM" \
  || bad "app TeamIdentifier is not $TEAM"
echo "$appinfo" | grep -q "flags=0x10000(runtime)" && ok "hardened runtime enabled" \
  || bad "hardened runtime NOT enabled (flags missing 0x10000)"

if [ $REQUIRE_DEVID -eq 1 ]; then
  echo "$appinfo" | grep -q "Authority=Developer ID Application" \
    && ok "Developer ID Application identity" \
    || bad "not signed with Developer ID Application (NOTARY-001 rule 4)"
fi

# --- payload signatures -----------------------------------------------------
bad_files=0; adhoc=0; unsigned=0
while IFS= read -r -d '' f; do
  info=$(codesign -dvv "$f" 2>&1) || { unsigned=$((unsigned+1)); bad_files=$((bad_files+1)); continue; }
  if echo "$info" | grep -q "Signature=adhoc"; then
    adhoc=$((adhoc+1)); bad_files=$((bad_files+1))
    [ $bad_files -le 3 ] && note "FAIL" "ad-hoc signature: ${f##*/}"
  elif ! echo "$info" | grep -q "TeamIdentifier=$TEAM"; then
    bad_files=$((bad_files+1))
    [ $bad_files -le 3 ] && note "FAIL" "wrong/missing TeamIdentifier: ${f##*/}"
  fi
done < <(find "$APP/Contents/Frameworks" "$APP/Contents/PlugIns/vlc" -type f -name '*.dylib' -print0)

if [ $bad_files -eq 0 ]; then
  ok "all $((fw_count/2 + pi_count)) payload dylibs signed with TeamIdentifier=$TEAM"
else
  bad "$bad_files payload file(s) badly signed ($adhoc ad-hoc, $unsigned unsigned)"
fi

# --- dependency resolution --------------------------------------------------
strays=$(for f in "$APP/Contents/PlugIns/vlc"/*.dylib "$APP/Contents/Frameworks"/*.dylib; do
  otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}'
done | grep -v '^@rpath' | grep -v '^@executable_path' | grep -v '^/usr/lib' \
     | grep -v '^/System' | grep -v '_plugin.dylib$' | sort -u)
if [ -z "$strays" ]; then
  ok "no payload dependency outside @rpath / /usr/lib / /System"
else
  bad "payload depends on paths outside the bundle:"; echo "$strays" | sed 's/^/           /'
fi

# --- Gatekeeper (NOTARY-001 rule 7.7 only when asked, else informational) ----
if spctl -a -vv -t install "$APP" >/dev/null 2>&1; then
  ok "spctl: accepted"
elif [ $REQUIRE_SPCTL -eq 1 ]; then
  bad "spctl rejected a build that requires acceptance (NOTARY-001 rule 7.7)"
else
  note "info" "spctl: rejected — expected before notarisation"
fi

echo
if [ $fail -eq 0 ]; then echo "verify_signing: PASS"; else echo "verify_signing: FAIL"; fi
exit $fail
