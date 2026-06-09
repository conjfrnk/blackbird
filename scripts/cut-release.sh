#!/usr/bin/env bash
set -euo pipefail

# Cut a new Blackbird release.
#
# 1. Validates the working tree is clean and on an up-to-date main.
# 2. Bumps CFBundleShortVersionString in project.yml to the given version.
# 3. Regenerates Xcode project so Info.plist carries the new value.
# 4. Commits + tags + pushes.
# 5. The remote tag push triggers .github/workflows/release.yml, which
#    builds / signs / notarizes / publishes the DMG to GitHub Releases.
#
# After this completes and CI finishes (~4 min), run:
#     scripts/publish-update.sh <version>
# to sign the Sparkle appcast locally and push it to the website.
#
# Usage:
#   scripts/cut-release.sh 0.1.1
#   scripts/cut-release.sh v0.1.1   # leading 'v' accepted
#
# Requires: git, gh (optional, for run URL), xcodegen.

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 0.1.1" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Normalise version: strip optional leading 'v'.
RAW_VERSION="$1"
VERSION="${RAW_VERSION#v}"
TAG="v${VERSION}"

# Basic semver shape check (X.Y.Z with optional -pre.N).
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "!! '$VERSION' doesn't look like semver (e.g. 0.1.1 or 0.1.1-rc.1)" >&2
    exit 2
fi

echo "==> Pre-flight checks"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "!! Working tree is dirty. Commit or stash first." >&2
    git status --short >&2
    exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    echo "!! Must be on main to cut a release (you're on $BRANCH)." >&2
    exit 1
fi

git fetch origin main --tags --quiet
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"
if [[ "$LOCAL" != "$REMOTE" ]]; then
    echo "!! main is not up-to-date with origin/main. Pull/push first." >&2
    echo "   local:  $LOCAL" >&2
    echo "   origin: $REMOTE" >&2
    exit 1
fi

if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    echo "!! Tag $TAG already exists locally." >&2
    exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "!! Tag $TAG already exists on origin." >&2
    exit 1
fi

# Accept either `CFBundleShortVersionString: "0.1.4"` or the YAML
# plain-scalar form `CFBundleShortVersionString: 0.1.4` — xcodegen
# writes the quoted form today but an editor autoformat or merge
# conflict resolution can strip the quotes and the old `"[^"]+"`
# regex would silently no-op on the sed pass below. Audit
# scripts-release F7.
extract_yaml_value() {
    local key="$1"
    grep -E "^ *${key}:" project.yml \
        | head -1 \
        | sed -E "s/^ *${key}: *\"?([^\"]+)\"? *$/\\1/"
}
# `|| true` is load-bearing on these command-substitution assignments:
# under `set -euo pipefail`, a missing key makes the grep (and so the
# whole pipeline) exit non-zero, which kills the script AT the
# assignment — the diagnostic branches below were dead code and the
# abort printed nothing. Audit S2-010.
CURRENT="$(extract_yaml_value CFBundleShortVersionString || true)"
if [[ -z "$CURRENT" ]]; then
    echo "!! Cannot find CFBundleShortVersionString in project.yml." >&2
    echo "   Has the key been renamed or the file reorganised?" >&2
    exit 1
fi
if [[ "$CURRENT" == "$VERSION" ]]; then
    echo "!! project.yml already declares version $VERSION — nothing to bump." >&2
    exit 1
fi

# CFBundleVersion is the monotonic build number Sparkle uses for its
# appcast `<sparkle:version>` comparison. Keep it in lockstep with the
# short-version bump so that every release is strictly "newer" than the
# one before it, even when Sparkle is comparing a display version like
# "0.1.2" against an installed CFBundleVersion of "3".
CURRENT_BUILD="$(extract_yaml_value CFBundleVersion || true)"
if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "!! CFBundleVersion in project.yml isn't a plain integer (got '$CURRENT_BUILD')." >&2
    echo "   cut-release.sh only knows how to increment monotonic integers." >&2
    exit 1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "==> Bumping $CURRENT → $VERSION (build $CURRENT_BUILD → $NEW_BUILD)"

# macOS sed requires an empty arg for -i; keep portable.
# Match quoted OR unquoted values; always rewrite to the quoted form
# so the xcodegen-output invariant is restored regardless of how the
# file got edited in between releases.
sed -i '' -E "s/(CFBundleShortVersionString: *)\"?[^\"[:space:]]+\"?/\\1\"${VERSION}\"/" project.yml
sed -i '' -E "s/(CFBundleVersion: *)\"?[^\"[:space:]]+\"?/\\1\"${NEW_BUILD}\"/" project.yml

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "!! xcodegen not found — install via 'brew install xcodegen'" >&2
    exit 1
fi
xcodegen generate >/dev/null

# Sanity: Info.plist must now reflect both the new display version and
# the bumped build number. If either is wrong, abort before tagging.
# Capture-with-status (audit S2-010 + review follow-up): a missing or
# unreadable Info.plist makes PlistBuddy exit non-zero. The bare
# assignment died under `set -e` with the "Aborting." diagnostics
# unreachable; capturing with 2>/dev/null kept PlistBuddy's own error
# invisible (missing-KEY errors go to stderr; missing-FILE notices go
# to stdout and would garble the value). Capture stdout+stderr and
# branch on status so the operator sees the tool's root cause.
PB_STATUS=0
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Blackbird/Info.plist 2>&1)" || PB_STATUS=$?
if [[ $PB_STATUS -ne 0 ]]; then
    echo "!! PlistBuddy could not read CFBundleShortVersionString from Sources/Blackbird/Info.plist:" >&2
    echo "   $PLIST_VERSION" >&2
    exit 1
fi
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
    echo "!! Info.plist still reports '$PLIST_VERSION' after regen (expected '$VERSION'). Aborting." >&2
    exit 1
fi
PB_STATUS=0
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Sources/Blackbird/Info.plist 2>&1)" || PB_STATUS=$?
if [[ $PB_STATUS -ne 0 ]]; then
    echo "!! PlistBuddy could not read CFBundleVersion from Sources/Blackbird/Info.plist:" >&2
    echo "   $PLIST_BUILD" >&2
    exit 1
fi
if [[ "$PLIST_BUILD" != "$NEW_BUILD" ]]; then
    echo "!! Info.plist CFBundleVersion is '$PLIST_BUILD', expected '$NEW_BUILD'. Aborting." >&2
    exit 1
fi

echo "==> Committing + tagging $TAG"

# Surface any git add failure to the operator. Previously this swallowed
# stderr + masked the exit code via `2>/dev/null || true`, which left
# the script falling through to the misleading "Nothing staged to
# commit" branch when the real failure was upstream (permissions, lock
# file, etc). Audit F-S8-002 / SFH-026.
#
# Pass each path independently so a missing optional path (e.g. an
# unchanged Blackbird.xcodeproj/project.pbxproj that git won't add)
# doesn't fail the whole add. project.yml + Info.plist are required;
# the pbxproj line is best-effort because xcodegen sometimes produces
# a byte-identical pbxproj on regen.
git add project.yml Sources/Blackbird/Info.plist
if [[ -e Blackbird.xcodeproj/project.pbxproj ]]; then
    git add Blackbird.xcodeproj/project.pbxproj
fi
# Only commit if there's actually a diff (pbxproj may or may not change).
if [[ -n "$(git diff --cached --name-only)" ]]; then
    git commit -m "release: v${VERSION}"
else
    echo "!! Nothing staged to commit. Aborting before tag." >&2
    exit 1
fi

git tag "$TAG"

echo "==> Pushing main + tag"
git push origin main
git push origin "$TAG"

echo
echo "Tag $TAG pushed. Release workflow should start shortly."
if command -v gh >/dev/null 2>&1; then
    echo "Watch:"
    echo "  gh run watch \$(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
fi
echo
echo "When CI finishes (~4 min), run:"
echo "  scripts/publish-update.sh ${VERSION}"
