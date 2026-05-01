#!/usr/bin/env bash
set -euo pipefail

# Regenerate website/og-image.png (1200x630) from og-image.svg + the
# canonical app icon at design/icon/Blackbird-1024.png.
#
# Two-step build because rsvg-convert sandboxes external <image href>
# loads in 2.62+, so we render the text layer with rsvg-convert and
# composite the icon with ImageMagick.
#
# Requires: rsvg-convert (librsvg), magick (ImageMagick).
# Bump the ?v= query in index.html when the result changes so chat
# previews don't keep serving the old card.

cd "$(dirname "$0")"

ICON="../design/icon/Blackbird-1024.png"
[[ -f "$ICON" ]] || { echo "missing $ICON" >&2; exit 1; }

TMP="$(mktemp -t og-text.XXXXXX.png)"
trap 'rm -f "$TMP"' EXIT

rsvg-convert og-image.svg -o "$TMP"
magick "$TMP" \
  \( "$ICON" -resize 360x360 \) \
  -geometry +140+135 -composite \
  og-image.png

echo "wrote $(pwd)/og-image.png ($(stat -f %z og-image.png) bytes)"
