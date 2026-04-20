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

CURRENT="$(grep -E 'CFBundleShortVersionString:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [[ "$CURRENT" == "$VERSION" ]]; then
    echo "!! project.yml already declares version $VERSION — nothing to bump." >&2
    exit 1
fi

echo "==> Bumping $CURRENT → $VERSION"

# macOS sed requires an empty arg for -i; keep portable.
sed -i '' -E "s/(CFBundleShortVersionString: )\"[^\"]+\"/\\1\"${VERSION}\"/" project.yml

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "!! xcodegen not found — install via 'brew install xcodegen'" >&2
    exit 1
fi
xcodegen generate >/dev/null

# Sanity: Info.plist must now reflect the new version.
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Blackbird/Info.plist 2>/dev/null)"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
    echo "!! Info.plist still reports $PLIST_VERSION after regen. Aborting." >&2
    exit 1
fi

echo "==> Committing + tagging $TAG"

git add project.yml Sources/Blackbird/Info.plist Blackbird.xcodeproj/project.pbxproj 2>/dev/null || true
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
