#!/bin/bash
# impl: VLC-001 rules 7-10 (bundle layout, runpath, inside-out signing order) and
# NOTARY-001 rules 12-13 (CLT-only compile-and-assemble, no xcodebuild).
# Called by scripts/build.sh (development identity) and scripts/release.sh.
# Verifies nothing itself — the caller runs scripts/verify_signing.sh.
#
# Usage: scripts/compile_app.sh [--adhoc]
# Env:
#   CONFIG=Debug|Release              (default Debug)
#   DERIVED=build root                (default build; output mirrors xcodebuild)
#   IDENTITY=signing identity         (default "Apple Development")
#   ENTITLEMENTS=path                 (default Play.entitlements)
#   PLAY_TIMESTAMP_FLAG               (default --timestamp=none; release uses --timestamp)
#   COMPILE_TIMEOUT / SIGN_TIMEOUT    (defaults 600 / 300)
# --adhoc signs with `-` instead of a certificate. Mechanics testing only, for
# machines with no signing identity at all: verify_signing.sh's Team checks will
# fail by design. Never silent — the mode is printed on every run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
CONFIG="${CONFIG:-Debug}"
DERIVED="$ROOT/${DERIVED:-build}"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"
APP="$PRODUCTS/Play.app"
IDENTITY="${IDENTITY:-Apple Development}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/Play.entitlements}"
COMPILE_TIMEOUT="${COMPILE_TIMEOUT:-600}"
SIGN_TIMEOUT="${SIGN_TIMEOUT:-300}"

ADHOC=0
[ "${1:-}" = "--adhoc" ] && ADHOC=1
if [ $ADHOC -eq 1 ]; then
  IDENTITY="-"
  export PLAY_ALLOW_ADHOC=1
  echo "compile_app: AD-HOC mode — mechanics testing only, not a shippable signature"
fi

die() { echo "compile_app: $*" >&2; exit 1; }

if [ ! -f "$ROOT/Vendor/libvlc/lib/libvlc.5.dylib" ]; then
  echo "compile_app: vendoring libvlc first"
  ./scripts/vendor_libvlc.sh
fi

# impl: VLC-001 rule 9 — the identity must resolve before anything is built, so a
# missing certificate fails the run instead of producing an unsigned bundle.
if [ $ADHOC -eq 0 ]; then
  security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$IDENTITY" \
    || die "no '$IDENTITY' signing identity in the keychain. Create an Apple Development
  certificate at https://developer.apple.com/account/resources/certificates
  (CSR without Xcode: openssl req -new -newkey rsa:2048 -nodes -keyout dev.key -out dev.csr)
  and double-click the downloaded .cer to install it. Mechanics-only alternative:
  scripts/compile_app.sh --adhoc"
fi

[ -f "$ENTITLEMENTS" ] || die "no entitlements file at $ENTITLEMENTS"

SWIFTFLAGS=(-target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
  -module-cache-path "$DERIVED/ModuleCache")
if [ "$CONFIG" = "Release" ]; then
  SWIFTFLAGS+=(-O)
else
  SWIFTFLAGS+=(-Onone -g -D DEBUG)
fi

STAGE="$DERIVED/clt-stage"
rm -rf "$STAGE" "$APP"
mkdir -p "$STAGE/mods" "$STAGE/fw/PlayA11y.framework/Versions/A/Resources" \
         "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compile_app: PlayA11y framework ($CONFIG)"
# shellcheck disable=SC2086
timeout "$COMPILE_TIMEOUT" swiftc -emit-library \
  -module-name PlayA11y \
  -emit-module -emit-module-path "$STAGE/mods/PlayA11y.swiftmodule" \
  "${SWIFTFLAGS[@]}" \
  -Xlinker -install_name -Xlinker "@rpath/PlayA11y.framework/Versions/A/PlayA11y" \
  Sources/PlayA11y/A11yID.swift \
  -o "$STAGE/fw/PlayA11y.framework/Versions/A/PlayA11y"
FWROOT="$STAGE/fw/PlayA11y.framework"
ln -sfn A "$FWROOT/Versions/Current"
ln -sfn Versions/Current/PlayA11y "$FWROOT/PlayA11y"
ln -sfn Versions/Current/Resources "$FWROOT/Resources"

echo "compile_app: Play executable ($CONFIG)"
# shellcheck disable=SC2207,SC2086
SRCS=($(find Sources/Play -name '*.swift' | sort))
# impl: NOTARY-001 rule 13 — bridging header, libvlc headers, runpath (VLC-001 rule 8)
timeout "$COMPILE_TIMEOUT" swiftc "${SRCS[@]}" \
  -module-name Play \
  "${SWIFTFLAGS[@]}" \
  -import-objc-header "$ROOT/Sources/Play/Bridging/Play-Bridging-Header.h" \
  -I "$ROOT/Vendor/libvlc/include" \
  -Xcc "-I$ROOT/Vendor/libvlc/include" \
  -I "$STAGE/mods" \
  -L "$ROOT/Vendor/libvlc/lib" -lvlc \
  -F "$STAGE/fw" -framework PlayA11y \
  -framework AppKit \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -o "$APP/Contents/MacOS/Play"
# swiftc -g leaves .dSYM bundles beside their binaries; Xcode keeps them next to
# the app instead of inside it, so move them before signing seals the layout.
# The destination is cleared first: rebuilding the same CONFIG must work, and
# `mv` onto an existing directory nests instead of replacing (seen: rebuild
# fails with "Directory not empty"). Untouched when no fresh dSYM was produced.
if [ -d "$APP/Contents/MacOS/Play.dSYM" ]; then
  rm -rf "$PRODUCTS/Play.app.dSYM"
  mv "$APP/Contents/MacOS/Play.dSYM" "$PRODUCTS/Play.app.dSYM"
fi
if [ -d "$STAGE/fw/PlayA11y.framework/Versions/A/PlayA11y.dSYM" ]; then
  rm -rf "$PRODUCTS/PlayA11y.framework.dSYM"
  mv "$STAGE/fw/PlayA11y.framework/Versions/A/PlayA11y.dSYM" \
     "$PRODUCTS/PlayA11y.framework.dSYM"
fi

echo "compile_app: assembling bundle"
python3 - "$ROOT/Sources/Play/Info.plist" "$APP/Contents/Info.plist" \
  "EXECUTABLE_NAME=Play" "PRODUCT_BUNDLE_IDENTIFIER=gl.j4.Play" "DEVELOPMENT_LANGUAGE=en" \
  <<'EOF'
import plistlib, sys
base, dest, *subs = sys.argv[1:]
table = dict(s.split('=', 1) for s in subs)
with open(base, 'rb') as f:
    info = plistlib.load(f)
def fix(v):
    if isinstance(v, str):
        for k, val in table.items():
            v = v.replace('$(' + k + ')', val)
        return v
    if isinstance(v, list):
        return [fix(x) for x in v]
    if isinstance(v, dict):
        return {k: fix(x) for k, x in v.items()}
    return v
with open(dest, 'wb') as f:
    plistlib.dump(fix(info), f)
EOF
python3 - "$ROOT/Sources/PlayA11y/Info.plist" \
  "$STAGE/fw/PlayA11y.framework/Versions/A/Resources/Info.plist" \
  "EXECUTABLE_NAME=PlayA11y" "PRODUCT_BUNDLE_IDENTIFIER=gl.j4.PlayA11y" "DEVELOPMENT_LANGUAGE=en" \
  <<'EOF'
import plistlib, sys
base, dest, *subs = sys.argv[1:]
table = dict(s.split('=', 1) for s in subs)
with open(base, 'rb') as f:
    info = plistlib.load(f)
def fix(v):
    if isinstance(v, str):
        for k, val in table.items():
            v = v.replace('$(' + k + ')', val)
        return v
    if isinstance(v, list):
        return [fix(x) for x in v]
    if isinstance(v, dict):
        return {k: fix(x) for k, x in v.items()}
    return v
with open(dest, 'wb') as f:
    plistlib.dump(fix(info), f)
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"

# impl: VLC-001 rule 7 — dylibs + versioned symlinks, 133 plugins
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/PlugIns/vlc"
cp -a "$ROOT/Vendor/libvlc/lib/." "$APP/Contents/Frameworks/"
cp -a "$ROOT/Vendor/libvlc/plugins/." "$APP/Contents/PlugIns/vlc/"
cp -a "$STAGE/fw/PlayA11y.framework" "$APP/Contents/Frameworks/"
echo "payload: $(ls "$APP/Contents/PlugIns/vlc" | wc -l | tr -d ' ') plugins"

echo "compile_app: signing (VLC-001 rule 10, inside out)"
export TARGET_BUILD_DIR="$PRODUCTS" CONTENTS_FOLDER_PATH="Play.app/Contents"
export CODE_SIGN_IDENTITY="$IDENTITY"
TS="${PLAY_TIMESTAMP_FLAG:---timestamp=none}"
timeout "$SIGN_TIMEOUT" ./scripts/sign_vlc_payload.sh
timeout "$SIGN_TIMEOUT" codesign --force --options runtime "$TS" \
  --sign "$IDENTITY" "$APP/Contents/Frameworks/PlayA11y.framework"
timeout "$SIGN_TIMEOUT" codesign --force --options runtime "$TS" \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

echo
echo "compile_app: $APP"
du -sh "$APP"
