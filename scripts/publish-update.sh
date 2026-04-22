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

echo "==> Verifying release $TAG exists on GitHub with an attached DMG"
if ! gh release view "$TAG" >/dev/null 2>&1; then
    echo "!! No GH release found for $TAG. Has CI finished?" >&2
    echo "   gh run list --workflow=release.yml --limit 3" >&2
    exit 1
fi
# `gh release view` passes as soon as the release object exists, but the
# DMG upload happens AFTER the release is created — a publish that races
# past the upload step would download a 404 and write a zero-byte DMG.
# Verify the asset is actually listed before proceeding. Audit
# scripts-release F4.
EXPECTED_DMG="Blackbird-${VERSION}.dmg"
if ! gh release view "$TAG" --json assets --jq '.assets[].name' | \
     grep -Fxq "$EXPECTED_DMG"; then
    echo "!! Release $TAG exists but $EXPECTED_DMG isn't attached yet." >&2
    echo "   CI may still be uploading; retry in a minute." >&2
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

# Ordering matters: commit + push FIRST, then S3 deploy. If the push fails
# (auth hiccup, someone else pushed main, hook rejection), S3 is untouched
# so the live appcast keeps matching the tracked appcast. If the S3 upload
# fails AFTER the push succeeds, a subsequent re-run of this script is
# idempotent: the appcast regenerates to the same content (same DMG bytes,
# same EdDSA signature input), `git diff --cached --quiet` will then say
# "nothing to commit" and we fall through to re-deploying S3 on retry.
echo "==> Committing appcast.xml"
git add website/appcast.xml
if git diff --cached --quiet; then
    echo "==> website/appcast.xml unchanged — skipping commit (assuming retry after S3 failure)"
else
    git commit -m "feat(website): signed appcast for ${TAG}"
fi

echo "==> Pushing to origin main (before S3 deploy — if this fails we stop)"
if ! git push origin main; then
    echo "error: git push origin main failed. S3 was NOT touched." >&2
    echo "error: resolve the push failure and re-run this script." >&2
    exit 1
fi

echo "==> Deploying website to S3 + CloudFront"
if ! ( cd website && bash deploy.sh ); then
    echo "error: S3/CloudFront deploy failed AFTER git push succeeded." >&2
    echo "error: the tracked appcast is now ahead of the live appcast." >&2
    echo "error: re-run this script; the commit step is idempotent and will re-deploy." >&2
    exit 1
fi

echo
echo "Done. $TAG is live on blackbird-terminal.com/appcast.xml."
echo "Existing Blackbird installs will pick it up on their next daily poll,"
echo "or via Sparkle → Check for Updates from the app menu."
