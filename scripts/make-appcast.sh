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

FULL=0
if [[ "${1:-}" == "--full" ]]; then
    FULL=1
fi

DMG="$(ls -t dist/Blackbird-*.dmg 2>/dev/null | head -1 || true)"
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
    echo "!! No DMG found in dist/. Run scripts/release.sh first." >&2
    exit 1
fi

DMG_NAME="$(basename "$DMG")"
VERSION="$(echo "$DMG_NAME" | sed -E 's/^Blackbird-(.*)\.dmg$/\1/')"

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
SIG_LINE="$($SIGN_UPDATE_PATH "$DMG")"

# PubDate in RFC 822 format, as Sparkle expects.
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

URL="${APPCAST_BASE_URL%/}/$DMG_NAME"

ITEM=$(cat <<XML
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${URL}"
                 type="application/octet-stream"
                 ${SIG_LINE} />
    </item>
XML
)

if [[ "$FULL" == "1" ]]; then
    cat <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/"
     version="2.0">
  <channel>
    <title>Blackbird</title>
    <link>${APPCAST_BASE_URL%/}/appcast.xml</link>
    <description>Release feed for Blackbird.</description>
    <language>en</language>
${ITEM}
  </channel>
</rss>
XML
else
    echo "$ITEM"
fi
