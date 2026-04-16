#!/usr/bin/env bash
set -euo pipefail

# Blackbird local release builder.
#
# Produces a signed, notarized (if credentials available) DMG in ./dist/.
#
# Env vars (all optional — omit to skip that step):
#   DEVELOPER_ID          — "Developer ID Application: Name (TEAMID)" identity.
#                           If unset, the script uses the first matching
#                           identity in the default keychain.
#   APPLE_ID              — Apple ID for notarization.
#   APP_SPECIFIC_PASSWORD — app-specific password (NOT your Apple password).
#   TEAM_ID               — your 10-char team ID (from Apple Developer portal).
#
# Usage:
#   scripts/release.sh            # build + sign + DMG
#   scripts/release.sh notarize   # also notarize + staple

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DIST_DIR="$REPO_ROOT/dist"
mkdir -p "$DIST_DIR"

echo "==> Building Rust core (universal)"
bash scripts/build-core.sh

echo "==> xcodebuild Release"
xcodebuild \
    -project Blackbird.xcodeproj \
    -scheme Blackbird \
    -configuration Release \
    -derivedDataPath "$DIST_DIR/DerivedData" \
    build \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    ${DEVELOPER_ID:+CODE_SIGN_IDENTITY="$DEVELOPER_ID"} \
    >/dev/null

APP_SRC="$DIST_DIR/DerivedData/Build/Products/Release/Blackbird.app"
APP_DST="$DIST_DIR/Blackbird.app"
if [[ ! -d "$APP_SRC" ]]; then
    echo "!! Missing Release build output at $APP_SRC"
    exit 1
fi
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "==> Verifying code signature"
codesign --verify --strict --deep --verbose=2 "$APP_DST" 2>&1 | tail -3 || {
    echo "!! Code signature verification failed."
    exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DST/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG_NAME="Blackbird-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo "==> Packaging DMG ($DMG_NAME)"
rm -f "$DMG_PATH"
TMP_DMG_DIR="$(mktemp -d)"
cp -R "$APP_DST" "$TMP_DMG_DIR/"
ln -s /Applications "$TMP_DMG_DIR/Applications"
hdiutil create \
    -volname "Blackbird $VERSION" \
    -srcfolder "$TMP_DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
rm -rf "$TMP_DMG_DIR"

echo "==> DMG: $DMG_PATH"

if [[ "${1:-}" == "notarize" ]]; then
    : "${APPLE_ID:?APPLE_ID required for notarization}"
    : "${APP_SPECIFIC_PASSWORD:?APP_SPECIFIC_PASSWORD required for notarization}"
    : "${TEAM_ID:?TEAM_ID required for notarization}"
    echo "==> Submitting to notarytool"
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APP_SPECIFIC_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait
    echo "==> Stapling"
    xcrun stapler staple "$DMG_PATH"
    echo "==> Verifying staple"
    xcrun stapler validate "$DMG_PATH"
fi

echo "Done."
