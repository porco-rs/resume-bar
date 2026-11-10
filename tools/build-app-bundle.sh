#!/bin/bash
# Assemble and sign ResumeBar.app from a SwiftPM release binary.
# Adapted from another local app bundle builder.
# Usage: tools/build-app-bundle.sh <release-binary> <out-dir>
# Signing identity: $RB_SIGN_IDENTITY, defaulting to Developer ID Application when available,
# otherwise ad hoc signing. A stable identity keeps Accessibility and Automation grants across rebuilds.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'usage: %s <release-binary> <out-dir>\n' "$0" >&2
    exit 64
fi

SOURCE_BINARY=$1
OUTPUT_DIR=$2
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
INFO_PLIST="$ROOT/Bundle/Info.plist"
ENTITLEMENTS="$ROOT/Bundle/ResumeBar.entitlements"
UI_DIR="$ROOT/ui"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)
[[ -n "$BUNDLE_ID" ]] || { printf 'CFBundleIdentifier missing or empty in %s\n' "$INFO_PLIST" >&2; exit 1; }
TEAM_ID=${RB_TEAM_ID:-}
if [[ -n ${RB_SIGN_IDENTITY:-} ]]; then
    SIGN_IDENTITY=$RB_SIGN_IDENTITY
elif [[ $(security find-identity -v -p codesigning 2>/dev/null || true) == *'Developer ID Application:'* ]]; then
    SIGN_IDENTITY="Developer ID Application"
    printf 'Signing identity: Developer ID Application (available)\n'
else
    SIGN_IDENTITY=-
    printf 'Signing identity: ad hoc (no Developer ID Application identity found)\n'
fi
if [[ ${RB_SIGN_IDENTITY+x} ]]; then
    printf 'Signing identity: %s\n' "$([[ $SIGN_IDENTITY == - ]] && printf 'ad hoc' || printf 'explicit identity')"
fi
if [[ ${RELEASE:-0} == 1 && ( -z $TEAM_ID || $SIGN_IDENTITY == - ) ]]; then
    printf 'release signing requires RB_TEAM_ID and a non-ad-hoc RB_SIGN_IDENTITY\n' >&2
    exit 1
fi
TIMESTAMP=--timestamp=none
if [[ ${RELEASE:-0} == 1 ]]; then TIMESTAMP=--timestamp; fi

[[ -x "$SOURCE_BINARY" ]] || { printf 'release binary missing or not executable: %s\n' "$SOURCE_BINARY" >&2; exit 1; }
[[ -f "$INFO_PLIST" ]] || { printf 'Info.plist missing: %s\n' "$INFO_PLIST" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd -P)
BUNDLE="$OUTPUT_DIR/ResumeBar.app"
STAGING="$OUTPUT_DIR/.ResumeBar.app.$$.new"
BACKUP="$OUTPUT_DIR/.ResumeBar.app.$$.old"

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    [[ -e "$STAGING" ]] && rm -rf "$STAGING"
    [[ -e "$BACKUP" && ! -e "$BUNDLE" ]] && mv "$BACKUP" "$BUNDLE"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$SOURCE_BINARY" "$STAGING/Contents/MacOS/ResumeBar"
RB_BINARY="$(dirname "$SOURCE_BINARY")/rb"
[[ -x "$RB_BINARY" ]] || { printf 'rb binary missing: %s\n' "$RB_BINARY" >&2; exit 1; }
cp "$RB_BINARY" "$STAGING/Contents/MacOS/rb"
# Debug symbols name the folder the app was built in, so shipped binaries carry none.
/usr/bin/strip -S -x "$STAGING/Contents/MacOS/ResumeBar" 2>/dev/null
/usr/bin/strip -S -x "$STAGING/Contents/MacOS/rb" 2>/dev/null
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$TIMESTAMP" "$STAGING/Contents/MacOS/rb"
chmod 0755 "$STAGING/Contents/MacOS/ResumeBar"
cp "$INFO_PLIST" "$STAGING/Contents/Info.plist"
for LANGUAGE_DIR in "$ROOT"/Bundle/*.lproj; do
    [[ -d "$LANGUAGE_DIR" ]] || continue
    cp -R "$LANGUAGE_DIR" "$STAGING/Contents/Resources/$(basename "$LANGUAGE_DIR")"
done
if [[ -d "$UI_DIR" ]]; then
    cp -R "$UI_DIR" "$STAGING/Contents/Resources/ui"
fi
# License texts travel with the binary.
mkdir -p "$STAGING/Contents/Resources/licenses"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$STAGING/Contents/Resources/licenses/"
cp "$ROOT/Sources/CZstd/LICENSE" "$STAGING/Contents/Resources/licenses/zstd-LICENSE"
# App icon (Bundle/AppIcon.svg, small sizes from AppIcon-small.svg).
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/tools/render-icon.swift" "$ROOT/Bundle/AppIcon.svg" "$ROOT/Bundle/AppIcon-small.svg" "$ICONSET"
/usr/bin/iconutil -c icns "$ICONSET" -o "$STAGING/Contents/Resources/AppIcon.icns"

codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --options runtime \
    --entitlements "$ENTITLEMENTS" "$TIMESTAMP" "$STAGING"
codesign --verify --deep --strict "$STAGING"
if [[ -n $TEAM_ID ]]; then
    codesign -v -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\" and identifier \"$BUNDLE_ID\"" \
        "$STAGING"
fi

if [[ -e "$BUNDLE" || -L "$BUNDLE" ]]; then
    mv "$BUNDLE" "$BACKUP"
fi
mv "$STAGING" "$BUNDLE"
rm -rf "$BACKUP"
trap - EXIT HUP INT TERM
printf '%s\n' "$BUNDLE"
