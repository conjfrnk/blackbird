#!/usr/bin/env bash
set -euo pipefail

# Publish a Sparkle update for a released Blackbird version.
#
# Prerequisite: the GitHub release for vX.Y.Z already exists (i.e.
# scripts/cut-release.sh vX.Y.Z finished and the `Release` workflow is
# green — DMG must be attached to the release).
#
# 1. Downloads the notarized DMG from the GH release into ./dist/.
# 2. Signs it with Sparkle's sign_update (reads private EdDSA key from
#    the local login keychain).
# 3. Regenerates website/appcast.xml with the new entry.
# 4. Deploys website/ to S3 + invalidates CloudFront.
# 5. Commits the updated appcast.xml to main and pushes.
#
# The Sparkle private key never leaves this machine — that's why this
# step stays local rather than being wired into CI.
#
# Usage:
#   scripts/publish-update.sh 0.1.1
#   scripts/publish-update.sh v0.1.1
#
# Requires: curl, git, gh, aws (profile "personal"), Sparkle's sign_update.

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 0.1.1" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

RAW_VERSION="$1"
VERSION="${RAW_VERSION#v}"
TAG="v${VERSION}"

echo "==> Verifying release $TAG exists on GitHub"
if ! gh release view "$TAG" >/dev/null 2>&1; then
    echo "!! No GH release found for $TAG. Has CI finished?" >&2
    echo "   gh run list --workflow=release.yml --limit 3" >&2
    exit 1
fi

DMG_URL="https://github.com/conjfrnk/blackbird/releases/download/${TAG}/Blackbird-${VERSION}.dmg"
DMG_PATH="dist/Blackbird-${VERSION}.dmg"
mkdir -p dist

echo "==> Downloading $DMG_URL"
curl -fsSL -o "$DMG_PATH" "$DMG_URL"
if [[ ! -s "$DMG_PATH" ]]; then
    echo "!! Downloaded DMG is empty." >&2
    exit 1
fi
echo "    $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')  $(wc -c <"$DMG_PATH") bytes"

echo "==> Signing + regenerating website/appcast.xml"
APPCAST_BASE_URL="https://github.com/conjfrnk/blackbird/releases/download/${TAG}" \
  APPCAST_FEED_URL="https://blackbird-terminal.com/appcast.xml" \
  bash scripts/make-appcast.sh --full > website/appcast.xml

echo "==> Deploying website to S3 + CloudFront"
( cd website && bash deploy.sh )

echo "==> Committing appcast.xml"
git add website/appcast.xml
if git diff --cached --quiet; then
    echo "!! website/appcast.xml is unchanged — nothing to commit."
    exit 1
fi
git commit -m "feat(website): signed appcast for ${TAG}"
git push origin main

echo
echo "Done. $TAG is live on blackbird-terminal.com/appcast.xml."
echo "Existing Blackbird installs will pick it up on their next daily poll,"
echo "or via Sparkle → Check for Updates from the app menu."
