#!/usr/bin/env bash
set -euo pipefail

# Generate a Sparkle appcast <item> snippet for the freshest DMG in ./dist.
#
# Usage:
#   scripts/make-appcast.sh [--full]
#
# Required env:
#   APPCAST_BASE_URL   — URL prefix where the DMG will be hosted, e.g.
#                        https://dl.example.com/blackbird/
#
# Optional env:
#   APPCAST_FEED_URL   — self-URL of the appcast feed. Used as the
#                        <atom:link rel="self"> reference and defaults to
#                        "${APPCAST_BASE_URL}/appcast.xml". Set this when
#                        the feed lives on a different host than the
#                        binaries (e.g. binaries on GitHub Releases but
#                        the feed served from blackbird-terminal.com).
#   APPCAST_SITE_URL   — project homepage URL, used as the RSS
#                        <channel>/<link>. Defaults to
#                        "https://blackbird-terminal.com/". The RSS spec
#                        says <channel>/<link> should be the human-
#                        readable homepage of the feed, not the feed URL.
#   SIGN_UPDATE        — path to Sparkle's sign_update binary. If unset,
#                        the script looks in PATH first, then in the
#                        Xcode DerivedData SPM artifact tree.
#
# The script PRINTS the snippet on stdout — it does not modify any file.
# Redirect to append to a hosted appcast.xml, or paste into one by hand.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

: "${APPCAST_BASE_URL:?APPCAST_BASE_URL must be set (e.g. https://dl.example.com/blackbird/)}"
FEED_URL="${APPCAST_FEED_URL:-${APPCAST_BASE_URL%/}/appcast.xml}"
SITE_URL="${APPCAST_SITE_URL:-https://blackbird-terminal.com/}"

FULL=0
if [[ "${1:-}" == "--full" ]]; then
    FULL=1
fi

# Pick the version-newest DMG, NOT the mtime-newest. A stale-dated
# rebuild of an OLDER version sitting next to the freshly-cut newer
# one would otherwise shadow the real release. Sort lexicographically
# on the version segment using `sort -V` (GNU/BSD versionsort), which
# correctly orders "0.10.0" after "0.9.0" — plain `sort` would not.
# Audit F-S8-008 / SFH-027.
DMG=""
for candidate in $(ls dist/Blackbird-*.dmg 2>/dev/null \
                       | sed -E 's|^dist/Blackbird-(.*)\.dmg$|\1|' \
                       | sort -V); do
    DMG="dist/Blackbird-${candidate}.dmg"
done
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
    echo "!! No DMG found in dist/. Run scripts/release.sh first." >&2
    exit 1
fi

DMG_NAME="$(basename "$DMG")"
VERSION="$(echo "$DMG_NAME" | sed -E 's/^Blackbird-(.*)\.dmg$/\1/')"

# Extract CFBundleVersion from the built app's Info.plist. This is what
# Sparkle compares against the installed CFBundleVersion to decide if an
# update is available; using the display version here (e.g. "0.1.2")
# breaks that comparison against older installs whose build number is a
# plain integer like "1" — Sparkle's component-wise comparator sees
# [0,1,2] < [1] and hides the update. Mount the DMG read-only, read the
# plist, detach. Requires nothing beyond built-in macOS tools.
MOUNT_POINT="$(mktemp -d -t blackbird-dmg)"
# `-owners off` avoids a root-owner warning on read-only mounts; `-nobrowse`
# hides the volume from Finder so this doesn't spam the sidebar.
hdiutil attach "$DMG" -nobrowse -noverify -noautoopen -readonly -owners off \
    -mountpoint "$MOUNT_POINT" >/dev/null
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$MOUNT_POINT/Blackbird.app/Contents/Info.plist")"
hdiutil detach "$MOUNT_POINT" -quiet
rmdir "$MOUNT_POINT" 2>/dev/null || true

if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "!! CFBundleVersion in the shipped app is '$BUILD', not a monotonic integer." >&2
    echo "   Sparkle's comparator requires this to be a strictly-increasing integer" >&2
    echo "   so installs on older builds recognise the update as newer." >&2
    exit 1
fi

# Locate sign_update. Homebrew installs it as `sign_update`; SPM checkout
# puts it under DerivedData.
SIGN_UPDATE_PATH="${SIGN_UPDATE:-}"
if [[ -z "$SIGN_UPDATE_PATH" ]]; then
    if command -v sign_update >/dev/null 2>&1; then
        SIGN_UPDATE_PATH="$(command -v sign_update)"
    else
        CANDIDATE=$(ls -d ~/Library/Developer/Xcode/DerivedData/Blackbird-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update 2>/dev/null | head -1 || true)
        if [[ -n "$CANDIDATE" ]]; then
            SIGN_UPDATE_PATH="$CANDIDATE"
        fi
    fi
fi
if [[ -z "$SIGN_UPDATE_PATH" || ! -x "$SIGN_UPDATE_PATH" ]]; then
    echo "!! sign_update not found. Install with 'brew install sparkle'" >&2
    echo "   or pass SIGN_UPDATE=/path/to/sign_update" >&2
    exit 1
fi

# sign_update emits a line like:
#   sparkle:edSignature="abc…" length="123456"
# Quote SIGN_UPDATE_PATH so a path containing spaces (e.g. a macOS
# developer whose home dir has spaces) still resolves to the executable
# rather than splitting into argv. Audit scripts-release F8.
SIG_LINE="$("$SIGN_UPDATE_PATH" "$DMG")"

# PubDate in RFC 822 format, as Sparkle expects.
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

URL="${APPCAST_BASE_URL%/}/$DMG_NAME"

ITEM=$(cat <<XML
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${URL}"
                 type="application/x-apple-diskimage"
                 ${SIG_LINE} />
    </item>
XML
)

if [[ "$FULL" == "1" ]]; then
    cat <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/"
     xmlns:atom="http://www.w3.org/2005/Atom"
     version="2.0">
  <channel>
    <title>Blackbird</title>
    <link>${SITE_URL}</link>
    <atom:link href="${FEED_URL}" rel="self" type="application/rss+xml" />
    <description>Release feed for Blackbird.</description>
    <language>en</language>
${ITEM}
  </channel>
</rss>
XML
else
    echo "$ITEM"
fi
