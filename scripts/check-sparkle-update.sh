#!/usr/bin/env bash
set -euo pipefail

# Tell the maintainer when a Sparkle release newer than the pinned one exists.
#
# .github/dependabot.yml has no `swift` ecosystem on purpose (Dependabot's
# Sparkle PRs can never pass ci.yml's xcodegen drift gate), so nothing else
# notices a new release. Sparkle has shipped installer security fixes in
# point releases (2.9.5, 2.9.6), and check-security-posture.sh only enforces
# a fixed floor, so this is the reminder. .github/workflows/
# sparkle-update-check.yml runs it weekly with --open-issue; it also works
# locally.
#
# Usage:
#   scripts/check-sparkle-update.sh                # report only
#   scripts/check-sparkle-update.sh --open-issue   # also file a GitHub issue
#                                                  # (needs an authenticated `gh`)
#
# Environment:
#   BB_SPARKLE_LATEST      treat this as the latest release; skips the network
#   BB_PACKAGE_RESOLVED    Package.resolved to read (default: the checked-in one)
#
# Exit codes: 0 pin is current, or a newer release was reported;
#             1 could not determine a version or file the issue; 2 usage.

OPEN_ISSUE=0
if [[ $# -eq 1 && "$1" == "--open-issue" ]]; then
    OPEN_ISSUE=1
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--open-issue]" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED="${BB_PACKAGE_RESOLVED:-$ROOT/Blackbird.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved}"

# Dotted numeric versions only; anything else (a beta tag, an empty reply)
# stops the run rather than being compared as if it were a release.
is_version() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

# version_gt A B: true when A > B, comparing dotted components numerically.
version_gt() {
    local -a a b
    local i n x y
    IFS=. read -r -a a <<<"$1"
    IFS=. read -r -a b <<<"$2"
    n=${#a[@]}
    if (( ${#b[@]} > n )); then n=${#b[@]}; fi
    for (( i = 0; i < n; i++ )); do
        x=$(( 10#${a[i]:-0} ))
        y=$(( 10#${b[i]:-0} ))
        if (( x > y )); then return 0; fi
        if (( x < y )); then return 1; fi
    done
    return 1
}

if [[ ! -r "$RESOLVED" ]]; then
    echo "!! $RESOLVED not found or unreadable" >&2
    exit 1
fi
# Same extraction as check-security-posture.sh: the version SwiftPM actually
# resolved, not the `from:` floor in project.yml.
PINNED="$(
    awk '
        /"identity" : "sparkle"/ { found = 1; next }
        found && /"version" : / { gsub(/[",]/, "", $NF); print $NF; exit }
    ' "$RESOLVED"
)"
if ! is_version "$PINNED"; then
    echo "!! could not read a Sparkle version from $RESOLVED (got '${PINNED}')" >&2
    exit 1
fi

if [[ -n "${BB_SPARKLE_LATEST:-}" ]]; then
    LATEST="$BB_SPARKLE_LATEST"
else
    # /releases/latest skips drafts and pre-releases.
    if ! LATEST="$(gh api repos/sparkle-project/Sparkle/releases/latest --jq .tag_name)"; then
        echo "!! could not query the latest Sparkle release (is gh installed and authenticated?)" >&2
        exit 1
    fi
fi
LATEST="${LATEST#v}"
if ! is_version "$LATEST"; then
    echo "!! latest Sparkle release tag '${LATEST}' is not a plain dotted version" >&2
    exit 1
fi

if ! version_gt "$LATEST" "$PINNED"; then
    echo "Sparkle $PINNED is current (latest release: $LATEST)."
    exit 0
fi

echo "Sparkle $LATEST is available; Package.resolved pins $PINNED."
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning title=Sparkle update available::Sparkle $LATEST is out; Package.resolved pins $PINNED."
fi

if (( OPEN_ISSUE == 0 )); then
    exit 0
fi

# One issue per release, ever: `--state all` so closing it (bumped, or
# deliberately skipped) does not make the next run file it again.
TITLE="Bump Sparkle to $LATEST"
if ! EXISTING="$(gh issue list --state all --limit 200 --search "\"$TITLE\" in:title" --json title --jq '.[].title')"; then
    echo "!! could not list existing issues" >&2
    exit 1
fi
if grep -Fxq -- "$TITLE" <<<"$EXISTING"; then
    echo "Issue \"$TITLE\" already exists; nothing to file."
    exit 0
fi

BODY="Sparkle $LATEST is out; Package.resolved pins $PINNED.
https://github.com/sparkle-project/Sparkle/releases/tag/$LATEST

Read the release notes first: Sparkle's point releases have carried installer
security fixes (2.9.5, 2.9.6).

To bump (Dependabot cannot: its PR edits only the generated project.pbxproj,
which ci.yml's xcodegen drift gate rejects):

1. Raise \`from:\` under \`packages.Sparkle\` in project.yml to $LATEST.
2. \`xcodegen generate\`.
3. \`xcodebuild -resolvePackageDependencies -project Blackbird.xcodeproj -scheme Blackbird\`
   to refresh Package.resolved (revision and version).
4. Update the Sparkle version mentioned in scripts/check-security-posture.sh.

Filed by .github/workflows/sparkle-update-check.yml. Closing this issue,
bumped or not, stops it being filed again for $LATEST."

gh issue create --title "$TITLE" --body "$BODY"
