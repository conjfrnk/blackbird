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
ARCHIVE_PATH="$DIST_DIR/Blackbird.xcarchive"
EXPORT_DIR="$DIST_DIR/Export"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"
mkdir -p "$DIST_DIR"

echo "==> Building Rust core (universal)"
bash scripts/build-core.sh

# `xcodebuild archive` + `-exportArchive` is the only path that gives us
# distribution-grade signatures: secure timestamp on every inner binary,
# no injected `get-task-allow` entitlement, and a deep re-sign of Sparkle's
# nested XPCs + Updater.app with our Developer ID. A plain `xcodebuild
# build` skips all three and fails notarization.
echo "==> xcodebuild archive"
rm -rf "$ARCHIVE_PATH"
xcodebuild \
    -project Blackbird.xcodeproj \
    -scheme Blackbird \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DIST_DIR/DerivedData" \
    archive \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    ${DEVELOPER_ID:+CODE_SIGN_IDENTITY="$DEVELOPER_ID"} \
    >/dev/null

echo "==> xcodebuild -exportArchive (Developer ID)"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    >/dev/null

APP_SRC="$EXPORT_DIR/Blackbird.app"
APP_DST="$DIST_DIR/Blackbird.app"
if [[ ! -d "$APP_SRC" ]]; then
    echo "!! Missing exported app at $APP_SRC"
    exit 1
fi
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "==> Verifying code signature"
# Capture the full codesign diagnostic before truncating. `tail -3` at the
# end of a pipe hid the critical "file modified in transit" / "resource fork
# ... missing" messages when signatures failed; on failure, dump the full
# log so the operator can actually see what's wrong. Audit scripts-release
# F6.
CODESIGN_LOG="$(codesign --verify --strict --deep --verbose=2 "$APP_DST" 2>&1)"
CODESIGN_STATUS=$?
if [[ $CODESIGN_STATUS -ne 0 ]]; then
    echo "!! Code signature verification failed (exit $CODESIGN_STATUS)."
    echo "$CODESIGN_LOG" >&2
    exit 1
fi
printf '%s\n' "$CODESIGN_LOG" | tail -3

# Pin Team ID at the build phase, symmetric with publish-update.sh:147.
# `publish-update.sh` already greps `TeamIdentifier=` from `codesign
# --display` on the DMG before signing it into the appcast; that catches a
# wrong-team DMG at publish time. This pre-flight catches the same problem
# at build time so an artifact signed under a different Apple Developer
# account never even reaches the notarization step (saves an Apple-side
# round-trip and a bad upload). Read DEVELOPMENT_TEAM out of project.yml so
# the expected value tracks the project config, not a duplicated literal.
# Audit M-11 (S-7 + N-3 / L-25).
EXPECTED_TEAM_ID="$(awk -F': ' '/^[[:space:]]*DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml | tr -d ' ')"
if [[ -z "$EXPECTED_TEAM_ID" ]]; then
    echo "!! release.sh: cannot read DEVELOPMENT_TEAM from project.yml" >&2
    exit 1
fi
ACTUAL_TEAM_ID="$(codesign --display --verbose=2 "$APP_DST" 2>&1 | awk -F'=' '/^TeamIdentifier=/ {print $2; exit}')"
if [[ -z "$ACTUAL_TEAM_ID" ]]; then
    echo "!! release.sh: codesign --display did not emit TeamIdentifier= for $APP_DST" >&2
    echo "   the bundle may be unsigned or the signature unreadable; aborting." >&2
    exit 1
fi
if [[ "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
    echo "!! release.sh: signed Team ID mismatch — got '$ACTUAL_TEAM_ID', expected '$EXPECTED_TEAM_ID'" >&2
    echo "   the .app was signed under a different Apple Developer account than the one" >&2
    echo "   pinned in project.yml. Check DEVELOPER_ID / keychain identity selection." >&2
    exit 1
fi
echo "    codesign Team ID verified: $ACTUAL_TEAM_ID"

# Sparkle is a SwiftPM binary product (XCFramework) pulled via
# XCRemoteSwiftPackageReference. Xcode's SPM integration auto-creates an
# implicit "Embed & Sign" step for package products that include
# .framework/.xpc bundles — there's no visible PBXCopyFilesBuildPhase in
# the pbxproj. If a future Sparkle release changes its artifact layout or
# Xcode's SPM embedding behavior, the app could build clean and ship
# without the framework, leaving auto-update silently broken on users'
# installs. Hard-fail here so the DMG never packages a broken bundle.
# Audit xcode-project F14.
if [[ ! -d "$APP_DST/Contents/Frameworks/Sparkle.framework" ]]; then
    echo "!! Sparkle.framework missing from $APP_DST/Contents/Frameworks/" >&2
    echo "!! SwiftPM-managed embedding probably failed. Re-run xcodegen and rebuild." >&2
    exit 1
fi

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
    : "${DEVELOPER_ID:?DEVELOPER_ID required for notarization (used to sign the DMG)}"
    # notarytool will happily accept an unsigned DMG when its inner .app
    # is signed, and stapler will attach a ticket to it — but Gatekeeper
    # rejects the resulting DMG at mount time with `source=no usable
    # signature`, and publish-update.sh's verify_dmg refuses to sign the
    # Sparkle appcast for the same reason. Sign the DMG itself before
    # submission so the wrapper carries a Developer ID signature with a
    # secure Apple timestamp; spctl will then accept the stapled DMG.
    # F-S8-004 follow-up.
    echo "==> Signing DMG"
    codesign --sign "$DEVELOPER_ID" --timestamp "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
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
