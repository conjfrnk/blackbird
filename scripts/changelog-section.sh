#!/usr/bin/env bash
set -euo pipefail

# Print the CHANGELOG.md section for one version, from its `## [X.Y.Z]`
# heading up to (not including) the next `## [` heading.
#
# This is the single source of release notes: cut-release.sh refuses to
# tag a version that has no section here, release.yml uses the section
# as the GitHub release body, and publish-update.sh renders it into the
# page the Sparkle appcast links via <sparkle:releaseNotesLink>.
#
# Usage:
#   scripts/changelog-section.sh <version> [path/to/CHANGELOG.md]
#   scripts/changelog-section.sh v0.8.1          # leading 'v' accepted
#
# Exit codes: 0 section printed; 1 no such section; 2 usage / missing file.

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <version> [CHANGELOG.md]" >&2
    exit 2
fi

VERSION="${1#v}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="${2:-$SCRIPT_DIR/../CHANGELOG.md}"

if [[ ! -r "$FILE" ]]; then
    echo "!! $FILE not found or unreadable" >&2
    exit 2
fi

# awk: start printing at the exact `## [VERSION]` heading (the version is
# matched literally, not as a regex, so `0.8.1` can't match `0.8.10`),
# stop at the next `## [` heading, and fail if the heading never appeared.
awk -v v="$VERSION" '
    /^## \[/ {
        if (found) exit
        if (index($0, "## [" v "]") == 1) found = 1
    }
    found { print }
    END { exit found ? 0 : 1 }
' "$FILE" || {
    echo "!! CHANGELOG.md has no '## [$VERSION]' section" >&2
    exit 1
}
